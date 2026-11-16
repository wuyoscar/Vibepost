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
  assert.match(html, /图片长按/);
  // iPhone 的 Safari：视频要带时间片段才有第一帧；视频控件的行内样式表不能被 CSP 拦掉，脚本仍然只认 nonce
  assert.match(html, /<video controls playsinline preload="metadata" src="[^"]+files\/0#t=0\.001">/);
  const csp = response.headers.get('content-security-policy');
  assert.match(csp, /default-src 'none'/);
  assert.match(csp, /style-src 'unsafe-inline'/);
  assert.match(csp, /script-src 'nonce-[^']+'/);
  assert.doesNotMatch(csp, /script-src[^;]*unsafe-inline/);
  // 到期时间由页面按手机的时区写成几点几分，不把 UTC 的 ISO 串直接给人看
  assert.match(html, /<time id="expires" datetime="[^"]+Z">/);
  assert.doesNotMatch(html, /链接到期时间：\d{4}-/);
  // App 自带浏览器（微信等）里下载会被拦：有一条默认藏着的提示
  assert.match(html, /<p id="inapp" hidden>/);
  assert.match(html, /MicroMessenger/);
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

// 只有文件头的 PNG：页面按 IHDR 里的宽高认长图
function pngHeader(width, height) {
  const data = Buffer.alloc(33);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(data);
  data.writeUInt32BE(13, 8);
  data.write('IHDR', 12, 'latin1');
  data.writeUInt32BE(width, 16);
  data.writeUInt32BE(height, 20);
  return data.toString('base64');
}

test('long images preview their top instead of shrinking into a sliver', async (t) => {
  const { service } = await setup(t);
  const result = await service.start({ files: [
    { name: '01.png', data: pngHeader(1728, 2304) },
    { name: '长图.png', data: pngHeader(1728, 9000) },
    { name: '照片.jpg', data: Buffer.from('not measured').toString('base64') },
  ] });
  const html = await (await fetch(result.addresses.find((address) => address.includes('127.0.0.1')))).text();
  const articles = html.split('<article>').slice(1);
  assert.equal(articles.length, 3);
  assert.match(articles[0], /^<img loading="lazy" src="[^"]+" alt="01\.png" width="1728" height="2304">/);
  assert.doesNotMatch(articles[0], /class="long"/);
  assert.match(articles[1], /^<div class="long"><img [^>]*width="1728" height="9000"><\/div>/);
  assert.match(articles[1], /长图只预览开头/);
  assert.match(articles[2], /^<img loading="lazy" src="[^"]+" alt="照片\.jpg">/);
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
