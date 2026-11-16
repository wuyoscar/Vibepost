'use strict';
const fs = require('node:fs');
const readline = require('node:readline');
const path = require('node:path');
const args = process.argv.slice(2);
if (args[0] === '--version') { console.log('fixture-cli 1.2.3'); process.exit(0); }
if (args[0] === 'login') process.exit(process.env.AI_FIXTURE_LOGIN_FAIL ? 1 : 0);
const record = value => { if (process.env.AI_FIXTURE_LOG) fs.appendFileSync(process.env.AI_FIXTURE_LOG, JSON.stringify(value) + '\n'); };
record({ kind: 'launch', args, cwd: process.cwd(), temp: process.env.TEMP, backgroundDisabled: process.env.CLAUDE_CODE_DISABLE_BACKGROUND_TASKS, permission: process.env.OPENCODE_PERMISSION, config: process.env.OPENCODE_CONFIG_CONTENT, keys: Object.fromEntries(Object.entries(process.env).filter(([name]) => name.startsWith('VIBEPOST_API_KEY_'))) });
// 像出错信息里带出了密钥（在 App 里填的接口）
if (process.env.AI_FIXTURE_ECHO_KEYS) process.stderr.write('request failed: ' + (process.env.VIBEPOST_API_KEY_1 || '') + '\n');
const write = value => process.stdout.write(JSON.stringify(value) + '\n');
let initialized = false, acpPrompt = null;
const input = readline.createInterface({ input: process.stdin });
input.on('line', text => {
  const message = JSON.parse(text); record(message);
  if (args[0] === 'acp') {
    // ACP（OpenCode、Oh My Pi、Kimi Code）：握手 → 开会话 → 这一轮（问一次权限，答了才改稿、说完）
    const reply = (id, result) => write({ jsonrpc: '2.0', id, result });
    const update = value => write({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: 'fixture-session', update: value } });
    const options = [{ id: 'model', category: 'model', type: 'select', currentValue: 'fixture/large', options: [{ value: 'fixture/large', name: 'Fixture Large' }] }];
    if (message.method === 'initialize') reply(message.id, { protocolVersion: 1, agentCapabilities: { loadSession: true, sessionCapabilities: { resume: {} } } });
    else if (message.method === 'session/new') reply(message.id, { sessionId: 'fixture-session', configOptions: options });
    else if (message.method === 'session/resume') reply(message.id, { configOptions: options });
    else if (message.method === 'session/set_config_option') reply(message.id, { configOptions: options });
    else if (message.method === 'session/prompt') {
      acpPrompt = message.id;
      update({ sessionUpdate: 'available_commands_update', availableCommands: [{ name: 'hidden', description: 'do not expose' }] });
      update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: '完成 🐈' } });
      update({ sessionUpdate: 'tool_call_update', toolCallId: 'call-1', kind: 'edit', status: 'completed', rawInput: { filePath: 'draft.md', newString: 'secret body' }, content: [{ type: 'diff', newText: 'x'.repeat(5000) }] });
      write({ jsonrpc: '2.0', id: 77, method: 'session/request_permission', params: { sessionId: 'fixture-session', toolCall: { toolCallId: 'call-2', kind: 'execute', rawInput: { command: 'fixture' } }, options: [{ optionId: 'once', kind: 'allow_once' }, { optionId: 'reject', kind: 'reject_once' }] } });
    } else if (message.id === 77 && message.method == null) {
      fs.writeFileSync(path.join(process.cwd(), 'draft.md'), 'ACP 改稿');
      reply(acpPrompt, { stopReason: 'end_turn' });
    }
  } else if (args[0] === 'app-server') {
    if (message.method === 'initialize') write({ id: 'initialize', result: { userAgent: 'fixture' } });
    else if (message.method === 'initialized') initialized = true;
    else if (!initialized) write({ id: message.id, error: { message: 'initialized missing' } });
    else if (message.method === 'model/list') write({ id: message.id, result: { data: [{ id: 'gpt-fixture', displayName: 'Fixture', isDefault: true, supportedReasoningEfforts: [{ reasoningEffort: 'high' }, 'low', 'INVALID'], defaultReasoningEffort: 'high' }] } });
    else if (message.method === 'thread/start' || message.method === 'thread/resume') {
      write({ id: message.id, result: { thread: { id: 'fixture-thread' }, model: 'gpt-fixture' } });
      if (!process.env.AI_FIXTURE_WAIT) write({ id: 99, method: 'item/commandExecution/requestApproval', params: { command: 'test fixture only', cwd: process.cwd() } });
    } else if (message.method === 'turn/start') {
      write({ id: message.id, result: { turn: { id: 'fixture-turn' } } });
      write({ method: 'turn/completed', params: { threadId: 'other-thread', turn: { id: 'other-turn', status: 'completed' } } });
      if (process.env.AI_FIXTURE_WAIT) return;
      write({ method: 'account/updated', params: { hidden: 'do not expose' } });
      write({ method: 'item/agentMessage/delta', params: { threadId: 'fixture-thread', turnId: 'fixture-turn', delta: '完成 🐈' } });
      if (process.env.AI_FIXTURE_GENERATED) write({ method: 'item/completed', params: { threadId: 'fixture-thread', item: { type: 'imageGeneration', result: process.env.AI_FIXTURE_GENERATED, savedPath: process.env.AI_FIXTURE_GENERATED_PATH || null } } });
      fs.writeFileSync(path.join(process.cwd(), 'draft.md'), 'Codex 改稿');
      setTimeout(() => write({ method: 'turn/completed', params: { threadId: 'fixture-thread', turn: { id: 'fixture-turn', status: 'completed' } } }), 50);
    }
  } else {
    if (message.type === 'control_request') write({ type: 'control_response', response: { subtype: 'success', request_id: message.request_id, response: {} } });
    else if (message.type === 'user') {
      write({ type: 'system', subtype: 'init', session_id: '00000000-0000-4000-8000-000000000001', model: 'fixture' });
      if (!process.env.AI_FIXTURE_WAIT) write({ type: 'control_request', request_id: 'permission', request: { subtype: 'can_use_tool', tool_name: 'Bash', input: { command: 'fixture' } } });
    } else if (message.type === 'control_response') {
      write({ type: 'keep_alive' });
      fs.writeFileSync(path.join(process.cwd(), 'draft.md'), 'Claude 改稿');
      fs.writeFileSync(path.join(process.cwd(), 'title.txt'), '新标题');
      write({ type: 'result', result: '完成', is_error: false });
    }
  }
});
input.on('close', () => { record({ kind: 'eof' }); process.exit(0); });
