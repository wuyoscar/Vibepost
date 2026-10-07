// 外部 Agent（MCP）：终端里的 Claude Code 等启动 mediacraft-mcp，经 Unix 域套接字连进 App（壳 ExternalAgents.swift），
// 工具清单与调用由壳交到这里的 handle()：一次执行一个（和 AI 助手里的工具一样，几个改稿子的动作并发会互相覆盖）。
// 工具 = AI 助手里标了 shared 的那些（src/ai/tools.js）+ 外部 Agent 另外要的（src/mcp/tools.js），只经 App API 读写。
// 每次会话（一个 mediacraft-mcp 进程，重连不变）认定一篇稿子（新建、打开的那篇；没有时是它第一次看、改稿子时正在编辑的那篇），
// 认定由壳记着（ShellCore），请求交到开着那篇的窗口；那篇已经不在任何窗口里开着（用户切走了、关了窗口）时不再动手，免得改错稿子。
// 新建的稿子开在壳为它开的新窗口里（壳带来 reuseBlank：那个窗口里新建的空稿子就是它要的）。
// 改稿子的调用都是撤销历史里的一步（⌘Z），另外列进「外部 Agent 的操作」（App 开着期间，最近 50 个），可以逐个撤销；
// 新建、打开、导出、发送也列进去（没有撤销）。对外是 mediacraft.mcp（docs/app-api.md）。
(function (root) {
  "use strict";

  const mc = () => root.mediacraft;
  const native = root.MediaCraftNative?.mcp ?? null;
  const shared = root.MediaCraftAITools.shared;
  const LOG_LIMIT = 50;

  // 工具在清单里的顺序：手册、稿子、样式、结构、图片、出图与导出
  const ORDER = [
    "get_manual",
    "list_drafts", "get_draft", "create_draft", "open_draft", "update_draft",
    "set_theme", "set_style", "set_mode", "list_palettes", "apply_palette",
    "insert_page_break", "remove_page_break", "move_section", "restyle_block", "set_card_css",
    "import_images", "insert_image", "move_image", "resize_image", "crop_image",
    "get_pages", "render_pages", "export", "send_to_iphone",
  ];
  const own = new Map(root.MediaCraftMCPTools.TOOLS.map((tool) => [tool.name, tool]));
  const common = new Map(shared.definitions().map((tool) => [tool.name, tool]));
  const TOOLS = ORDER.map((name) => own.get(name) ?? common.get(name));

  const windows = root.MediaCraftNative?.windows ?? null;
  const listeners = new Set();
  let status = { available: false, enabled: false, clients: 0, command: null };
  // 外部 Agent 的操作：{ id, text, draftId, at, undone }，旧的在前；undoers：操作 id → undo()
  let log = [];
  const undoers = new Map();
  let queue = Promise.resolve();

  // 这次会话认定这篇（壳记着）
  function bind(session, draftId) {
    return windows?.bindAgent(session, draftId);
  }

  // 一次只做一件：工具调用与撤销排在同一个队列里，几个改稿子的动作并发会互相覆盖
  function serial(task) {
    const run = queue.then(task);
    queue = run.catch(() => undefined);
    return run;
  }

  function emit() {
    for (const listener of listeners) listener();
  }

  function record(draftId, text, undo = null) {
    const entry = { id: crypto.randomUUID(), text, draftId, at: Date.now(), undone: false };
    log = [...log, entry].slice(-LOG_LIMIT);
    if (undo) undoers.set(entry.id, undo);
    for (const id of undoers.keys()) {
      if (!log.some((item) => item.id === id)) undoers.delete(id);
    }
    emit();
  }

  const view = (entry) => ({ ...entry, undoable: !entry.undone && undoers.has(entry.id) });

  // 这次会话要动手的那篇：认定了的就是它（壳把请求交到开着它的窗口；它已经不在任何窗口里开着就报错），
  // 还没认定时认定这个窗口正开着的这篇
  async function draftFor(request) {
    const draft = await mc().drafts.current();
    const bound = request.bound ?? null;
    if (!bound) await bind(request.session, draft.id);
    else if (bound !== draft.id) {
      const list = await mc().drafts.list();
      const name = (id) => list.find((item) => item.id === id)?.title || id;
      throw new Error(`用户在 Vibepost 里切到了别的稿子，「${name(bound)}」现在没有在哪个窗口里开着。要接着改它，先用 open_draft 打开它（id ${bound}）；要改用户正在看的「${name(draft.id)}」，用 open_draft 打开 ${draft.id}`);
    }
    return draft;
  }

  // 工具执行时的上下文：AI 助手的工具要的那几项（没有 draft.md、不能问用户），加上外部 Agent 的
  function contextFor(request, draft) {
    const context = {
      draftId: draft.id,
      turnId: null,
      merge: root.MediaCraftAI.merge,
      sync: null,
      line: () => undefined,
      action: ({ text, undo }) => record(context.draftId, text, undo),
      record: (text) => record(context.draftId, text),
      candidates: () => {
        throw new Error("外部 Agent 不能放配图候选，用 import_images");
      },
      confirm: async () => "deny",
      // 新建、打开之后改认定这篇
      bind: async (id) => {
        context.draftId = id;
        await bind(request.session, id);
      },
      // 壳为这次新建开了一个新窗口：那里新建的空稿子就是它要的
      reuseBlank: Boolean(request.reuseBlank),
      files: request.files,
      exportRequest: request.exportRequest,
    };
    return context;
  }

  async function callTool(request) {
    const { name, arguments: args } = request.params ?? {};
    const tool = TOOLS.find((item) => item.name === name);
    if (!tool) throw new Error(`没有这个工具：${name}`);
    const input = args && typeof args === "object" && !Array.isArray(args) ? args : {};
    try {
      const draft = tool.free ? await mc().drafts.current() : await draftFor(request);
      const context = contextFor(request, draft);
      if (common.has(name)) return await shared.call(name, input, context);
      const outcome = await tool.run(input, context, draft);
      return typeof outcome === "string" ? shared.reply(outcome) : outcome;
    } catch (error) {
      return { content: [{ type: "text", text: error?.message || String(error) }], isError: true };
    }
  }

  async function dispatch(request) {
    if (request.method === "tools/list") {
      return { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) };
    }
    if (request.method === "tools/call") return callTool(request);
    // 握手时 MCP 服务要的操作手册（接在握手说明后面，src/engine/manual.js）
    if (request.method === "manual/get") return { text: root.MediaCraftManual.document() };
    throw new Error(`不支持 ${request.method}`);
  }

  // 壳交来的一条请求（JSON 文本）：{ session, method, params, files?, exportRequest? } → { result } 或 { error }（JSON 文本）
  async function handle(message) {
    try {
      return JSON.stringify({ result: await serial(() => dispatch(JSON.parse(message))) });
    } catch (error) {
      return JSON.stringify({ error: error?.message || String(error) });
    }
  }

  // ===== 开关与状态（壳记着，mcp.json） =====

  function setStatus(next) {
    status = {
      available: Boolean(next.available),
      enabled: Boolean(next.enabled),
      clients: Number(next.clients) || 0,
      command: next.command ?? null,
    };
    emit();
    return { ...status };
  }

  async function refresh() {
    return native ? setStatus(await native.status()) : { ...status };
  }

  async function setEnabled(enabled) {
    if (typeof enabled !== "boolean") throw new TypeError("enabled 需要是 true 或 false");
    if (!native) throw new Error("只有在 Vibepost App 里才有外部 Agent 的连接");
    return setStatus(await native.setEnabled(enabled));
  }

  function undo(id) {
    return serial(async () => {
      const entry = log.find((item) => item.id === id);
      const undoer = undoers.get(id);
      if (!entry || !undoer || entry.undone) throw new Error("这个操作已经没法撤销了");
      await undoer();
      undoers.delete(id);
      log = log.map((item) => (item.id === id ? { ...item, undone: true } : item));
      emit();
    });
  }

  native?.onEvent((event) => {
    if (event?.type === "clients") setStatus({ ...status, clients: event.count });
  });
  void refresh().catch(() => undefined);

  root.MediaCraftMCP = {
    handle,
    // 界面（src/mcp/panel.js）用：状态或操作记录变了
    on(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    status: () => ({ ...status }),
    log: () => log.map(view),
    // mediacraft.mcp（App API）
    api: {
      status: () => refresh(),
      setEnabled,
      log: async () => log.map(view),
      undo,
    },
  };
})(window);
