'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { spawn } = require('node:child_process');

function failure(message, status = 400) { return Object.assign(new Error(message), { status }); }
function envPath(env) { return Object.keys(env).find(key => key.toLowerCase() === 'path') || 'PATH'; }
function childEnv(base, executable, tempDir) {
  const env = { ...base, TMP: tempDir, TEMP: tempDir, TMPDIR: tempDir };
  const key = envPath(env);
  env[key] = path.dirname(executable) + path.delimiter + (env[key] || '');
  return env;
}
async function regular(file) { try { return (await fs.stat(file)).isFile(); } catch { return false; } }

// Never execute a command shim in a shell. Resolve only the standard npm wrapper's
// literal target, then launch the executable or JS entry point with an argv array.
async function resolveProgram(file, env = process.env) {
  file = path.resolve(file);
  if (!await regular(file)) throw failure('这个路径不是可以运行的 AI 程序：' + file);
  const ext = path.extname(file).toLowerCase();
  if (ext === '.exe' || (process.platform !== 'win32' && !['.cmd', '.bat', '.ps1', '.js', '.cjs', '.mjs'].includes(ext))) {
    return { executable: file, args: [], path: file };
  }
  let target = file;
  if (['.cmd', '.bat', '.ps1'].includes(ext)) {
    const text = await fs.readFile(file, 'utf8');
    const matches = [...text.matchAll(/(?:%dp0%|\$basedir)[\\/]([^"'\r\n]+?\.(?:exe|[cm]?js))["']/gi)];
    const candidates = matches.map(match => path.resolve(path.dirname(file), match[1])).filter(value => /[\\/]node_modules[\\/]/i.test(value));
    target = candidates.find(value => /\.(exe|[cm]?js)$/i.test(value)) || '';
    if (!target || !await regular(target)) throw failure('不能安全解析这个命令行包装器，请选择实际的 .exe 或 JS 入口：' + file);
  }
  if (/\.exe$/i.test(target)) return { executable: target, args: [], path: file };
  if (!/\.[cm]?js$/i.test(target)) throw failure('请选择实际的 .exe 或 JS 入口：' + file);
  let node = path.join(path.dirname(file), 'node.exe');
  if (!await regular(node)) {
    node = '';
    for (const directory of (env[envPath(env)] || '').split(path.delimiter)) {
      const candidate = path.join(directory.replace(/^"|"$/g, ''), process.platform === 'win32' ? 'node.exe' : 'node');
      if (await regular(candidate)) { node = candidate; break; }
    }
  }
  return { executable: node || process.execPath, args: [target], path: file, runAsNode: !node };
}

async function findProgram(name, env = process.env) {
  const names = process.platform === 'win32' ? [name + '.exe', name + '.cmd', name + '.ps1', name] : [name];
  const directories = (env[envPath(env)] || '').split(path.delimiter).filter(Boolean);
  if (process.platform === 'win32') {
    if (env.USERPROFILE) directories.push(path.join(env.USERPROFILE, '.local', 'bin'));
    if (env.APPDATA) directories.push(path.join(env.APPDATA, 'npm'));
  }
  for (const directory of directories) for (const basename of names) {
    const file = path.join(directory.replace(/^"|"$/g, ''), basename);
    if (await regular(file)) return resolveProgram(file, env);
  }
  return null;
}

function launch(program, args, options = {}) {
  const env = { ...(options.env || process.env) };
  if (program.runAsNode) env.ELECTRON_RUN_AS_NODE = '1';
  return spawn(program.executable, [...program.args, ...args], {
    ...options, env, shell: false, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
    detached: process.platform !== 'win32',
  });
}

function killTree(child, force = false) {
  if (!child.pid || child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  if (process.platform === 'win32') {
    // taskkill takes a numeric PID as a distinct argument; no shell interpolation.
    const killer = spawn(path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'taskkill.exe'),
      ['/PID', String(child.pid), '/T', ...(force ? ['/F'] : [])], { windowsHide: true, shell: false, stdio: 'ignore' });
    return new Promise(resolve => { killer.once('error', resolve); killer.once('close', resolve); });
  }
  try { process.kill(-child.pid, force ? 'SIGKILL' : 'SIGTERM'); } catch {}
  return Promise.resolve();
}

function run(program, args, options, timeout = 10000) {
  return new Promise((resolve, reject) => {
    const child = launch(program, args, options);
    let stdout = '', stderr = '', settled = false;
    const timer = setTimeout(() => { killTree(child, true); done(failure('AI 程序检查超时', 500)); }, timeout);
    const done = (error, result) => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      error ? reject(error) : resolve(result);
    };
    child.stdout.on('data', chunk => { stdout = (stdout + chunk).slice(-65536); });
    child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-8192); });
    child.on('error', error => done(failure('AI 程序启动失败：' + error.code, 500)));
    child.on('close', status => done(null, { status, stdout, stderr }));
    child.stdin.on('error', () => {});
    child.stdin.end();
  });
}

function jsonLines(stream, onLine, onError, limit = 32 * 1024 * 1024) {
  let buffer = Buffer.alloc(0);
  stream.on('data', chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    let end;
    while ((end = buffer.indexOf(10)) >= 0) {
      const bytes = buffer.subarray(0, end); buffer = buffer.subarray(end + 1);
      if (bytes.length > limit) { onError(failure('AI 输出行超过大小限制', 500)); return; }
      try { const line = JSON.parse(bytes.toString('utf8')); if (line && typeof line === 'object' && !Array.isArray(line)) onLine(line); } catch {}
    }
    if (buffer.length > limit) { buffer = Buffer.alloc(0); onError(failure('AI 输出行超过大小限制', 500)); }
  });
  stream.on('end', () => {
    if (buffer.length) { try { const line = JSON.parse(buffer.toString('utf8')); if (line && typeof line === 'object') onLine(line); } catch {} }
    buffer = Buffer.alloc(0);
  });
}

module.exports = { failure, childEnv, resolveProgram, findProgram, launch, killTree, run, jsonLines };
