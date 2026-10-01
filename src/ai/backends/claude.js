// AI 后端：本机的 Claude Code（`claude -p`，stream-json 进出；壳那边见 AIBackends.swift）。
// 会话核心（src/ai/session.js）只经这里和 claude 打交道：一轮续不续上次的会话、交给壳的参数、
// 把 claude 的输出行翻成核心的动作（core：流式出字、记一行工具、问权限、调 App 的工具、这一轮的结果），
// 把核心的回答（权限、工具的结果）写成 claude 认得的控制回答（经壳写回 stdin）。
(function (root) {
  "use strict";

  const backends = ((root.MediaCraftAI ||= {}).backends ||= {});

  // App 自己的工具挂成一个 SDK MCP 服务（壳在命令行里登记）
  const TOOL_SERVER = "mediacraft";
  const TOOL_PREFIX = `mcp__${TOOL_SERVER}__`;

  // 会话里记一行：claude 用了什么工具
  function describeTool({ name, input = {} }) {
    const file = (path) => String(path || "").split("/").pop();
    switch (name) {
      case "Read": return `读取 ${file(input.file_path)}`;
      case "Edit":
      case "MultiEdit": return `修改 ${file(input.file_path)}`;
      case "Write": return `写入 ${file(input.file_path)}`;
      case "Bash": return `运行 ${input.command ?? ""}`;
      case "Grep":
      case "Glob": return `查找 ${input.pattern ?? ""}`;
      case "WebSearch": return `搜索网页：${input.query ?? ""}`;
      case "WebFetch": return `打开网页 ${input.url ?? ""}`;
      case "Task":
      case "Agent": return `交给子助手：${input.description ?? ""}`;
      case "Skill": return `使用技能 ${input.skill ?? input.command ?? ""}`;
      case "TodoWrite": return "更新待办";
      default: {
        const mcp = /^mcp__(.+?)__(.+)$/.exec(name);
        return mcp ? `调用 ${mcp[1]} · ${mcp[2]}` : `使用工具 ${name}`;
      }
    }
  }

  // 确认框里显示的：标题（Claude 想做什么）、细节（命令、文件、网址……）、附注（Claude 自己的说明、不在工作目录里的路径）
  function permissionView({ tool_name: name, input = {}, description, blocked_path: blocked }) {
    const views = {
      Bash: ["运行命令", input.command],
      Write: ["写入文件", input.file_path],
      Edit: ["修改文件", input.file_path],
      MultiEdit: ["修改文件", input.file_path],
      NotebookEdit: ["修改文件", input.notebook_path],
      Read: ["读取文件", input.file_path],
      WebFetch: ["打开网页", input.url],
      WebSearch: ["搜索网页", input.query],
      Glob: ["查找文件", input.pattern],
      Grep: ["搜索文件内容", input.pattern],
      Skill: ["使用技能", input.skill ?? input.command],
    };
    const mcp = /^mcp__(.+?)__(.+)$/.exec(name);
    const [title, detail] = views[name] ?? [mcp ? `使用 ${mcp[1]} 的 ${mcp[2]}` : `使用工具 ${name}`, JSON.stringify(input, null, 1)];
    const notes = [input.description ?? description, blocked ? `不在这篇稿子的工作目录里：${blocked}` : null].filter(Boolean);
    return { title, detail: String(detail ?? ""), note: notes.join("\n") };
  }

  // 「本次会话都允许」放行的范围：只用 claude 自己给的建议（和终端里「以后不再问」的范围一样，如某条命令、某个网站）。
  // 没给建议时没有这个选项（不退而放行整个工具），rules 为空。
  // updates 是回给 claude 的 updatedPermissions（只在这一轮的进程里有效），rules 是规则的写法（之后每轮经命令行带上）。
  function sessionScope(suggestions = []) {
    const updates = suggestions
      .filter((item) => item?.type === "addRules" && item.behavior === "allow" && Array.isArray(item.rules) && item.rules.length)
      .map((item) => ({ ...item, destination: "session" }));
    const rules = updates.flatMap((item) => item.rules.map(({ toolName, ruleContent }) => (ruleContent ? `${toolName}(${ruleContent})` : toolName)));
    return { updates, rules };
  }

  // 说完（result）之后还来的控制请求想做什么（写进这一轮的结尾）
  function lateWhat(request) {
    if (request?.subtype === "can_use_tool") {
      const { title, detail } = permissionView(request);
      return `${title}${detail ? `：${detail.split("\n")[0].slice(0, 120)}` : ""}`;
    }
    if (request?.subtype === "mcp_message") return `调用 App 的工具 ${request.message?.params?.name ?? ""}`.trim();
    return `发来 ${request?.subtype}`;
  }

  // 回答一个控制请求：成功给 response，失败给 error
  function reply(requestId, response, error = null) {
    return {
      type: "control_response",
      response: error ? { subtype: "error", request_id: requestId, error } : { subtype: "success", request_id: requestId, response },
    };
  }

  function controlRequest(turn, { request_id: requestId, request }, core) {
    if (request?.subtype === "can_use_tool") {
      const suggestions = request.permission_suggestions ?? [];
      core.askPermission(turn, {
        id: requestId,
        tool: String(request.tool_name ?? ""),
        input: request.input ?? {},
        ...permissionView(request),
        scope: sessionScope(suggestions).rules,
        suggestions,
      });
    } else if (request?.subtype === "mcp_message") {
      const { server_name: server, message } = request;
      // 一次只执行一个工具（核心排队）：几个改稿子的动作并发会互相覆盖
      core.runTool(turn, requestId, async (context) => ({
        mcp_response: server === TOOL_SERVER
          ? await core.tools.handle(message, context)
          : { jsonrpc: "2.0", id: message?.id ?? 0, error: { code: -32601, message: `没有这个服务：${server}` } },
      }));
    } else {
      core.reply(turn, requestId, null, `Vibepost 不支持 ${request?.subtype}`);
    }
  }

  // 子助手（parent_tool_use_id 不为空）的输出不显示，只看主对话；控制请求不论来自谁都要回答。
  // App 自己的工具不在这里记一行：执行时由工具记（看了什么、做了什么动作）。
  function read(turn, event, core) {
    if (event.type === "control_request") {
      if (turn.result) {
        core.late(turn, lateWhat(event.request));
        return;
      }
      try {
        controlRequest(turn, event, core);
      } catch (error) {
        core.reply(turn, event.request_id, null, error?.message || String(error));
      }
      return;
    }
    if (event.type === "control_cancel_request") {
      core.withdraw(turn, event.request_id);
      return;
    }
    if (event.parent_tool_use_id) return;
    if (event.type === "system" && event.subtype === "init") {
      core.session(turn, { sessionId: event.session_id, model: event.model });
    } else if (event.type === "stream_event") {
      const { type, content_block: block, delta } = event.event ?? {};
      if (type === "content_block_start" && block?.type === "text") core.textStart(turn);
      else if (type === "content_block_delta" && delta?.type === "text_delta") core.textDelta(turn, delta.text);
    } else if (event.type === "assistant") {
      core.answered(turn);
      for (const block of event.message?.content ?? []) {
        if (block.type === "text") core.text(turn, block.text);
        else if (block.type === "tool_use" && !block.name.startsWith(TOOL_PREFIX)) core.tool(turn, describeTool(block));
      }
    } else if (event.type === "result") {
      const detail = typeof event.result === "string" && event.result ? event.result : (event.errors ?? []).join("；");
      core.result(turn, {
        error: event.is_error ? detail || `Claude Code 没能完成（${event.subtype ?? "出错"}）` : null,
        reply: typeof event.result === "string" ? event.result : "",
        // system init 没报模型时，取这一轮花费里的第一个模型
        model: Object.keys(event.modelUsage ?? {})[0] ?? null,
        costUsd: event.total_cost_usd,
        durationMs: event.duration_ms,
      });
    }
  }

  backends.claude = {
    id: "claude",
    // 会话里、出错说明里怎么称呼它
    name: "Claude",
    label: "Claude Code",
    // App 的工具在它那边叫什么（写进给它的说明）
    toolNames: `${TOOL_PREFIX}*`,
    // 生图怎么做（写进给它的说明）：用 App 的 generate_image
    imagePrompt: [
      "  要生成图片就用 generate_image（App 直接调生图接口，生成的图同样进配图候选），不要自己跑生图脚本、curl 或别的生图技能。",
      "  生图按张计费、记在用户自己的账户上：用户要图时才生成，张数默认 1。",
    ].join("\n"),
    // 这一轮续不续上次的会话：claude 的会话 id 由这边定（UUID），答过一次之后下一轮用 --resume 接着
    session: (ai) => (ai.resumable && ai.sessionId ? { sessionId: ai.sessionId, resume: true } : { sessionId: crypto.randomUUID(), resume: false }),
    // 交给壳、只有 claude 用得上的参数：会话、模型、这篇的会话里放行过的规则（如 Bash(npm test:*)）
    launch: (turn, { rules }) => ({ sessionId: turn.sessionId, resume: turn.resume, model: turn.chosenModel, allowedTools: rules }),
    read,
    reply,
    // 用户对一个权限请求的回答写成 claude 的回答；session 时带上放行规则（这一轮生效），并交回规则的写法（之后每轮带上）
    permissionReply(request, decision, deniedMessage) {
      if (decision === "deny") return { response: { behavior: "deny", message: deniedMessage }, rules: [] };
      const scope = decision === "session" ? sessionScope(request.suggestions) : null;
      return {
        response: { behavior: "allow", updatedInput: request.input, ...(scope ? { updatedPermissions: scope.updates } : {}) },
        rules: scope?.rules ?? [],
      };
    },
    // 进程结束了却没有 result：stderr 的最后一行，或退出码、信号
    exitError(exit) {
      const stderr = String(exit.stderr || "").trim().split("\n").filter(Boolean).at(-1);
      return stderr || `claude 意外退出（${exit.signal ? `信号 ${exit.signal}` : `退出码 ${exit.status}`}）`;
    },
    // 续上次的会话时 Claude Code 那边已经没有它了（下一轮开新会话）
    lostSession: (exit) => /No conversation found/i.test(exit.stderr || ""),
  };
})(window);
