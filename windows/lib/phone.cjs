'use strict';

const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const JSZip = require('jszip');
const QRCode = require('qrcode');

const MIME = new Map([
  ['.png', 'image/png'], ['.jpg', 'image/jpeg'], ['.jpeg', 'image/jpeg'],
  ['.gif', 'image/gif'], ['.webp', 'image/webp'], ['.mp4', 'video/mp4'],
  ['.mov', 'video/quicktime'], ['.txt', 'text/plain; charset=utf-8'], ['.zip', 'application/zip'],
]);
const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function fileName(name, index) {
  const clean = String(name || '').replace(/[\\/:*?"<>|\x00-\x1f]/g, '-').replace(/^[.\s]+|[.\s]+$/g, '').slice(0, 140);
  return clean || `file-${index + 1}`;
}

function addresses(port, token) {
  const ips = new Set();
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const item of entries || []) if ((item.family === 'IPv4' || item.family === 4) && !item.internal) ips.add(item.address);
  }
  return [...ips, '127.0.0.1'].map((ip) => `http://${ip}:${port}/t/${token}/`);
}

// PNG 的宽高（IHDR），别的格式不量：只用来认出长图、给预览留好位置
function pngSize(data) {
  if (data.length < 24 || data.readUInt32BE(0) !== 0x89504e47 || data.toString('latin1', 12, 16) !== 'IHDR') return null;
  const width = data.readUInt32BE(16);
  const height = data.readUInt32BE(20);
  return width && height ? { width, height } : null;
}

const LONG_RATIO = 2.2; // 高超过宽这么多倍算长图：预览只露开头一截，不把整张压成一条细线

function page({ title, text, topics, files, prefix, expiresAt, nonce }) {
  const rows = files.map((file, index) => {
    const href = `${prefix}files/${index}`;
    const size = file.width && file.height ? ` width="${file.width}" height="${file.height}"` : '';
    const long = file.width && file.height / file.width > LONG_RATIO;
    const image = `<img loading="lazy" src="${href}" alt="${escapeHtml(file.name)}"${size}>`;
    // #t=0.001：iPhone 的 Safari 不自己取第一帧，不加就是一块白
    const preview = file.type.startsWith('image/') ? (long ? `<div class="long">${image}</div><p class="notice">长图只预览开头，下载或长按保存的是完整的一张。</p>` : image)
      : file.type.startsWith('video/') ? `<video controls playsinline preload="metadata" src="${href}#t=0.001"></video>` : '';
    return `<article>${preview}<a class="download" href="${href}?download=1" download="${escapeHtml(file.name)}">下载 ${escapeHtml(file.name)}</a></article>`;
  }).join('');
  const section = (label, value, id) => value ? `<section><h2>${label}</h2><textarea readonly id="${id}" rows="${id === 'caption' ? 6 : 2}">${escapeHtml(value)}</textarea><button data-copy="${id}">复制${label}</button></section>` : '';
  return `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(title || 'Vibepost 手机传输')}</title><style>
  :root{color-scheme:light dark;font:16px/1.6 system-ui,sans-serif}body{margin:0;background:#f5f3ee;color:#24251f}main{max-width:720px;margin:auto;padding:28px 18px 60px}h1{font-size:26px;margin-bottom:8px}h2{font-size:18px}p{color:#5c6055}article,section{margin:18px 0;padding:16px;background:white;border-radius:16px;border:1px solid #dadbd2}img,video{display:block;max-width:100%;height:auto;max-height:65vh;margin:0 auto 16px;border-radius:8px}img{width:auto;object-fit:contain}.long{position:relative;max-height:65vh;overflow:hidden;margin:0 0 8px;border-radius:8px}.long img{width:100%;max-height:none;margin:0;border-radius:0}.long::after{content:"";position:absolute;left:0;right:0;bottom:0;height:72px;background:linear-gradient(transparent,white)}a,button{display:inline-block;background:#244d3e;color:white;border:0;border-radius:8px;padding:10px 14px;text-decoration:none;font:inherit;cursor:pointer}textarea{box-sizing:border-box;width:100%;background:#f6f6f2;color:inherit;border:1px solid #ccc;border-radius:8px;padding:12px;font:inherit;resize:vertical;margin:0 0 10px}#status{min-height:1.6em}.notice{font-size:14px}#inapp{padding:12px 14px;border-radius:12px;background:#fdf1d6;color:#5b4300;border:1px solid #e8cf93}@media(prefers-color-scheme:dark){body{background:#191b18;color:#f1f2ec}p{color:#c0c5b9}article,section{background:#262b24;border-color:#485044}textarea{background:#1b201a;border-color:#485044}a,button{background:#3a7a62}.long::after{background:linear-gradient(transparent,#262b24)}#inapp{background:#3b3014;color:#f3deaa;border-color:#6b5621}}
  </style><main><h1>接收 Vibepost 卡片</h1><p>请保持电脑和手机连接同一局域网，电脑上的传输窗口保持打开。</p><p id="inapp" hidden>这里是 App 自带的浏览器，下载多半会被拦下。点右上角的菜单，选「在浏览器打开」再保存。</p><p class="notice">图片长按，选「存储到照片」或「保存图片」就进相册。视频和 ZIP 点下载，之后在「文件」或「下载」里找。</p><a href="${prefix}bundle.zip" download="Vibepost.zip">下载全部 ZIP</a><p class="notice">链接到 <time id="expires" datetime="${escapeHtml(expiresAt)}">十分钟内</time> 失效，过期后在电脑上重新发送。</p><div>${rows}</div>${section('标题', title, 'title')}${section('正文', text, 'caption')}${section('话题', topics.map((t) => `#${t.replace(/^#/, '')}`).join(' '), 'topics')}<p id="status" role="status"></p></main><script nonce="${nonce}">
  const expires=document.getElementById('expires');const due=new Date(expires.dateTime);if(!isNaN(due))expires.textContent=String(due.getHours()).padStart(2,'0')+':'+String(due.getMinutes()).padStart(2,'0');
  if(/MicroMessenger|QQ\\/|Weibo|AlipayClient|DingTalk|Lark|XiaoHongShu/i.test(navigator.userAgent))document.getElementById('inapp').hidden=false;
  for(const button of document.querySelectorAll('[data-copy]'))button.addEventListener('click',async()=>{const field=document.getElementById(button.dataset.copy);const status=document.getElementById('status');try{if(navigator.clipboard&&window.isSecureContext){await navigator.clipboard.writeText(field.value);status.textContent='已复制，可以粘贴到发布页面';return}}catch{}field.focus();field.select();field.setSelectionRange(0,field.value.length);let copied=false;try{copied=document.execCommand('copy')}catch{}status.textContent=copied?'已复制，可以粘贴到发布页面':'文字已选中，请长按文字并选择「复制」';});
  </script></html>`;
}

class PhoneService {
  constructor({ dataDir, ttlMs = 10 * 60 * 1000 }) {
    if (!dataDir) throw new Error('手机传输缺少存储目录');
    this.root = path.resolve(dataDir, 'phone-transfer');
    this.ttlMs = Math.max(20, Math.min(Number(ttlMs) || 600000, 600000));
    this.sessions = new Map();
    this.disposed = false;
  }

  async start({ files, text = '', title = '', topics = [] } = {}) {
    if (this.disposed) throw new Error('手机传输服务已关闭');
    if (!Array.isArray(files) || !files.length || files.length > 200) throw new Error('手机传输需要 1–200 个导出文件');
    const session = crypto.randomUUID();
    const token = crypto.randomBytes(32).toString('hex');
    const dir = path.join(this.root, session);
    await fsp.mkdir(dir, { recursive: true });
    const staged = [];
    const usedNames = new Set();
    const zip = new JSZip();
    let total = 0;
    let server;
    try {
      for (const [index, file] of files.entries()) {
        if (!file || typeof file.data !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(file.data)) throw new Error('传输文件不是有效的 Base64');
        const data = Buffer.from(file.data, 'base64');
        total += data.length;
        if (!data.length || total > 1024 * 1024 * 1024) throw new Error('传输文件为空或总大小超过 1 GB');
        const rawName = fileName(file.name, index);
        let name = rawName;
        for (let n = 2; usedNames.has(name.toLowerCase()); n++) {
          const ext = path.extname(rawName);
          name = `${rawName.slice(0, rawName.length - ext.length)}-${n}${ext}`;
        }
        usedNames.add(name.toLowerCase());
        const type = MIME.get(path.extname(name).toLowerCase()) || 'application/octet-stream';
        const target = path.join(dir, String(index));
        await fsp.writeFile(target, data);
        staged.push({ name, type, path: target, size: data.length, ...(type === 'image/png' ? pngSize(data) : null) });
        zip.file(name, data);
      }
      const safeTitle = String(title).slice(0, 10000);
      const safeText = String(text).slice(0, 1000000);
      const safeTopics = Array.isArray(topics) ? topics.map(String).slice(0, 100) : [];
      // Reserve metadata names without replacing any exported file with the same name.
      const addText = (name, value) => { if (value) { while (usedNames.has(name.toLowerCase())) name = `_${name}`; usedNames.add(name.toLowerCase()); zip.file(name, value); } };
      addText('标题.txt', safeTitle);
      addText('正文.txt', safeText);
      addText('话题.txt', safeTopics.map((t) => `#${t.replace(/^#/, '')}`).join(' '));
      const zipPath = path.join(dir, 'bundle.zip');
      await fsp.writeFile(zipPath, await zip.generateAsync({ type: 'nodebuffer', compression: 'STORE' }));
      const bundle = { name: 'Vibepost.zip', type: 'application/zip', path: zipPath, size: (await fsp.stat(zipPath)).size };
      const expires = Date.now() + this.ttlMs;
      const expiresAt = new Date(expires).toISOString();
      const prefix = `/t/${token}/`;
      const nonce = crypto.randomBytes(18).toString('base64');
      const html = Buffer.from(page({ title: safeTitle, text: safeText, topics: safeTopics, files: staged, prefix, expiresAt, nonce }));
      server = http.createServer((req, res) => {
        res.setHeader('Cache-Control', 'no-store');
        res.setHeader('Referrer-Policy', 'no-referrer');
        res.setHeader('X-Content-Type-Options', 'nosniff');
        // style-src 用 'unsafe-inline'：Safari 的视频控件靠自己插的行内样式表排版，只认 nonce 时会被拦掉、播放键错位。
        // 页面里没有不转义的内容，脚本仍然只认 nonce
        res.setHeader('Content-Security-Policy', `default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'`);
        if (Date.now() >= expires) { res.writeHead(410); res.end('传输链接已到期'); return; }
        if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405, { Allow: 'GET, HEAD' }); res.end(); return; }
        let url;
        try { url = new URL(req.url, 'http://localhost'); } catch { res.writeHead(400); res.end(); return; }
        if (url.pathname === prefix) {
          res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': html.length });
          res.end(req.method === 'HEAD' ? undefined : html);
          return;
        }
        let file;
        if (url.pathname === `${prefix}bundle.zip`) file = bundle;
        else if (url.pathname.startsWith(`${prefix}files/`)) {
          const id = url.pathname.slice(`${prefix}files/`.length);
          if (/^(0|[1-9][0-9]*)$/.test(id)) file = staged[Number(id)];
        }
        if (!file) { res.writeHead(404); res.end(); return; }
        const headers = { 'Content-Type': file.type, 'Accept-Ranges': 'bytes' };
        if (file === bundle || url.searchParams.get('download') === '1') {
          const encoded = encodeURIComponent(file.name).replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
          headers['Content-Disposition'] = `attachment; filename="download${path.extname(file.name)}"; filename*=UTF-8''${encoded}`;
        }
        let start = 0;
        let end = file.size - 1;
        let code = 200;
        if (req.headers.range) {
          const match = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range);
          if (!match || (!match[1] && !match[2])) { res.writeHead(416, { 'Content-Range': `bytes */${file.size}` }); res.end(); return; }
          if (!match[1]) start = Math.max(0, file.size - Number(match[2]));
          else { start = Number(match[1]); if (match[2]) end = Math.min(Number(match[2]), end); }
          if (!Number.isSafeInteger(start) || start < 0 || start > end || start >= file.size) { res.writeHead(416, { 'Content-Range': `bytes */${file.size}` }); res.end(); return; }
          code = 206;
          headers['Content-Range'] = `bytes ${start}-${end}/${file.size}`;
        }
        headers['Content-Length'] = end - start + 1;
        res.writeHead(code, headers);
        if (req.method === 'HEAD') { res.end(); return; }
        const stream = fs.createReadStream(file.path, { start, end });
        stream.on('error', () => res.destroy());
        res.on('close', () => stream.destroy());
        stream.pipe(res);
      });
      server.requestTimeout = 30000;
      server.headersTimeout = 10000;
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '0.0.0.0', resolve); });
      const urls = addresses(server.address().port, token);
      const qrcode = await QRCode.toDataURL(urls[0], { width: 320, margin: 2, errorCorrectionLevel: 'M' });
      if (this.disposed) throw new Error('手机传输服务已关闭');
      const timer = setTimeout(() => void this.stop(session), Math.max(0, expires - Date.now()));
      timer.unref();
      this.sessions.set(session, { server, dir, timer });
      return { session, url: urls[0], addresses: urls, qrcode, expiresAt };
    } catch (error) {
      if (server?.listening) { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
      await fsp.rm(dir, { recursive: true, force: true });
      throw error;
    }
  }

  async stop(session) {
    const item = this.sessions.get(String(session));
    if (!item) return { stopped: false };
    this.sessions.delete(String(session));
    clearTimeout(item.timer);
    item.server.closeAllConnections();
    await new Promise((resolve) => item.server.close(resolve));
    await fsp.rm(item.dir, { recursive: true, force: true });
    return { stopped: true };
  }

  async dispose() {
    this.disposed = true;
    await Promise.all([...this.sessions.keys()].map((id) => this.stop(id)));
  }
}

module.exports = { PhoneService };
