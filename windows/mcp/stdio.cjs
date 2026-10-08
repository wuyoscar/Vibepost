#!/usr/bin/env node
'use strict';

const path = require('node:path');
const os = require('node:os');
const { AppLink } = require('./app-link.cjs');
const { MCPServer } = require('./protocol.cjs');

function options(argv) {
  const parsed = { dataDir: process.env.MEDIACRAFT_DATA_DIR || path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'Vibepost'), executable: process.execPath, appArgs: [] };
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i], value = argv[++i];
    if (!value || !['--data-dir', '--app', '--app-arg'].includes(flag)) throw new Error(`不支持的 MCP 参数：${flag}`);
    if (flag === '--data-dir') parsed.dataDir = path.resolve(value);
    else if (flag === '--app') parsed.executable = value;
    else parsed.appArgs.push(value);
  }
  return parsed;
}

async function main() {
  const link = new AppLink(options(process.argv.slice(2)));
  let outputClosed = false;
  process.stdout.on('error', () => { outputClosed = true; link.close(); process.stdin.destroy(); });
  const server = new MCPServer({ link, output: value => { if (!outputClosed) process.stdout.write(JSON.stringify(value) + '\n'); } });
  let buffer = Buffer.alloc(0), discarding = false;
  for await (const chunk of process.stdin) {
    buffer = Buffer.concat([buffer, chunk]);
    let newline;
    while ((newline = buffer.indexOf(10)) >= 0) {
      if (!discarding) server.receive(buffer.subarray(0, newline).toString('utf8'));
      discarding = false;
      buffer = buffer.subarray(newline + 1);
    }
    if (buffer.length > 90 * 1024 * 1024) {
      server.send({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Invalid Request：消息太大' } });
      buffer = Buffer.alloc(0); discarding = true;
    }
  }
  await server.close();
}

if (require.main === module) main().catch(error => { process.stderr.write(`mediacraft-mcp: ${error.message}\n`); process.exitCode = 1; });
module.exports = { options, main };
