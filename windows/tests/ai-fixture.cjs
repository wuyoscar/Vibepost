'use strict';
const fs = require('node:fs');
const readline = require('node:readline');
const path = require('node:path');
const args = process.argv.slice(2);
if (args[0] === '--version') { console.log('fixture-cli 1.2.3'); process.exit(0); }
if (args[0] === 'login') process.exit(process.env.AI_FIXTURE_LOGIN_FAIL ? 1 : 0);
const record = value => { if (process.env.AI_FIXTURE_LOG) fs.appendFileSync(process.env.AI_FIXTURE_LOG, JSON.stringify(value) + '\n'); };
record({ kind: 'launch', args, cwd: process.cwd(), temp: process.env.TEMP, backgroundDisabled: process.env.CLAUDE_CODE_DISABLE_BACKGROUND_TASKS });
const write = value => process.stdout.write(JSON.stringify(value) + '\n');
let initialized = false;
const input = readline.createInterface({ input: process.stdin });
input.on('line', text => {
  const message = JSON.parse(text); record(message);
  if (args[0] === 'app-server') {
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
