// AI 后端：本机的 Codex（`codex app-server`，stdio 上的 JSON-RPC，每行一条；壳那边见 AIBackends.swift 的 CodexBackend）。
// 壳只写开头的握手；这里接着说：握手回来开线程（新会话，挂上 App 的工具）或续线程，线程回来发这一轮的话，
// 流式的回复、它用的命令与改的文件、审批请求与 App 工具的调用都在这里翻成会话核心（src/ai/session.js）的动作。
// 回答（审批、工具的结果）写成 JSON-RPC 的回答，经壳写回 stdin。turn/completed 就是说完了（壳随即关上 stdin，它就退出）。
(function (root) {
  "use strict";

  const backends = ((root.MediaCraftAI ||= {}).backends ||= {});

  // 生图在 Codex 那边用它自带的（第 06 张票），不给它 App 的生图工具
  const EXCLUDED_TOOLS = ["generate_image"];
  // 线程与这一轮的权限：工作区（这篇的工作副本）里可以改，要别的（联网、目录外、跑有风险的命令）先问
  const APPROVAL_POLICY = "on-request";
  const SANDBOX = "workspace-write";

  const file = (path) => String(path || "").split("/").pop();
  // 配图候选下面的说明（它改写后的提示词）最多这么长
  const CAPTION_LIMIT = 60;
  const caption = (text) => {
    const flat = String(text ?? "").replace(/\s+/g, " ").trim();
    return flat.length > CAPTION_LIMIT ? `${flat.slice(0, CAPTION_LIMIT - 1)}…` : flat;
  };

  // App 的工具 → Codex 的动态工具
  const dynamicTools = (tools) => tools.list({ except: EXCLUDED_TOOLS })
    .map(({ name, description, inputSchema }) => ({ type: "function", name, description, inputSchema }));

  // App 工具的结果（MCP 的样子：content 里是文字与图片）→ 动态工具的回答
  function toolOutput(result) {
    const items = (result?.content ?? []).map((item) => (item.type === "image"
      ? { type: "inputImage", imageUrl: `data:${item.mimeType};base64,${item.data}` }
      : { type: "inputText", text: String(item.text ?? "") }));
    return { success: !result?.isError, contentItems: items.length ? items : [{ type: "inputText", text: "" }] };
  }

  // 线程的设置：新会话挂上 App 的工具（续上的线程 Codex 自己记着它们）
  function threadRequest(turn, core) {
    const params = {
      approvalPolicy: APPROVAL_POLICY,
      sandbox: SANDBOX,
      developerInstructions: turn.instructions,
      ...(turn.chosenModel ? { model: turn.chosenModel } : {}),
    };
    return turn.resume
      ? { id: "thread", method: "thread/resume", params: { ...params, threadId: turn.sessionId, excludeTurns: true } }
      : { id: "thread", method: "thread/start", params: { ...params, dynamicTools: dynamicTools(core.tools) } };
  }

  // 会话里记一行：它做了什么（它自己的回复、App 的工具由别处记）。你拒绝了的不记（确认框那一行已经写了），没成功的写明
  function describeItem(item) {
    if (item.status === "declined") return null;
    const failed = item.status === "failed" ? "没成功：" : "";
    switch (item.type) {
      case "commandExecution": return `运行${failed ? `${failed}` : " "}${item.command ?? ""}`;
      case "fileChange": return `修改${failed ? `${failed}` : " "}${(item.changes ?? []).map((change) => file(change.path)).join("、")}`;
      case "webSearch": return `搜索网页：${item.query ?? ""}`;
      case "mcpToolCall": return `调用 ${item.server} · ${item.tool}`;
      case "imageView": return `查看图片 ${file(item.path)}`;
      default: return null;
    }
  }

  const ACCESS = { read: "读取", write: "写入", deny: "禁止访问" };

  // 文件系统规则（fileSystem.entries）里的一个位置写给人看
  function placeOf(path) {
    if (path?.type === "path") return path.path;
    if (path?.type === "glob_pattern") return `匹配 ${path.pattern} 的文件`;
    const special = path?.value ?? {};
    const places = {
      root: "整个磁盘（/）", minimal: "系统运行需要的最小范围", tmpdir: "临时目录", slash_tmp: "/tmp",
      project_roots: `项目根目录${special.subpath ? `下的 ${special.subpath}` : ""}`,
      unknown: `${special.path ?? "?"}${special.subpath ? `/${special.subpath}` : ""}`,
    };
    return places[special.kind] ?? JSON.stringify(path);
  }

  // 认得的写法：network 只有 enabled；fileSystem 只有 read、write、entries、globScanMaxDepth
  function familiar(wanted) {
    const only = (value, keys) => !value || Object.keys(value).every((key) => keys.includes(key));
    return only(wanted, ["network", "fileSystem"]) && only(wanted.network, ["enabled"])
      && only(wanted.fileSystem, ["read", "write", "entries", "globScanMaxDepth"]);
  }

  // 要的权限写给人看，一项一行：联网、读 / 写哪些位置。有认不出的写法时后面附上完整的请求：框里写的就是会给出去的全部
  function permissionLines(wanted) {
    if (!wanted) return [];
    const lines = [
      wanted.network?.enabled ? "联网" : null,
      ...(wanted.fileSystem?.read ?? []).map((path) => `读取 ${path}`),
      ...(wanted.fileSystem?.write ?? []).map((path) => `写入 ${path}`),
      ...(wanted.fileSystem?.entries ?? []).map((entry) => `${ACCESS[entry?.access] ?? entry?.access ?? "?"} ${placeOf(entry?.path)}`),
    ].filter(Boolean);
    return familiar(wanted) ? lines : [...lines, `完整的请求：${JSON.stringify(wanted)}`];
  }

  // 标题里的几个字：联网、读 / 写工作区以外的文件
  function permissionSummary(wanted) {
    const entries = wanted?.fileSystem?.entries ?? [];
    const writes = wanted?.fileSystem?.write?.length || entries.some((entry) => entry?.access === "write");
    const reads = wanted?.fileSystem?.read?.length || entries.some((entry) => entry?.access === "read");
    return [wanted?.network?.enabled ? "联网" : null, writes ? "写工作区以外的文件" : reads ? "读工作区以外的文件" : null]
      .filter(Boolean).join("、");
  }

  // 审批请求 → 确认框里显示的（标题接在「Codex 想」后面）。rule 是「本次会话都允许」记下的规则：请求的全部要素
  // （命令连同工作目录与额外权限、主机、文件与授权目录、整组权限），只有一模一样的请求之后才不再问；
  // scopeText 是给人看的范围。Codex 没给「本会话接受」这个选项时 rule 为 null
  function approvalView(method, params, state) {
    if (method === "item/commandExecution/requestApproval") {
      const sessionOK = !params.availableDecisions || params.availableDecisions.includes("acceptForSession");
      const extra = permissionLines(params.additionalPermissions);
      const note = [params.reason, extra.length ? `还要：${extra.join("；")}` : null, params.cwd ? `目录：${params.cwd}` : null]
        .filter(Boolean).join("\n");
      // 受管的网络：问的是能不能连这个主机
      const network = params.networkApprovalContext;
      if (network?.host) {
        return {
          tool: "network", title: `访问 ${network.host}`, detail: params.command ?? "", note,
          rule: sessionOK ? `network:${JSON.stringify([network.host, network.protocol ?? null, params.additionalPermissions ?? null])}` : null,
          scopeText: `访问 ${network.host}`,
        };
      }
      const command = params.command ?? "";
      return {
        tool: "command", title: params.kind === "writeStdin" ? "往正在运行的命令里输入" : "运行命令", detail: command, note,
        rule: sessionOK && command
          ? `command:${JSON.stringify([params.kind ?? "command", params.cwd ?? null, command, params.additionalPermissions ?? null])}` : null,
        scopeText: `在同一个目录运行「${command}」${extra.length ? "（要同样的额外权限）" : ""}`,
      };
    }
    if (method === "item/fileChange/requestApproval") {
      const paths = (state.changes[params.itemId] ?? []).map((change) => change.path);
      const root = params.grantRoot ? `之后都能写：${params.grantRoot}` : null;
      return {
        tool: "fileChange", title: "修改文件", detail: [...paths, root].filter(Boolean).join("\n"), note: params.reason ?? "",
        rule: paths.length || params.grantRoot ? `files:${JSON.stringify([paths, params.grantRoot ?? null])}` : null,
        scopeText: `修改 ${paths.map(file).join("、") || params.grantRoot}`,
      };
    }
    // 额外的权限（联网、工作区以外的读写）
    const wanted = params.permissions ?? {};
    const lines = permissionLines(wanted);
    return {
      tool: "permissions", title: `获得更多权限（${permissionSummary(wanted) || "见下面"}）`,
      detail: lines.join("\n") || JSON.stringify(wanted), note: params.reason ?? "",
      rule: `permissions:${JSON.stringify(wanted)}`, scopeText: "同样的这组权限",
    };
  }

  const APPROVALS = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"];

  // 它要问的：审批、App 工具的调用；别的（要用户填表之类）回答不支持。服务端请求不论来自哪个线程都要回答（它在等）。
  function serverRequest(turn, { id, method, params = {} }, core) {
    if (method === "item/tool/call") {
      // 一次只执行一个工具（核心排队）
      core.runTool(turn, id, async (context) => toolOutput(await core.tools.call(params.tool, params.arguments ?? {}, context)));
      return;
    }
    if (APPROVALS.includes(method)) {
      const { scopeText, ...view } = approvalView(method, params, turn.state);
      // Codex 每轮是新进程，请求 id 从 0 数起：确认框用带上这一轮的 id（几篇稿子同时跑也不会撞上），回答时用它原来的 id
      const request = { id: `${turn.id}:${id}`, replyId: id, method, input: params, ...view, scope: view.rule ? [scopeText] : [] };
      // 这篇的会话里「本次会话都允许」过一模一样的：不再问
      if (view.rule && core.allowed(turn, view.rule)) {
        core.reply(turn, id, backends.codex.permissionReply(request, "allow").response);
        return;
      }
      core.askPermission(turn, request);
      return;
    }
    core.reply(turn, id, null, `Vibepost 不支持 ${method}`);
  }

  // 自带的生图没成功的原因（没失败为 null）
  function imageFailure(item) {
    const failure = item.failure;
    if (failure?.type === "usageLimitExceeded") {
      const at = Number(failure.resetsAt);
      const reset = Number.isFinite(at) && at > 0
        ? `，${new Date(at > 1e12 ? at : at * 1000).toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" })} 恢复`
        : "";
      return `Codex 的生图额度用完了${reset}`;
    }
    if (failure) return `Codex 没能生成（${failure.type ?? "出错了"}）`;
    return item.status === "failed" ? "Codex 没能生成这张图" : null;
  }

  // 自带的生图：开始时面板显示进度（停止就是停掉这一轮）；说完时壳已经把图存成这篇的配图候选（vibepostCandidates，
  // 见 AIBackends.swift 的 GeneratedImages），会话里放出来，下面的说明是它改写后的提示词；没成功时记一行原因
  function imageGeneration(turn, method, item, stored, core) {
    const state = turn.state;
    const progress = () => core.generating(turn, state.images.length ? { provider: "Codex", count: state.images.length } : null);
    if (method === "item/started") {
      state.images = [...state.images, item.id];
      progress();
      return;
    }
    state.images = state.images.filter((id) => id !== item.id);
    progress();
    const saved = (Array.isArray(stored) ? stored : []).filter(Boolean);
    const images = saved.filter((image) => image.id)
      .map((image) => ({ ...image, ...(item.revisedPrompt ? { caption: caption(item.revisedPrompt) } : {}) }));
    if (images.length) core.candidates(turn, images);
    const problem = imageFailure(item) ?? saved.find((image) => image.error)?.error ?? (images.length ? null : "没有拿到生成的图");
    if (problem) core.tool(turn, `生成图片没成功：${problem}`);
  }

  // 续线程时 Codex 说找不到这个线程（它那边的记录没了）：只有这种才算会话没了、下一轮开新线程；别的错误照常报，会话留着
  const LOST_THREAD = /no rollout found|thread not found|unknown thread|not found for thread/i;

  // 我们发出的请求的回答：握手 → 开 / 续线程 → 发这一轮
  function response(turn, { id, result, error }, core) {
    const failed = (what) => core.fail(turn, `Codex 没能${what}：${error.message ?? "出错了"}`);
    if (id === "initialize") {
      if (error) return failed("启动");
      core.send(turn, threadRequest(turn, core));
    } else if (id === "thread") {
      if (error) {
        // 续不上：Codex 那边没有这个线程了，下一轮开新会话
        if (turn.resume && LOST_THREAD.test(error.message ?? "")) {
          turn.state.lost = true;
          return core.fail(turn, "之前的会话在 Codex 里找不到了，下一轮会开一个新会话。");
        }
        return failed(turn.resume ? "接着上次的会话" : "开始会话");
      }
      core.session(turn, { sessionId: result.thread.id, model: result.model });
      core.send(turn, {
        id: "turn",
        method: "turn/start",
        params: { threadId: result.thread.id, input: [{ type: "text", text: turn.prompt }] },
      });
    } else if (id === "turn") {
      if (error) return failed("开始这一轮");
      turn.state.turnId = result?.turn?.id ?? null;
    }
  }

  // 这个线程这一轮的通知才算（Codex 的子线程也可能走这条连接）；还不知道线程、这一轮的 id 时不挡
  function ours(turn, params) {
    if (params.threadId && turn.sessionId && params.threadId !== turn.sessionId) return false;
    const turnId = params.turnId ?? params.turn?.id;
    return !(turnId && turn.state.turnId && turnId !== turn.state.turnId);
  }

  function notification(turn, message, core) {
    const { method, params = {} } = message;
    if (!ours(turn, params)) return;
    const state = turn.state;
    const item = params.item;
    if (item?.type === "imageGeneration" && (method === "item/started" || method === "item/completed")) {
      imageGeneration(turn, method, item, message.vibepostCandidates, core);
      return;
    }
    if (method === "item/started") {
      if (item?.type === "agentMessage") core.textStart(turn);
      if (item?.type === "fileChange") state.changes[item.id] = item.changes ?? [];
    } else if (method === "item/agentMessage/delta") {
      core.textDelta(turn, params.delta ?? "");
    } else if (method === "item/completed") {
      if (!item) return;
      if (item.type === "agentMessage") {
        core.answered(turn);
        state.reply = item.text ?? "";
        core.text(turn, state.reply);
        return;
      }
      if (item.type === "fileChange") state.changes[item.id] = item.changes ?? state.changes[item.id] ?? [];
      const line = describeItem(item);
      if (line) core.tool(turn, line);
    } else if (method === "error") {
      state.error = params.error?.message ?? params.message ?? state.error;
    } else if (method === "turn/completed") {
      const done = params.turn ?? {};
      const failed = done.status === "failed";
      core.result(turn, {
        error: failed ? done.error?.message ?? state.error ?? "Codex 没能完成这一轮" : null,
        reply: state.reply ?? "",
        model: null,
        durationMs: Number.isFinite(done.durationMs) ? done.durationMs
          : Number.isFinite(done.completedAt) && Number.isFinite(done.startedAt) ? (done.completedAt - done.startedAt) * 1000 : undefined,
      });
    }
  }

  function read(turn, message, core) {
    if (message.id !== undefined && message.method === undefined) {
      response(turn, message, core);
    } else if (message.id !== undefined) {
      // 说完之后还来的请求：送不到了（壳已经关上 stdin）
      if (turn.result) {
        core.late(turn, message.method === "item/tool/call" ? `调用 App 的工具 ${message.params?.tool ?? ""}`.trim() : "请你确认一个操作");
        return;
      }
      try {
        serverRequest(turn, message, core);
      } catch (error) {
        core.reply(turn, message.id, null, error?.message || String(error));
      }
    } else if (message.method) {
      notification(turn, message, core);
    }
  }

  backends.codex = {
    id: "codex",
    name: "Codex",
    label: "Codex",
    toolNames: "App 的工具，直接按名字调用",
    // 生图怎么做（写进给它的说明）：用它自带的，不装技能、不给它 App 的生图工具
    imagePrompt: [
      "  要生成图片就直接用你自带的生图，不要写脚本、不要调用别的服务或技能；生成的图 App 会自动放进配图候选，用户点了才插入，你不用往稿子里写图片标记。",
      "  用户要图时才生成，张数默认 1。",
    ].join("\n"),
    // 这一轮续不续上次的会话：线程 id 由 Codex 起，答过一次之后下一轮 thread/resume 接着
    session: (ai) => (ai.resumable && ai.sessionId ? { sessionId: ai.sessionId, resume: true } : { sessionId: null, resume: false }),
    // 壳只起 `codex app-server`：开线程、续线程要的都由这里经 stdin 发（线程 id 的格式归 Codex 管，不交给壳去认）
    launch: () => ({}),
    // 这一轮里这边记着的：改文件的条目（审批时显示改哪些文件）、最后一段回复、出错的说明、Codex 那边这一轮的 id、
    // 续不上会话、正在生成的图
    state: () => ({ changes: {}, reply: null, error: null, turnId: null, lost: false, images: [] }),
    read,
    // JSON-RPC 的回答：成功给 result，失败给 error
    reply: (requestId, response, error = null) => (error
      ? { id: requestId, error: { code: -32000, message: error } }
      : { id: requestId, result: response ?? {} }),
    // 用户对一个审批的回答写成 Codex 的回答；session 时记下规则（之后同样的请求不再问）
    permissionReply(request, decision) {
      const rules = decision === "session" && request.rule ? [request.rule] : [];
      if (request.method === "item/permissions/requestApproval") {
        // 给的就是它要的（没要的项不写）；拒绝是什么都不给
        const wanted = Object.entries(request.input.permissions ?? {}).filter(([, value]) => value != null);
        const response = decision === "deny"
          ? { permissions: {}, scope: "turn" }
          : { permissions: Object.fromEntries(wanted), scope: decision === "session" ? "session" : "turn" };
        return { response, rules };
      }
      const value = { allow: "accept", session: "acceptForSession", deny: "decline" }[decision];
      return { response: { decision: value }, rules };
    },
    exitError(exit) {
      const stderr = String(exit.stderr || "").trim().split("\n").filter(Boolean).at(-1);
      return stderr || `codex 意外退出（${exit.signal ? `信号 ${exit.signal}` : `退出码 ${exit.status}`}）`;
    },
    lostSession: (exit, turn) => Boolean(turn?.state?.lost),
  };
})(window);
