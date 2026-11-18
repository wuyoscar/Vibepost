'use strict';

// 在 App 里填的接口（AI 设置 ›「接别家的模型」›「接口」）：一家服务商的密钥，或一个 OpenAI 兼容的接口地址加模型名。
// 它们经 OpenCode 使用：起 `opencode acp` 时把这几家写成一段内联配置（环境变量 OPENCODE_CONFIG_CONTENT，OpenCode 把它和
// 用户自己的配置合并），密钥各放进一个只给这个进程的环境变量，配置里只写 {env:…}。用户自己的 OpenCode 配置与凭据不动。
// 存在 <AI 目录>/providers.json。密钥只进不出：页面存的时候给，之后只知道「填了没有」；换了接口地址的那一项不沿用旧密钥。
// Mac 壳的同一份规矩在 macos/Sources/MediaCraftShell/AIProviders.swift。

const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { failure } = require('./ai-process.cjs');

const LIMIT = 20;
const MODEL_LIMIT = 50;
const KEY_PREFIX = 'VIBEPOST_API_KEY_';
const CONFIG_VARIABLE = 'OPENCODE_CONFIG_CONTENT';
const PROVIDER = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const MODEL = /^[A-Za-z0-9][A-Za-z0-9._:@/[\]-]{0,99}$/;

const text = value => (typeof value === 'string' ? value.trim() : '');
const fields = entry => ({ provider: entry.provider, name: entry.name, baseURL: entry.baseURL ?? null, models: entry.models, hasKey: !!entry.key });

function entry(item) {
  if (!item || typeof item !== 'object' || Array.isArray(item)) throw failure('接口的字段不对');
  const provider = text(item.provider);
  if (!PROVIDER.test(provider)) throw failure('服务商不对：「' + provider + '」');
  const name = text(item.name);
  if (!name || [...name].length > 60 || /[\r\n]/.test(name)) throw failure('接口要有个名字（最多 60 个字）');
  const key = text(item.key);
  // eslint-disable-next-line no-control-regex
  if (key.length > 500 || /[\s\u0000-\u001f\u007f]/.test(key)) throw failure('「' + name + '」的密钥不对：不能有空格或换行');
  const address = text(item.baseURL);
  if (!address) return { provider, name, baseURL: null, models: [], key };
  let url; try { url = new URL(address); } catch { url = null; }
  if (!url || address.length > 500 || !['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.search || url.hash) {
    throw failure('「' + name + '」的接口地址不对：要像 https://api.example.com/v1 这样');
  }
  const models = (Array.isArray(item.models) ? item.models : []).map(text).filter(Boolean);
  if (!models.length) throw failure('「' + name + '」要写上至少一个模型名');
  if (models.length > MODEL_LIMIT || new Set(models).size !== models.length) throw failure('「' + name + '」的模型名重复了，或多于 ' + MODEL_LIMIT + ' 个');
  const bad = models.find(model => !MODEL.test(model));
  if (bad) throw failure('模型名不对：「' + bad + '」（不能有空格，最多 100 个字符）');
  return { provider, name, baseURL: address, models, key };
}

// 这一家在 OpenCode 配置里的样子
function block(item, key) {
  if (!item.baseURL) return { options: { apiKey: key } };
  return {
    npm: '@ai-sdk/openai-compatible', name: item.name, options: { baseURL: item.baseURL, apiKey: key },
    models: Object.fromEntries(item.models.map(model => [model, { name: model }])),
  };
}

class AIProviders {
  constructor(root) { this.file = path.join(root, 'providers.json'); this.queue = Promise.resolve(); }

  async _read() {
    try {
      const stored = JSON.parse(await fs.readFile(this.file, 'utf8'));
      return (Array.isArray(stored?.providers) ? stored.providers : []).flatMap(item => (typeof item?.provider === 'string' && typeof item?.name === 'string'
        ? [{ provider: item.provider, name: item.name, baseURL: typeof item.baseURL === 'string' ? item.baseURL : null, models: Array.isArray(item.models) ? item.models.filter(model => typeof model === 'string') : [], key: typeof item.key === 'string' ? item.key : '' }]
        : []));
    } catch { return []; }
  }

  // 给页面的列表：没有密钥，只有 hasKey
  async list() { await this.queue; return (await this._read()).map(fields); }

  // 存整份列表。没带 key 的沿用已存的那把（服务商和接口地址都没变时）
  save(incoming) {
    const update = this.queue.then(async () => {
      if (!Array.isArray(incoming)) throw failure('接口的字段不对');
      if (incoming.length > LIMIT) throw failure('接口最多 ' + LIMIT + ' 个');
      const stored = new Map((await this._read()).map(item => [item.provider, item]));
      const entries = [];
      for (const item of incoming) {
        const next = entry(item);
        if (entries.some(other => other.provider === next.provider)) throw failure('「' + next.name + '」已经有一个了');
        const old = stored.get(next.provider);
        if (!next.key && old && old.baseURL === next.baseURL) next.key = old.key;
        entries.push(next);
      }
      await fs.mkdir(path.dirname(this.file), { recursive: true });
      const temp = this.file + '.' + crypto.randomUUID() + '.tmp';
      // 一开始就只有本人可读（Windows 上这个参数不起作用，靠用户目录自己的权限）
      try { await fs.writeFile(temp, JSON.stringify({ providers: entries }, null, 2), { flag: 'wx', mode: 0o600 }); await fs.rename(temp, this.file); } finally { await fs.rm(temp, { force: true }); }
      return entries.map(fields);
    });
    this.queue = update.catch(() => {});
    return update;
  }

  // 起 OpenCode 时另加的环境变量（内联配置与各家的密钥）和这些密钥本身（出错信息里要打码）。
  // existing：用户环境里原有的 OPENCODE_CONFIG_CONTENT（有的话把我们的服务商并进去，别的原样留着）
  async launch(existing) {
    await this.queue;
    const entries = (await this._read()).filter(item => item.key);
    if (!entries.length) return { env: {}, secrets: [] };
    const env = {}; const providers = {};
    entries.forEach((item, index) => { const variable = KEY_PREFIX + (index + 1); env[variable] = item.key; providers[item.provider] = block(item, '{env:' + variable + '}'); });
    let config = {};
    try { const parsed = JSON.parse(existing || ''); if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) config = parsed; } catch { /* 原来的读不出来：只用我们的 */ }
    const before = config.provider && typeof config.provider === 'object' && !Array.isArray(config.provider) ? config.provider : {};
    env[CONFIG_VARIABLE] = JSON.stringify({ ...config, provider: { ...before, ...providers } });
    return { env, secrets: entries.map(item => item.key) };
  }
}

const redact = (value, secrets) => secrets.reduce((result, secret) => result.split(secret).join('…'), String(value || ''));

module.exports = { AIProviders, CONFIG_VARIABLE, KEY_PREFIX, redact };
