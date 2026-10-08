'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const dns = require('node:dns/promises');
const net = require('node:net');
const http = require('node:http');
const https = require('node:https');
const { fileURLToPath } = require('node:url');
const { failure } = require('./ai-process.cjs');
const { constants } = require('node:fs');

const BYTE_LIMIT = 20 * 1024 * 1024;
const PIXEL_LIMIT = 64000000;
const TYPES = { png: 'image/png', jpg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp' };
const keyPath = value => process.platform === 'win32' ? value.toLowerCase() : value;
const inside = (base, file) => { const relative = path.relative(keyPath(base), keyPath(file)); return relative !== '' && !relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative); };
const site = url => `${url.protocol}//${url.hostname.toLowerCase()}:${url.port || (url.protocol === 'https:' ? '443' : '80')}`;
function remoteURL(value) {
  let url; try { url = new URL(value); } catch { throw failure('图片网址不对'); }
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.href.length > 2048) throw failure('图片网址不支持、含凭据或超过 2048 个字');
  return url;
}

async function origin(source, directory) {
  if (typeof source !== 'string' || !source.trim()) throw failure('没有给图片的路径或网址');
  source = source.trim();
  if (/^https?:/i.test(source)) { const url = remoteURL(source); return { remote: true, url, key: url.href, scope: site(url), label: '网站 ' + url.origin, needsApproval: true }; }
  let file;
  if (/^file:/i.test(source)) { try { file = fileURLToPath(source); } catch { throw failure('图片文件路径不对'); } }
  else file = source.replace(/^~(?=$|[\\/])/, os.homedir());
  file = path.resolve(directory, file);
  // realpath before approval: a symlink inside the workcopy must not grant reads outside it.
  try { file = await fs.realpath(file); } catch { throw failure('找不到图片文件：' + source); }
  let base; try { base = await fs.realpath(directory); } catch { base = directory; }
  const scope = keyPath(path.dirname(file));
  return { remote: false, file, key: keyPath(file), scope, label: '目录 ' + path.dirname(file), needsApproval: !inside(base, file) };
}

function isPrivate(address) {
  address = address.toLowerCase().split('%')[0];
  const embedded = /^(?:::ffff:)(\d+\.\d+\.\d+\.\d+)$/.exec(address);
  if (embedded) return isPrivate(embedded[1]);
  if (net.isIP(address) === 4) {
    const [a, b] = address.split('.').map(Number);
    return a === 0 || a === 10 || a === 127 || a === 169 && b === 254 || a === 172 && b >= 16 && b <= 31 || a === 192 && b === 168 || a === 100 && b >= 64 && b <= 127 || a >= 224;
  }
  // Normalize IPv6 into bytes, including hex-encoded IPv4 mapped addresses.
  if (net.isIP(address) === 6) {
    let [left, right = ''] = address.split('::');
    const a = left ? left.split(':') : [], b = right ? right.split(':') : [];
    const words = [...a, ...Array(Math.max(0, 8 - a.length - b.length)).fill('0'), ...b].map(word => parseInt(word || '0', 16));
    if (words.slice(0, 5).every(word => word === 0) && words[5] === 65535) return isPrivate(`${words[6] >> 8}.${words[6] & 255}.${words[7] >> 8}.${words[7] & 255}`);
    return words.slice(0, 7).every(word => word === 0) && words[7] <= 1 || (words[0] & 0xfe00) === 0xfc00 || (words[0] & 0xffc0) === 0xfe80 || (words[0] & 0xff00) === 0xff00;
  }
  return true;
}
async function addressFor(url) {
  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  const explicit = net.isIP(host) || host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local');
  const addresses = await dns.lookup(host, { all: true });
  if (!addresses.length || !explicit && addresses.some(entry => isPrivate(entry.address))) throw failure('图片主机指向本机或局域网地址，请直接写那个地址');
  return addresses[0];
}

function requestBytes(url, { method = 'GET', body, headers = {}, signal, limit = BYTE_LIMIT, idleMs = 15000, totalMs = 30000, address } = {}) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const done = (error, result) => { if (settled) return; settled = true; clearTimeout(total); signal?.removeEventListener('abort', abort); error ? reject(error) : resolve(result); };
    const client = url.protocol === 'https:' ? https : http;
    const options = { method, headers, ...(address ? { lookup: (_hostname, options, callback) => callback(null, options?.all ? [address] : address.address, address.family) } : {}) };
    const req = client.request(url, options, response => {
      if (Number(response.headers['content-length']) > limit) { req.destroy(failure('图片超过大小限制')); return; }
      const chunks = []; let length = 0;
      response.on('data', chunk => { length += chunk.length; if (length > limit) req.destroy(failure('图片超过大小限制')); else chunks.push(chunk); });
      response.on('error', error => done(error));
      response.on('end', () => done(null, { status: response.statusCode, headers: response.headers, bytes: Buffer.concat(chunks) }));
    });
    const abort = () => req.destroy(failure('已停止载入或生图'));
    const total = setTimeout(() => req.destroy(failure('图片请求超时')), totalMs);
    req.setTimeout(idleMs, () => req.destroy(failure('图片请求超时')));
    req.on('error', error => done(error));
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) abort();
    req.end(body);
  });
}

async function download(url, allowed, signal) {
  const deadline = Date.now() + 30000;
  for (let hop = 0; hop < 10; hop++) {
    if (signal.aborted) throw failure('已停止载入');
    let timer;
    const remaining = () => Math.max(1, deadline - Date.now());
    if (Date.now() >= deadline) throw failure('图片请求超时');
    let address;
    try { address = await Promise.race([addressFor(url), new Promise((_, reject) => { timer = setTimeout(() => reject(failure('图片地址检查超时')), remaining()); })]); }
    finally { clearTimeout(timer); }
    const response = await requestBytes(url, { signal, address, totalMs: remaining(), headers: { Accept: 'image/*' } });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      if (!response.headers.location) throw failure('图片重定向没有给地址');
      const next = remoteURL(new URL(response.headers.location, url).href);
      if (!allowed.has(site(next))) throw Object.assign(failure('图片重定向到了别的站点'), { redirect: next.href, scope: site(next), label: '网站 ' + next.origin });
      url = next; continue;
    }
    if (response.status < 200 || response.status >= 300) throw failure('下载图片失败（' + response.status + '）');
    return { bytes: response.bytes, name: decodeURIComponent(url.pathname.split('/').pop() || '配图').slice(0, 80) };
  }
  throw failure('图片重定向过多');
}

async function readLocal(file) {
  const handle = await fs.open(file, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
  try {
    const stat = await handle.stat();
    const current = await fs.lstat(file);
    if (!stat.isFile() || current.isSymbolicLink() || stat.dev !== current.dev || stat.ino !== current.ino || stat.size > BYTE_LIMIT) throw failure('图片不是普通文件、文件已更换或超过 20 MB');
    const bytes = await handle.readFile();
    if (bytes.length > BYTE_LIMIT) throw failure('图片超过 20 MB');
    return { bytes, name: path.basename(file).slice(0, 80) };
  } finally { await handle.close(); }
}

// Read dimensions before passing compressed data to the native decoder.
function header(bytes) {
  if (bytes.length > BYTE_LIMIT) throw failure('图片超过 20 MB');
  if (bytes.length >= 24 && bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return { ext: 'png', width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  if (bytes.length >= 10 && /^GIF8[79]a$/.test(bytes.subarray(0, 6).toString())) return { ext: 'gif', width: bytes.readUInt16LE(6), height: bytes.readUInt16LE(8) };
  if (bytes.length >= 30 && bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP') {
    const type = bytes.toString('ascii', 12, 16);
    if (type === 'VP8X') return { ext: 'webp', width: 1 + bytes.readUIntLE(24, 3), height: 1 + bytes.readUIntLE(27, 3) };
    if (type === 'VP8 ' && bytes[23] === 157 && bytes[24] === 1 && bytes[25] === 42) return { ext: 'webp', width: bytes.readUInt16LE(26) & 16383, height: bytes.readUInt16LE(28) & 16383 };
    if (type === 'VP8L' && bytes[20] === 47) { const bits = bytes.readUInt32LE(21); return { ext: 'webp', width: 1 + (bits & 16383), height: 1 + ((bits >>> 14) & 16383) }; }
  }
  if (bytes.length >= 4 && bytes[0] === 255 && bytes[1] === 216) {
    let offset = 2;
    while (offset + 3 < bytes.length) {
      if (bytes[offset++] !== 255) break;
      while (bytes[offset] === 255) offset++;
      const marker = bytes[offset++];
      if ([216, 217, 1].includes(marker) || marker >= 208 && marker <= 215) continue;
      if (offset + 2 > bytes.length) break;
      const length = bytes.readUInt16BE(offset);
      if (length < 2 || offset + length > bytes.length) break;
      if ([192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207].includes(marker) && length >= 7) return { ext: 'jpg', height: bytes.readUInt16BE(offset + 3), width: bytes.readUInt16BE(offset + 5) };
      offset += length;
    }
  }
  throw failure('不是支持的 PNG、JPEG、WebP 或 GIF 图片');
}
async function store(root, draftId, bytes, name, nativeImage, signal) {
  const meta = header(bytes);
  if (!meta.width || !meta.height || meta.width * meta.height > PIXEL_LIMIT) throw failure('图片超过 6400 万像素');
  if (!nativeImage?.createFromBuffer) throw failure('图片解码器暂时不可用', 503);
  const decoded = nativeImage.createFromBuffer(bytes);
  if (decoded.isEmpty()) throw failure('不是能打开的图片');
  const size = decoded.getSize();
  if (!size.width || !size.height || size.width * size.height > PIXEL_LIMIT) throw failure('图片超过 6400 万像素');
  const scale = Math.min(1, 360 / Math.max(size.width, size.height));
  const dimensions = { width: Math.max(1, Math.round(size.width * scale)), height: Math.max(1, Math.round(size.height * scale)) };
  let small = decoded.resize({ ...dimensions, quality: 'good' });
  if (small.toBitmap && nativeImage.createFromBitmap) {
    const bitmap = small.toBitmap();
    if (bitmap.length !== dimensions.width * dimensions.height * 4) throw failure('图片缩略图位图大小不对');
    // NativeImage's BGRA bitmap is premultiplied. Composite transparency onto
    // white before JPEG encoding; transparent PNGs otherwise get a dark matte.
    for (let offset = 0; offset < bitmap.length; offset += 4) {
      const white = 255 - bitmap[offset + 3];
      bitmap[offset] = Math.min(255, bitmap[offset] + white);
      bitmap[offset + 1] = Math.min(255, bitmap[offset + 1] + white);
      bitmap[offset + 2] = Math.min(255, bitmap[offset + 2] + white);
      bitmap[offset + 3] = 255;
    }
    small = nativeImage.createFromBitmap(bitmap, dimensions);
  }
  const thumb = small.toJPEG(82);
  if (!thumb.length) throw failure('图片缩略图生成失败');
  if (signal?.aborted) throw failure('已停止载入');
  const id = crypto.randomUUID();
  const folder = path.join(root, '.candidates', draftId);
  await fs.mkdir(folder, { recursive: true });
  if (signal?.aborted) throw failure('已停止载入');
  const file = path.join(folder, id + '.' + meta.ext);
  await fs.writeFile(file, bytes, { flag: 'wx' });
  if (signal?.aborted) { await fs.rm(file, { force: true }); throw failure('已停止载入'); }
  return { id, name: String(name || '配图').slice(0, 80), width: size.width, height: size.height, thumb: 'data:image/jpeg;base64,' + thumb.toString('base64') };
}
async function candidateFile(root, draftId, id) {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id || '')) throw failure('候选图片 id 不对', 404);
  const folder = path.join(root, '.candidates', draftId);
  for (const ext of Object.keys(TYPES)) {
    try { const { bytes } = await readLocal(path.join(folder, id.toLowerCase() + '.' + ext)); return { type: TYPES[ext], data: bytes.toString('base64') }; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  throw failure('这张候选图已经不在了', 404);
}

module.exports = { BYTE_LIMIT, PIXEL_LIMIT, origin, site, inside, isPrivate, download, readLocal, store, candidateFile, requestBytes };
