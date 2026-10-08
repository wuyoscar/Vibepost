'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const JSZip = require('jszip');

function setup(platform = 'windows', cards = [false, true]) {
  const saved = [];
  const calls = [];
  const packages = [];
  const controllers = [];
  const canvases = cards.map((live, index) => ({ index, live, toBlob: (callback) => callback(new Blob([`card-${index}`], { type: 'image/png' })) }));
  const native = {
    saveFile: async (blob, name) => { saved.push({ blob, name }); return { name }; },
    livePhoto: async (request) => { calls.push({ native: 'live', request }); return { movie: new Blob(['MOV']), photo: new Blob(['JPG']), metadata: new Blob(['plist']) }; },
    sendToIPhone: async (files, text) => { calls.push({ native: 'airdrop', files, text }); },
    sendToPhone: async (files, text, info) => { calls.push({ native: 'phone', files, text, info }); return { session: 'phone-session', url: 'http://localhost/t/token/', qrcode: 'data:image/png;base64,x', addresses: [], expiresAt: new Date(Date.now() + 600000).toISOString() }; },
    motionVideo: async (request, options) => { calls.push({ native: 'motion', request, options }); return new Blob(['MP4'], { type: request.format === 'gif' ? 'image/gif' : 'video/mp4' }); },
    stopPhoneTransfer: async (id) => calls.push({ native: 'stop', id }),
  };
  if (platform === 'windows') native.capabilities = { phoneTransfer: true, motionExport: ['mp4', 'gif'], airDrop: false, livePhoto: false };
  const context = {
    Blob, AbortController, setTimeout, clearTimeout,
    document: { querySelectorAll: () => [], querySelector: () => null },
    MediaCraftNative: native,
    MediaCraftRender: { pageOf: (canvas) => ({ imageHits: canvas.live ? [{ live: true, imageId: 'live-1', x: 12, y: 15, width: 500, height: 600, radius: 20 }] : [] }) },
    MediaCraftProgress: { begin: () => { const controller = new AbortController(); controllers.push(controller); return { signal: controller.signal, note() {}, step() {}, succeed() {}, fail() {} }; } },
    MediaCraftPhoneTransfer: { open: (result, options) => packages.push({ result, options }) },
    JSZip,
    mediacraft: { drafts: { current: async () => ({ title: '测试', mode: 'cards', caption: '发布正文' }), list: async () => [] }, render: { plainText: async () => '全文' } },
  };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.resolve(__dirname, '../../src/output/output.js'), 'utf8'), context);
  const output = context.MediaCraftOutput.create({ cards: async () => canvases, liveSource: async () => ({ video: new Blob(['source']), videoName: 'source.mov', start: 1, span: 6, speed: 2, cover: 1.5, sound: true, crop: { x: 0.1, y: 0, width: 0.8, height: 1 } }), fontNotice: async () => null, topics: async () => ['旅行'], notify() {} });
  return { output, native, saved, calls, packages, controllers };
}

test('Windows standard exports use MP4 + PNG for motion pages while keeping static page PNG', async () => {
  const { output, saved, calls } = setup();
  await output.exportPng(1);
  let zip = await JSZip.loadAsync(await saved[0].blob.arrayBuffer());
  assert.deepEqual(Object.keys(zip.files).sort(), ['测试-02.mp4', '测试-02.png']);
  assert.equal(calls[0].request.cardWidth, 864);
  assert.equal(calls[0].request.cardHeight, 1152);
  assert.equal(calls[0].request.start, 1);
  assert.equal(calls[0].request.speed, 2);
  await output.exportZip();
  zip = await JSZip.loadAsync(await saved[1].blob.arrayBuffer());
  assert.deepEqual(Object.keys(zip.files).sort(), ['测试-01.png', '测试-02.mp4', '测试-02.png']);
  assert.ok(!calls.some((item) => item.native === 'live'));
});

test('explicit MP4/GIF exports use original page order and exclude static pages', async () => {
  const single = setup();
  const result = await single.output.exportMotion('gif', 1);
  assert.equal(result.filename, '测试-02.gif');
  assert.equal(single.calls[0].request.format, 'gif');
  await assert.rejects(single.output.exportMotion('mp4', 0), /没有动态视频/);
  const all = setup('windows', [true, false, true]);
  await all.output.exportMotion('mp4');
  const zip = await JSZip.loadAsync(await all.saved[0].blob.arrayBuffer());
  assert.deepEqual(Object.keys(zip.files).sort(), ['测试-01.mp4', '测试-03.mp4']);
  assert.ok(all.calls.every((item) => item.native === 'motion'));
});

test('Windows phone transfer hands all files and text to LAN service without claiming copied clipboard', async () => {
  const { output, calls, packages } = setup();
  const result = await output.sendToIPhone();
  const phone = calls.find((item) => item.native === 'phone');
  assert.deepEqual(Array.from(phone.files, (file) => file.name).sort(), ['01.png', '02.mp4', '02.png']);
  assert.equal(phone.text, '发布正文');
  assert.equal(phone.info.title, '测试');
  assert.equal(result.pageCount, 2);
  assert.equal(result.copied, false);
  assert.equal(result.session, 'phone-session');
  assert.equal(packages.length, 1);
  await packages[0].options.stop();
  assert.equal(calls.at(-1).native, 'stop');
});

test('macOS retains original .pvt package and AirDrop behavior when capabilities are absent', async () => {
  const { output, saved, calls } = setup('mac');
  await output.exportPng(1);
  const zip = await JSZip.loadAsync(await saved[0].blob.arrayBuffer());
  assert.ok(zip.file('测试-02.pvt/测试-02.MOV'));
  assert.ok(zip.file('测试-02.pvt/测试-02.JPG'));
  assert.ok(zip.file('测试-02.pvt/metadata.plist'));
  const result = await output.sendToIPhone();
  assert.equal(result.copied, true);
  assert.ok(calls.some((item) => item.native === 'airdrop' && item.text === '发布正文'));
  assert.ok(!calls.some((item) => item.native === 'motion' || item.native === 'phone'));
});
