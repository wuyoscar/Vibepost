'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const net = require('node:net');
const { spawn } = require('node:child_process');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { once } = require('node:events');
const vm = require('node:vm');
const { McpService, DISABLED, imageInfo } = require('../lib/mcp.cjs');
const { AppLink, LineReader } = require('../mcp/app-link.cjs');
const { MCPServer, LEGACY, SUPPORTED, VERSION_KEY } = require('../mcp/protocol.cjs');

const scratch = path.resolve(__dirname, '../../.scratch/windows-mcp-tests');
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');
async function fixture(t, dispatch = async request => ({ result: request.method === 'manual/get' ? { text: '实际页面操作手册' } : { content: [{ type: 'text', text: request.params.name || 'ok' }] } })) {
  await fs.mkdir(scratch, { recursive: true });
  const directory = await fs.mkdtemp(path.join(scratch, 'case-'));
  const socketPath = process.platform === 'win32' ? `\\\\.\\pipe\\mediacraft-test-${crypto.randomUUID()}` : path.join(directory, 'test.sock');
  const events = [];
  const service = new McpService({ dataDir: directory, socketPath, dispatch, emit: event => events.push(event), executable: process.execPath });
  t.after(async () => {
    await service.dispose();
    const relative = path.relative(scratch, directory);
    assert.ok(relative && !relative.startsWith('..') && !path.isAbsolute(relative));
    await fs.rm(directory, { recursive: true, force: true });
  });
  await service.start();
  return { directory, socketPath, service, events };
}

function stdio(t, directory) {
  const child = spawn(process.execPath, [path.resolve(__dirname, '../mcp/stdio.cjs'), '--data-dir', directory, '--app', process.execPath], { env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' }, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  const reader = new LineReader(child.stdout); let id = 0, errors = '';
  child.stderr.on('data', chunk => { errors += chunk; });
  t.after(async () => { if (child.exitCode === null) { child.stdin.end(); await Promise.race([once(child, 'exit'), new Promise(resolve => setTimeout(resolve, 2000))]); if (child.exitCode === null) child.kill(); } });
  return {
    child, reader, errors: () => errors,
    send(value) { child.stdin.write((typeof value === 'string' ? value : JSON.stringify(value)) + '\n'); },
    async request(method, params = {}) {
      const requestId = ++id; this.send({ jsonrpc: '2.0', id: requestId, method, params });
      const response = await reader.next(15000); assert.ok(response, `No stdio response: ${errors}`); assert.equal(response.id, requestId); return response;
    },
  };
}

test('real stdio negotiates all Swift versions, modern complete results, errors, and tools forwarding', async t => {
  let received;
  const { service, directory } = await fixture(t, async request => {
    if (request.method === 'manual/get') return JSON.stringify({ result: { text: '实际页面操作手册' } });
    received = request;
    return JSON.stringify({ result: request.method === 'tools/list' ? { tools: [{ name: 'get_manual', inputSchema: { type: 'object', properties: {} } }] } : { content: [{ type: 'text', text: '完成' }] } });
  });
  assert.equal(service.status().enabled, false);
  await service.setEnabled(true);
  const client = stdio(t, directory);
  for (const version of LEGACY) {
    const response = await client.request('initialize', { protocolVersion: version });
    assert.equal(response.result.protocolVersion, version); assert.match(response.result.instructions, /实际页面操作手册/);
  }
  assert.equal((await client.request('initialize', { protocolVersion: 'future' })).result.protocolVersion, LEGACY[0]);
  const modern = { _meta: { [VERSION_KEY]: SUPPORTED[0] } };
  const discovery = (await client.request('server/discover', modern)).result;
  assert.deepEqual(discovery.supportedVersions, SUPPORTED); assert.equal(discovery.resultType, 'complete'); assert.equal(discovery._meta['io.modelcontextprotocol/serverInfo'].name, 'mediacraft');
  assert.deepEqual((await client.request('ping')).result, {});
  assert.deepEqual((await client.request('ping', modern)).result, { resultType: 'complete' });
  const unsupported = await client.request('tools/list', { _meta: { [VERSION_KEY]: '1900-01-01' } });
  assert.equal(unsupported.error.code, -32022); assert.deepEqual(unsupported.error.data.supported, SUPPORTED);
  assert.equal((await client.request('resources/list')).error.code, -32601);
  client.send('[{"id":900,"method":"ping"}]'); assert.equal((await client.reader.next(5000)).error.code, -32600);
  client.send('{broken'); assert.equal((await client.reader.next(5000)).error.code, -32700);
  const list = (await client.request('tools/list', modern)).result;
  assert.equal(list.resultType, 'complete'); assert.equal(list.tools[0].name, 'get_manual'); assert.equal(received.params._meta, undefined);
  assert.equal((await client.request('tools/call', { ...modern, name: 'get_manual' })).result.resultType, 'complete');
  assert.equal(service.status().clients, 1); assert.ok(service.status().command.includes('ELECTRON_RUN_AS_NODE=1'));
  assert.match(service.status().command, /^claude mcp add mediacraft --transport stdio --env ELECTRON_RUN_AS_NODE=1 -- /);
  assert.ok(service.status().claudeConfig.mcpServers.mediacraft.args.includes(directory));
  assert.match(service.status().codexConfig, /\[mcp_servers\.mediacraft\]/);
  client.child.stdin.end(); await once(client.child, 'exit'); assert.equal(client.child.exitCode, 0); assert.equal(client.errors(), '');
});

test('authentication, default-off persistence, disable disconnect, and exclusive endpoint ownership', async t => {
  const { service, directory, socketPath } = await fixture(t);
  if (process.platform === 'win32') {
    const tokenPath = service.tokenFile.replace(/'/g, "''");
    const script = `$sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$acl=[System.IO.File]::GetAccessControl('${tokenPath}');[Console]::WriteLine((@{protected=$acl.AreAccessRulesProtected;identities=@($acl.Access|ForEach-Object{$_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value});sid=$sid}|ConvertTo-Json -Compress))`;
    const { stdout } = await promisify(execFile)('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')], { windowsHide: true });
    const acl = JSON.parse(stdout); assert.equal(acl.protected, true); assert.deepEqual(acl.identities, [acl.sid]);
    const pipeName = socketPath.slice('\\\\.\\pipe\\'.length).replace(/'/g, "''");
    // Read six connections, exceeding libuv's initial four pending instances.
    const pipeScript = `$all=@();for($i=0;$i -lt 6;$i++){$pipe=[System.IO.Pipes.NamedPipeClientStream]::new('.','${pipeName}',([System.IO.Pipes.PipeAccessRights]::ReadWrite -bor [System.IO.Pipes.PipeAccessRights]::ReadPermissions),[System.IO.Pipes.PipeOptions]::Asynchronous,[System.Security.Principal.TokenImpersonationLevel]::None,[System.IO.HandleInheritability]::None);try{$pipe.Connect(5000);$a=$pipe.GetAccessControl();$rules=@($a.GetAccessRules($true,$true,[System.Security.Principal.SecurityIdentifier])|ForEach-Object{@{sid=$_.IdentityReference.Value;type=$_.AccessControlType.ToString()}});$all+=,@{protected=$a.AreAccessRulesProtected;rules=$rules}}finally{$pipe.Dispose()}};[Console]::WriteLine((ConvertTo-Json -InputObject $all -Depth 5 -Compress))`;
    const pipeResult = await promisify(execFile)('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(pipeScript, 'utf16le').toString('base64')], { windowsHide: true });
    for (const security of JSON.parse(pipeResult.stdout)) {
      assert.equal(security.protected, true);
      assert.deepEqual(security.rules, [{ sid: 'S-1-5-2', type: 'Deny' }, { sid: acl.sid, type: 'Allow' }]);
    }
  }
  const unauth = net.createConnection(socketPath); const reader = new LineReader(unauth);
  await once(unauth, 'connect'); unauth.write(JSON.stringify({ auth: '汉'.repeat(64) }) + '\n');
  assert.match((await reader.next(5000)).error, /认证失败/);
  const link = new AppLink({ dataDir: directory, launch: () => { throw new Error('must not launch disabled App'); } }); t.after(() => link.close());
  await assert.rejects(link.call('tools/list', {}), /允许外部 Agent 连接/);
  await service.setEnabled(true); await link.call('tools/list', {}); assert.equal(service.status().clients, 1);
  const rival = new McpService({ dataDir: directory, socketPath, dispatch: async () => ({ result: {} }) }); t.after(() => rival.dispose());
  assert.equal((await rival.start()).available, false);
  await rival.dispose(); assert.equal(service.status().available, true);
  await service.setEnabled(false); await assert.rejects(link.call('tools/call', { name: 'update_draft' }), new RegExp(DISABLED.slice(0, 8)));
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(directory, 'mcp.json'))), { allowExternalAgents: false });
  const fresh = new McpService({ dataDir: directory, dispatch: async () => ({ result: {} }) }); assert.equal(fresh.status().enabled, false); await fresh.dispose();
});

test('imports enforce absolute local files, byte/count/total/pixel limits before page dispatch', async t => {
  let received, calls = 0;
  const { service, directory } = await fixture(t, async request => { calls++; received = request; return { result: { content: [{ type: 'text', text: '已插入' }] } }; });
  await service.setEnabled(true);
  const link = new AppLink({ dataDir: directory }); t.after(() => link.close());
  const file = path.join(directory, '图片.png'); await fs.writeFile(file, png);
  const call = paths => link.call('tools/call', { name: 'import_images', arguments: { paths } });
  assert.equal((await call([file])).isError, undefined); assert.equal(received.files[0].type, 'image/png'); assert.deepEqual(Buffer.from(received.files[0].data, 'base64'), png);
  assert.equal((await call(['relative.png'])).isError, true); assert.equal((await call(Array(21).fill(file))).isError, true);
  const huge = path.join(directory, 'huge.png'); const handle = await fs.open(huge, 'w'); await handle.truncate(20 * 1024 * 1024 + 1); await handle.close();
  assert.match((await call([huge])).content[0].text, /20 MB/);
  const pixels = Buffer.from(png); pixels.writeUInt32BE(64000001, 16); await fs.writeFile(path.join(directory, 'pixels.png'), pixels);
  assert.match((await call([path.join(directory, 'pixels.png')])).content[0].text, /6400 万/);
  await fs.writeFile(path.join(directory, 'bad.png'), 'not an image'); assert.equal((await call([path.join(directory, 'bad.png')])).isError, true);
  const padded = Buffer.alloc(16 * 1024 * 1024); png.copy(padded); const batch = path.join(directory, 'batch.png'); await fs.writeFile(batch, padded);
  assert.match((await call(Array(4).fill(batch))).content[0].text, /60 MB/);
  service.prepareImage = () => ({ isEmpty: () => false, getSize: () => ({ width: 64000001, height: 1 }) });
  assert.match((await call([file])).content[0].text, /6400 万/);
  assert.equal(calls, 1, 'rejected imports never reach renderer');
  assert.equal(imageInfo(png).width, 1);
});

test('export tokens only write during originating call, reject traversal/conflicts, and overwrite by explicit option', async t => {
  let service, token, outputs;
  const setup = await fixture(t, async request => {
    token = request.exportRequest;
    const saved = await service.write({ request: token, name: '标题-01.png', data: png });
    outputs = saved;
    await assert.rejects(service.write({ request: token, name: '..\\escape.png', data: png }), error => error.status === 400);
    await assert.rejects(service.write({ request: token, name: 'CON.png', data: png }), error => error.status === 400);
    return { result: { content: [{ type: 'text', text: JSON.stringify({ files: [saved.path] }) }] } };
  });
  service = setup.service; const { directory } = setup;
  await service.setEnabled(true);
  const link = new AppLink({ dataDir: directory }); t.after(() => link.close());
  const call = args => link.call('tools/call', { name: 'export', arguments: { format: 'png', directory, ...args } });
  await call({}); assert.equal(outputs.name, '标题-01.png'); assert.deepEqual(await fs.readFile(outputs.path), png);
  await assert.rejects(service.write({ request: token, name: 'late.png', data: png }), error => error.status === 403);
  await assert.rejects(call({}), /overwrite: true/); await call({ overwrite: true });
  const missing = await call({ directory: path.join(directory, 'missing') }); assert.equal(missing.isError, true);
  assert.equal((await call({ directory: 'relative' })).isError, true);
});

test('disconnect never replays a mutating request; next call reconnects with stable session', async t => {
  let calls = 0, firstSession;
  const { service, directory } = await fixture(t, async request => {
    calls++; firstSession ||= request.session;
    assert.equal(request.session, firstSession);
    if (request.params.name === 'update_draft') { for (const socket of service.clients) socket.destroy(); return { result: { done: true } }; }
    return { result: { done: true } };
  });
  await service.setEnabled(true);
  const link = new AppLink({ dataDir: directory, launch: () => { throw new Error('already running'); } }); t.after(() => link.close());
  await assert.rejects(link.call('tools/call', { name: 'update_draft' }), /可能没有完成/); assert.equal(calls, 1);
  assert.deepEqual(await link.call('tools/call', { name: 'get_draft' }), { done: true }); assert.equal(calls, 2);
  await service.dispose();
  const restarted = new McpService({ dataDir: directory, socketPath: service.socketPath, dispatch: async request => { assert.equal(request.session, firstSession); calls++; return { result: { restarted: true } }; } });
  t.after(() => restarted.dispose()); await restarted.start(); assert.equal(restarted.status().enabled, true);
  assert.deepEqual(await link.call('tools/call', { name: 'get_draft' }), { restarted: true }); assert.equal(calls, 3);
});

test('App startup removes inherited Electron Node mode and passes the requested data directory', async t => {
  const { directory } = await fixture(t);
  const launcher = path.join(directory, 'fake-app.cjs'), record = path.join(directory, 'launch.json');
  await fs.writeFile(launcher, `require('node:fs').writeFileSync(${JSON.stringify(record)},JSON.stringify({argv:process.argv.slice(2),nodeMode:process.env.ELECTRON_RUN_AS_NODE??null}));`);
  const before = process.env.ELECTRON_RUN_AS_NODE; process.env.ELECTRON_RUN_AS_NODE = '1';
  try {
    await new AppLink({ dataDir: directory, executable: process.execPath, appArgs: [launcher] }).startApp();
    let capture;
    for (let attempt = 0; attempt < 40; attempt++) {
      try { capture = JSON.parse(await fs.readFile(record, 'utf8')); break; } catch { await new Promise(resolve => setTimeout(resolve, 50)); }
    }
    assert.deepEqual(capture, { argv: ['--data-dir', directory], nodeMode: null });
  } finally { if (before === undefined) delete process.env.ELECTRON_RUN_AS_NODE; else process.env.ELECTRON_RUN_AS_NODE = before; }
});

test('queued cancellation skips mutation and ping stays responsive', async () => {
  let release; const blocked = new Promise(resolve => { release = resolve; }); const sent = [], calls = [];
  const server = new MCPServer({ link: { async call(method, params) { calls.push(params.name); if (params.name === 'first') await blocked; return { ok: true }; }, async callIfRunning() { return null; }, close() {} }, output: message => sent.push(message) });
  server.receive(JSON.stringify({ id: 1, method: 'tools/call', params: { name: 'first' } }));
  server.receive(JSON.stringify({ id: 2, method: 'tools/call', params: { name: 'must-not-run' } }));
  server.receive(JSON.stringify({ method: 'notifications/cancelled', params: { requestId: 2 } }));
  server.receive(JSON.stringify({ id: 3, method: 'ping' })); assert.equal(sent[0].id, 3);
  release(); await server.close(); assert.deepEqual(calls, ['first']); assert.ok(!sent.some(message => message.id === 2));
});

test('renderer preserves the original 31 Mac tools and exposes Windows phone/motion capabilities', async () => {
  const original = ['get_manual','get_writing_skill','list_writing_manuals','read_writing_manual','save_writing_manual','list_templates','list_drafts','get_draft','create_draft','open_draft','update_draft','set_theme','set_style','set_mode','list_palettes','apply_palette','insert_page_break','remove_page_break','move_section','restyle_block','insert_section','set_card_css','import_images','insert_image','move_image','resize_image','crop_image','get_pages','render_pages','export','send_to_iphone'];
  const source = await fs.readFile(path.resolve(__dirname, '../../src/mcp/tools.js'), 'utf8');
  const dispatcher = await fs.readFile(path.resolve(__dirname, '../../src/mcp/server.js'), 'utf8');
  async function toolList(capabilities) {
    const root = { MediaCraftNative: { capabilities }, MediaCraftAITools: { shared: { reply: text => ({ content: [{ type: 'text', text }] }), json: JSON.stringify, clip: String, anchor: () => ({ type: 'string' }), definitions: () => original.map(name => ({ name, description: name, inputSchema: { type: 'object', properties: {} } })) } }, mediacraft: {}, MediaCraftAI: {}, MediaCraftManual: { document: () => 'manual' } };
    const context = vm.createContext({ window: root, crypto }); vm.runInContext(source, context); vm.runInContext(dispatcher, context);
    return JSON.parse(await root.MediaCraftMCP.handle(JSON.stringify({ method: 'tools/list', session: 'test' }))).result.tools;
  }
  const mac = await toolList(); assert.deepEqual(mac.map(tool => tool.name), original); assert.deepEqual(mac.find(tool => tool.name === 'export').inputSchema.properties.format.enum, ['zip','png','long']);
  const windows = await toolList({ airDrop: false, livePhoto: false, phoneTransfer: true, motionExport: ['mp4','gif'] });
  assert.deepEqual(windows.map(tool => tool.name), [...original.slice(0, -1), 'send_to_phone']);
  assert.deepEqual(windows.find(tool => tool.name === 'export').inputSchema.properties.format.enum, ['zip','png','long','mp4','gif']);
  assert.ok(windows.every(tool => tool.inputSchema.type === 'object'));
});
