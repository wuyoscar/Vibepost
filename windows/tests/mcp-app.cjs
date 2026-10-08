'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { LineReader } = require('../mcp/app-link.cjs');

async function run({ application, page, data }) {
  const original = await page.evaluate(() => window.mediacraft.drafts.current());
  const status = await page.evaluate(() => window.MediaCraftNative.mcp.status());
  assert.equal(status.available, true); assert.equal(status.enabled, true);
  const config = status.claudeConfig.mcpServers.mediacraft;
  assert.equal(config.env.ELECTRON_RUN_AS_NODE, '1');
  const child = spawn(config.command, config.args, { env: { ...process.env, ...config.env }, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  const reader = new LineReader(child.stdout); let nextId = 0, errors = '';
  child.stderr.on('data', chunk => { errors += chunk; });
  child.stdin.on('error', () => {});
  child.on('error', error => { errors += error.message; });
  async function request(method, params = {}) {
    const id = ++nextId; child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    const deadline = Date.now() + 120000;
    while (Date.now() < deadline) {
      const response = await reader.next(Math.max(1, deadline - Date.now()));
      assert.ok(response, `MCP helper returned no response: ${errors}`);
      if (response.id !== id) continue;
      return response;
    }
    throw new Error(`MCP request timed out: ${method}`);
  }
  async function call(name, args = {}) {
    const response = await request('tools/call', { name, arguments: args });
    assert.equal(response.error, undefined, `${name}: ${JSON.stringify(response.error)}`);
    assert.ok(!response.result.isError, `${name}: ${JSON.stringify(response.result.content)}`);
    const text = response.result.content.find(item => item.type === 'text')?.text;
    try { return JSON.parse(text); } catch { return text; }
  }
  try {
    const initialized = await request('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'Windows MCP App smoke', version: '1' } });
    assert.equal(initialized.result.protocolVersion, '2025-11-25'); assert.equal(initialized.result.serverInfo.name, 'mediacraft');
    const listing = (await request('tools/list')).result.tools;
    assert.equal(listing.length, 30); assert.equal(listing.at(-1).name, 'send_to_phone');
    assert.ok(listing.every(tool => tool.inputSchema.type === 'object' && tool.description));
    assert.ok(!listing.some(tool => tool.name === 'send_to_iphone'));
    assert.deepEqual(listing.find(tool => tool.name === 'export').inputSchema.properties.format.enum, ['zip', 'png', 'long', 'mp4', 'gif']);
    const created = await call('create_draft', { title: 'MCP Windows 核验', markdown: '# MCP 草稿\n\n第一次创建。' });
    assert.ok(created.id); assert.notEqual(created.id, original.id);
    const markdown = '# MCP Windows 核验\n\n这篇由真实 stdio helper 写入。\n\n[[分页]]\n\n## 第二页\n\n导出应写进当前请求指定的文件夹。';
    await call('update_draft', { title: 'MCP Windows 核验', markdown, caption: '真实 MCP 调用核验。\n\n#Windows #Vibepost' });
    const draft = await call('get_draft'); assert.equal(draft.id, created.id); assert.equal(draft.markdown, markdown); assert.match(draft.caption, /真实 MCP/);
    let agent;
    for (const candidate of application.windows()) {
      if (candidate === page || !candidate.url().startsWith('mediacraft://app/index.html')) continue;
      await candidate.waitForFunction(() => window.mediacraft && window.MediaCraftDrafts.currentId(), null, { timeout: 30000 });
      if (await candidate.evaluate(() => window.MediaCraftDrafts.currentId()) === created.id) { agent = candidate; break; }
    }
    assert.ok(agent, 'create_draft must open and bind its own actual window');
    assert.equal((await agent.evaluate(() => window.mediacraft.drafts.current())).markdown, markdown);
    const preserved = await page.evaluate(() => window.mediacraft.drafts.current());
    assert.equal(preserved.id, original.id); assert.equal(preserved.markdown, original.markdown); assert.equal(preserved.title, original.title);
    const directory = await fs.mkdtemp(path.join(path.resolve(data), 'mcp-export-'));
    const png = await call('export', { format: 'png', page: 1, directory });
    const zip = await call('export', { format: 'zip', directory });
    assert.equal(png.files.length, 1); assert.equal(zip.files.length, 1);
    for (const file of [...png.files, ...zip.files]) {
      const relative = path.relative(directory, file); assert.ok(relative && !relative.startsWith('..') && !path.isAbsolute(relative));
      assert.ok((await fs.stat(file)).size > 1000);
    }
    assert.deepEqual((await fs.readFile(png.files[0])).subarray(0, 8), Buffer.from([137,80,78,71,13,10,26,10]));
    assert.equal((await fs.readFile(zip.files[0])).subarray(0, 2).toString(), 'PK');
    const refused = await request('tools/call', { name: 'export', arguments: { format: 'png', page: 1, directory } });
    assert.equal(refused.result.isError, true); assert.match(refused.result.content[0].text, /overwrite: true/);
    assert.equal((await call('get_draft')).id, created.id, 'export does not change bound draft');
    await page.evaluate(() => window.MediaCraftNative.mcp.setEnabled(false));
    const disabled = await request('tools/list'); assert.equal(disabled.error.code, -32603); assert.match(disabled.error.message, /允许外部 Agent 连接/);
    assert.equal((await page.evaluate(() => window.MediaCraftNative.mcp.status())).enabled, false);
    return { tools: listing.length, draftId: created.id, files: [...png.files, ...zip.files], helper: config.args[0], ok: true };
  } finally {
    await page.evaluate(() => window.MediaCraftNative.mcp.setEnabled(false)).catch(() => {});
    if (child.exitCode === null) {
      child.stdin.end();
      await Promise.race([once(child, 'exit'), new Promise(resolve => setTimeout(resolve, 3000))]);
      if (child.exitCode === null) { child.kill(); await once(child, 'exit').catch(() => {}); }
    }
  }
}

module.exports = { run };
