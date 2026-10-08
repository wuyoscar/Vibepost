'use strict';

const fs = require('node:fs/promises');
const fsSync = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const crypto = require('node:crypto');
const { restrictToCurrentUser, restrictNamedPipe, atomicJSON } = require('./mcp-security.cjs');

const DISABLED = 'Vibepost 里没有打开「允许外部 Agent 连接」（AI 助手 › 设置，默认是关的）。请用户打开后再试';
const MAX_LINE = 90 * 1024 * 1024;
const MAX_IMAGE = 20 * 1024 * 1024;
const MAX_TOTAL = 60 * 1024 * 1024;
function failure(message, status = 400) { return Object.assign(new Error(message), { status }); }
function toolError(error) { return { content: [{ type: 'text', text: error.message || String(error) }], isError: true }; }
function sameToken(a, b) {
  if (typeof a !== 'string') return false;
  const actual = Buffer.from(a), expected = Buffer.from(b);
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}

function imageInfo(bytes) {
  if (bytes.length >= 33 && bytes.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])) && bytes.toString('ascii', 12, 16) === 'IHDR') {
    let offset = 8, ended = false;
    while (offset + 12 <= bytes.length) {
      const length = bytes.readUInt32BE(offset), type = bytes.toString('ascii', offset + 4, offset + 8);
      if (length > bytes.length - offset - 12) break;
      offset += length + 12;
      if (type === 'IEND') { ended = length === 0; break; }
    }
    if (!ended) throw failure('PNG 图片不完整');
    return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), type: 'image/png' };
  }
  if (bytes.length >= 14 && /^GIF8[79]a$/.test(bytes.toString('ascii', 0, 6)) && bytes[bytes.length - 1] === 0x3b) {
    return { width: bytes.readUInt16LE(6), height: bytes.readUInt16LE(8), type: 'image/gif' };
  }
  if (bytes.length >= 26 && bytes.toString('ascii', 0, 2) === 'BM') {
    const size = bytes.readUInt32LE(14);
    if (size === 12) return { width: bytes.readUInt16LE(18), height: bytes.readUInt16LE(20), type: 'image/bmp' };
    if (size >= 40) return { width: Math.abs(bytes.readInt32LE(18)), height: Math.abs(bytes.readInt32LE(22)), type: 'image/bmp' };
  }
  if (bytes.length >= 30 && bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP') {
    if (bytes.readUInt32LE(4) + 8 > bytes.length) throw failure('WebP 图片不完整');
    const kind = bytes.toString('ascii', 12, 16);
    if (kind === 'VP8X') return { width: 1 + bytes.readUIntLE(24,3), height: 1 + bytes.readUIntLE(27,3), type: 'image/webp' };
    if (kind === 'VP8 ' && bytes.subarray(23,26).equals(Buffer.from([0x9d,0x01,0x2a]))) return { width: bytes.readUInt16LE(26) & 0x3fff, height: bytes.readUInt16LE(28) & 0x3fff, type: 'image/webp' };
    if (kind === 'VP8L' && bytes[20] === 0x2f) {
      const bits = bytes.readUInt32LE(21);
      return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1, type: 'image/webp' };
    }
  }
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset] !== 0xff) break;
      const marker = bytes[offset + 1];
      if (marker === 0xff) { offset++; continue; }
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { offset += 2; continue; }
      const length = bytes.readUInt16BE(offset + 2);
      if (length < 2 || offset + length + 2 > bytes.length) break;
      if ([0xc0,0xc1,0xc2,0xc3,0xc5,0xc6,0xc7,0xc9,0xca,0xcb,0xcd,0xce,0xcf].includes(marker) && length >= 8) {
        if (bytes.indexOf(Buffer.from([0xff,0xd9]), offset + length + 2) < 0) throw failure('JPEG 图片不完整');
        return { width: bytes.readUInt16BE(offset + 7), height: bytes.readUInt16BE(offset + 5), type: 'image/jpeg' };
      }
      offset += length + 2;
    }
  }
  throw failure('不是支持的图片（Windows 支持 PNG、JPEG、WebP、GIF、BMP；请先将 HEIC 转成 PNG）');
}

function absolute(value, what) {
  if (typeof value !== 'string' || !value.trim()) throw failure(`${what}要给绝对路径`);
  let expanded = value.trim();
  if (expanded === '~' || /^~[\\/]/.test(expanded)) expanded = path.join(os.homedir(), expanded.slice(2));
  if (!path.isAbsolute(expanded)) throw failure(`${what}要给绝对路径：${value}`);
  if (process.platform === 'win32' && (/^[\\/]{2}/.test(expanded) || !/^[a-z]:[\\/]/i.test(expanded))) throw failure(`${what}要给本机磁盘的绝对路径：${value}`);
  return path.resolve(expanded);
}

class McpService {
  constructor({ dataDir, executable = process.execPath, helperPath, dispatch, emit = () => {}, socketPath, appArgs = [], prepareImage } = {}) {
    if (!dataDir || typeof dispatch !== 'function') throw new TypeError('McpService requires dataDir and dispatch');
    this.dataDir = path.resolve(dataDir);
    this.directory = path.join(this.dataDir, 'mcp');
    this.settingsFile = path.join(this.dataDir, 'mcp.json');
    this.endpointFile = path.join(this.directory, 'endpoint.json');
    this.tokenFile = path.join(this.directory, 'token');
    this.lockFile = path.join(this.directory, 'owner.lock');
    const identity = `${os.userInfo().username}\0${this.dataDir.toLowerCase()}`;
    const suffix = crypto.createHash('sha256').update(identity).digest('hex').slice(0, 32);
    this.socketPath = socketPath || (process.platform === 'win32' ? `\\\\.\\pipe\\mediacraft-${suffix}` : path.join(this.directory, 'mcp.sock'));
    this.executable = executable;
    this.helperPath = helperPath || path.resolve(__dirname, '../mcp/stdio.cjs');
    this.appArgs = appArgs;
    this.dispatch = dispatch;
    this.emit = emit;
    this.prepareImage = prepareImage;
    this.clients = new Set();
    this.sockets = new Set();
    this.exports = new Map();
    this.enabled = false;
    this.server = null;
    this.owner = crypto.randomUUID();
    this.token = crypto.randomBytes(32).toString('hex');
    this.disposed = false;
    try { this.enabled = JSON.parse(fsSync.readFileSync(this.settingsFile, 'utf8')).allowExternalAgents === true; } catch {}
  }

  async start() {
    if (this.server || this.disposed) return this.status();
    await fs.mkdir(this.directory, { recursive: true, mode: 0o700 });
    await restrictToCurrentUser(this.directory, true);
    let lock;
    try { lock = await fs.open(this.lockFile, 'wx', 0o600); }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      let old;
      try { old = JSON.parse(await fs.readFile(this.lockFile, 'utf8')); } catch { return this.status(); }
      if (!Number.isSafeInteger(old.pid) || old.pid <= 0) return this.status();
      try { process.kill(old.pid, 0); return this.status(); }
      catch (probe) { if (probe.code !== 'ESRCH') return this.status(); }
      await fs.unlink(this.lockFile);
      lock = await fs.open(this.lockFile, 'wx', 0o600);
    }
    await lock.writeFile(JSON.stringify({ pid: process.pid, owner: this.owner }));
    await lock.close();
    this.ownsLock = true;
    try {
      await fs.writeFile(this.tokenFile, this.token, { mode: 0o600 });
      await restrictToCurrentUser(this.tokenFile);
      if (process.platform !== 'win32') await fs.rm(this.socketPath, { force: true });
      const server = net.createServer(socket => this.accept(socket));
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(this.socketPath, resolve); });
      this.server = server;
      server.on('error', () => {});
      await restrictNamedPipe(this.socketPath);
      if (process.platform !== 'win32') await fs.chmod(this.socketPath, 0o600);
      await atomicJSON(this.endpointFile, { version: 1, transport: process.platform === 'win32' ? 'named-pipe' : 'unix', address: this.socketPath, tokenFile: this.tokenFile, pid: process.pid, owner: this.owner });
      return this.status();
    } catch (error) { await this.dispose(); throw error; }
  }

  status() {
    const args = [this.helperPath, '--data-dir', this.dataDir, '--app', this.executable, ...this.appArgs.flatMap(arg => ['--app-arg', arg])];
    const quote = text => "'" + String(text).replace(/'/g, "''") + "'";
    // --env is variadic; the server name must precede it or becomes an env value.
    const command = `claude mcp add mediacraft --transport stdio --env ELECTRON_RUN_AS_NODE=1 -- ${[this.executable, ...args].map(quote).join(' ')}`;
    const claudeConfig = { mcpServers: { mediacraft: { command: this.executable, args, env: { ELECTRON_RUN_AS_NODE: '1' } } } };
    const toml = value => JSON.stringify(String(value));
    const codexConfig = `[mcp_servers.mediacraft]\ncommand = ${toml(this.executable)}\nargs = [${args.map(toml).join(', ')}]\nenv = { ELECTRON_RUN_AS_NODE = "1" }\n`;
    return { available: Boolean(this.server && !this.disposed), enabled: this.enabled, clients: this.clients.size, command, claudeConfig, codexConfig };
  }

  async setEnabled(enabled) {
    if (typeof enabled !== 'boolean') throw failure('要给 enabled');
    if (this.disposed) throw failure('Vibepost 正在关闭', 503);
    await fs.mkdir(this.dataDir, { recursive: true });
    await atomicJSON(this.settingsFile, { allowExternalAgents: enabled });
    this.enabled = enabled;
    if (!enabled) {
      this.exports.clear();
      for (const socket of this.clients) { socket.end(JSON.stringify({ error: DISABLED }) + '\n'); socket.destroySoon(); }
    }
    this.emit({ type: 'clients', count: this.clients.size });
    return this.status();
  }

  accept(socket) {
    this.sockets.add(socket);
    let authenticated = false, buffer = Buffer.alloc(0), queued = 0, queue = Promise.resolve();
    const timer = setTimeout(() => socket.destroy(), 10000);
    socket.on('error', () => {});
    const send = value => { if (!socket.destroyed) socket.write(JSON.stringify(value) + '\n'); };
    socket.on('close', () => {
      clearTimeout(timer);
      this.sockets.delete(socket);
      this.clients.delete(socket);
      for (const [token, target] of this.exports) if (target.socket === socket) this.exports.delete(token);
      this.emit({ type: 'clients', count: this.clients.size });
    });
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > MAX_LINE) { socket.destroy(); return; }
      let newline;
      while ((newline = buffer.indexOf(10)) >= 0) {
        const line = buffer.subarray(0, newline); buffer = buffer.subarray(newline + 1);
        let request;
        try { request = JSON.parse(line.toString('utf8')); } catch { send({ error: '请求的格式不对' }); continue; }
        if (!authenticated) {
          clearTimeout(timer);
          if (!sameToken(request?.auth, this.token)) { socket.end(JSON.stringify({ error: '只允许这台 Windows 上的当前用户连接 Vibepost（认证失败）' }) + '\n'); socket.destroySoon(); return; }
          if (!this.enabled || this.disposed || !this.server) { socket.end(JSON.stringify({ error: DISABLED }) + '\n'); socket.destroySoon(); return; }
          if (this.clients.size >= 32) { socket.end(JSON.stringify({ error: '外部 Agent 连接太多' }) + '\n'); socket.destroySoon(); return; }
          authenticated = true;
          this.clients.add(socket);
          send({ ready: true });
          this.emit({ type: 'clients', count: this.clients.size });
          continue;
        }
        if (++queued > 100) { socket.destroy(); return; }
        queue = queue.then(async () => {
          try { if (this.enabled && !socket.destroyed && !this.disposed) send(await this.respond(request, socket)); }
          finally { queued--; }
        }).catch(error => send({ id: request?.id, error: error.message }));
      }
    });
  }

  async respond(request, socket) {
    if (!request || typeof request !== 'object' || Array.isArray(request) || request.id == null || typeof request.method !== 'string' || typeof request.session !== 'string' || request.session.length > 256) return { error: '请求的格式不对' };
    const { id, method, session } = request;
    if (!['tools/list', 'tools/call', 'manual/get'].includes(method)) return { id, error: `Vibepost 不支持 ${method}` };
    const params = request.params && typeof request.params === 'object' && !Array.isArray(request.params) ? request.params : {};
    const message = { session, method, params };
    let exportRequest;
    try {
      if (method === 'tools/call') {
        const args = params.arguments || {};
        try {
          if (params.name === 'import_images') message.files = await this.images(args.paths);
          if (params.name === 'export') {
            exportRequest = crypto.randomUUID();
            const directory = await this.exportDirectory(args.directory);
            if (!this.enabled || socket.destroyed || this.disposed) throw failure('和 Vibepost 的连接断了，这次调用没有执行', 503);
            this.exports.set(exportRequest, { directory, overwrite: args.overwrite === true, socket });
            message.exportRequest = exportRequest;
          }
        } catch (error) { return { id, result: toolError(error) }; }
      }
      if (!this.enabled || socket.destroyed || this.disposed) return { id, error: '和 Vibepost 的连接断了，这次调用没有执行' };
      let answer = await this.dispatch(message);
      if (typeof answer === 'string') answer = JSON.parse(answer);
      if (!answer || typeof answer !== 'object' || Array.isArray(answer)) throw failure('页面的回答不对');
      if (typeof answer.error === 'string') return { id, error: answer.error };
      return { id, result: answer.result ?? {} };
    } catch (error) { return { id, error: `Vibepost 没能完成这次调用：${error.message || String(error)}` }; }
    finally { if (exportRequest) this.exports.delete(exportRequest); }
  }

  async images(paths) {
    if (!Array.isArray(paths) || !paths.length || paths.some(item => typeof item !== 'string')) throw failure('paths 要给一个或几个图片文件的绝对路径');
    if (paths.length > 20) throw failure('一次最多插 20 张图');
    const files = []; let total = 0;
    for (const source of paths) {
      const file = await fs.realpath(absolute(source, '图片'));
      const handle = await fs.open(file, 'r');
      let bytes;
      try {
        const stat = await handle.stat();
        if (!stat.isFile()) throw failure(`不是图片文件：${source}`);
        if (stat.size > MAX_IMAGE) throw failure(`「${path.basename(file)}」超过 20 MB`);
        if (total + stat.size > MAX_TOTAL) throw failure('这批图片一共超过 60 MB，分几次插');
        const chunks = []; let length = 0;
        while (true) {
          const chunk = Buffer.alloc(Math.min(65536, MAX_IMAGE + 1 - length));
          const { bytesRead } = await handle.read(chunk, 0, chunk.length, null);
          if (!bytesRead) break;
          length += bytesRead;
          if (length > MAX_IMAGE) throw failure(`「${path.basename(file)}」超过 20 MB`);
          chunks.push(chunk.subarray(0, bytesRead));
        }
        bytes = Buffer.concat(chunks, length);
      } finally { await handle.close(); }
      if (bytes.length > MAX_IMAGE) throw failure(`「${path.basename(file)}」超过 20 MB`);
      const info = imageInfo(bytes);
      if (!info.width || !info.height || info.width * info.height > 64000000) throw failure(`「${path.basename(file)}」太大了（${info.width} × ${info.height}），最多 6400 万像素`);
      if (this.prepareImage) {
        const decoded = await this.prepareImage(bytes, info);
        if (decoded?.isEmpty?.()) throw failure(`「${path.basename(file)}」图片解码失败`);
        const size = decoded?.getSize?.();
        if (size && (!size.width || !size.height || size.width * size.height > 64000000)) throw failure(`「${path.basename(file)}」超过 6400 万像素`);
      }
      else if (process.versions.electron) {
        const image = require('electron').nativeImage.createFromBuffer(bytes);
        if (image.isEmpty()) throw failure(`「${path.basename(file)}」图片解码失败`);
        const size = image.getSize();
        if (size.width * size.height > 64000000) throw failure(`「${path.basename(file)}」超过 6400 万像素`);
      }
      total += bytes.length;
      if (total > MAX_TOTAL) throw failure('这批图片一共超过 60 MB，分几次插');
      files.push({ path: file, name: path.basename(file), type: info.type, data: bytes.toString('base64') });
    }
    return files;
  }

  async exportDirectory(value) {
    const directory = await fs.realpath(absolute(value, '文件夹')).catch(() => { throw failure(`没有这个文件夹：${value}（要先建好）`); });
    if (!(await fs.stat(directory)).isDirectory()) throw failure(`没有这个文件夹：${value}（要先建好）`);
    await fs.access(directory, fsSync.constants.W_OK).catch(() => { throw failure(`这个文件夹写不进去：${value}`); });
    return directory;
  }

  async write({ request, name, data } = {}) {
    const target = this.exports.get(request);
    if (!target || !this.enabled || this.disposed || target.socket.destroyed) throw failure('这次导出不是外部 Agent 发起的，或者已经结束了', 403);
    if (typeof name !== 'string' || !name || name === '.' || name === '..' || /[\\/\x00-\x1f<>:"|?*]/.test(name) || /[ .]$/.test(name) || /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/i.test(name)) throw failure(`文件名不对：${name}`);
    const bytes = Buffer.isBuffer(data) ? data : Buffer.from(data || []);
    if (bytes.length > 256 * 1024 * 1024) throw failure('导出文件超过 256 MB');
    const currentDirectory = await fs.realpath(target.directory);
    if (currentDirectory !== target.directory) throw failure('导出文件夹已经改变', 403);
    const destination = path.join(target.directory, name);
    let existing;
    try { existing = await fs.lstat(destination); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (existing && (!target.overwrite || !existing.isFile() || existing.isSymbolicLink())) throw failure(`${destination} 已经有了；要覆盖就给 overwrite: true，或者换一个文件夹`, 409);
    if (this.exports.get(request) !== target || target.socket.destroyed || !this.enabled || this.disposed) throw failure('这次导出已经结束了', 403);
    // wx makes non-overwrite race-safe; overwrite uses rename so symlinks are never followed.
    if (!target.overwrite) await fs.writeFile(destination, bytes, { flag: 'wx' }).catch(error => { if (error.code === 'EEXIST') throw failure(`${destination} 已经有了；要覆盖就给 overwrite: true`, 409); throw error; });
    else {
      const temporary = path.join(target.directory, `.mediacraft-${crypto.randomUUID()}.tmp`);
      try {
        await fs.writeFile(temporary, bytes, { flag: 'wx' });
        if (!this.exports.has(request) || target.socket.destroyed || !this.enabled) throw failure('这次导出已经结束了', 403);
        await fs.rename(temporary, destination);
      } finally { await fs.rm(temporary, { force: true }).catch(() => {}); }
    }
    return { path: destination, name };
  }

  async dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.exports.clear();
    for (const socket of this.sockets) socket.destroy();
    if (this.server) { const server = this.server; this.server = null; await new Promise(resolve => server.close(resolve)); }
    if (this.ownsLock) {
      let owner;
      try { owner = JSON.parse(await fs.readFile(this.lockFile, 'utf8')).owner; } catch {}
      if (owner === this.owner) {
        await Promise.all([this.endpointFile, this.tokenFile, this.lockFile].map(file => fs.rm(file, { force: true })));
        if (process.platform !== 'win32') await fs.rm(this.socketPath, { force: true });
      }
    }
    this.emit({ type: 'clients', count: 0 });
  }
}

module.exports = { McpService, imageInfo, absolute, DISABLED };
