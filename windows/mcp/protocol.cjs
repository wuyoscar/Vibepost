'use strict';

const CURRENT = '2026-07-28';
const LEGACY = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const SUPPORTED = [CURRENT, ...LEGACY];
const VERSION_KEY = 'io.modelcontextprotocol/protocolVersion';
const SERVER_INFO = { name: 'mediacraft', title: 'Vibepost', version: '1' };
const INSTRUCTIONS = 'Vibepost 是用户这台 Windows 上的排版 App：把 Markdown 排成小红书图文卡片（3:4，每页 864 × 1152）或长文长图，支持 MP4 / GIF 动效与局域网手机下载。工具操作的是 App 里正在编辑的那篇稿子，改动马上出现在用户眼前，每一步都能 Ctrl+Z 撤销、也列在 AI 助手的「外部 Agent 的操作」里。一般流程：create_draft（或 list_drafts + open_draft）→ update_draft 写正文与标题 → set_theme / set_style 挑样式 → render_pages 看每页的图、get_pages 看每页的问题，按需 insert_page_break / move_section / restyle_block 调整 → export 导出或 send_to_phone（App 显示临时二维码，由用户在同一局域网的手机上打开下载）。内置说明书只读，先新建稿子再改。块样式、组件与记号的写法和排版经验在操作手册里，用 get_manual 读全文；写稿、改稿、润色、起标题之前用 get_writing_skill 读内置的写作技能，每次都守（讲一件真事、按顺序讲、用作者自己的话、不升华、不编）；用户自己的写作手册（list_writing_manuals、read_writing_manual）补充题材的口味。';
const result = (id, value) => ({ jsonrpc: '2.0', id, result: value });
const failure = (id, code, message, data) => ({ jsonrpc: '2.0', id, error: { code, message, ...(data ? { data } : {}) } });
const complete = value => ({ ...value, resultType: 'complete' });
const key = id => `${typeof id === 'number' ? 'n' : 's'}:${id}`;

class MCPServer {
  constructor({ link, output }) { this.link = link; this.output = output; this.queue = Promise.resolve(); this.pending = new Set(); this.cancelled = new Set(); }
  send(message) { this.output(message); }
  enqueue(task) { const promise = this.queue.then(task); this.queue = promise.catch(() => {}); return promise; }
  async instructions() {
    const manual = await this.link.callIfRunning('manual/get', {});
    return typeof manual?.text === 'string' && manual.text ? INSTRUCTIONS + '\n\n' + manual.text : INSTRUCTIONS;
  }
  receive(line) {
    if (!line.trim()) return;
    let message;
    try { message = JSON.parse(line); }
    catch { this.send(failure(null, -32700, 'Parse error：不是 JSON')); return; }
    if (!message || typeof message !== 'object' || Array.isArray(message)) { this.send(failure(null, -32600, 'Invalid Request：一行一条消息，不支持批量请求')); return; }
    if (typeof message.method !== 'string') return;
    const params = message.params && typeof message.params === 'object' && !Array.isArray(message.params) ? message.params : {};
    const { id, method } = message;
    if (id == null) {
      if (method === 'notifications/cancelled' && params.requestId != null && this.pending.has(key(params.requestId))) this.cancelled.add(key(params.requestId));
      return;
    }
    const requested = params._meta?.[VERSION_KEY];
    if (typeof requested === 'string' && !SUPPORTED.includes(requested)) { this.send(failure(id, -32022, 'Unsupported protocol version', { supported: SUPPORTED, requested })); return; }
    const modern = typeof requested === 'string';
    if (method === 'ping') { this.send(result(id, modern ? complete({}) : {})); return; }
    if (method === 'initialize') {
      void this.enqueue(async () => this.send(result(id, { protocolVersion: LEGACY.includes(params.protocolVersion) ? params.protocolVersion : LEGACY[0], capabilities: { tools: {} }, serverInfo: SERVER_INFO, instructions: await this.instructions() })));
      return;
    }
    if (method === 'server/discover') {
      void this.enqueue(async () => this.send(result(id, complete({ supportedVersions: SUPPORTED, capabilities: { tools: {} }, _meta: { 'io.modelcontextprotocol/serverInfo': SERVER_INFO }, instructions: await this.instructions() }))));
      return;
    }
    if (method === 'tools/list' || method === 'tools/call') {
      const requestKey = key(id), forwarded = { ...params }; delete forwarded._meta;
      this.pending.add(requestKey);
      void this.enqueue(async () => {
        try {
          if (this.cancelled.has(requestKey)) return;
          let response;
          try { const value = await this.link.call(method, forwarded); response = result(id, modern ? complete(value) : value); }
          catch (error) {
            if (method === 'tools/call') { const value = { content: [{ type: 'text', text: error.message || String(error) }], isError: true }; response = result(id, modern ? complete(value) : value); }
            else response = failure(id, -32603, error.message || String(error));
          }
          if (!this.cancelled.has(requestKey)) this.send(response);
        } finally { this.pending.delete(requestKey); this.cancelled.delete(requestKey); }
      });
      return;
    }
    this.send(failure(id, -32601, `Method not found：Vibepost 不支持 ${method}`));
  }
  async close() { await this.queue; this.link.close(); }
}

module.exports = { MCPServer, CURRENT, LEGACY, SUPPORTED, VERSION_KEY, SERVER_INFO };
