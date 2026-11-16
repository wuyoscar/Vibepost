'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const { AiService } = require('../lib/ai.cjs');
const { resolveProgram } = require('../lib/ai-process.cjs');
const { isPrivate } = require('../lib/ai-images.cjs');
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==', 'base64');
const nativeImage = { createFromBuffer(bytes) { return { isEmpty: () => !bytes.equals(png), getSize: () => ({ width: 1, height: 1 }), resize() { return { toJPEG: () => Buffer.from('fixture jpeg thumbnail') }; } }; } };
const owner = { id: 'window-a', epoch: 0 }, other = { id: 'window-b', epoch: 0 };
const request = (draftId = 'draft-one', backend = 'claude') => ({ draftId, turnId: draftId + '-turn', backend, sessionId: '00000000-0000-4000-8000-000000000001', prompt: '改稿', markdown: '原文', title: '标题', caption: '发布正文', agentsFile: '排版操作手册' });
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(predicate, timeout = 5000) { const end = Date.now() + timeout; while (Date.now() < end) { const value = await predicate(); if (value) return value; await delay(10); } throw new Error('test condition timeout'); }
async function setup(t, extra = {}) {
  const data = await fs.mkdtemp(path.join(path.resolve(__dirname, '..', '..', '.scratch'), 'ai-test-'));
  const log = path.join(data, 'fixture.jsonl'), events = [];
  const service = new AiService({ dataDir: data, nativeImage, emit: (owner, event) => events.push({ owner, event }), exitGraceMs: 200, cancelGraceMs: 50, ...extra, environment: { ...process.env, AI_FIXTURE_LOG: log, ...extra.environment } });
  t.after(async () => { await service.dispose(); await fs.rm(data, { recursive: true, force: true }); });
  await service.setPath(path.join(__dirname, 'ai-fixture.cjs'), 'claude');
  await service.setPath(path.join(__dirname, 'ai-fixture.cjs'), 'codex');
  return { service, data, log, events, messages: async () => (await fs.readFile(log, 'utf8')).trim().split('\n').map(JSON.parse) };
}
test.before(async () => { await fs.mkdir(path.resolve(__dirname, '..', '..', '.scratch'), { recursive: true }); });

test('Claude launch, SDK controls, ownership, edit result, and EOF lifecycle', async t => {
  const { service, events, messages } = await setup(t);
  const job = request(); job.allowedTools = ['Bash(echo:*)', '--dangerous', 'bad\nrule']; job.model = 'sonnet'; job.effort = 'high';
  await service.send(owner, job);
  await waitFor(() => events.find(value => value.event.lines?.some(line => JSON.parse(line).request_id === 'permission')));
  assert.deepEqual(await service.respond(other, { ...job, message: { type: 'control_response', response: { request_id: 'permission', subtype: 'success', response: {} } } }), { ok: true, delivered: false });
  await assert.rejects(service.respond(owner, { ...job, message: { type: 'control_response', response: { request_id: 'forged' } } }), /没有对应/);
  assert.equal((await service.respond(owner, { ...job, message: { type: 'control_response', response: { request_id: 'permission', subtype: 'success', response: { behavior: 'allow' } } } })).delivered, true);
  const exit = await waitFor(() => events.find(value => value.event.type === 'exit'));
  assert.equal(exit.event.status, 0); assert.equal(exit.event.markdown, 'Claude 改稿'); assert.equal(exit.event.title, '新标题'); assert.equal(exit.event.caption, '发布正文');
  assert(events.every(value => value.owner.id === owner.id && value.owner.epoch === 0));
  const recorded = await messages(), launch = recorded.find(value => value.kind === 'launch');
  assert.equal(launch.backgroundDisabled, '1'); assert(launch.temp.startsWith(path.dirname(launch.cwd)));
  for (const [flag, value] of [['--permission-mode', 'acceptEdits'], ['--setting-sources', 'user'], ['--permission-prompt-tool', 'stdio'], ['--model', 'sonnet']]) assert.equal(launch.args[launch.args.indexOf(flag) + 1], value);
  const mcp = JSON.parse(launch.args[launch.args.indexOf('--mcp-config') + 1]); assert.equal(mcp.mcpServers.mediacraft.alwaysLoad, true);
  assert(!launch.args.includes('--dangerous')); assert(!launch.args.includes('bad\nrule'));
  assert(recorded.find(value => value.request?.sdkMcpServers?.[0] === 'mediacraft')); assert(recorded.find(value => value.kind === 'eof'));
  const agents = await fs.readFile(path.join(launch.cwd, 'AGENTS.md'), 'utf8'); assert.match(agents, /排版操作手册/); assert.match(agents, /save_writing_manual/);
});

test('Codex handshake precedes thread opening; sandbox filtering and unrelated completion', async t => {
  const { service, events, messages } = await setup(t);
  const job = request('codex-one', 'codex');
  await service.send(owner, job);
  await waitFor(() => events.some(value => value.event.lines?.some(line => JSON.parse(line).id === 'initialize')));
  await assert.rejects(service.respond(owner, { ...job, message: { id: 'unsafe', method: 'account/login/start' } }), /不支持/);
  await service.respond(owner, { ...job, message: { id: 'thread', method: 'thread/start', params: { model: 'gpt-fixture', developerInstructions: 'test', dynamicTools: [], cwd: 'C:\\', sandbox: 'danger-full-access', approvalPolicy: 'never', config: { unsafe: true } } } });
  await waitFor(() => events.some(value => value.event.lines?.some(line => JSON.parse(line).id === 'thread')));
  await service.respond(owner, { ...job, message: { id: 99, result: { decision: 'decline' } } });
  await service.respond(owner, { ...job, message: { id: 'turn', method: 'turn/start', params: { threadId: 'fixture-thread', input: [{ type: 'text', text: '写作', unsafe: true }, { type: 'image', url: 'secret' }], effort: 'high', cwd: 'C:\\' } } });
  const exit = await waitFor(() => events.find(value => value.event.type === 'exit'));
  assert.equal(exit.event.markdown, 'Codex 改稿'); assert.equal(exit.event.status, 0);
  const recorded = await messages(), methods = recorded.filter(value => value.method).map(value => value.method);
  assert.deepEqual(methods.slice(0, 3), ['initialize', 'initialized', 'thread/start']);
  const thread = recorded.find(value => value.method === 'thread/start');
  assert.equal(thread.params.cwd, path.join(service.root, job.draftId)); assert.equal(thread.params.sandbox, 'workspace-write'); assert.equal(thread.params.approvalPolicy, 'on-request'); assert(!('config' in thread.params));
  const turn = recorded.find(value => value.method === 'turn/start'); assert.deepEqual(turn.params.input, [{ type: 'text', text: '写作' }]); assert(!('cwd' in turn.params));
  assert(!events.some(value => value.event.lines?.some(line => JSON.parse(line).method === 'account/updated')));
  assert(events.some(value => value.event.lines?.some(line => JSON.parse(line).params?.delta === '完成 🐈')));
});

test('Codex model discovery handshakes without creating a model turn', async t => {
  const { service, messages } = await setup(t);
  assert.deepEqual(await service.models('codex'), { ok: true, models: [{ id: 'gpt-fixture', name: 'Fixture', isDefault: true, efforts: ['high', 'low'], defaultEffort: 'high' }] });
  const methods = (await messages()).filter(value => value.method).map(value => value.method);
  assert.deepEqual(methods, ['initialize', 'initialized', 'model/list']);
});

test('one turn per draft; stale owners, close and cancellation stay in their window', async t => {
  const { service, events } = await setup(t, { environment: { AI_FIXTURE_WAIT: '1' } });
  const a = request('draft-a'), b = request('draft-b');
  await service.send(owner, a); await service.send(other, b);
  await assert.rejects(service.send(other, a), /还在回复/);
  assert.equal((await service.cancel(other, { draftId: a.draftId })).cancelled, false);
  await service.workFile(owner, { ...a, markdown: '工具同步' });
  assert.equal((await service.workFile(owner, { draftId: a.draftId, turnId: a.turnId })).markdown, '工具同步');
  await assert.rejects(service.workFile(other, a), /已经结束/);
  await service.closeOwner(owner);
  assert(service.turns.has(b.draftId)); assert(!events.some(value => value.owner.id === owner.id && value.event.type === 'exit'));
  await assert.rejects(service.send(owner, request('stale')), /已经关闭/);
  const refreshed = { ...owner, epoch: 1 }; await service.send(refreshed, request('refreshed'));
  await service.closeOwner(owner); assert(service.turns.has('refreshed'));
  await service.cancel(other, { draftId: b.draftId }); await waitFor(() => events.find(value => value.owner.id === other.id && value.event.type === 'exit'));
});

test('candidate approval is one-use and tied to turn, origin and owner; local directory session scope', async t => {
  const { service, data } = await setup(t, { environment: { AI_FIXTURE_WAIT: '1' } });
  const job = request(); await service.send(owner, job);
  const local = path.join(service.root, job.draftId, 'own.png'), external = path.join(data, 'external.png');
  await fs.writeFile(local, png); await fs.writeFile(external, png); await fs.writeFile(path.join(data, 'next.png'), png);
  const own = await service.candidate(owner, { ...job, source: 'own.png' }); assert.equal(own.width, 1);
  const approval = await service.candidate(owner, { ...job, source: external }); assert.equal(approval.needsApproval, true); assert.match(approval.scope, /^目录 /);
  await assert.rejects(service.candidate(other, { ...job, source: external, approval: approval.approval }), /已经结束/);
  const forged = await service.candidate(owner, { ...job, source: external, approval: 'forged', approved: true }); assert.equal(forged.needsApproval, true);
  const different = await service.candidate(owner, { ...job, source: path.join(data, 'next.png'), approval: approval.approval }); assert.equal(different.needsApproval, true);
  const stored = await service.candidate(owner, { ...job, source: external, approval: approval.approval, session: true }); assert(stored.id);
  assert((await service.candidate(owner, { ...job, source: path.join(data, 'next.png') })).id);
  const file = await service.candidateFile(owner, { draftId: job.draftId, id: stored.id }); assert.equal(file.data, png.toString('base64'));
  await assert.rejects(service.candidateFile(other, { draftId: job.draftId, id: stored.id }), /另一个窗口/);
  await fs.writeFile(path.join(service.root, job.draftId, 'invalid.png'), Buffer.from('not an image'));
  await assert.rejects(service.candidate(owner, { ...job, source: 'invalid.png' }), /不是支持/);
  const huge = Buffer.from(png); huge.writeUInt32BE(100000, 16); huge.writeUInt32BE(100000, 20); await fs.writeFile(path.join(service.root, job.draftId, 'huge.png'), huge);
  await assert.rejects(service.candidate(owner, { ...job, source: 'huge.png' }), /6400 万/);
  await service.remove(owner, { draftId: job.draftId });
  await assert.rejects(fs.stat(path.join(service.root, job.draftId)), { code: 'ENOENT' }); await assert.rejects(fs.stat(path.join(service.root, '.candidates', job.draftId)), { code: 'ENOENT' });
});

async function server(t, handler) {
  const app = http.createServer(handler); await new Promise(resolve => app.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { app.closeAllConnections(); app.close(resolve); }));
  return 'http://127.0.0.1:' + app.address().port;
}
test('remote image does not fetch before approval; cross-site redirect asks again, tokens stay image-specific', async t => {
  let count = 0;
  const final = await server(t, (_req, res) => { count++; res.end(png); });
  const first = await server(t, (_req, res) => { count++; res.writeHead(302, { Location: final + '/image.png' }); res.end(); });
  const { service } = await setup(t, { environment: { AI_FIXTURE_WAIT: '1' } }); const job = request(); await service.send(owner, job);
  const args = { ...job, source: first + '/image.png' };
  const prompt = await service.candidate(owner, args); assert.equal(count, 0); assert(!prompt.scope);
  const redirect = await service.candidate(owner, { ...args, approval: prompt.approval, session: true }); assert.equal(count, 1); assert.equal(redirect.redirect, final + '/image.png'); assert(!redirect.scope);
  const saved = await service.candidate(owner, { ...args, approval: redirect.approval }); assert(saved.id); assert.equal(count, 3);
  assert.equal((await service.candidate(owner, args)).needsApproval, true); assert.equal(count, 3);
});

test('Codex generated image is stored and base64 is stripped from renderer output', async t => {
  const { service, events } = await setup(t, { environment: { AI_FIXTURE_GENERATED: png.toString('base64') } });
  const job = request('images', 'codex'); await service.send(owner, job);
  await waitFor(() => events.some(value => value.event.lines?.some(line => JSON.parse(line).id === 'initialize')));
  await service.respond(owner, { ...job, message: { id: 'thread', method: 'thread/start', params: {} } });
  await waitFor(() => events.some(value => value.event.lines?.some(line => JSON.parse(line).id === 'thread')));
  await service.respond(owner, { ...job, message: { id: 'turn', method: 'turn/start', params: { threadId: 'fixture-thread', input: [{ type: 'text', text: 'fixture' }] } } });
  await waitFor(() => events.find(value => value.event.type === 'exit'));
  const generated = events.flatMap(value => (value.event.lines || []).map(JSON.parse)).find(line => line.params?.item?.type === 'imageGeneration');
  assert.equal(generated.params.item.result, ''); assert.equal(generated.vibepostCandidates[0].width, 1);
  assert.equal((await service.candidateFile(owner, { draftId: job.draftId, id: generated.vibepostCandidates[0].id })).data, png.toString('base64'));
});

test('Claude image API uses only configured environment key, enforces eight images and redacts API errors', async t => {
  let calls = 0, auth;
  const api = await server(t, (req, res) => {
    auth = req.headers.authorization; const parts = []; req.on('data', chunk => parts.push(chunk)); req.on('end', () => {
      calls++; const body = JSON.parse(Buffer.concat(parts));
      assert.equal(req.url, '/v1/images/generations'); assert.equal(body.quality, 'high');
      res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ data: Array.from({ length: body.n }, () => ({ b64_json: png.toString('base64') })) }));
    });
  });
  const { service } = await setup(t, { imageAPI: api, environment: { AI_FIXTURE_WAIT: '1', OPENAI_API_KEY: 'fixture-secret-key' } });
  const job = request(); await service.send(owner, job); const args = { ...job, model: 'gpt-image-fixture', prompt: 'test', count: 4, size: '1024x1536' };
  assert.equal((await service.generateImage(owner, args)).images.length, 4); assert.equal((await service.generateImage(owner, args)).images.length, 4);
  await assert.rejects(service.generateImage(owner, { ...args, count: 1 }), /最多生成 8/); assert.equal(calls, 2); assert.equal(auth, 'Bearer fixture-secret-key');
  const missing = await setup(t, { environment: { AI_FIXTURE_WAIT: '1', OPENAI_API_KEY: '' } }); await missing.service.send(owner, job);
  await assert.rejects(missing.service.generateImage(owner, args), /生图暂不可用/); assert.equal(calls, 2);
});

test('generation cancellation belongs to the initiating window and errors never return the key', async t => {
  let received = false;
  const stalled = await server(t, (_req, _res) => { received = true; });
  const { service } = await setup(t, { imageAPI: stalled, environment: { AI_FIXTURE_WAIT: '1', OPENAI_API_KEY: 'fixture-secret-key' } });
  const job = request(); await service.send(owner, job);
  const args = { ...job, model: 'gpt-image-fixture', prompt: 'test', count: 1, size: '1024x1536' };
  const pending = service.generateImage(owner, args); const rejection = assert.rejects(pending, /已停止生图/);
  await waitFor(() => received);
  assert.equal((await service.generateCancel(other, { draftId: job.draftId })).cancelled, false);
  assert.equal((await service.generateCancel(owner, { draftId: job.draftId })).cancelled, true);
  await rejection; assert(!service.generating.has(job.draftId)); assert.equal(service.turns.get(job.draftId).generated, 0);
  const broken = await server(t, (_req, res) => { res.writeHead(401, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ error: { message: 'bad key fixture-secret-key' } })); });
  service.imageAPI = broken;
  await assert.rejects(service.generateImage(owner, args), error => !error.message.includes('fixture-secret-key') && error.message.includes('…'));
});

test('work file updates are serialized and traversal ids never create directories', async t => {
  const { service } = await setup(t, { environment: { AI_FIXTURE_WAIT: '1' } });
  await assert.rejects(service.send(owner, request('../escape')), /稿子 id 不对/);
  await assert.rejects(service.send(owner, request('CON')), /稿子 id 不对/);
  const job = request(); await service.send(owner, job);
  const writes = Array.from({ length: 10 }, (_, index) => service.workFile(owner, { draftId: job.draftId, turnId: job.turnId, markdown: String(index) }));
  assert.deepEqual((await Promise.all(writes)).map(value => value.markdown), Array.from({ length: 10 }, (_, index) => String(index)));
  assert.equal((await service.workFile(owner, { draftId: job.draftId, turnId: job.turnId })).markdown, '9');
});

test('successful image responses consume quota even when returned bytes cannot be decoded', async t => {
  let calls = 0;
  const api = await server(t, (_req, res) => { calls++; res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ data: [{ b64_json: Buffer.from('invalid image').toString('base64') }] })); });
  const { service } = await setup(t, { imageAPI: api, environment: { AI_FIXTURE_WAIT: '1', OPENAI_API_KEY: 'fixture-secret-key' } });
  const job = request(); await service.send(owner, job);
  const args = { ...job, model: 'gpt-image-fixture', prompt: 'test', count: 4, size: '1024x1536' };
  await assert.rejects(service.generateImage(owner, args), /不是支持/); await assert.rejects(service.generateImage(owner, args), /不是支持/);
  await assert.rejects(service.generateImage(owner, { ...args, count: 1 }), /最多生成 8/); assert.equal(calls, 2);
});

// .cmd 包装脚本只有 Windows 有（里面的路径用反斜杠），在别的系统上不跑
test('npm wrappers resolve literal targets without invoking a shell; unsafe wrapper rejected', { skip: process.platform !== 'win32' }, async t => {
  const { data } = await setup(t); const folder = path.join(data, 'node_modules', '@fixture', 'cli'); await fs.mkdir(folder, { recursive: true });
  const entry = path.join(folder, 'cli.cjs'); await fs.writeFile(entry, '');
  const cmd = path.join(data, 'fixture.cmd'); await fs.writeFile(cmd, '@echo off\n"%_prog%" "%dp0%\\node_modules\\@fixture\\cli\\cli.cjs" %*\n');
  const resolved = await resolveProgram(cmd); assert.deepEqual(resolved.args, [entry]); assert(!/cmd\.exe$/i.test(resolved.executable));
  await fs.writeFile(cmd, '@echo off\ncalc.exe & echo malicious'); await assert.rejects(resolveProgram(cmd), /不能安全解析/);
});

test('private DNS address classification includes IPv4-mapped IPv6', () => {
  for (const value of ['127.0.0.1', '10.1.2.3', '172.16.0.1', '192.168.1.1', '100.64.0.1', '::1', 'fc00::1', 'fe80::1', '::ffff:127.0.0.1', '::ffff:7f00:1']) assert.equal(isPrivate(value), true, value);
  for (const value of ['8.8.8.8', '172.15.0.1', '2606:4700:4700::1111']) assert.equal(isPrivate(value), false, value);
});
