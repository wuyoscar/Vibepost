'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function seam() {
  const calls = [];
  const boundaryCalls = [];
  const handlers = new Map();
  let bridge;
  const checkData = (value) => {
    if (value === null || value === undefined || ['string', 'boolean', 'number'].includes(typeof value)) return;
    assert.notEqual(typeof value, 'function', 'binary bridge operations must not carry callbacks');
    assert.ok(!(value instanceof Blob) && typeof value.arrayBuffer !== 'function', 'Blob must remain in the main world');
    assert.ok(!ArrayBuffer.isView(value) && !(value instanceof ArrayBuffer), 'the preload seam expects base64 strings');
    for (const item of Object.values(value)) checkData(item);
  };
  // Use distinct VM contexts and require binary arguments to be serializable.
  // The fixed event-listener methods are the permitted callback exception.
  const proxy = (value, prefix = '') => Object.fromEntries(Object.entries(value).map(([key, item]) => {
    const operation = prefix ? prefix + '.' + key : key;
    if (typeof item === 'function') return [key, (...args) => {
      if (!['onMotion', 'ai.onEvent', 'mcp.onEvent'].includes(operation)) checkData(args);
      boundaryCalls.push({ operation, args });
      return item(...args);
    }];
    return [key, item && typeof item === 'object' ? proxy(item, operation) : item];
  }));
  const electron = {
    contextBridge: { exposeInMainWorld: (_name, value) => { bridge = value; } },
    ipcRenderer: {
      sendSync: () => 1,
      on: (name, handler) => handlers.set(name, handler),
      invoke: async (_channel, request) => {
        checkData(request);
        calls.push(request);
        if (request.action === 'motion/render') {
          handlers.get('native:event')?.({}, { kind: 'motion', event: { job: request.params.job, progress: 0.5 } });
          return { data: Buffer.from('encoded').toString('base64'), type: request.params.format === 'gif' ? 'image/gif' : 'video/mp4' };
        }
        if (request.action === 'phone/start') return { session: 'phone-session', url: 'http://localhost/t/token/' };
        if (request.action === 'save') return { name: request.params.name };
        return { cancelled: true };
      },
    },
  };
  const isolated = vm.createContext({ require: (name) => { assert.equal(name, 'electron'); return electron; }, Buffer, window: {} });
  vm.runInContext(fs.readFileSync(path.resolve(__dirname, '../preload.cjs'), 'utf8'), isolated);
  let counter = 0;
  const window = { __electronBridge: proxy(bridge) };
  const main = vm.createContext({
    window, Blob, Uint8Array, ArrayBuffer, AbortController,
    crypto: { randomUUID: () => 'vm-job-' + (++counter) },
    btoa: (value) => Buffer.from(value, 'latin1').toString('base64'),
    atob: (value) => Buffer.from(value, 'base64').toString('latin1'),
  });
  vm.runInContext(fs.readFileSync(path.resolve(__dirname, '../../src/native-bridge.js'), 'utf8'), main);
  return { native: window.MediaCraftNative, bridge, calls, boundaryCalls };
}

test('main-world Blob conversion cancellation prevents a later preload motion/render job', async () => {
  const { native, bridge, calls, boundaryCalls } = seam();
  let finish;
  const card = new Blob(['card'], { type: 'image/png' });
  Object.defineProperty(card, 'arrayBuffer', { value: () => new Promise((resolve) => { finish = resolve; }) });
  const controller = new AbortController();
  const pending = native.motionVideo({ card, video: new Blob(['video']), format: 'mp4' }, { signal: controller.signal });
  const rejection = assert.rejects(pending, { name: 'AbortError' });
  assert.equal(typeof finish, 'function');
  controller.abort(Object.assign(new Error('已取消'), { name: 'AbortError' }));
  finish(Uint8Array.from(Buffer.from('card')).buffer);
  await rejection;
  assert.equal(calls.length, 1);
  assert.equal(calls[0].action, 'motion/cancel');
  const prepared = boundaryCalls.find((item) => item.operation === 'motionRender').args[0];
  assert.equal(prepared.card, 'Y2FyZA==');
  assert.equal(prepared.video, 'dmlkZW8=');
  assert.equal(prepared.job, calls[0].params.job);
  // Preload rejects the prepared strings using the pending cancel marker, then
  // clears that marker so a later completed request does not inherit it.
  await bridge.motionRender({ job: prepared.job, card: 'Y2FyZA==', video: 'dmlkZW8=', format: 'mp4' });
  assert.equal(calls.at(-1).action, 'motion/render');
});

test('real shared Windows wrapper sends base64 across preload for save, phone, MCP and motion', async () => {
  const { native, bridge, calls, boundaryCalls } = seam();
  const card = new Blob(['card'], { type: 'image/png' });
  const video = new Blob(['video'], { type: 'video/mp4' });
  await native.saveFile(card, 'card.png');
  assert.equal(calls.at(-1).action, 'save');
  assert.equal(calls.at(-1).params.data, 'Y2FyZA==');
  await native.mcp.write('export-request', 'card.png', card);
  assert.equal(calls.at(-1).action, 'mcp/write');
  assert.equal(calls.at(-1).params.data, 'Y2FyZA==');
  await native.sendToPhone([{ name: 'card.png', blob: card }], '正文', { title: '标题' });
  const phone = calls.at(-1);
  assert.equal(phone.action, 'phone/start');
  assert.equal(phone.params.files[0].data, 'Y2FyZA==');
  assert.equal(phone.params.files[0].type, 'image/png');
  assert.equal(phone.params.text, '正文');
  assert.equal(phone.params.title, '标题');
  const progress = [];
  const blob = await native.motionVideo({ card, video, format: 'gif', speed: 2 }, { onProgress: (value) => progress.push(value) });
  const render = calls.at(-1);
  assert.equal(render.action, 'motion/render');
  assert.equal(render.params.card, 'Y2FyZA==');
  assert.equal(render.params.video, 'dmlkZW8=');
  assert.equal(render.params.speed, 2);
  assert.equal(render.epoch, 1);
  assert.equal(blob.type, 'image/gif');
  assert.equal(await blob.text(), 'encoded');
  assert.deepEqual(progress, [0.5]);
  for (const operation of ['saveFile', 'mcp.write', 'sendToPhone', 'motionRender']) assert.ok(boundaryCalls.some((item) => item.operation === operation));
  await assert.rejects(bridge.saveFile(card, 'bad.png'), /转换为 Base64/);
});