'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const vm = require('node:vm');
const { WindowState } = require('../lib/window-state.cjs');

// Execute the real host functions. Electron windows are the seam; no App, pipe,
// or global config is started or changed by these routing/authorization tests.
async function host() {
  const handlers = new Map(), created = [], writes = []; let focused;
  const fakeElectron = {
    app: { getPath: () => path.resolve(__dirname, '../../.scratch/mcp-main-vm'), setPath() {}, setName() {}, requestSingleInstanceLock: () => true, on() {}, whenReady: () => ({ then: () => ({ catch() {} }) }), quit() {} },
    BrowserWindow: { fromWebContents: sender => sender.view, getFocusedWindow: () => focused },
    ipcMain: { on() {}, handle: (name, handler) => handlers.set(name, handler) },
    protocol: { registerSchemesAsPrivileged() {} },
  };
  const context = vm.createContext({
    require(name) {
      if (name === 'electron') return fakeElectron;
      if (name === 'node:fs') return { mkdirSync() {}, readFileSync: () => '0.7.3' };
      if (name === './lib/window-state.cjs') return { WindowState };
      if (name.startsWith('./lib/')) return { Library: class {}, safeName: String, within: () => true, atomicJson: async () => {}, AiService: class {}, McpService: class {}, PhoneService: class {}, MotionService: class {} };
      return require(name);
    },
    __dirname: path.resolve(__dirname, '..'),
    process: { argv: ['node', 'main.cjs'], env: {}, resourcesPath: path.resolve(__dirname, '../resources') },
    Buffer, URL, URLSearchParams, Response, setTimeout, setImmediate, console,
  });
  vm.runInContext(await fs.readFile(path.resolve(__dirname, '../main.cjs'), 'utf8'), context);
  const states = vm.runInContext('states', context), views = vm.runInContext('views', context), active = vm.runInContext('activeDispatch', context);
  let nextId = 0;
  function add(current, held = current ? [current] : []) {
    const id = ++nextId, state = states.add(id); state.current = current; state.held = new Set(held);
    const view = { id, isDestroyed: () => false };
    view.webContents = { view, mainFrame: { url: 'mediacraft://app/index.html' }, send() {}, async executeJavaScript(script) {
      view.request = JSON.parse(JSON.parse(script.slice('window.MediaCraftMCP.handle('.length, -1)));
      if (view.run) await view.run(view.request);
      return JSON.stringify({ result: { window: id } });
    } };
    views.set(id, view); focused ||= view; return view;
  }
  context.__createWindow = async options => { created.push(options); return add(options?.draftId || `fresh-${nextId + 1}`); };
  context.__mcp = { async write(request) { writes.push(request); return { name: request.name }; } };
  vm.runInContext('createWindow=__createWindow;ready=async()=>{};mcp=__mcp', context);
  const dispatch = vm.runInContext('dispatchMcp', context);
  const call = (view, action, params, epoch = states.owner(view.id).epoch) => handlers.get('native:call')({ sender: view.webContents, senderFrame: view.webContents.mainFrame }, { epoch, action, params });
  return { states, views, active, add, created, writes, dispatch, call, focus: view => { focused = view; } };
}

test('main routes only tools/call window changes, uses current bound window, and keeps guide reads bound', async () => {
  const h = await host(), user = h.add('user'), bound = h.add('agent');
  h.states.bind('session', 'agent');
  await h.dispatch({ session: 'session', method: 'tools/call', params: { name: 'get_draft' } }); assert.equal(bound.request.bound, 'agent');
  await h.dispatch({ session: 'session', method: 'tools/list', params: { name: 'create_draft' } }); assert.equal(h.created.length, 0);
  await h.dispatch({ session: 'session', method: 'tools/call', params: { name: 'open_draft', arguments: {} } }); assert.equal(h.created.length, 0);
  await h.dispatch({ session: 'session', method: 'tools/call', params: { name: 'open_draft', arguments: { id: '' } } }); assert.equal(h.created.length, 0);
  const guide = h.add('guide_styles', []); h.states.bind('guide-session', 'guide_styles'); h.focus(user);
  await h.dispatch({ session: 'guide-session', method: 'tools/call', params: { name: 'get_draft' } }); assert.equal(guide.request.bound, 'guide_styles');
  await h.dispatch({ session: 'guide-session', method: 'tools/call', params: { name: 'open_draft', arguments: { id: 'guide_styles' } } }); assert.equal(h.created.length, 0); assert.equal(guide.request.params.name, 'open_draft');
});

test('main create/open selects proper window and rejects a draft held by background AI', async () => {
  const h = await host(), user = h.add('user'), running = h.add('visible', ['visible', 'running']);
  const denied = JSON.parse(await h.dispatch({ session: 'session', method: 'tools/call', params: { name: 'open_draft', arguments: { id: 'running' } } }));
  assert.equal(denied.result.isError, true); assert.equal(h.created.length, 0); assert.equal(running.request, undefined);
  await h.dispatch({ session: 'session', method: 'tools/call', params: { name: 'open_draft', arguments: { id: 'new-draft' } } }); assert.equal(h.created[0].draftId, 'new-draft');
  assert.equal(h.created[0].background, true);
  await h.dispatch({ session: 'session', method: 'tools/call', params: { name: 'create_draft' } }); assert.equal(h.created[1].fresh, true);
  assert.equal(h.created[1].background, true);
  const created = [...h.views.values()].at(-1); assert.equal(created.request.reuseBlank, true); assert.equal(user.request, undefined);
});

test('main export write checks the originating window token and epoch; guide binding checks current draft/session', async () => {
  const h = await host(), a = h.add('a'), b = h.add('b');
  h.active.set(a.id, { session: 'sa', epoch: 1, exportRequest: 'token-a' });
  h.active.set(b.id, { session: 'sb', epoch: 1, exportRequest: 'token-b' });
  const params = { request: 'token-a', name: 'card.png', data: 'aGVsbG8=' };
  assert.ok((await h.call(b, 'mcp/write', params)).__error); assert.equal(h.writes.length, 0);
  assert.ok((await h.call(a, 'mcp/write', params, 0)).__error); assert.equal(h.writes.length, 0);
  assert.equal((await h.call(a, 'mcp/write', params)).name, 'card.png'); assert.equal(h.writes[0].data.toString(), 'hello');
  h.active.delete(a.id); assert.ok((await h.call(a, 'mcp/write', params)).__error);
  const guide = h.add('guide_styles', []); h.active.set(guide.id, { session: 'sg', epoch: 1 });
  assert.equal((await h.call(guide, 'window/bind', { session: 'sg', draftId: 'guide_styles' })).__error, undefined); assert.equal(h.states.bindings.get('sg'), 'guide_styles');
  assert.ok((await h.call(guide, 'window/bind', { session: 'other', draftId: 'guide_styles' })).__error);
  assert.ok((await h.call(guide, 'window/bind', { session: 'sg', draftId: 'a' })).__error);
  guide.webContents.mainFrame.url = 'https://example.test'; assert.ok((await h.call(guide, 'window/bind', { session: 'sg', draftId: 'guide_styles' })).__error);
});

test('main serializes concurrent clients in one window while keeping bind/write authority on each active call', async () => {
  const h = await host(), view = h.add('draft');
  let release, entered;
  const blocked = new Promise(resolve => { release = resolve; }), started = new Promise(resolve => { entered = resolve; });
  const order = [];
  view.run = async request => {
    order.push(request.session);
    assert.equal(h.active.get(view.id).session, request.session);
    assert.equal((await h.call(view, 'window/bind', { session: request.session, draftId: 'draft' })).__error, undefined);
    assert.equal((await h.call(view, 'mcp/write', { request: request.exportRequest, name: 'card.png', data: 'aGVsbG8=' })).__error, undefined);
    if (request.session === 'first') { entered(); await blocked; }
  };
  const first = h.dispatch({ session: 'first', method: 'tools/call', params: { name: 'get_draft' }, exportRequest: 'first-token' });
  await started;
  const second = h.dispatch({ session: 'second', method: 'tools/call', params: { name: 'get_draft' }, exportRequest: 'second-token' });
  await Promise.resolve(); await Promise.resolve();
  assert.deepEqual(order, ['first']); assert.equal(h.active.get(view.id).session, 'first');
  release(); await Promise.all([first, second]);
  assert.deepEqual(order, ['first', 'second']); assert.deepEqual(h.writes.map(write => write.request), ['first-token', 'second-token']);
  assert.equal(h.active.has(view.id), false);
});
