'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const transport = require('./ai-process.cjs');
const images = require('./ai-images.cjs');
const { failure } = transport;
const safeId = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,120}$/.test(value) && !/^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i.test(value);
const modelId = value => typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:@/\[\]-]{0,99}$/.test(value);
const effortId = value => typeof value === 'string' && /^[a-z]{1,16}$/.test(value);
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const ownerKey = owner => String(owner.id) + ':' + owner.epoch;
const sameOwner = (a, b) => a.id === b.id && a.epoch === b.epoch;
const sleep = delay => new Promise(resolve => setTimeout(resolve, delay));
const FORWARDED = new Set(['item/started', 'item/completed', 'item/agentMessage/delta', 'error', 'turn/completed']);
const METHODS = new Set(['thread/start', 'thread/resume', 'turn/start', 'turn/interrupt']);
const picked = (value, keys) => Object.fromEntries(Object.entries(value || {}).filter(([key]) => keys.includes(key)));

class AiService {
  constructor({ dataDir, emit = () => {}, nativeImage, environment = process.env, imageAPI = 'https://api.openai.com', exitGraceMs = 10000, cancelGraceMs = 1500, probeTimeoutMs = 10000 } = {}) {
    if (!dataDir || !path.isAbsolute(dataDir)) throw failure('AI 数据目录必须是绝对路径');
    this.root = path.join(dataDir, 'AI');
    this.manuals = path.join(dataDir, '写作手册');
    this.temp = path.join(this.root, '.tmp');
    this.emit = emit; this.nativeImage = nativeImage; this.environment = { ...environment };
    this.imageAPI = imageAPI; this.exitGraceMs = exitGraceMs; this.cancelGraceMs = cancelGraceMs; this.probeTimeoutMs = probeTimeoutMs;
    this.turns = new Map(); this.epochs = new Map(); this.closed = new Set(); this.removing = new Set();
    this.tickets = new Map(); this.scopes = new Map(); this.draftOwners = new Map(); this.jobs = new Map(); this.generating = new Map();
    this.cache = new Map(); this.pendingStatus = new Map(); this.lookupVersions = new Map(); this.settingsQueue = Promise.resolve(); this.operations = new Set(); this.exchanges = new Set(); this.disposed = false;
    this.ready = this._initialize();
  }

  async _initialize() {
    await fs.mkdir(this.temp, { recursive: true });
    const bundled = path.resolve(__dirname, '..', '..', 'src', 'writing-manuals');
    await require('./writing-manuals.cjs').seedWritingManuals(this.manuals, bundled);
  }

  _backend(backend = 'claude') { if (!['claude', 'codex'].includes(backend)) throw failure('不认识的 AI 后端'); return backend; }
  _owner(owner) {
    if (!owner || !['string', 'number'].includes(typeof owner.id) || !Number.isSafeInteger(owner.epoch) || owner.epoch < 0) throw failure('窗口身份不对');
    const normalized = { id: String(owner.id), epoch: owner.epoch };
    if (this.disposed || this.closed.has(ownerKey(normalized)) || owner.epoch < (this.epochs.get(normalized.id) ?? 0)) throw failure('这个窗口已经关闭或重新载入', 409);
    this.epochs.set(normalized.id, normalized.epoch);
    return normalized;
  }
  _current(owner) { return !this.disposed && !this.closed.has(ownerKey(owner)) && this.epochs.get(owner.id) === owner.epoch; }
  _draft(request) { if (!safeId(request?.draftId)) throw failure('稿子 id 不对'); return request.draftId; }
  _turn(owner, request) {
    const active = this.turns.get(this._draft(request));
    return active && active.request.turnId === request.turnId && sameOwner(active.owner, owner) && !active.finished ? active : null;
  }
  _owned(owner, draftId) { const active = this.turns.get(draftId); if (active && !sameOwner(active.owner, owner)) throw failure('这篇稿子的 AI 由另一个窗口发起', 409); }
  _redact(value) {
    let result = String(value || '');
    for (const [key, secret] of Object.entries(this.environment)) if (/(key|token|secret|password)/i.test(key) && typeof secret === 'string' && secret.length >= 8) result = result.split(secret).join('…');
    return result;
  }
  _event(turn, event) { if (this._current(turn.owner)) this.emit({ ...turn.owner }, { draftId: turn.request.draftId, turnId: turn.request.turnId, ...event }); }
  _track(promise) { this.operations.add(promise); promise.finally(() => this.operations.delete(promise)).catch(() => {}); return promise; }

  async _settings() { await this.ready; try { return JSON.parse(await fs.readFile(path.join(this.root, 'settings.json'), 'utf8')); } catch { return {}; } }
  async setPath(value, backend = 'claude') {
    this._backend(backend);
    if (value != null && typeof value !== 'string') throw failure('程序路径不对');
    const update = this.settingsQueue.then(async () => {
      const settings = await this._settings();
      const chosen = (value || '').trim().replace(/^~(?=$|[\\/])/, this.environment.USERPROFILE || require('node:os').homedir());
      if (chosen && !path.isAbsolute(chosen)) throw failure('程序路径必须是绝对路径');
      if (chosen) settings[backend + 'Path'] = chosen; else delete settings[backend + 'Path'];
      await this._atomic(path.join(this.root, 'settings.json'), JSON.stringify(settings, null, 2));
    });
    this.settingsQueue = update.catch(() => {});
    await update;
    return this.status(true, backend);
  }

  async status(refresh = false, backend = 'claude') {
    this._backend(backend); await this.ready;
    if (!refresh && this.cache.has(backend)) return { ok: true, ...this.cache.get(backend).fields };
    if (!refresh && this.pendingStatus.has(backend)) return { ok: true, ...(await this.pendingStatus.get(backend)).fields };
    const revision = (this.lookupVersions.get(backend) || 0) + 1; this.lookupVersions.set(backend, revision);
    const lookup = this._locate(backend); this.pendingStatus.set(backend, lookup);
    const found = await lookup;
    if (revision === this.lookupVersions.get(backend)) { this.cache.set(backend, found); this.pendingStatus.delete(backend); }
    else if (this.pendingStatus.has(backend)) return { ok: true, ...(await this.pendingStatus.get(backend)).fields };
    return { ok: true, ...found.fields };
  }
  async _locate(backend) {
    const fields = { available: false, path: null, version: null, source: null, error: null, reason: null };
    let program, env;
    try {
      const settings = await this._settings();
      program = settings[backend + 'Path'] ? await transport.resolveProgram(settings[backend + 'Path'], this.environment) : await transport.findProgram(backend, this.environment);
      fields.source = settings[backend + 'Path'] ? 'settings' : 'path';
      if (!program) { fields.reason = 'missing'; fields.error = '在 PATH 里没有找到 ' + backend; return { fields }; }
      fields.path = program.path; env = transport.childEnv(this.environment, program.executable, this.temp);
      const result = await transport.run(program, ['--version'], { env, cwd: this.root }, this.probeTimeoutMs);
      if (result.status !== 0 || !result.stdout.trim()) throw failure('退出码 ' + result.status + '：' + this._redact(result.stderr).slice(-300));
      fields.version = result.stdout.trim().split(/\s+/).find(word => /^v?\d+(\.\d+)+/.test(word)) || result.stdout.trim().split(/\s+/)[0];
      if (backend === 'codex') {
        const login = await transport.run(program, ['login', 'status'], { env, cwd: this.root }, this.probeTimeoutMs);
        if (login.status !== 0) { fields.reason = 'login'; fields.error = 'Codex 还没有登录：在终端里运行一次 codex login'; return { fields, program, env }; }
      }
      fields.available = true;
    } catch (error) { fields.reason = error.status === 400 ? 'missing' : 'broken'; fields.error = backend + ' 运行失败：' + this._redact(error.message).slice(0, 300); }
    return { fields, program, env };
  }

  async models(backend = 'claude') {
    this._backend(backend);
    if (backend !== 'codex') return { ok: true, models: [] };
    await this.status(false, backend);
    const located = this.cache.get(backend);
    if (!located?.fields.available) throw failure(located?.fields.error || '找不到 Codex');
    const reply = await this._modelExchange(located);
    if (reply.error) throw failure('没能读出 Codex 模型：' + String(reply.error.message || '出错了'), 500);
    return { ok: true, models: (reply.result?.data || []).flatMap(value => {
      const id = value.id || value.model;
      if (typeof id !== 'string') return [];
      const efforts = (value.supportedReasoningEfforts || []).map(option => typeof option === 'string' ? option : option.reasoningEffort).filter(effortId);
      return [{ id, name: value.displayName || id, isDefault: !!value.isDefault, efforts, defaultEffort: effortId(value.defaultReasoningEffort) ? value.defaultReasoningEffort : null }];
    }) };
  }
  _initializeMessage() { return { id: 'initialize', method: 'initialize', params: { clientInfo: { name: 'vibepost', title: 'Vibepost', version: 'dev' }, capabilities: { experimentalApi: true } } }; }
  _modelExchange(located) {
    return this._track(new Promise((resolve, reject) => {
      const child = transport.launch(located.program, ['app-server'], { env: located.env, cwd: this.root });
      this.exchanges.add(child);
      let done = false, initialized = false;
      const end = (error, reply) => {
        if (done) return;
        done = true; clearTimeout(timer);
        const complete = () => { this.exchanges.delete(child); error ? reject(error) : resolve(reply); };
        // Keep the exchange pending until the process has really exited. Windows
        // keeps the cwd locked while the child lives, including after stdin EOF.
        if (child.exitCode !== null || child.signalCode !== null) complete();
        else { child.once('close', complete); child.stdin.end(); transport.killTree(child, true); }
      };
      const timer = setTimeout(() => end(failure('Codex 模型列表检查超时', 500)), 20000);
      child.stdin.on('error', error => end(failure('Codex 模型列表连接已断开', 500)));
      child.on('error', error => end(failure('Codex 启动失败：' + error.code, 500)));
      child.on('close', () => end(failure('Codex 没有回答模型列表就退出了', 500)));
      child.stderr.resume();
      transport.jsonLines(child.stdout, line => {
        if (line.id === 'initialize') {
          if (line.error) return end(failure('Codex 初始化失败', 500));
          initialized = true;
          child.stdin.write(JSON.stringify({ method: 'initialized' }) + '\n' + JSON.stringify({ id: 'models', method: 'model/list', params: {} }) + '\n');
        } else if (initialized && line.id === 'models') end(null, line);
      }, error => end(error), 4 * 1024 * 1024);
      child.stdin.write(JSON.stringify(this._initializeMessage()) + '\n');
    }));
  }

  _request(fields) {
    this._draft(fields);
    if (typeof fields.turnId !== 'string' || !fields.turnId || fields.turnId.length > 200 || typeof fields.prompt !== 'string' || !fields.prompt || typeof fields.markdown !== 'string') throw failure('AI 请求的字段不对');
    const request = { ...fields, backend: this._backend(fields.backend), title: fields.title || '', caption: fields.caption || '', systemPrompt: fields.systemPrompt || '', agentsFile: String(fields.agentsFile || '').slice(0, 200000), resume: !!fields.resume };
    for (const key of ['title', 'caption', 'systemPrompt']) if (typeof request[key] !== 'string') throw failure('AI 请求的字段不对');
    if (request.backend === 'claude' && !uuid(request.sessionId)) throw failure('Claude Code 的一轮要带 UUID 会话 id');
    if (fields.model != null && !modelId(fields.model)) throw failure('模型 ID 不对');
    if (fields.effort != null && !effortId(fields.effort)) throw failure('推理强度不对');
    request.allowedTools = (Array.isArray(fields.allowedTools) ? fields.allowedTools : []).filter(value => typeof value === 'string' && value.length <= 500 && value && !value.startsWith('-') && !/[\r\n\0]/.test(value));
    return request;
  }

  send(owner, fields) { return this._track(this._send(owner, fields)); }
  async _send(owner, fields) {
    owner = this._owner(owner); const request = this._request(fields);
    if (this.removing.has(request.draftId)) throw failure('这篇稿子正在删除', 409);
    if (this.turns.has(request.draftId)) throw failure('这篇稿子的 AI 还在回复，先停止或等它说完', 409);
    let resolveDone;
    const turn = { request, owner, directory: path.join(this.root, request.draftId), inputOpen: true, cancelled: false, finished: false, stderr: '', inputQueue: Promise.resolve(), outputQueue: Promise.resolve(), fileQueue: Promise.resolve(), pendingReplies: new Set(), context: {}, controllers: new Set(), generated: 0, timers: [], done: new Promise(resolve => { resolveDone = resolve; }), resolveDone };
    this.turns.set(request.draftId, turn); this.draftOwners.set(request.draftId, owner);
    try {
      await this.ready; await this.status(false, request.backend);
      const located = this.cache.get(request.backend);
      if (!located?.fields.available) throw failure(located?.fields.error || '找不到本机 AI');
      if (!this._current(owner) || turn.cancelled || this.removing.has(request.draftId)) throw failure('这个窗口已经关闭或重新载入', 409);
      await this._prepare(turn);
      if (!this._current(owner) || turn.cancelled) throw failure('这个窗口已经关闭或重新载入', 409);
      const env = { ...located.env, ...(request.backend === 'claude' ? { CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '1' } : {}) };
      turn.child = transport.launch(located.program, this._arguments(request), { cwd: turn.directory, env });
      turn.child.stdin.on('error', () => {});
      turn.child.stderr.on('data', chunk => { turn.stderr = (turn.stderr + chunk.toString('utf8')).slice(-8192); });
      transport.jsonLines(turn.child.stdout, line => {
        turn.outputQueue = turn.outputQueue.then(() => this._line(turn, line)).catch(error => { turn.stderr += '\n' + this._redact(error.message); return this._stop(turn); });
      }, error => { turn.stderr += '\n' + error.message; this._stop(turn); });
      turn.child.on('close', (code, signal) => this._finish(turn, code, signal));
      await new Promise((resolve, reject) => { turn.child.once('spawn', resolve); turn.child.once('error', error => reject(failure('AI 程序启动失败：' + error.code, 500))); });
      for (const line of this._opening(request)) await this._write(turn, line);
      if (request.backend === 'codex') turn.timers.push(setTimeout(() => { if (!turn.context.initialized && !turn.finished) { turn.stderr += '\nCodex 初始化超时'; this._stop(turn); } }, 20000));
      return { ok: true };
    } catch (error) {
      if (turn.child) await this._stop(turn);
      else { if (this.turns.get(request.draftId) === turn) this.turns.delete(request.draftId); turn.finished = true; turn.resolveDone(); }
      throw error;
    }
  }
  _arguments(request) {
    if (request.backend === 'codex') return ['app-server'];
    const args = ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--include-partial-messages', '--permission-mode', 'acceptEdits', '--permission-prompt-tool', 'stdio', '--setting-sources', 'user', '--mcp-config', JSON.stringify({ mcpServers: { mediacraft: { type: 'sdk', name: 'mediacraft', alwaysLoad: true } } }), '--allowedTools', 'mcp__mediacraft', ...request.allowedTools];
    if (request.systemPrompt) args.push('--append-system-prompt', request.systemPrompt);
    if (request.model) args.push('--model', request.model);
    if (request.effort) args.push('--effort', request.effort);
    args.push(request.resume ? '--resume' : '--session-id', request.sessionId.toLowerCase());
    return args;
  }
  _opening(request) {
    return request.backend === 'codex' ? [this._initializeMessage()] : [
      { type: 'control_request', request_id: 'mediacraft-initialize', request: { subtype: 'initialize', sdkMcpServers: ['mediacraft'] } },
      { type: 'user', message: { role: 'user', content: [{ type: 'text', text: request.prompt }] } },
    ];
  }
  async _atomic(file, content) {
    const temp = file + '.' + crypto.randomUUID() + '.tmp';
    try { await fs.writeFile(temp, content, { flag: 'wx' }); await fs.rename(temp, file); } finally { await fs.rm(temp, { force: true }); }
  }
  async _prepare(turn) {
    await fs.mkdir(turn.directory, { recursive: true });
    if (!images.inside(await fs.realpath(this.root), await fs.realpath(turn.directory))) throw failure('AI 工作目录不能是目录外的链接');
    for (const [name, content] of [['draft.md', turn.request.markdown], ['title.txt', turn.request.title], ['caption.txt', turn.request.caption]]) await this._atomic(path.join(turn.directory, name), content);
    const folder = path.join(turn.directory, '写作手册');
    // Remove only this draft's copy, after verifying its parent work directory.
    await fs.rm(folder, { recursive: true, force: true }); await fs.mkdir(folder);
    const manualLines = ['## 写作手册', '', '写作手册只管题材、读者、语气与结构；排版看操作手册。用户本条选了多份技能时按用途配合使用；未选时按题材挑选，不自动继承历史消息的选择。全文在当前目录的 写作手册/。', '新建或修改手册请用 save_writing_manual 提议，经用户确认后保存。直接改工作副本里的手册不会保留。', ''];
    for (const name of await fs.readdir(this.manuals)) {
      if (!name.endsWith('.md') || name.includes('\n')) continue;
      const file = path.join(this.manuals, name), stat = await fs.lstat(file);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 2 * 1024 * 1024) continue;
      await fs.copyFile(file, path.join(folder, name)); manualLines.push('- ' + name + '（写作手册/' + name + '）');
    }
    await this._atomic(path.join(turn.directory, 'AGENTS.md'), [turn.request.agentsFile.trimEnd(), manualLines.join('\n')].filter(Boolean).join('\n\n') + '\n');
  }

  _write(turn, line) {
    const promise = turn.inputQueue.then(() => {
      if (!turn.inputOpen || turn.finished || turn.child?.stdin.destroyed) return false;
      return new Promise((resolve, reject) => turn.child.stdin.write(JSON.stringify(line) + '\n', error => error ? reject(failure('AI 回答没能写进程序', 500)) : resolve(true)));
    });
    turn.inputQueue = promise.catch(() => {}); return promise;
  }
  _closeInput(turn) {
    const promise = turn.inputQueue.then(() => { if (turn.inputOpen) { turn.inputOpen = false; turn.child?.stdin.end(); } });
    turn.inputQueue = promise.catch(() => {}); return promise;
  }
  async respond(owner, fields) {
    owner = this._owner(owner); const turn = this._turn(owner, fields);
    if (!turn) return { ok: true, delivered: false };
    const message = fields.message;
    if (!message || typeof message !== 'object' || Array.isArray(message)) throw failure('AI 回应的字段不对');
    let outgoing;
    if (turn.request.backend === 'claude') {
      const id = message.response?.request_id;
      if (message.type !== 'control_response' || !turn.pendingReplies.has(String(id))) throw failure('AI 回应没有对应的控制请求');
      outgoing = message; turn.pendingReplies.delete(String(id));
    } else {
      const id = message.id;
      if (!['string', 'number'].includes(typeof id) || id === 'initialize') throw failure('AI 回应的 id 不对');
      if (typeof message.method !== 'string') {
        if (!turn.pendingReplies.has(String(id)) || !('result' in message || 'error' in message)) throw failure('AI 回应没有对应的服务端请求');
        outgoing = 'result' in message ? { id, result: message.result } : { id, error: message.error }; turn.pendingReplies.delete(String(id));
      } else {
        if (!turn.context.initialized || !METHODS.has(message.method)) throw failure('不支持这个 Codex 请求');
        const params = message.params || {}, method = message.method;
        let kept;
        if (method.startsWith('thread/')) {
          if (turn.context.threadRequest) throw failure('这一轮已经开过线程');
          kept = picked(params, method === 'thread/start' ? ['model', 'developerInstructions', 'dynamicTools'] : ['threadId', 'model', 'developerInstructions']);
          Object.assign(kept, { cwd: turn.directory, sandbox: 'workspace-write', approvalPolicy: 'on-request' });
          if (method === 'thread/resume') { if (typeof kept.threadId !== 'string' || !kept.threadId) throw failure('Codex 线程 id 不对'); kept.excludeTurns = true; }
          if (kept.model != null && !modelId(kept.model)) throw failure('模型 ID 不对');
          turn.context.threadRequest = String(id);
        } else {
          if (typeof params.threadId !== 'string' || !turn.context.thread || params.threadId !== turn.context.thread) throw failure('Codex 线程 id 对不上');
          kept = { threadId: turn.context.thread };
          if (method === 'turn/start') {
            if (turn.context.turnRequest) throw failure('这一轮已经开始');
            kept.input = (Array.isArray(params.input) ? params.input : []).filter(item => item?.type === 'text' && typeof item.text === 'string').map(item => ({ type: 'text', text: item.text }));
            if (!kept.input.length) throw failure('Codex 输入没有文字');
            if (effortId(params.effort)) kept.effort = params.effort;
            turn.context.turnRequest = String(id);
          } else if (turn.context.turn) kept.turnId = turn.context.turn;
        }
        outgoing = { id, method, params: kept };
      }
    }
    return { ok: true, delivered: await this._write(turn, outgoing) };
  }

  async _line(turn, line) {
    if (turn.finished) return;
    let forward = true, finished = false;
    if (turn.request.backend === 'claude') {
      forward = !['control_response', 'keep_alive'].includes(line.type); finished = line.type === 'result';
      if (line.type === 'control_request' && typeof line.request_id === 'string') turn.pendingReplies.add(line.request_id);
      if (line.type === 'control_cancel_request') turn.pendingReplies.delete(line.request_id);
    } else {
      const context = turn.context;
      if (line.method == null) {
        if (line.id === 'initialize' && !line.error) {
          // Finish writing initialized BEFORE publishing the response to the page:
          // its adapter may immediately send thread/start on seeing initialize.
          await this._write(turn, { method: 'initialized' }); context.initialized = true;
        }
        if (String(line.id) === context.threadRequest && line.result?.thread?.id) context.thread = line.result.thread.id;
        if (String(line.id) === context.turnRequest && line.result?.turn?.id) context.turn = line.result.turn.id;
      } else if (line.id != null) turn.pendingReplies.add(String(line.id));
      else {
        forward = FORWARDED.has(line.method);
        const params = line.params || {};
        finished = line.method === 'turn/completed' && (!params.threadId || !context.thread || params.threadId === context.thread) && (!params.turn?.id || !context.turn || params.turn.id === context.turn);
      }
      if (line.method === 'item/completed' && line.params?.item?.type === 'imageGeneration') {
        const item = line.params.item, source = item.savedPath || item.result;
        const controller = new AbortController(); turn.controllers.add(controller);
        line = { ...line, params: { ...line.params, item: { ...item, result: '' } }, vibepostCandidates: [] };
        if (source) {
          try {
            if (this.removing.has(turn.request.draftId) || turn.cancelled) throw failure('已停止载入');
            if (turn.generated >= 8) throw failure('这一轮最多生成 8 张图片');
            turn.generated++;
            const bytes = item.savedPath ? (await images.readLocal(item.savedPath)).bytes : this._base64(item.result);
            line.vibepostCandidates.push(await images.store(this.root, turn.request.draftId, bytes, '生图', this.nativeImage, controller.signal));
          } catch (error) { line.vibepostCandidates.push({ error: error.message }); }
          finally { turn.controllers.delete(controller); }
        }
      }
    }
    if (forward) this._event(turn, { type: 'lines', lines: [JSON.stringify(line)] });
    if (finished) {
      turn.timers.push(setTimeout(() => this._stop(turn, false), this.exitGraceMs));
      await this._closeInput(turn);
    }
  }
  _base64(value) { if (typeof value !== 'string' || value.length > Math.ceil(images.BYTE_LIMIT / 3) * 4 + 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value) || value.length % 4 === 1) throw failure('生成的图片数据不对或超过 20 MB'); return Buffer.from(value, 'base64'); }

  async _safeRead(directory, name) {
    const file = path.join(directory, name);
    try { const stat = await fs.lstat(file); if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 20 * 1024 * 1024) return null; return await fs.readFile(file, 'utf8'); } catch { return null; }
  }
  async _finish(turn, status, signal) {
    if (turn.finishing) return; turn.finishing = true;
    for (const timer of turn.timers) clearTimeout(timer);
    await turn.outputQueue;
    await turn.fileQueue;
    for (const timer of turn.timers) clearTimeout(timer);
    turn.finished = true; turn.inputOpen = false;
    for (const controller of turn.controllers) controller.abort();
    this._forgetTickets(turn);
    const [markdown, title, caption] = await Promise.all(['draft.md', 'title.txt', 'caption.txt'].map(name => this._safeRead(turn.directory, name)));
    if (this.turns.get(turn.request.draftId) === turn) this.turns.delete(turn.request.draftId);
    this._event(turn, { type: 'exit', status, signal, cancelled: turn.cancelled, stderr: this._redact(turn.stderr), markdown, title, caption });
    turn.resolveDone();
  }
  async workFile(owner, fields) {
    owner = this._owner(owner); const turn = this._turn(owner, fields);
    if (!turn) throw failure('这一轮已经结束', 409);
    const operation = turn.fileQueue.then(async () => {
      if (turn.finished || turn.cancelled || !this._current(owner)) throw failure('这一轮已经结束', 409);
      if (fields.markdown !== undefined) { if (typeof fields.markdown !== 'string') throw failure('Markdown 字段不对'); await this._atomic(path.join(turn.directory, 'draft.md'), fields.markdown); }
      const markdown = await this._safeRead(turn.directory, 'draft.md');
      if (markdown === null) throw failure('工作副本读写失败', 500);
      return { ok: true, markdown };
    });
    turn.fileQueue = operation.catch(() => {}); return operation;
  }

  async _stop(turn, cancelled = true) {
    if (cancelled) turn.cancelled = true;
    for (const controller of turn.controllers) controller.abort();
    if (!turn.child || turn.finished) return;
    // Do not let a blocked stdin write delay cancellation. EOF stays ordered
    // after writes, while process-tree termination releases a blocked pipe.
    this._closeInput(turn);
    if (!turn.finished) turn.timers.push(setTimeout(() => transport.killTree(turn.child, true), this.cancelGraceMs));
    await transport.killTree(turn.child);
  }
  async cancel(owner, fields) {
    owner = this._owner(owner); const draft = this._draft(fields), turn = this.turns.get(draft);
    if (!turn || !sameOwner(turn.owner, owner)) return { ok: true, cancelled: false };
    await this._stop(turn); return { ok: true, cancelled: true };
  }

  _forgetTickets(turn) { for (const [token, ticket] of this.tickets) if (ticket.turn === turn) this.tickets.delete(token); }
  _ask(turn, origin, scope, label, allowed, redirect) {
    const approval = crypto.randomUUID(); this.tickets.set(approval, { turn, key: origin.key, scope, allowed: [...allowed] });
    return { ok: true, needsApproval: true, approval, ...(!origin.remote ? { scope: label } : {}), ...(redirect ? { redirect } : {}) };
  }
  candidate(owner, fields) { return this._track(this._candidate(owner, fields)); }
  async _candidate(owner, fields) {
    owner = this._owner(owner); const turn = this._turn(owner, fields);
    if (!turn || turn.cancelled || this.removing.has(fields.draftId)) throw failure('这一轮已经结束', 409);
    const origin = await images.origin(fields.source, turn.directory);
    if (!this._turn(owner, fields) || turn.cancelled) throw failure('这一轮已经结束', 409);
    const permissionsKey = ownerKey(owner) + ':' + fields.draftId;
    const allowed = new Set(this.scopes.get(permissionsKey) || []);
    const ticket = typeof fields.approval === 'string' ? this.tickets.get(fields.approval) : null;
    let redeemed = false;
    if (ticket && ticket.turn === turn && ticket.key === origin.key) {
      this.tickets.delete(fields.approval); redeemed = true;
      ticket.allowed.forEach(scope => allowed.add(scope)); allowed.add(ticket.scope);
      if (fields.session && !origin.remote) { const scopes = this.scopes.get(permissionsKey) || new Set(); scopes.add(ticket.scope); this.scopes.set(permissionsKey, scopes); }
    }
    if (origin.needsApproval && !redeemed && !allowed.has(origin.scope)) return this._ask(turn, origin, origin.scope, origin.label, allowed);
    allowed.add(origin.scope);
    const controller = new AbortController(); turn.controllers.add(controller);
    const promise = (async () => {
      try {
        const loaded = origin.remote ? await images.download(origin.url, allowed, controller.signal) : await images.readLocal(origin.file);
        if (!this._current(owner) || turn.finished || turn.cancelled || this.removing.has(fields.draftId)) controller.abort();
        return { ok: true, ...await images.store(this.root, fields.draftId, loaded.bytes, loaded.name, this.nativeImage, controller.signal) };
      } catch (error) {
        if (error.redirect && !controller.signal.aborted && !turn.finished) return this._ask(turn, origin, error.scope, error.label, allowed, error.redirect);
        throw error;
      } finally { turn.controllers.delete(controller); }
    })();
    this._job(fields.draftId, promise, controller);
    return promise;
  }
  _job(draftId, promise, controller) {
    const record = { promise, controller }, set = this.jobs.get(draftId) || new Set(); set.add(record); this.jobs.set(draftId, set);
    promise.finally(() => { set.delete(record); if (!set.size) this.jobs.delete(draftId); }).catch(() => {});
  }
  async candidateFile(owner, fields) { owner = this._owner(owner); const draftId = this._draft(fields); this._owned(owner, draftId); return { ok: true, ...await images.candidateFile(this.root, draftId, fields.id) }; }

  generateImage(owner, fields) { return this._track(this._generateImage(owner, fields)); }
  async _generateImage(owner, fields) {
    owner = this._owner(owner); const turn = this._turn(owner, fields);
    if (!turn || turn.cancelled || this.removing.has(fields.draftId)) throw failure('这一轮已经结束', 409);
    if (turn.request.backend !== 'claude') throw failure('Codex 请使用它自带的生图工具');
    const prompt = typeof fields.prompt === 'string' ? fields.prompt.trim() : '';
    const size = /^(\d+)x(\d+)$/.exec(fields.size || '');
    if (!modelId(fields.model) || !prompt || prompt.length > 4000 || !Number.isInteger(fields.count) || fields.count < 1 || fields.count > 4 || !size || size.slice(1).some(edge => Number(edge) < 256 || Number(edge) > 3840)) throw failure('生图要求不对：提示词最多 4000 字、张数 1–4、每边 256–3840 像素');
    const key = this.environment.OPENAI_API_KEY;
    if (!key) throw failure('生图暂不可用：请在启动 Vibepost 的环境中配置 OPENAI_API_KEY', 503);
    if (this.generating.has(fields.draftId)) throw failure('这篇稿子正在生图，等生成完或先停止', 409);
    if (turn.generated + fields.count > 8) throw failure('这一轮最多生成 8 张图片');
    turn.generated += fields.count;
    const controller = new AbortController(); turn.controllers.add(controller);
    let providerCompleted = false;
    const job = (async () => {
      try {
        const url = new URL('/v1/images/generations', this.imageAPI);
        if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw failure('生图接口地址不对');
        const body = JSON.stringify({ model: fields.model, prompt, size: fields.size, n: fields.count, quality: 'high' });
        const response = await images.requestBytes(url, { method: 'POST', body, headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + key }, signal: controller.signal, limit: 120 * 1024 * 1024, idleMs: 300000, totalMs: 600000 });
        providerCompleted = response.status >= 200 && response.status < 300;
        let reply; try { reply = JSON.parse(response.bytes.toString('utf8')); } catch { throw failure('生图接口没有返回有效 JSON'); }
        if (response.status < 200 || response.status >= 300) throw failure('OpenAI 生图失败（' + response.status + '）：' + String(reply.error?.message || '接口出错了').split(key).join('…').slice(0, 300));
        const generated = (reply.data || []).slice(0, fields.count);
        if (!generated.length) throw failure('OpenAI 没有返回图片');
        const stored = [];
        for (const [index, entry] of generated.entries()) {
          if (!this._current(owner) || turn.finished || turn.cancelled || this.removing.has(fields.draftId)) controller.abort();
          stored.push(await images.store(this.root, fields.draftId, this._base64(entry.b64_json), '生图 ' + (index + 1), this.nativeImage, controller.signal));
        }
        return { ok: true, images: stored };
      } catch (error) {
        // A successful provider response may already be billed. Decoder or
        // storage failures must not enable an unbounded retry loop this turn.
        if (!providerCompleted) turn.generated -= fields.count;
        if (controller.signal.aborted) throw failure('已停止生图');
        throw failure(this._redact(error.message), error.status || 400);
      }
      finally { turn.controllers.delete(controller); this.generating.delete(fields.draftId); }
    })();
    this.generating.set(fields.draftId, { owner, controller, promise: job }); this._job(fields.draftId, job, controller);
    return job;
  }
  async generateCancel(owner, fields) {
    owner = this._owner(owner); const draftId = this._draft(fields), job = this.generating.get(draftId);
    const cancelled = !!job && sameOwner(job.owner, owner); if (cancelled) job.controller.abort();
    return { ok: true, cancelled };
  }

  remove(owner, fields) { return this._track(this._remove(owner, fields)); }
  async _remove(owner, fields) {
    owner = this._owner(owner); const draftId = this._draft(fields); this._owned(owner, draftId);
    if (this.removing.has(draftId)) throw failure('这篇稿子正在删除', 409);
    this.removing.add(draftId);
    try {
      const turn = this.turns.get(draftId);
      if (turn) { await this._stop(turn); await Promise.race([turn.done, sleep(this.cancelGraceMs * 2 + 3000)]); if (!turn.finished && turn.child) { await transport.killTree(turn.child, true); await turn.done; } }
      const pending = [...(this.jobs.get(draftId) || [])]; pending.forEach(job => job.controller.abort()); await Promise.allSettled(pending.map(job => job.promise));
      for (const [token, ticket] of this.tickets) if (ticket.turn.request.draftId === draftId) this.tickets.delete(token);
      for (const key of this.scopes.keys()) if (key.endsWith(':' + draftId)) this.scopes.delete(key);
      this.draftOwners.delete(draftId);
      await fs.rm(path.join(this.root, draftId), { recursive: true, force: true });
      await fs.rm(path.join(this.root, '.candidates', draftId), { recursive: true, force: true });
      return { ok: true };
    } finally { this.removing.delete(draftId); }
  }
  async closeOwner(owner) {
    if (!owner || !Number.isSafeInteger(owner.epoch)) return;
    owner = { id: String(owner.id), epoch: owner.epoch }; this.closed.add(ownerKey(owner));
    const turns = [...this.turns.values()].filter(turn => sameOwner(turn.owner, owner));
    for (const turn of turns) { this._forgetTickets(turn); await this._stop(turn); }
    for (const key of this.scopes.keys()) if (key.startsWith(ownerKey(owner) + ':')) this.scopes.delete(key);
    for (const [draft, held] of this.draftOwners) if (sameOwner(held, owner)) this.draftOwners.delete(draft);
    await Promise.all(turns.map(turn => Promise.race([turn.done, sleep(this.cancelGraceMs + 2000)])));
  }
  async dispose() {
    if (this.disposed) return;
    this.disposed = true;
    await Promise.all([...this.exchanges].map(child => transport.killTree(child, true)));
    for (const job of this.jobs.values()) for (const entry of job) entry.controller.abort();
    const turns = [...this.turns.values()];
    await Promise.all(turns.map(turn => this._stop(turn)));
    await Promise.all(turns.map(turn => Promise.race([turn.done, sleep(this.cancelGraceMs + 2000)])));
    for (const turn of turns) if (!turn.finished && turn.child) await transport.killTree(turn.child, true);
    await Promise.allSettled([...this.operations]);
    this.tickets.clear(); this.scopes.clear();
  }
}

module.exports = { AiService };
