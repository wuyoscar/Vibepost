'use strict';

// Explicit opt-in real CLI smoke. This is not part of node --test tests/*.test.cjs.
// It executes the frontend adapters unchanged, requests only a textual OK, and
// never configures global MCP servers or invokes the Images API.
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { AiService } = require('../lib/ai.cjs');
const base = path.resolve(process.env.VIBEPOST_AI_SMOKE_DIR || 'E:\\software-package\\vibepost-worklog\\real-ai-smoke');
const source = path.resolve(__dirname, '..', '..');
const owner = { id: 'real-cli-smoke', epoch: 0 };
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const session = crypto.randomUUID();
const runFolder = path.join(base, 'runs', stamp);
const eventFile = path.join(runFolder, 'events.jsonl');
const backends = (process.env.VIBEPOST_AI_SMOKE_BACKENDS || 'claude,codex').split(',').filter(value => ['claude', 'codex'].includes(value));
const report = { startedAt: new Date().toISOString(), dataDir: base, runFolder, frontend: ['src/ai/session.js:launchTurn', 'src/ai/backends/claude.js', 'src/ai/backends/codex.js'], prompt: 'Reply with exactly OK. Do not use any tools, run commands, read or edit files, create images, or change configuration.', status: {}, selectedModels: {}, results: [] };
let current = null, eventWrites = Promise.resolve();
function redact(value) {
  let text = String(value || '');
  for (const [key, secret] of Object.entries(process.env)) if (/(key|token|secret|password)/i.test(key) && secret.length >= 8) text = text.split(secret).join('…');
  return text.replace(/Bearer\s+[A-Za-z0-9._-]+/gi, 'Bearer …');
}
const service = new AiService({ dataDir: base, environment: { ...process.env, TEMP: path.join(base, 'cache'), TMP: path.join(base, 'cache') }, emit: (eventOwner, event) => {
  const summary = event.type === 'lines' ? { ...event, lines: event.lines.map(line => redact(line)) } : { ...event, stderr: redact(event.stderr) };
  eventWrites = eventWrites.then(() => fs.appendFile(eventFile, JSON.stringify({ owner: eventOwner, ...summary }) + '\n'));
  if (!current || event.turnId !== current.turn.id) return;
  if (event.type === 'lines') {
    for (const line of event.lines) {
      try { current.backend.read(current.turn, JSON.parse(line), current.core); } catch (error) { current.errors.push(redact(error.message)); }
    }
  } else if (event.type === 'exit') {
    current.exit = { status: event.status, signal: event.signal, cancelled: event.cancelled, stderr: redact(event.stderr), unchangedFiles: event.markdown === current.request.markdown && event.title === current.request.title && event.caption === current.request.caption };
    current.resolve();
  }
} });

async function adapter(id) {
  const root = {};
  const context = vm.createContext({ window: root, crypto, console });
  vm.runInContext(await fs.readFile(path.join(source, 'src', 'ai', 'backends', id + '.js'), 'utf8'), context, { filename: id + '.js' });
  return root.MediaCraftAI.backends[id];
}

async function oneTurn(backend, index, previous) {
  const draftId = backend.id + '-smoke-' + session;
  const turn = { id: crypto.randomUUID(), draftId, backend, chosenModel: report.selectedModels[backend.id] || null, chosenEffort: null, instructions: 'This is a connectivity smoke test. Reply only OK. Do not use tools or read/change files.', prompt: report.prompt, ...backend.session(previous || {}), result: null };
  turn.state = backend.state?.() || {};
  const state = { turn, backend, reply: '', errors: [], session: null, result: null, events: 0, pending: [] };
  const send = message => {
    const call = service.respond(owner, { draftId, turnId: turn.id, message }).catch(error => { state.errors.push(redact(error.message)); return service.cancel(owner, { draftId }); });
    state.pending.push(call); return call;
  };
  const core = {
    tools: {
      list: () => [],
      call: async () => { throw new Error('Smoke test forbids App tools'); },
      handle: async message => {
        let result;
        if (message?.method === 'initialize') result = { protocolVersion: message.params?.protocolVersion || '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'mediacraft', version: 'smoke' } };
        else if (message?.method === 'tools/list') result = { tools: [] };
        else return { jsonrpc: '2.0', id: message?.id ?? 0, error: { code: -32601, message: 'Smoke test forbids App tools' } };
        return { jsonrpc: '2.0', id: message.id, result };
      },
    },
    send: (_turn, message) => send(message),
    reply: (_turn, id, response, error) => send(backend.reply(id, response, error)),
    session: (_turn, value) => { state.session = value; turn.sessionId = value.sessionId; },
    result: (_turn, value) => { state.result = value; turn.result = value; if (value.error) state.errors.push(redact(value.error)); },
    textStart: () => { state.events++; }, textDelta: (_turn, value) => { state.reply += value; state.events++; }, text: (_turn, value) => { state.reply = value; state.events++; },
    answered: () => {}, tool: (_turn, text) => { state.errors.push('Unexpected tool: ' + redact(text)); },
    generating: () => { state.errors.push('Unexpected image generation'); }, candidates: () => { state.errors.push('Unexpected image candidate'); },
    askPermission: (_turn, permission) => { state.errors.push('Unexpected permission request: ' + permission.title); send(backend.reply(permission.replyId ?? permission.id, backend.permissionReply(permission, 'deny', 'Smoke test forbids tools').response)); },
    runTool: (_turn, id, execute) => { const call = Promise.resolve().then(() => execute({})).then(response => send(backend.reply(id, response))).catch(error => send(backend.reply(id, null, error.message))); state.pending.push(call); },
    fail: (_turn, message) => { state.errors.push(redact(message)); service.cancel(owner, { draftId }).catch(() => {}); },
    late: (_turn, message) => { state.errors.push('Late request: ' + message); }, withdraw: () => {}, allowed: () => false,
  };
  state.core = core;
  state.request = { turnId: turn.id, draftId, backend: backend.id, prompt: report.prompt, markdown: '# Smoke test\n\nDo not edit this file.\n', title: 'Smoke test', caption: 'Do not edit', systemPrompt: turn.instructions, agentsFile: 'Connectivity smoke test. Do not read or edit files; respond only OK.', ...backend.launch(turn, { rules: [] }) };
  state.done = new Promise(resolve => { state.resolve = resolve; });
  current = state;
  const start = Date.now();
  const timer = setTimeout(() => { state.errors.push('Turn timeout after 180 seconds'); service.cancel(owner, { draftId }).catch(() => {}); }, 180000);
  try {
    await service.send(owner, state.request);
    await state.done;
    await Promise.allSettled(state.pending);
    const success = !!state.result && !state.result.error && !state.errors.length && state.exit?.status === 0 && state.exit.unchangedFiles && state.reply.trim() === 'OK';
    const result = { backend: backend.id, turn: index, resume: turn.resume, success, durationMs: Date.now() - start, sessionId: state.session?.sessionId || turn.sessionId, reply: state.reply.trim(), streamEvents: state.events, result: state.result, exit: state.exit, errors: state.errors };
    report.results.push(result);
    console.log(JSON.stringify({ backend: backend.id, turn: index, resume: turn.resume, success, durationMs: result.durationMs, reply: result.reply, errors: result.errors, exitStatus: result.exit?.status }));
    return { resumable: success, sessionId: result.sessionId };
  } catch (error) {
    report.results.push({ backend: backend.id, turn: index, resume: turn.resume, success: false, durationMs: Date.now() - start, errors: [redact(error.message)] });
    console.log(JSON.stringify({ backend: backend.id, turn: index, success: false, error: redact(error.message) }));
    return { resumable: false };
  } finally { clearTimeout(timer); current = null; }
}

async function main() {
  await fs.mkdir(runFolder, { recursive: true }); await fs.mkdir(path.join(base, 'cache'), { recursive: true });
  for (const id of backends) {
    report.status[id] = await service.status(true, id);
    console.log(JSON.stringify({ backend: id, available: report.status[id].available, version: report.status[id].version, error: report.status[id].error }));
    if (!report.status[id].available) { report.results.push({ backend: id, turn: 0, success: false, errors: [report.status[id].error || 'CLI unavailable'] }); continue; }
    if (id === 'codex' && process.env.VIBEPOST_AI_SMOKE_DISCOVER_MODEL === '1') {
      const models = (await service.models(id)).models;
      report.advertisedModels = models;
      report.selectedModels[id] = models.find(model => model.id === 'gpt-5.1-codex-mini')?.id || models.find(model => model.isDefault)?.id || models[0]?.id;
      if (!report.selectedModels[id]) throw new Error('Codex did not advertise any usable model');
      console.log(JSON.stringify({ backend: id, selectedModel: report.selectedModels[id], advertisedModels: models.map(model => model.id) }));
    }
    const backend = await adapter(id);
    const previous = await oneTurn(backend, 1);
    if (previous.resumable) await oneTurn(backend, 2, previous);
  }
  report.finishedAt = new Date().toISOString(); report.success = report.results.length === backends.length * 2 && report.results.every(value => value.success);
  await service.dispose(); await eventWrites;
  const reportFile = path.join(runFolder, 'report.json');
  await fs.writeFile(reportFile, redact(JSON.stringify(report, null, 2)));
  console.log(JSON.stringify({ report: reportFile, success: report.success }));
  process.exitCode = report.success ? 0 : 1;
}
main().catch(async error => {
  console.error(redact(error.message));
  report.finishedAt = new Date().toISOString(); report.success = false; report.harnessError = redact(error.message);
  await service.dispose(); await eventWrites;
  await fs.mkdir(runFolder, { recursive: true });
  await fs.writeFile(path.join(runFolder, 'report.json'), redact(JSON.stringify(report, null, 2)));
  process.exitCode = 1;
});
