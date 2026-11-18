#!/usr/bin/env node
'use strict';

// App 里的 AI 这一轮的工具中继：说 ACP 的 Agent（OpenCode、Oh My Pi、Kimi Code）把它当 stdio 的 MCP 服务启动，
// 它只把 stdin / stdout 和壳这一轮开的管道接在一起（Mac 上这件事由系统自带的 nc -U 做）。MCP 的消息由页面里的工具回答，
// 见 windows/lib/ai.cjs 的 _toolServer。用法：<electron，ELECTRON_RUN_AS_NODE=1> turn-relay.cjs <管道地址>，
// 口令在环境变量 VIBEPOST_TOOLS_TOKEN 里，连上后第一行交给壳核对。stdout 只写 MCP 消息。

const net = require('node:net');

function main(address, token) {
  if (!address) { process.stderr.write('vibepost-tools: 没有给管道地址\n'); process.exitCode = 2; return; }
  const socket = net.connect(address);
  socket.on('connect', () => {
    socket.write(JSON.stringify({ token }) + '\n');
    process.stdin.pipe(socket);
    socket.pipe(process.stdout);
  });
  socket.on('error', error => { process.stderr.write(`vibepost-tools: ${error.message}\n`); process.exitCode = 1; });
  socket.on('close', () => { process.stdin.destroy(); });
  process.stdout.on('error', () => socket.destroy());
}

if (require.main === module) main(process.argv[2], process.env.VIBEPOST_TOOLS_TOKEN || '');
module.exports = { main };
