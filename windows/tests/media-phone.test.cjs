'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fsp = require('node:fs/promises');
const path = require('node:path');
const JSZip = require('jszip');
const { PhoneService } = require('../lib/phone.cjs');

async function setup(t, options = {}) {
  const base = path.resolve(__dirname, '../.test-tmp');
  await fsp.mkdir(base, { recursive: true });
  const dir = await fsp.mkdtemp(path.join(base, 'phone-'));
  const service = new PhoneService({ dataDir: dir, ...options });
  t.after(async () => { await service.dispose(); await fsp.rm(dir, { recursive: true, force: true }); });
  return { service, dir };
}

test('phone sessions expose only their explicit files, previews, text, ZIP and byte ranges', async (t) => {
  const { service, dir } = await setup(t);
  const data = Buffer.from('0123456789');
  const result = await service.start({ title: '<script>alert(1)</script>', text: '正文 & 保留\n第二行', topics: ['旅行'], files: [
    { name: '../卡片.mp4', type: 'text/html', data: data.toString('base64') },
    { name: '卡片.png', type: 'image/png', data: data.toString('base64') },
  ] });
  const url = result.addresses.find((address) => address.includes('127.0.0.1'));
  assert.match(result.qrcode, /^data:image\/png;base64,/);
  assert.ok(Date.parse(result.expiresAt) > Date.now());
  const response = await fetch(url);
  const html = await response.text();
  assert.match(html, /<video controls/);
  assert.match(html, /<img loading="lazy"/);
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.match(html, /长按文字/);
  assert.match(html, /保存到相册请使用浏览器/);
  assert.match(response.headers.get('content-security-policy'), /default-src 'none'/);
  const file = await fetch(`${url}files/0`, { headers: { Range: 'bytes=2-5' } });
  assert.equal(file.status, 206);
  assert.equal(file.headers.get('content-type'), 'video/mp4');
  assert.equal(file.headers.get('content-range'), 'bytes 2-5/10');
  assert.equal(await file.text(), '2345');
  assert.equal((await fetch(`${url}files/0`, { headers: { Range: 'bytes=50-' } })).status, 416);
  const head = await fetch(`${url}files/0`, { method: 'HEAD' });
  assert.equal(head.headers.get('content-length'), '10');
  assert.equal(await head.text(), '');
  assert.equal((await fetch(`${url}files/999`)).status, 404);
  assert.equal((await fetch(`${url}files/%2e%2e%2fsecret.txt`)).status, 404);
  assert.equal((await fetch(new URL('/t/wrong/', url))).status, 404);
  assert.equal((await fetch(url, { method: 'POST', body: 'no writes' })).status, 405);
  const bundle = await fetch(`${url}bundle.zip`);
  const zip = await JSZip.loadAsync(await bundle.arrayBuffer());
  assert.equal(await zip.file('正文.txt').async('string'), '正文 & 保留\n第二行');
  assert.ok(Object.keys(zip.files).every((name) => !name.includes('/') && !name.includes('\\')));
  assert.deepEqual(await service.stop(result.session), { stopped: true });
  await assert.rejects(fetch(url));
  assert.deepEqual(await fsp.readdir(path.join(dir, 'phone-transfer')), []);
  assert.deepEqual(await service.stop(result.session), { stopped: false });
});

test('expiry and disposal close servers and delete staged files', async (t) => {
  const { service, dir } = await setup(t, { ttlMs: 500 });
  const result = await service.start({ files: [{ name: 'one.png', data: Buffer.from('test').toString('base64') }] });
  const url = result.addresses.find((address) => address.includes('127.0.0.1'));
  await new Promise((resolve) => setTimeout(resolve, 650));
  await assert.rejects(fetch(url));
  assert.equal(service.sessions.size, 0);
  assert.deepEqual(await fsp.readdir(path.join(dir, 'phone-transfer')), []);
  await service.dispose();
  await assert.rejects(service.start({ files: [{ data: 'dGVzdA==' }] }), /服务已关闭/);
});

test('invalid file payload leaves no staged session', async (t) => {
  const { service, dir } = await setup(t);
  await assert.rejects(service.start({ files: [{ name: 'bad.png', data: '***' }] }), /Base64/);
  assert.equal(service.sessions.size, 0);
  assert.deepEqual(await fsp.readdir(path.join(dir, 'phone-transfer')), []);
});
