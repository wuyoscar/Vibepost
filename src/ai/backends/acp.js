// AI 后端：说 ACP（Agent Client Protocol，stdio 上的 JSON-RPC，每行一条）的本机 Agent，一个适配器管几个：
// OpenCode（`opencode acp`）、Oh My Pi（`omp acp`）、Kimi Code（`kimi acp`）。壳那边见 AIBackends.swift 的 ACPBackend。
// 它们各自接着很多家的模型（自己配的 OpenAI 兼容接口也算），能选的模型由 Agent 自己报（会话的 configOptions）。
// 壳只写开头的 initialize；这里接着说：握手回来开会话或续会话，按这篇选的换模型、推理强度，再发这一轮的话。
// 流式的回复、它用的工具、权限请求都在这里翻成会话核心（src/ai/session.js）的动作；回答经壳写回 stdin。
// session/prompt 的回答就是说完了（壳随即关上 stdin，它就退出）。
// App 的工具经 MCP 挂给它：壳每一轮开一个只给这一轮用的 MCP 服务（开会话时写进 mcpServers，macOS AIToolServer.swift，
// Windows windows/lib/ai.cjs 的 _toolEndpoint），Agent 发来的 MCP 消息壳原样推过来（method 是 vibepost/mcp 的一行），
// 这里交给 src/ai/tools.js 回答，回答经壳写回那条连接。所以只有 API 的模型套上这些 Agent 之后，既能改文件也能操作 App。
// 说明书在新会话的第一句里给它（ACP 没有系统提示词这一项，工作副本里的 AGENTS.md 它们自己会读）。
// 再加一个说 ACP 的 Agent：在下面的 AGENTS 里登记一行，壳里 AISessions 的 backends / locators 各加一项（docs/app-api.md 的「加一个后端」）。
(function (root) {
  "use strict";

  const backends = ((root.MediaCraftAI ||= {}).backends ||= {});

  // name：会话里、确认框里怎么称呼它；program：终端里的命令；install、login：找不到、没登录时指引里写的命令（没有就不写）
  const AGENTS = [
    { id: "opencode", name: "OpenCode", program: "opencode", install: "npm install -g opencode-ai", login: "opencode auth login" },
    { id: "omp", name: "Oh My Pi", program: "omp", install: "bun install -g @oh-my-pi/pi-coding-agent", login: "omp login" },
    { id: "kimi", name: "Kimi Code", program: "kimi", install: null, login: "kimi login" },
  ];

  // 我们发出的请求的 id：握手（壳写的）、开或续会话、发这一轮；换模型、推理强度从 10 数起
  const ID = { initialize: 1, session: 2, prompt: 3, option: 10 };

  // App 的工具挂给它时那组工具的名字（和 Claude Code 里的一样）；壳推过来的 MCP 消息那一行的 method
  const TOOL_SERVER = "mediacraft";
  const TOOL_METHOD = "vibepost/mcp";

  const file = (path) => String(path || "").split("/").pop();
  const request = (id, method, params) => ({ jsonrpc: "2.0", id, method, params });

  // 会话的一个设置（configOptions 里 category 是 model / thought_level 的选单）与它能选的值（可能分了组）
  const selectOf = (options, category) => (Array.isArray(options) ? options : [])
    .find((option) => option?.category === category && option.type === "select") ?? null;
  const valuesOf = (option) => (option?.options ?? [])
    .flatMap((item) => (Array.isArray(item?.options) ? item.options : [item]))
    .filter((item) => typeof item?.value === "string");
  const currentModel = (state) => selectOf(state.options, "model")?.currentValue ?? null;

  // 用户拒绝了的工具调用（会话 id + 调用 id）：它随后报「没成功」时不再记一行（确认框那一行已经写了）
  const denied = new Set();

  // 这个工具调用里的路径与命令（各家的写法不一样：locations、rawInput.path / filePath / file_path）
  function targetsOf(call) {
    const input = call.rawInput && typeof call.rawInput === "object" ? call.rawInput : {};
    const paths = [...(call.locations ?? []).map((location) => location?.path), input.path, input.filePath, input.file_path]
      .filter((path) => typeof path === "string" && path);
    return {
      paths: [...new Set(paths)],
      command: typeof input.command === "string" ? input.command : null,
      url: typeof input.url === "string" ? input.url : null,
    };
  }

  // 这个工具调用是不是 App 的工具（各家写法不一样：OpenCode 的标题是 mediacraft_<工具>，Oh My Pi 的在 rawInput.path 里
  // 写 xd://mcp__mediacraft_<工具>）。App 的工具执行时自己记一行、要问的自己问，这里不再记、不再问
  function isAppTool(call) {
    const input = call?.rawInput && typeof call.rawInput === "object" ? call.rawInput : {};
    const names = [call?.title, input.path, input.name, input.tool].filter((value) => typeof value === "string");
    return names.some((name) => new RegExp(`(^|mcp__)${TOOL_SERVER}(_|\\.|:)`).test(name));
  }

  // 会话里记一行：它做了什么。读文件、查找、思考不记（太碎）；没成功的写明
  function describeCall(call) {
    const failed = call.status === "failed" ? "没成功：" : " ";
    const { paths, command, url } = targetsOf(call);
    const where = paths.map(file).join("、");
    switch (call.kind) {
      case "execute": return `运行${failed}${command ?? call.title ?? ""}`;
      case "edit": return `修改${failed}${where || call.title || ""}`;
      case "delete": return `删除${failed}${where || call.title || ""}`;
      case "move": return `移动${failed}${where || call.title || ""}`;
      case "fetch": return `打开网页${failed}${url ?? call.title ?? ""}`;
      case "read":
      case "search":
      case "think": return null;
      default: return command ? `运行${failed}${command}` : `使用工具${failed}${call.title ?? ""}`;
    }
  }

  // 权限请求 → 确认框里显示的（标题接在「OpenCode 想」后面）。key 是「本次会话都允许」记下的规则：
  // 一模一样的操作（同一条命令、同样的文件、同一个网址）之后才不再问；认不出是什么操作时没有这个选项
  function permissionView(params) {
    const call = params.toolCall ?? {};
    const { paths, command, url } = targetsOf(call);
    if (call.kind === "execute" || (command && !call.kind)) {
      return { tool: "command", title: "运行命令", detail: command ?? call.title ?? "", key: command ? ["execute", command] : null, scopeText: `运行「${command}」` };
    }
    if (["edit", "delete", "move"].includes(call.kind)) {
      const title = { edit: "修改文件", delete: "删除文件", move: "移动文件" }[call.kind];
      return { tool: "fileChange", title, detail: paths.join("\n") || call.title || "", key: paths.length ? [call.kind, paths] : null, scopeText: `${title.slice(0, 2)} ${paths.map(file).join("、")}` };
    }
    if (call.kind === "fetch") {
      return { tool: "network", title: "打开网页", detail: url ?? call.title ?? "", key: url ? ["fetch", url] : null, scopeText: `打开 ${url}` };
    }
    if (call.kind === "read" || call.kind === "search") {
      return { tool: "read", title: call.kind === "read" ? "读取文件" : "查找文件", detail: paths.join("\n") || call.title || "", key: paths.length ? [call.kind, paths] : null, scopeText: `读取 ${paths.map(file).join("、")}` };
    }
    const detail = command ?? (call.rawInput ? JSON.stringify(call.rawInput, null, 1) : "");
    return { tool: "other", title: call.title ? `使用工具「${call.title}」` : "做一个操作", detail, key: null, scopeText: "" };
  }

  // 新会话的第一句带上说明书；续上的会话里它已经有了
  const promptText = (turn) => (turn.resume ? turn.prompt : `${turn.instructions}\n\n下面是用户这一轮说的话：\n\n${turn.prompt}`);

  // 没登录时各家报的错（Kimi Code：Authentication required）
  const AUTH_ERROR = /auth|log ?in|credential|unauthori[sz]ed|api key/i;

  function adapter(agent) {
    const label = agent.name;

    // 开会话或续会话（工作目录、MCP 服务由壳填）。续会话：有 session/resume 用它（不重放历史），
    // 只有 session/load 时用它、重放的历史不看；两样都没有的 Agent 每轮都是新会话
    function sessionRequest(turn) {
      const caps = turn.state.caps ?? {};
      const method = !turn.resume ? null : caps.sessionCapabilities?.resume ? "session/resume" : caps.loadSession ? "session/load" : null;
      if (!method) {
        turn.resume = false;
        return request(ID.session, "session/new", {});
      }
      turn.state.replaying = method === "session/load";
      return request(ID.session, method, { sessionId: turn.sessionId });
    }

    // 会话有了：这篇选了模型、推理强度而它现在用的不是这个，就先换；都对了发这一轮的话
    function proceed(turn, core) {
      const state = turn.state;
      const model = selectOf(state.options, "model");
      if (!state.modelSet) {
        state.modelSet = true;
        if (turn.chosenModel && model && model.currentValue !== turn.chosenModel) {
          return setOption(turn, core, model.id, turn.chosenModel, `换到模型「${turn.chosenModel}」`);
        }
        if (turn.chosenModel && !model) return core.fail(turn, `${label} 没有报能选的模型，这篇选的「${turn.chosenModel}」用不上；把模型改回「默认模型」再试。`);
      }
      const effort = selectOf(state.options, "thought_level");
      if (!state.effortSet) {
        state.effortSet = true;
        if (turn.chosenEffort && effort && effort.currentValue !== turn.chosenEffort
          && valuesOf(effort).some((item) => item.value === turn.chosenEffort)) {
          return setOption(turn, core, effort.id, turn.chosenEffort, "调推理强度");
        }
      }
      core.session(turn, { model: currentModel(state) });
      state.startedAt = Date.now();
      return core.send(turn, request(ID.prompt, "session/prompt", { sessionId: turn.sessionId, prompt: [{ type: "text", text: promptText(turn) }] }));
    }

    function setOption(turn, core, configId, value, what) {
      const id = ID.option + turn.state.optionRequests;
      turn.state.optionRequests += 1;
      turn.state.pending[id] = what;
      return core.send(turn, request(id, "session/set_config_option", { sessionId: turn.sessionId, configId, value }));
    }

    // 一段回复说完（它去用工具了，或这一轮说完了）
    function endText(turn, core) {
      const state = turn.state;
      if (!state.streaming) return;
      state.streaming = false;
      state.reply = state.segment;
      core.text(turn, state.segment);
    }

    // 这一轮怎么结束的（session/prompt 的回答）
    function finish(turn, { result, error }, core) {
      const state = turn.state;
      endText(turn, core);
      const reasons = {
        max_tokens: `${label} 说到一半到了长度上限`,
        max_turn_requests: `${label} 这一轮的步数用完了`,
        refusal: "模型拒绝了这个请求",
      };
      const problem = error
        ? (AUTH_ERROR.test(error.message ?? "") ? notLoggedIn(state, error) : `${label} 没能完成这一轮：${error.message ?? "出错了"}`)
        : reasons[result?.stopReason] ?? null;
      core.result(turn, { error: problem, reply: state.reply ?? "", model: currentModel(state), durationMs: Date.now() - state.startedAt });
    }

    const notLoggedIn = (state, error) => `${label} 还没有登录${state.auth ? `：${state.auth}` : agent.login ? `：在终端里运行 ${agent.login}` : ""}（${error.message ?? ""}）`;

    // 我们发出的请求的回答：握手 → 开 / 续会话 →（换模型、推理强度）→ 这一轮
    function response(turn, message, core) {
      const { id, result, error } = message;
      const state = turn.state;
      if (id === ID.initialize) {
        if (error) return core.fail(turn, `${label} 没能启动：${error.message ?? "出错了"}`);
        state.caps = result?.agentCapabilities ?? {};
        state.auth = (result?.authMethods ?? []).map((method) => method?.description).find(Boolean) ?? null;
        return core.send(turn, sessionRequest(turn));
      }
      if (id === ID.session) {
        state.replaying = false;
        if (error) {
          if (AUTH_ERROR.test(error.message ?? "")) return core.fail(turn, notLoggedIn(state, error));
          if (!turn.resume) return core.fail(turn, `${label} 没能开始会话：${error.message ?? "出错了"}`);
          // 续不上：它那边没有这个会话了（各家报的错不一样，分不出别的原因），下一轮开新会话
          state.lost = true;
          return core.fail(turn, `之前的会话在 ${label} 里续不上了（${error.message ?? "出错了"}），下一轮会开一个新会话。`);
        }
        state.options = result?.configOptions ?? [];
        core.session(turn, { sessionId: result?.sessionId ?? turn.sessionId, model: currentModel(state) });
        return proceed(turn, core);
      }
      if (id === ID.prompt) return finish(turn, message, core);
      const what = state.pending[id];
      if (!what) return undefined;
      delete state.pending[id];
      if (error) return core.fail(turn, `${label} 没能${what}：${error.message ?? "出错了"}`);
      // 换了模型，能选的推理强度可能跟着变
      if (Array.isArray(result?.configOptions)) state.options = result.configOptions;
      return proceed(turn, core);
    }

    // 它要问的：只认权限请求；别的（读写文件、开终端：握手时说了不提供）回答不支持
    function agentRequest(turn, { id, method, params = {} }, core) {
      if (method !== "session/request_permission") {
        core.reply(turn, id, null, `Vibepost 不支持 ${method}`);
        return;
      }
      // App 的工具不在这里问（该问的工具自己问）
      if (isAppTool(params.toolCall)) {
        core.reply(turn, id, backends[agent.id].permissionReply({ input: params }, "allow").response);
        return;
      }
      const { key, scopeText, ...view } = permissionView(params);
      const rule = key ? `acp:${JSON.stringify(key)}` : null;
      // 每轮是新进程，请求 id 会重复：确认框用带上这一轮的 id，回答时用它原来的 id
      const asked = { id: `${turn.id}:${id}`, replyId: id, input: params, ...view, note: "", rule, scope: rule ? [scopeText] : [] };
      // 这篇的会话里「本次会话都允许」过一模一样的：不再问
      if (rule && core.allowed(turn, rule)) {
        core.reply(turn, id, backends[agent.id].permissionReply(asked, "allow").response);
        return;
      }
      endText(turn, core);
      core.askPermission(turn, asked);
    }

    function update(turn, params, core) {
      const state = turn.state;
      // 续会话时重放的历史不看；别的会话的（它的子会话）不混进来
      if (state.replaying || (params.sessionId && turn.sessionId && params.sessionId !== turn.sessionId)) return;
      const change = params.update ?? {};
      if (change.sessionUpdate === "agent_message_chunk") {
        const text = change.content?.type === "text" ? String(change.content.text ?? "") : "";
        if (!text) return;
        if (!state.streaming) {
          state.streaming = true;
          state.segment = "";
          core.answered(turn);
          core.textStart(turn);
        }
        state.segment += text;
        core.textDelta(turn, text);
      } else if (change.sessionUpdate === "tool_call" || change.sessionUpdate === "tool_call_update") {
        if (!change.toolCallId) return;
        endText(turn, core);
        const known = state.calls[change.toolCallId] ?? {};
        // 后来的更新只带变了的字段
        const call = Object.fromEntries(["title", "kind", "status", "locations", "rawInput"]
          .map((field) => [field, change[field] ?? known[field]]).filter(([, value]) => value != null));
        call.logged = known.logged;
        state.calls[change.toolCallId] = call;
        if (call.logged || !["completed", "failed"].includes(call.status)) return;
        call.logged = true;
        const refused = denied.delete(`${turn.sessionId}:${change.toolCallId}`);
        const line = refused || isAppTool(call) ? null : describeCall(call);
        if (line) core.tool(turn, line);
      }
    }

    function read(turn, message, core) {
      if (message.id !== undefined && message.method === undefined) {
        response(turn, message, core);
      } else if (message.id !== undefined) {
        // 说完之后还来的请求：送不到了（壳已经关上 stdin）
        if (turn.result) {
          core.late(turn, "请你确认一个操作");
          return;
        }
        try {
          agentRequest(turn, message, core);
        } catch (error) {
          core.reply(turn, message.id, null, error?.message || String(error));
        }
      } else if (message.method === "session/update") {
        update(turn, message.params ?? {}, core);
      } else if (message.method === TOOL_METHOD) {
        // 它经挂上的 MCP 服务发来的一条消息（握手、列工具、调工具）：交给 App 的工具回答，一次执行一个（核心排队）。
        // 通知（没有 id）不用回答
        const { connection, message: call } = message.params ?? {};
        if (!call || call.id === undefined || call.id === null || turn.result) return;
        endText(turn, core);
        core.runTool(turn, { mcp: connection, id: call.id }, (context) => core.tools.handle(call, context));
      }
    }

    // 给它的回答：对它的请求（权限）的是一条 JSON-RPC 回答，写进 stdin；对 MCP 消息的（requestId 是 { mcp, id }）
    // 是工具给的整条 JSON-RPC 回答，壳写回那条连接
    function reply(requestId, result, error = null) {
      if (requestId && typeof requestId === "object") {
        const message = error ? { jsonrpc: "2.0", id: requestId.id, error: { code: -32603, message: error } } : result;
        return { mcp: { connection: requestId.mcp, message } };
      }
      return error
        ? { jsonrpc: "2.0", id: requestId, error: { code: -32601, message: error } }
        : { jsonrpc: "2.0", id: requestId, result: result ?? {} };
    }

    return {
      id: agent.id,
      name: label,
      label,
      // 说 ACP 的后端：模型、推理强度由 Agent 自己报，没选过时跟随它自己的设置（session.js、panel.js 按这个分支）
      protocol: "acp",
      program: agent.program,
      install: agent.install,
      login: agent.login,
      // App 的工具在它那边是 MCP 服务 mediacraft 里的工具（各家显示的名字不一样，多半带着 mediacraft 前缀）
      toolNames: `MCP 服务 ${TOOL_SERVER} 里的工具，名字可能带着 ${TOOL_SERVER} 前缀`,
      // 生图怎么做（写进给它的说明）：和 Claude Code 一样用 App 的 generate_image
      imagePrompt: backends.claude?.imagePrompt ?? "",
      // 会话 id 由 Agent 起，答过一次之后下一轮接着
      session: (ai) => (ai.resumable && ai.sessionId ? { sessionId: ai.sessionId, resume: true } : { sessionId: null, resume: false }),
      // 壳只起 `<program> acp`：开会话、续会话、换模型都由这里经 stdin 发
      launch: () => ({}),
      // 这一轮里这边记着的：它的能力与登录办法、会话的设置（模型、推理强度的选单）、换设置的请求、工具调用、
      // 正在流的这一段回复、最后一段回复、续不上会话、正在重放历史
      state: () => ({
        caps: null, auth: null, options: [], pending: {}, optionRequests: 0, modelSet: false, effortSet: false,
        calls: {}, streaming: false, segment: "", reply: null, lost: false, replaying: false, startedAt: Date.now(),
      }),
      read,
      reply,
      // 用户的回答 → 它给的选项里的一个。「本次会话都允许」对它也只答「允许这一次」，规则由这边记着
      // （它自己的「总是允许」范围各家不一样，往往比这一条命令宽；它每轮是新进程，也记不到下一轮）
      permissionReply(asked, decision) {
        const options = Array.isArray(asked.input?.options) ? asked.input.options : [];
        const pick = (kinds) => kinds.map((kind) => options.find((option) => option?.kind === kind)).find(Boolean);
        const option = decision === "deny" ? pick(["reject_once", "reject_always"]) : pick(["allow_once", "allow_always"]);
        if (decision === "deny" && asked.input?.toolCall?.toolCallId) denied.add(`${asked.input.sessionId}:${asked.input.toolCall.toolCallId}`);
        return {
          response: { outcome: option ? { outcome: "selected", optionId: option.optionId } : { outcome: "cancelled" } },
          rules: decision === "session" && asked.rule ? [asked.rule] : [],
        };
      },
      exitError(exit) {
        const stderr = String(exit.stderr || "").trim().split("\n").filter(Boolean).at(-1);
        return stderr || `${agent.program} 意外退出（${exit.signal ? `信号 ${exit.signal}` : `退出码 ${exit.status}`}）`;
      },
      lostSession: (exit, turn) => Boolean(turn?.state?.lost),
    };
  }

  for (const agent of AGENTS) backends[agent.id] = adapter(agent);

  // 壳的 ai/models 回来的是会话的 configOptions（原样），这里挑出模型与推理强度：
  // [{ id, name, isDefault（它现在用的）, efforts（现在能选的推理强度，各模型不一定一样）, defaultEffort }]
  root.MediaCraftAI.acpModels = (options) => {
    const model = selectOf(options, "model");
    const effort = selectOf(options, "thought_level");
    const efforts = valuesOf(effort).map((item) => item.value);
    return valuesOf(model).map((item) => ({
      id: item.value,
      name: String(item.name ?? item.value),
      isDefault: item.value === model.currentValue,
      efforts,
      defaultEffort: effort?.currentValue ?? null,
    }));
  };
})(window);
