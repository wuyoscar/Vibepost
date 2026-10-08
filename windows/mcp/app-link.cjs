'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

class LineReader {
  constructor(socket) {
    this.socket = socket; this.buffer = Buffer.alloc(0); this.lines = []; this.waiters = []; this.closed = false;
    socket.on('data', chunk => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      if (this.buffer.length > 90 * 1024 * 1024) { socket.destroy(new Error('Vibepost 的回答太大')); return; }
      let at;
      while ((at = this.buffer.indexOf(10)) >= 0) {
        const line = this.buffer.subarray(0, at); this.buffer = this.buffer.subarray(at + 1);
        let object;
        try { object = JSON.parse(line.toString('utf8')); } catch { continue; }
        if (!object || typeof object !== 'object' || Array.isArray(object)) continue;
        const waiter = this.waiters.shift();
        if (waiter) waiter(object); else this.lines.push(object);
      }
    });
    const closed = () => { this.closed = true; for (const waiter of this.waiters.splice(0)) waiter(null); };
    socket.on('close', closed); socket.on('error', closed);
  }
  next(timeout) {
    if (this.lines.length) return Promise.resolve(this.lines.shift());
    if (this.closed) return Promise.resolve(null);
    return new Promise(resolve => {
      const done = value => { clearTimeout(timer); resolve(value); };
      const timer = setTimeout(() => { const at = this.waiters.indexOf(done); if (at >= 0) this.waiters.splice(at, 1); resolve(null); }, timeout);
      this.waiters.push(done);
    });
  }
}

class AppLink {
  constructor({ dataDir, executable = process.execPath, appArgs = [], launchTimeout = 20000, callTimeout = 600000, launch } = {}) {
    this.dataDir = path.resolve(dataDir);
    this.executable = executable; this.appArgs = appArgs;
    this.launchTimeout = launchTimeout; this.callTimeout = callTimeout;
    this.launch = launch || (() => this.startApp());
    this.session = crypto.randomUUID(); this.nextId = 0; this.channel = null;
  }

  async startApp() {
    // The helper is Node inside Electron; the launched App must run Electron normally.
    const env = { ...process.env }; delete env.ELECTRON_RUN_AS_NODE;
    await new Promise((resolve, reject) => {
      const child = spawn(this.executable, [...this.appArgs, '--data-dir', this.dataDir], { env, detached: true, stdio: 'ignore', windowsHide: true });
      child.once('error', reject); child.once('spawn', () => { child.unref(); resolve(); });
    });
  }

  async connectOnce(timeout = 10000) {
    const directory = path.join(this.dataDir, 'mcp');
    const metadata = JSON.parse(await fs.readFile(path.join(directory, 'endpoint.json'), 'utf8'));
    const tokenFile = path.join(directory, 'token');
    if (metadata.version !== 1 || typeof metadata.address !== 'string' || path.resolve(metadata.tokenFile || '') !== tokenFile) throw new Error('Vibepost 的 MCP 连接信息不对');
    if (process.platform === 'win32' && (!metadata.address.startsWith('\\\\.\\pipe\\mediacraft-') || metadata.transport !== 'named-pipe')) throw new Error('MCP 只允许本机 Windows 命名管道');
    if (process.platform !== 'win32' && !path.isAbsolute(metadata.address)) throw new Error('MCP 套接字路径不对');
    const token = (await fs.readFile(tokenFile, 'utf8')).trim();
    if (!/^[a-f0-9]{64}$/.test(token)) throw new Error('Vibepost 的 MCP 认证令牌不对');
    const socket = net.createConnection(metadata.address);
    const reader = new LineReader(socket);
    try {
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { socket.destroy(); reject(new Error('Vibepost 没有回应连接，稍后再试')); }, timeout);
        socket.once('connect', () => { clearTimeout(timer); resolve(); });
        socket.once('error', error => { clearTimeout(timer); reject(error); });
      });
      socket.write(JSON.stringify({ auth: token }) + '\n');
      const greeting = await reader.next(timeout);
      if (greeting?.error) throw Object.assign(new Error(greeting.error), { refused: true });
      if (greeting?.ready !== true) throw new Error('Vibepost 没有回应连接，稍后再试');
      return { socket, reader };
    } catch (error) { socket.destroy(); throw error; }
  }

  async connected(launching = true) {
    if (this.channel && !this.channel.socket.destroyed && !this.channel.reader.closed && !this.channel.reader.lines.length) return this.channel;
    this.close();
    try { this.channel = await this.connectOnce(launching ? 10000 : 5000); return this.channel; }
    catch (error) {
      if (error.refused || !launching) throw error;
      // Reconnection is only before sending a request. A sent request is never replayed.
      await this.launch();
      const deadline = Date.now() + this.launchTimeout;
      while (Date.now() < deadline) {
        try { this.channel = await this.connectOnce(Math.min(1000, deadline - Date.now())); return this.channel; }
        catch (again) { if (again.refused) throw again; }
        await new Promise(resolve => setTimeout(resolve, Math.min(200, Math.max(1, deadline - Date.now()))));
      }
      throw new Error(`已经打开 Vibepost，但它没有在 ${this.launchTimeout / 1000} 秒内准备好外部 Agent 的连接。确认装的是带 MCP 的版本，再试一次`);
    }
  }

  async call(method, params, { launching = true, timeout = this.callTimeout } = {}) {
    const channel = await this.connected(launching);
    const id = ++this.nextId;
    try {
      await new Promise((resolve, reject) => channel.socket.write(JSON.stringify({ id, session: this.session, method, params }) + '\n', error => error ? reject(error) : resolve()));
    } catch (error) { this.close(); throw new Error(`和 Vibepost 的连接断了，这次调用没有送到：${error.message}`); }
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      const response = await channel.reader.next(Math.max(1, deadline - Date.now()));
      if (!response) break;
      if (response.id == null) {
        if (typeof response.error === 'string') { this.close(); throw new Error(response.error); }
        continue;
      }
      if (response.id !== id) continue;
      if (typeof response.error === 'string') throw new Error(response.error);
      return response.result && typeof response.result === 'object' && !Array.isArray(response.result) ? response.result : {};
    }
    this.close();
    throw new Error(`Vibepost 在处理这次调用时断开了连接（App 退出、重新载入），或者 ${Math.round(timeout / 60000)} 分钟都没有回答；这次调用可能没有完成`);
  }

  async callIfRunning(method, params) {
    try { return await this.call(method, params, { launching: false, timeout: 5000 }); }
    catch { this.close(); return null; }
  }
  close() { this.channel?.socket.destroy(); this.channel = null; }
}

module.exports = { AppLink, LineReader };
