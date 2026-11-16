// 检查器里的「AI 助手」：顶上是这篇的会话（标题就是稿子的标题，可以直接改；会话历史在 src/ai/history.js；
// 更多里「重新开始这篇的对话」；用哪个后端（Codex / Claude Code，有对话后锁定）与模型；AI 设置），
// 下面是会话记录（流式显示回复）、找不到 / 没登录时按后端的指引、快捷命令（有了对话收成一行）与输入框。
// 选中文字点「改写」或按 ⌘J：把选区带进输入框（附上它在正文里的位置），切到这个标签并聚焦输入框，都进同一个会话。
// 每轮的结尾：改了几处（待确认时可以全部接受 / 全部拒绝，逐处的在编辑器里）、「撤回到这一轮之前」。
// 会话里还有：AI 用 App 工具做的动作（每行可撤销）、要你确认的操作（输入框上方的确认框）、配图候选（点一张才插入）。
// 只经 App API（window.mediacraft）与 AI 会话（src/ai/session.js）工作，不碰 src/app.js 的内部名字。
(function (root) {
  "use strict";

  const mc = root.mediacraft;
  const ai = root.MediaCraftAI;
  const $ = (selector) => document.querySelector(selector);

  // 快捷命令：按钮上的字进会话记录，这里的话发给 AI。预设命令（封面标题、首图文案……）在 src/ai/presets.js
  const COMMANDS = {
    shorten: "把 draft.md 的正文缩短到 800 字以内：保留要点、语气和所有自定义标记，直接修改 draft.md。",
    tags: "为这篇稿子想 5 个小红书话题标签，加到 caption.txt（小红书正文）的最后：另起一行，写成「#话题 #话题」，已经有的不重复；caption.txt 里原来的字一个都不改，也不要修改 draft.md 和 title.txt。",
  };
  // 输入框最高长到这么高（再多在里面滚）
  const INPUT_MAX_HEIGHT = 220;
  // 离底部这么近时算「在看最新的」，新消息来了跟着滚到底
  const PIN_DISTANCE = 40;
  // 会话里记下的权限回答
  const DECISIONS = { allow: "已允许", session: "本次会话都允许", deny: "已拒绝" };

  const panel = $("#aiPanel");
  const aiTab = $("#aiTab");
  const statusDot = $("#aiStatusDot");
  const statusText = $("#aiStatusText");
  const polishButton = $("#aiPolishBtn");
  const commandButtons = [...panel.querySelectorAll("[data-ai-command], [data-ai-preset]")];
  const titlePicker = $("#aiTitlePicker");
  const titleOptions = $("#aiTitleOptions");
  const titleNote = $("#aiTitleNote");
  const guide = $("#aiGuide");
  const guideTitle = $("#aiGuideTitle");
  const guideLead = $("#aiGuideLead");
  const guideSteps = $("#aiGuideSteps");
  const guideReason = $("#aiGuideReason");
  const guideSwitch = $("#aiGuideSwitch");
  const thread = $("#aiThread");
  const empty = $("#aiEmpty");
  const emptyTitle = $("#aiEmptyTitle");
  const emptyText = $("#aiEmptyText");
  const composer = $("#aiComposer");
  const input = $("#aiInput");
  const sendButton = $("#aiSendBtn");
  const stopButton = $("#aiStopBtn");
  const contextBox = $("#aiContext");
  const contextLabel = $("#aiContextLabel");
  const contextText = $("#aiContextText");
  const settings = $("#aiSettings");
  // AI 设置里每个后端一组：{ found, input, error }
  const pathGroups = Object.fromEntries([...settings.querySelectorAll("[data-backend]")].map((group) => [group.dataset.backend, {
    group,
    found: group.querySelector("[data-path-found]"),
    input: group.querySelector("[data-path-input]"),
    error: group.querySelector("[data-path-error]"),
  }]));
  const permissionSheet = $("#aiPermission");
  const permissionTitle = $("#aiPermissionTitle");
  const permissionDetail = $("#aiPermissionDetail");
  const permissionNote = $("#aiPermissionNote");
  const permissionQueue = $("#aiPermissionQueue");
  const allowSessionButton = $("#aiAllowSessionBtn");
  const backendSelect = $("#aiBackendSelect");
  const modelSelect = $("#aiModelSelect");
  const modelCustom = $("#aiModelCustom");
  const modelInput = $("#aiModelInput");
  const modelError = $("#aiModelError");
  const effortSelect = $("#aiEffortSelect");
  // 推理强度的中文叫法（Codex、Claude Code 用的英文词放在括号里）
  const EFFORT_NAMES = { none: "不推理", off: "不推理", auto: "自动", minimal: "最低", low: "低", medium: "中", high: "高", xhigh: "很高", max: "最高", ultra: "极限" };
  const effortName = (effort) => EFFORT_NAMES[effort] ?? effort;
  const newSessionButton = $("#aiNewSessionBtn");
  const moreMenu = $("#aiMore");
  const sessionTitle = $("#aiSessionTitle");
  const presets = $("#aiPresets");
  const presetsToggle = $("#aiPresetsToggle");
  const imageModelInput = $("#aiImageModelInput");
  const imageError = $("#aiImageError");
  const imageNote = $("#aiImageNote");
  const editorRoot = $("#markdownEditor");
  const appStatus = $("#statusText");

  // 找没找到本机的程序：后端 id → 状态（还没找过的没有）
  const statuses = {};
  // 这篇用的后端（session.js 的 backends 里的一个）
  let backend = ai.backends.claude;
  // 当前后端的状态
  let status = null;
  let draft = { id: null, readOnly: true };
  let context = null;
  let composerRevision = 0;
  const writingSkills = root.MediaCraftWritingSkills.mount({ composer, input, changed: () => { composerRevision++; } });
  // 上一次画出来的是哪一篇的哪些消息：同一篇里新来的那几条才浮起来（每次整段重画，旧的不再动一遍）
  let shown = { draftId: null, ids: new Set() };

  const element = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  // ===== 回复的简易 Markdown：段落、标题、列表、引用、代码块、加粗、行内代码。只建节点、只填文字，不解析 HTML =====

  function inline(parent, text) {
    let last = 0;
    for (const match of text.matchAll(/\*\*([^*]+)\*\*|`([^`]+)`/g)) {
      parent.append(text.slice(last, match.index));
      parent.append(match[1] !== undefined ? element("strong", null, match[1]) : element("code", null, match[2]));
      last = match.index + match[0].length;
    }
    parent.append(text.slice(last));
    return parent;
  }

  function renderMarkdown(text) {
    const fragment = document.createDocumentFragment();
    const lines = text.split("\n");
    let paragraph = null;
    let list = null;
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      if (/^\s*```/.test(line)) {
        const code = [];
        for (index += 1; index < lines.length && !/^\s*```/.test(lines[index]); index += 1) code.push(lines[index]);
        const pre = element("pre");
        pre.append(element("code", null, code.join("\n")));
        fragment.append(pre);
        paragraph = null;
        list = null;
        continue;
      }
      const heading = /^#{1,6}\s+(.*)$/.exec(line);
      const bullet = /^\s*[-*+]\s+(.*)$/.exec(line);
      const ordered = /^\s*(\d+)[.)]\s+(.*)$/.exec(line);
      const quote = /^>\s?(.*)$/.exec(line);
      if (!line.trim()) {
        paragraph = null;
        list = null;
      } else if (heading) {
        fragment.append(inline(element("p", "ai-md-heading"), heading[1]));
        paragraph = null;
        list = null;
      } else if (bullet || ordered) {
        const tag = bullet ? "UL" : "OL";
        if (list?.tagName !== tag) {
          list = element(tag);
          fragment.append(list);
        }
        const item = inline(element("li"), bullet ? bullet[1] : ordered[2]);
        if (ordered) item.value = Number(ordered[1]);
        list.append(item);
        paragraph = null;
      } else if (quote) {
        fragment.append(inline(element("blockquote"), quote[1]));
        paragraph = null;
        list = null;
      } else {
        if (paragraph) paragraph.append(element("br"));
        else {
          paragraph = element("p");
          fragment.append(paragraph);
        }
        inline(paragraph, line);
        list = null;
      }
    }
    return fragment;
  }

  // ===== 会话记录 =====

  const rangeLabel = ({ start, end }) => `第 ${start + 1}–${end} 字`;

  function quoteNode(selection) {
    const quote = element("blockquote", "ai-quote");
    quote.append(element("span", "ai-quote-range", `选中的文字 · ${rangeLabel(selection)}`), element("span", "ai-quote-text", selection.text));
    return quote;
  }

  function seconds(ms) {
    return ms < 10000 ? (ms / 1000).toFixed(1) : String(Math.round(ms / 1000));
  }

  function button(className, text, onClick, title) {
    const node = element("button", className, text);
    node.type = "button";
    if (title) node.title = title;
    node.addEventListener("click", onClick);
    return node;
  }

  // 一轮的结尾：改了几处、接受了几处，模型、用时与花费，出错原因；有版本的可以撤回到这一轮之前
  function endNode(message, versions) {
    const node = element("div", `ai-end is-${message.state}`);
    const { review } = message;
    const open = review !== undefined && review.accepted === undefined;
    if (open) node.append(element("span", "ai-badge", `${review.count} 处修改待确认`));
    else if (message.edited) node.append(element("span", "ai-badge", "已修改稿子"));
    else if (review) node.append(element("span", "ai-badge is-warning", "没有采用修改"));
    const parts = [];
    if (review && !open) parts.push(`接受 ${review.accepted}/${review.count} 处`);
    if (message.state === "cancelled") parts.push("已停止");
    if (message.state === "interrupted") parts.push("已中断");
    if (message.model) parts.push(message.model);
    if (Number.isFinite(message.durationMs)) parts.push(`${seconds(message.durationMs)} 秒`);
    if (Number.isFinite(message.costUsd)) parts.push(`$${message.costUsd.toFixed(2)}`);
    if (parts.length) node.append(element("span", "ai-end-meta", parts.join(" · ")));
    if (open && ai.review.isOpen(draft.id)) {
      const actions = element("span", "ai-end-actions");
      actions.append(
        button("pill-button", "全部拒绝", () => run(() => ai.api.review.rejectAll())),
        button("primary-button", "全部接受", () => run(() => ai.api.review.acceptAll())),
      );
      node.append(actions);
    }
    if (message.error) node.append(element("span", "ai-end-error", `出错：${message.error}`));
    if (versions.has(message.turn)) {
      const revert = button("text-button ai-revert", "撤回到这一轮之前", () => run(async () => {
        await ai.api.versions.revert(message.turn);
        appStatus.textContent = root.MediaCraftPlatform.keys("已撤回到这一轮之前，⌘Z 可以撤销这次撤回");
      }), "正文、标题、主题配色、字体版式与图片都换回这一轮开始前的样子");
      revert.disabled = ai.running(draft.id);
      node.append(revert);
    }
    return node;
  }

  // Claude 用 App 工具做的一个动作：做了什么，还能撤销时带「撤销」（undo 默认撤销会话里的这个动作；外部 Agent 的操作也用这一行，src/mcp/panel.js）
  function actionNode(message, undo = () => ai.api.undoAction(message.id)) {
    const node = element("div", `ai-action${message.undone ? " is-undone" : ""}`);
    node.append(element("span", "ai-action-text", message.text));
    if (message.undone) {
      node.append(element("span", "ai-action-state", "已撤销"));
    } else if (message.undoable) {
      const button = element("button", "text-button ai-action-undo", "撤销");
      button.type = "button";
      button.setAttribute("aria-label", `撤销：${message.text}`);
      button.addEventListener("click", () => run(undo));
      node.append(button);
    }
    return node;
  }
  ai.actionLine = actionNode;

  function candidatesNode(message) {
    const node = element("div", "ai-candidates");
    node.append(element("p", "ai-candidates-title", "配图候选 · 点一张插进稿子"));
    const grid = element("div", "ai-candidate-grid");
    for (const image of message.images) {
      const button = element("button", "ai-candidate");
      button.type = "button";
      button.disabled = Boolean(image.inserted);
      button.setAttribute("aria-label", `${image.inserted ? "已插入" : "插入"}配图「${image.name}」`);
      button.title = image.caption || image.name;
      const thumb = element("img");
      thumb.src = image.thumb;
      thumb.alt = "";
      button.append(thumb);
      if (image.caption) button.append(element("span", "ai-candidate-caption", image.caption));
      if (image.inserted) button.append(element("span", "ai-candidate-badge", "已插入"));
      button.addEventListener("click", () => {
        button.disabled = true; // 连点只插一次
        run(() => ai.api.insertCandidate(message.id, image.id), () => {
          button.disabled = false;
        });
      });
      grid.append(button);
    }
    node.append(grid);
    return node;
  }

  function messageNode(message, versions) {
    let node;
    if (message.role === "user") {
      node = element("div", "ai-message ai-user");
      if (message.context) node.append(quoteNode(message.context));
      if (message.skills?.length) {
        const tags = element("div", "ai-skill-tags ai-message-skills");
        tags.setAttribute("aria-label", "本条消息的写作手册");
        for (const { name } of message.skills) tags.append(element("span", "ai-skill-tag", name));
        node.append(tags);
      }
      if (message.text) node.append(element("p", "ai-user-text", message.text));
    } else if (message.role === "assistant") {
      node = element("div", "ai-message ai-assistant");
      node.append(renderMarkdown(message.text));
    } else if (message.role === "tool") {
      node = element("p", "ai-tool", message.text);
    } else if (message.role === "action") {
      node = actionNode(message);
    } else if (message.role === "permission") {
      node = element("p", `ai-permission-line is-${message.decision}`, `${DECISIONS[message.decision]} · ${message.text}`);
    } else if (message.role === "candidates") {
      node = candidatesNode(message);
    } else {
      node = endNode(message, versions);
    }
    node.dataset.messageId = message.id;
    return node;
  }

  // 正在生图：一行进度（每秒更新用时）。App 的生图工具「停止生成」让 Claude 收到「已停止生图」、这一轮接着往下走；
  // 后端自己在生图（Codex 自带的）时只能「停止这一轮」
  let generatingTimer = null;

  function generatingNode({ provider, model, count, size, startedAt, byBackend }) {
    const node = element("div", "ai-generating");
    node.setAttribute("role", "status");
    const text = element("span", "ai-generating-text");
    const tick = () => {
      const seconds = Math.max(0, Math.round((Date.now() - startedAt) / 1000));
      text.textContent = byBackend
        ? `${provider} 正在生成${count > 1 ? ` ${count} 张` : ""}图片… ${seconds} 秒`
        : `正在用 ${provider} ${model} 生成 ${count} 张图（${size}）… ${seconds} 秒`;
    };
    tick();
    generatingTimer = setInterval(tick, 1000);
    const stop = button("pill-button", byBackend ? "停止这一轮" : "停止生成", () => {
      stop.disabled = true;
      run(() => ai.api.stopImages(draft.id));
    });
    node.append(element("span", "status-dot"), text, stop);
    return node;
  }

  // 输入框上方的确认框：一次问一个，后面还有几个也说一声
  function syncPermission(permissions) {
    const [request] = permissions;
    permissionSheet.hidden = !request;
    if (!request) return;
    permissionSheet.dataset.requestId = request.id;
    permissionTitle.textContent = `${backend.name} 想${request.title}`;
    permissionDetail.textContent = request.detail;
    permissionDetail.hidden = !request.detail;
    permissionNote.textContent = request.note;
    permissionNote.hidden = !request.note;
    // 没有可以放行的范围（后端没给）时不提供「本次会话都允许」
    allowSessionButton.hidden = !request.scope.length;
    allowSessionButton.title = `这篇稿子的 AI 会话里，之后这些不再问：${request.scope.join("、")}（重新打开 App 后恢复询问）`;
    permissionQueue.hidden = permissions.length < 2;
    permissionQueue.textContent = `还有 ${permissions.length - 1} 个请求等你确认`;
  }

  // 双击的第二下不算：第一下答完，确认框已经换成下一个还没看过的请求
  function answerPermission(event, decision) {
    const requestId = permissionSheet.dataset.requestId;
    if (event.detail > 1 || permissionSheet.hidden || !requestId) return;
    run(() => ai.api.answer(requestId, decision));
  }

  $("#aiAllowBtn").addEventListener("click", (event) => answerPermission(event, "allow"));
  $("#aiDenyBtn").addEventListener("click", (event) => answerPermission(event, "deny"));
  allowSessionButton.addEventListener("click", (event) => answerPermission(event, "session"));

  function pinnedToBottom() {
    return thread.scrollHeight - thread.scrollTop - thread.clientHeight < PIN_DISTANCE;
  }

  function renderThread() {
    const pinned = pinnedToBottom();
    const { messages, running, permissions, generating } = draft.id
      ? ai.history(draft.id)
      : { messages: [], running: false, permissions: [], generating: null };
    const versions = new Set(draft.id ? ai.versions.ids(draft.id) : []);
    const nodes = messages.map((message) => messageNode(message, versions));
    if (shown.draftId === draft.id) {
      for (const node of nodes) node.classList.toggle("is-new", !shown.ids.has(node.dataset.messageId));
    }
    shown = { draftId: draft.id, ids: new Set(messages.map((message) => message.id)) };
    // 正在流式写的回复末尾带一根光标
    if (running && messages.at(-1)?.role === "assistant") nodes.at(-1).classList.add("is-streaming");
    thread.replaceChildren(...nodes);
    syncPermission(permissions);
    clearInterval(generatingTimer);
    if (generating) thread.append(generatingNode(generating));
    else if (running && !permissions.length && messages.at(-1)?.role !== "assistant") {
      const typing = element("p", "ai-typing");
      typing.append(element("span", "ai-typing-dots"), `${backend.name} 正在回复`);
      thread.append(typing);
    }
    thread.hidden = messages.length === 0;
    if (pinned || running) thread.scrollTop = thread.scrollHeight;
    syncControls();
  }

  function updateText({ messageId, text }) {
    const node = thread.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`);
    if (!node) {
      renderThread();
      return;
    }
    const pinned = pinnedToBottom();
    node.replaceChildren(renderMarkdown(text));
    if (pinned) thread.scrollTop = thread.scrollHeight;
  }

  // ===== 状态与按钮 =====

  // used 是这篇最近一轮后端实际用的模型（它自己报的）
  function statusLine(busy, reviewing, used) {
    if (!status) return ["checking", `正在查找本机 ${backend.label}…`];
    if (!status.available) return ["missing", `没有找到本机 ${backend.label}`];
    if (busy) return ["busy", `${permissionSheet.hidden ? `${backend.name} 正在回复…` : `${backend.name} 在等你确认…`}${used ? `（${used}）` : ""}`];
    if (reviewing) return ["review", "先确认 AI 的修改，再接着说"];
    const connected = status.version ? `本机 ${backend.label} ${status.version} · 已连接` : `本机 ${backend.label} · 已连接`;
    return ["ok", used ? `${connected} · ${used}` : connected];
  }

  // 输入框与它的名字跟着这篇的后端叫
  function syncBackendNames() {
    composer.setAttribute("aria-label", `对 ${backend.name} 说`);
    input.setAttribute("aria-label", `问 ${backend.name}`);
    input.placeholder = `让 ${backend.name} 排版或改稿，比如「每页只讲一件事，要点做成步骤」`;
    emptyTitle.textContent = `让 ${backend.name} 帮你排这篇`;
  }

  function syncControls() {
    const busy = draft.id !== null && ai.running(draft.id);
    const reviewing = draft.id !== null && ai.review.isOpen(draft.id);
    const usable = status?.available === true && !draft.readOnly;
    const session = draft.id ? ai.history(draft.id) : null;
    const [state, text] = statusLine(busy, reviewing, session?.usedModel);
    statusDot.dataset.state = state;
    statusText.textContent = text;
    statusText.title = text; // 窄的时候模型名会被截断
    polishButton.disabled = !usable || busy || reviewing;
    for (const button of commandButtons) button.disabled = !usable || busy || reviewing;
    input.disabled = !usable;
    writingSkills.disable(draft.readOnly);
    modelSelect.disabled = draft.readOnly;
    modelInput.disabled = draft.readOnly;
    backendSelect.disabled = draft.readOnly || Boolean(session?.locked);
    backendSelect.closest(".ai-picker").classList.toggle("is-locked", Boolean(session?.locked));
    backendSelect.title = session?.locked
      ? `这篇的对话用的是 ${backend.label}；要换，先在「更多」里重新开始这篇的对话`
      : "这篇稿子用哪个本机 AI（有了对话之后就不能换了）";
    newSessionButton.disabled = draft.readOnly || !session?.messages.length;
    const talking = Boolean(session?.messages.length);
    presets.classList.toggle("is-compact", talking);
    if (!talking) setPresetsOpen(false);
    sendButton.hidden = busy;
    stopButton.hidden = !busy;
    sendButton.disabled = !usable || reviewing || (!input.value.trim() && !context);
    syncGuide(Boolean(session?.locked));
    empty.hidden = !thread.hidden || !guide.hidden;
    emptyText.textContent = draft.readOnly
      ? "内置说明书不能改。新建一篇稿子后，就能让 AI 帮你排版、润色、起标题。"
      : "它会看每一页，帮你分页、换块的样式、调字号行距与段距；改字的地方先标在正文里等你逐处确认，每轮之前自动存版本，随时能撤回。";
    fitInput();
  }

  // 输入框跟着字长高（最多约十行），发出去清空后回到两行
  function fitInput() {
    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, INPUT_MAX_HEIGHT)}px`;
  }

  // 找这个后端（默认这篇用的）的程序
  function checkStatus(options = {}) {
    return ai.api.status({ backend: backend.id, ...options }).catch((error) => {
      appStatus.textContent = error.message || String(error);
    });
  }

  // 这篇的后端变了（换稿子、选了别的、重新开始）：称呼、状态、模型选项跟上
  function syncBackend() {
    const id = draft.id ? ai.history(draft.id).backend : "claude";
    const changed = backend.id !== id;
    backend = ai.backends[id] ?? ai.backends.claude;
    backendSelect.value = backend.id;
    fitPicker(backendSelect);
    status = statuses[backend.id] ?? null;
    syncBackendNames();
    if (changed) void loadModels();
    if (!status && statuses.codex !== undefined) void checkStatus();
  }

  // ===== 后端与模型：每篇各选，模型下一轮起生效；后端有对话后锁定 =====

  // 药丸按选中那一项的字宽：原生选单的宽度按最长的那个选项算，「推理：中」后面会空出一截，
  // 三个药丸在默认宽度的检查器里就排不成一行。量字宽用画布（面板没显示时也量得出）
  const ruler = document.createElement("canvas").getContext("2d");
  function fitPicker(select) {
    const text = select.selectedOptions[0]?.textContent ?? "";
    const style = getComputedStyle(select);
    ruler.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
    const padding = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
    select.style.width = text && Number.isFinite(padding) ? `${Math.ceil(ruler.measureText(text).width + padding) + 2}px` : "";
  }
  for (const select of [backendSelect, modelSelect, effortSelect]) select.addEventListener("change", () => fitPicker(select));

  // 这个后端列在选单里的模型（Claude Code 是三个别名，Codex 问它自己）：[{ id, name }]
  let modelOptions = [];

  // 选单的选项：默认（跟随后端自己的设置）、这个后端的模型、自定义…
  async function loadModels() {
    const forBackend = backend;
    let list = [];
    try {
      // 要问后端自己的（Codex、说 ACP 的那几个）：还没找到它时先不问，找到了再来（见下面的 status 事件）
      list = forBackend.id !== "claude" && !statuses[forBackend.id]?.available ? [] : await ai.api.models(forBackend.id);
    } catch {
      list = []; // 读不出来就只留「默认」与「自定义」
    }
    if (forBackend !== backend) return;
    modelOptions = list;
    modelSelect.replaceChildren(
      new Option("默认模型", "default"),
      ...list.map((model) => new Option(model.name, model.id)),
      new Option("自定义…", "custom"),
    );
    syncModel(true);
  }

  // 这篇自己填的模型 ID（不在这个后端的列表里）：选单里单独一项，显示的就是这个 ID；「自定义…」用来填新的
  const ownOption = new Option("", "");

  // 选单跟上这篇选的模型（在「自定义…」里正输入着时不打断，除非选项刚换过）
  function syncModel(rebuilt = false) {
    const model = draft.id && !draft.readOnly ? ai.history(draft.id).model : null;
    if (model === null || modelOptions.some((option) => option.id === model)) ownOption.remove();
    else {
      ownOption.value = model;
      ownOption.textContent = model;
      if (!ownOption.parentElement) modelSelect.insertBefore(ownOption, modelSelect.lastElementChild);
    }
    void syncEffort();
    if (!rebuilt && modelSelect.value === "custom" && !modelCustom.hidden) return;
    modelSelect.value = model ?? "default";
    fitPicker(modelSelect);
    modelCustom.hidden = true;
    modelSelect.title = `这篇稿子的 AI 用${model === null ? ` ${backend.label} 设置里的模型` : `「${model}」`}，下一轮起生效`;
  }

  // 推理强度选单跟上这篇：档位来自这篇的后端与模型（ai.effort），选中的是这篇这一轮会用的那档
  let effortTicket = 0;
  async function syncEffort() {
    const mine = ++effortTicket;
    const usable = draft.id && !draft.readOnly;
    const info = usable ? await ai.api.effort(draft.id).catch(() => null) : null;
    if (mine !== effortTicket) return;
    const efforts = info?.efforts ?? ["medium"];
    // 说 ACP 的后端没报能选的档位（或这个模型没有）：跟随它自己的设置，选单停用
    const own = usable && info && !efforts.length;
    effortSelect.replaceChildren(...(own ? [new Option("推理：默认", "")] : efforts.map((effort) => new Option(`推理：${effortName(effort)}`, effort))));
    effortSelect.value = own ? "" : info?.effort ?? "medium";
    fitPicker(effortSelect);
    effortSelect.disabled = !usable || own;
    effortSelect.title = own
      ? `推理强度跟随 ${backend.label} 自己的设置`
      : `推理强度：${effortName(effortSelect.value)}（${effortSelect.value}）。想得越深越慢，下一轮起生效`;
  }

  effortSelect.addEventListener("change", () => run(async () => {
    try {
      const info = await ai.api.setEffort(effortSelect.value, draft.id);
      appStatus.textContent = `这篇稿子之后推理强度用「${effortName(info.effort)}」`;
    } catch (error) {
      showModelError(error.message || String(error));
    }
    await syncEffort();
  }));

  function showModelError(message) {
    modelError.hidden = !message;
    modelError.textContent = message ?? "";
  }

  async function chooseModel(model) {
    try {
      await ai.api.setModel(model, draft.id);
      showModelError(null);
      modelCustom.hidden = true; // 填好了，收起输入框
      appStatus.textContent = `这篇稿子之后用${model === null ? ` ${backend.label} 设置里的模型` : `「${model}」`}`;
    } catch (error) {
      showModelError(error.message || String(error));
    }
    syncModel();
  }

  modelSelect.addEventListener("change", () => {
    showModelError(null);
    if (modelSelect.value === "custom") {
      modelCustom.hidden = false;
      modelInput.value = ownOption.parentElement ? ownOption.value : "";
      modelInput.focus();
      return;
    }
    modelCustom.hidden = true;
    void chooseModel(modelSelect.value === "default" ? null : modelSelect.value);
  });
  modelInput.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" || event.isComposing) return;
    event.preventDefault();
    void chooseModel(modelInput.value);
  });

  backendSelect.addEventListener("change", () => run(async () => {
    showModelError(null);
    try {
      await ai.api.setBackend(backendSelect.value, draft.id);
      appStatus.textContent = `这篇稿子之后用 ${ai.backends[backendSelect.value].label}`;
    } catch (error) {
      showModelError(error.message || String(error));
    }
    syncBackend();
    syncControls();
  }));

  // ===== 重新开始这篇的对话：问一次再清空，后端解锁 =====

  // 「+」：新建一篇稿子，在新窗口里打开，一开就是 AI 助手（App 里经壳开窗口，地址带 panel=ai）；浏览器里没有窗口，就在这里新建
  $("#aiNewWindowBtn").addEventListener("click", () => run(async () => {
    const windows = root.MediaCraftNative?.windows;
    if (windows) await windows.open({ fresh: true, panel: "ai" });
    else await mc.drafts.create();
  }));

  newSessionButton.addEventListener("click", () => run(async () => {
    moreMenu.open = false;
    const busy = ai.running(draft.id);
    const confirmed = await root.MediaCraftConfirm({
      title: "重新开始这篇的对话？",
      message: `清空这篇稿子的 AI 会话记录，下一轮 ${backend.name} 从头开始，不记得之前说过的话；之后也可以换成别的 AI 后端。${busy ? "正在回复的这一轮会先停止。" : ""}还没确认的修改会丢掉；每轮之前存的版本都保留，照样能撤回。`,
      okLabel: "重新开始",
    });
    if (!confirmed) return;
    await ai.api.newSession();
    appStatus.textContent = `已重新开始，下一轮 ${backend.name} 从头开始`;
    input.focus();
  }));

  // ===== 选中的文字 =====

  function setContext(selection) {
    composerRevision++;
    context = selection && selection.end > selection.start ? { start: selection.start, end: selection.end, text: selection.text } : null;
    contextBox.hidden = !context;
    if (context) {
      contextLabel.textContent = `选中的文字 · ${rangeLabel(context)}`;
      contextText.textContent = context.text;
    }
    syncControls();
  }

  // 切到 AI 助手并聚焦输入框；selection 不为空时把它带进输入框。
  function askAbout(selection) {
    if (selection?.text) setContext(selection);
    if (aiTab.getAttribute("aria-selected") !== "true") aiTab.click();
    input.focus();
  }

  // ===== 发送 =====

  function run(task, restore) {
    task().catch((error) => {
      restore?.();
      appStatus.textContent = error.message || String(error);
    });
    syncControls();
  }

  function submit() {
    const text = input.value.trim();
    if (sendButton.hidden || sendButton.disabled) return;
    const sent = context;
    const skills = writingSkills.get();
    const sentDraft = draft.id;
    const options = sent ? { context: { start: sent.start, end: sent.end } } : {};
    if (skills.length) options.skills = skills;
    input.value = "";
    setContext(null);
    writingSkills.set([]);
    writingSkills.close();
    const revision = composerRevision;
    const restore = () => {
      if (draft.id !== sentDraft || composerRevision !== revision || input.value || context || writingSkills.get().length) return;
      input.value = text;
      writingSkills.set(skills);
      setContext(sent);
    };
    run(async () => {
      const result = await ai.api.send(text, options);
      if (result.state === "error") restore();
    }, restore);
  }

  // 润色与快捷命令也是下一条消息，同样消费当前选择。
  async function withWritingSkills(action) {
    const skills = writingSkills.get();
    const sentDraft = draft.id;
    writingSkills.set([]);
    writingSkills.close();
    const revision = composerRevision;
    const restore = () => {
      if (draft.id === sentDraft && composerRevision === revision) writingSkills.set(skills);
    };
    try {
      const result = await action(skills.length ? { skills } : {});
      if (result.state === "error") restore();
      return result;
    } catch (error) { restore(); throw error; }
  }

  composer.addEventListener("submit", (event) => {
    event.preventDefault();
    submit();
  });
  // ↩ 发送，⇧↩ 换行；输入法选字时的回车不算
  input.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing || event.keyCode === 229) return;
    event.preventDefault();
    submit();
  });
  input.addEventListener("input", () => { composerRevision++; syncControls(); });
  // 点输入框外面的底栏空白处也聚焦输入框
  composer.addEventListener("pointerdown", (event) => {
    if (event.target === composer || event.target.classList?.contains("ai-composer-foot")) {
      event.preventDefault();
      input.focus();
    }
  });
  stopButton.addEventListener("click", () => run(() => ai.api.cancel(draft.id)));
  polishButton.addEventListener("click", () => run(() => withWritingSkills((options) => ai.api.polish(options))));
  for (const button of commandButtons) {
    const { aiPreset: preset, aiCommand: command } = button.dataset;
    if (preset) (button.querySelector("[data-preset-label]") ?? button).textContent = ai.presets.PRESETS[preset].label;
    button.addEventListener("click", () => {
      setPresetsOpen(false);
      run(() => withWritingSkills((options) => (preset
        ? ai.api.preset(preset, options)
        : ai.api.send(COMMANDS[command], { ...options, kind: "command", label: button.textContent.trim() }))));
    });
  }

  // ===== 快捷命令：有了对话收成一行，「快捷命令」弹出两组；点一个、点别处、Esc 都收起 =====

  function setPresetsOpen(open) {
    presets.classList.toggle("is-open", open);
    presetsToggle.setAttribute("aria-expanded", String(open));
  }

  presetsToggle.addEventListener("click", () => setPresetsOpen(!presets.classList.contains("is-open")));
  document.addEventListener("pointerdown", (event) => {
    if (presets.classList.contains("is-open") && !presets.contains(event.target)) setPresetsOpen(false);
  });
  presets.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !presets.classList.contains("is-open")) return;
    event.preventDefault();
    event.stopPropagation();
    setPresetsOpen(false);
    presetsToggle.focus();
  });

  // ===== 封面标题候选：这篇会话里最后一轮是「封面标题 5 选 1」且已说完时，列出从回复里读出的候选 =====
  // 点一个写进标题框（撤销历史里的一步）；和现在的标题一样的那个标为选中。收起的只在 App 开着期间记着。
  const dismissedTitles = new Set();
  let titleSeq = 0;

  // 最后一轮的候选：{ turn, titles }；最后一轮不是它、还没说完、出错或停止了时为 null
  function latestTitles(messages) {
    const last = messages.findLast((message) => message.role === "user");
    if (last?.preset !== "coverTitles" || dismissedTitles.has(last.turn)) return null;
    const turn = messages.filter((message) => message.turn === last.turn);
    if (turn.at(-1)?.role !== "end" || turn.at(-1).state !== "done") return null;
    const replies = turn.filter((message) => message.role === "assistant").reverse();
    const titles = replies.map((message) => ai.presets.parseTitles(message.text)).find((list) => list.length) ?? [];
    return { turn: last.turn, titles };
  }

  function titleOption({ text, width, over }, current) {
    const option = element("button", `pill-button ai-title-option${over ? " is-over" : ""}`);
    option.type = "button";
    option.setAttribute("aria-pressed", String(text === current));
    const count = element("span", "ai-title-count", `${Math.ceil(width / 2)}/${ai.presets.TITLE_WIDTH_LIMIT / 2}`);
    count.title = over ? "超过小红书标题的 20 字" : "按显示宽度：汉字算 1 字，字母数字算半个";
    option.append(element("span", "ai-title-text", text), count);
    option.addEventListener("click", () => run(async () => {
      await ai.api.useTitle(text);
      appStatus.textContent = `标题换成了「${text}」，${root.MediaCraftPlatform.keys("⌘Z")} 可以撤销`;
    }));
    return option;
  }

  async function syncTitles() {
    const seq = ++titleSeq;
    const current = await mc.drafts.current();
    if (seq !== titleSeq) return;
    const found = current.readOnly ? null : latestTitles(ai.history(current.id).messages);
    titlePicker.hidden = !found;
    // 候选与标题都没变时不重建（免得键盘焦点从选项上掉下来）
    const signature = found && JSON.stringify([found.turn, current.title]);
    if (!found || signature === titlePicker.dataset.signature) return;
    titlePicker.dataset.signature = signature;
    titlePicker.dataset.turn = found.turn;
    titleOptions.replaceChildren(...found.titles.map((option) => titleOption(option, current.title)));
    titleOptions.hidden = !found.titles.length;
    titleNote.hidden = found.titles.length > 0;
  }

  $("#aiTitlePickerClose").addEventListener("click", () => {
    dismissedTitles.add(titlePicker.dataset.turn);
    titlePicker.hidden = true;
  });
  ai.on((event) => {
    if (event.type !== "text" && event.type !== "status") void syncTitles();
  });
  mc.on("change", () => void syncTitles());
  mc.on("rendered", () => void syncTitles());
  $("#aiContextClear").addEventListener("click", () => {
    setContext(null);
    input.focus();
  });

  document.addEventListener("mediacraft:rewrite", (event) => askAbout(event.detail));
  // ⌘J：编辑器里选中了文字就带上，否则只是打开 AI 助手
  document.addEventListener("keydown", (event) => {
    if (!(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey || event.key.toLowerCase() !== "j") return;
    event.preventDefault();
    const fromEditor = editorRoot.contains(document.activeElement);
    void (fromEditor ? mc.editor.selection() : Promise.resolve(null)).then(askAbout);
  });

  // ===== 找不到、运行不起来、没登录：按这篇的后端说清楚怎么办 =====

  // 每一步是几段：字符串照原样，{ code } 显示成命令
  const GUIDES = {
    codex: {
      missing: {
        title: "没有找到本机 Codex",
        lead: "AI 助手用你电脑上的 Codex 改稿、生图，沿用它在终端里的登录与设置，不用另填密钥。",
        steps: [
          ["在「终端」里安装：", { code: "npm install -g @openai/codex" }],
          ["在终端里运行一次 ", { code: "codex" }, "，按提示用 ChatGPT 账号登录。"],
          ["回到这里点「重新查找」。装在别处的话，在终端运行 ", { code: "which codex" }, "，把显示的路径填进「指定路径」。"],
        ],
      },
      login: {
        title: "Codex 还没有登录",
        lead: "找到了本机的 Codex，但它还没有登录，没法替你改稿。",
        steps: [
          ["在「终端」里运行 ", { code: "codex login" }, "，用 ChatGPT 账号（或 API key）登录。"],
          ["登录好之后回到这里，点「重新查找」。"],
        ],
      },
      broken: {
        title: "本机的 Codex 运行不起来",
        lead: "找到了 codex，但它启动时出错了，原因在下面。",
        steps: [
          ["在「终端」里运行 ", { code: "codex --version" }, "，看看能不能启动（npm 装的要找得到 node）。"],
          ["不行就重新安装：", { code: "npm install -g @openai/codex" }, "，再回来点「重新查找」。"],
        ],
      },
    },
    claude: {
      missing: {
        title: "没有找到本机 Claude Code",
        lead: "AI 助手用你电脑上的 Claude Code 改稿，沿用它在终端里的设置（技能、MCP、权限）。",
        steps: [
          ["在「终端」里安装：", { code: "npm install -g @anthropic-ai/claude-code" }],
          ["在终端里运行一次 ", { code: "claude" }, "，按提示完成首次设置。"],
          ["回到这里点「重新查找」。装在别处的话，在终端运行 ", { code: "which claude" }, "，把显示的路径填进「指定路径」。"],
        ],
      },
      broken: {
        title: "本机的 Claude Code 运行不起来",
        lead: "找到了 claude，但它启动时出错了，原因在下面。",
        steps: [
          ["在「终端」里运行 ", { code: "claude --version" }, "，看看能不能启动（npm 装的要找得到 node）。"],
          ["不行就重新安装：", { code: "npm install -g @anthropic-ai/claude-code" }, "，再回来点「重新查找」。"],
        ],
      },
    },
  };
  // 没有专门写指引的后端（说 ACP 的那几个，src/ai/backends/acp.js）：照它登记的命令拼一份
  function genericGuide({ label, program, install, login }) {
    const which = ["回到这里点「重新查找」。装在别处的话，在终端运行 ", { code: `which ${program}` }, "，把显示的路径填进「指定路径」。"];
    return {
      missing: {
        title: `没有找到本机 ${label}`,
        lead: `AI 助手用你电脑上的 ${label} 改稿，沿用它在终端里的登录与模型设置，不用另填密钥。`,
        steps: [
          install ? ["在「终端」里安装：", { code: install }] : [`照 ${label} 官网的办法安装。`],
          login ? ["在终端里登录、配好模型：", { code: login }] : ["在终端里运行一次 ", { code: program }, "，配好要用的模型。"],
          which,
        ],
      },
      broken: {
        title: `本机的 ${label} 运行不起来`,
        lead: `找到了 ${program}，但它启动时出错了，原因在下面。`,
        steps: [
          ["在「终端」里运行 ", { code: `${program} --version` }, "，看看能不能启动。"],
          install ? ["不行就重新安装：", { code: install }, "，再回来点「重新查找」。"] : ["不行就重新安装，再回来点「重新查找」。"],
        ],
      },
    };
  }
  // 为了「改用另一个后端」去找过的
  const probed = new Set();

  // locked：这篇已经有对话（不能换后端）
  function syncGuide(locked) {
    guide.hidden = status?.available !== false;
    if (guide.hidden) return;
    const texts = GUIDES[backend.id] ?? genericGuide(backend);
    const text = texts[status.reason] ?? texts.missing;
    guideTitle.textContent = text.title;
    guideLead.textContent = text.lead;
    guideSteps.replaceChildren(...text.steps.map((parts) => {
      const item = element("li");
      for (const part of parts) item.append(typeof part === "string" ? part : element("code", null, part.code));
      return item;
    }));
    guideReason.textContent = status.error ?? "";
    // 这篇还没有对话、另一个后端能用：一键改用它（没找过就去找一次）
    // 另一个：Codex 不行时是 Claude Code，别的都先看 Codex，Codex 也不行再看 Claude Code
    const others = backend.id === "codex" ? ["claude"] : ["codex", "claude"].filter((id) => id !== backend.id);
    const switchable = !locked && !draft.readOnly;
    for (const id of others) {
      if (!switchable || statuses[id] !== undefined || probed.has(id)) continue;
      probed.add(id);
      void ai.api.status({ backend: id }).catch(() => undefined);
    }
    const other = others.find((id) => statuses[id]?.available === true) ?? others[0];
    guideSwitch.hidden = !switchable || statuses[other]?.available !== true;
    guideSwitch.textContent = `改用 ${ai.backends[other].label}`;
    guideSwitch.dataset.backend = other;
  }

  guideSwitch.addEventListener("click", () => run(async () => {
    await ai.api.setBackend(guideSwitch.dataset.backend, draft.id);
    appStatus.textContent = `这篇稿子之后用 ${ai.backends[guideSwitch.dataset.backend].label}`;
    syncBackend();
    syncControls();
    input.focus();
  }));

  // ===== 顶上的标题：就是这篇稿子的标题 =====
  // 照着标题框（编辑器上面那个）显示：在那里打字、AI 改了、撤销、换了稿子都跟着变（不等出图）；
  // 在这里改完（↩ 或点别处）写回稿子，是撤销历史里的一步（⌘Z）；Esc 放弃

  const titleField = $("#titleInput");

  function syncSessionTitle() {
    sessionTitle.disabled = draft.readOnly;
    sessionTitle.title = draft.readOnly
      ? "内置说明书不能改"
      : "就是这篇稿子的标题：在这里改，稿子的标题也跟着改（⌘Z 可以撤销）";
    if (document.activeElement !== sessionTitle) sessionTitle.value = titleField.value;
  }

  async function commitSessionTitle() {
    const text = sessionTitle.value.trim();
    if (draft.readOnly || !text || text === titleField.value.trim()) {
      sessionTitle.value = titleField.value;
      return;
    }
    await ai.api.useTitle(text);
    appStatus.textContent = `标题改成了「${text}」，${root.MediaCraftPlatform.keys("⌘Z")} 可以撤销`;
  }

  sessionTitle.addEventListener("keydown", (event) => {
    if (event.isComposing || event.keyCode === 229) return;
    if (event.key === "Enter") {
      event.preventDefault();
      sessionTitle.blur();
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      sessionTitle.dataset.cancelled = "true";
      sessionTitle.blur();
    }
  });
  sessionTitle.addEventListener("blur", () => {
    if (sessionTitle.dataset.cancelled) {
      delete sessionTitle.dataset.cancelled;
      syncSessionTitle();
      return;
    }
    run(commitSessionTitle, syncSessionTitle);
  });
  titleField.addEventListener("input", syncSessionTitle);
  mc.on("change", syncSessionTitle);

  // ===== AI 设置（每个后端的程序在哪） =====

  // 「关于」：版本号与「检查更新…」（只在 App 里有；版本问一次就记着）
  const about = $("#aboutSettings");
  let aboutLoaded = false;
  async function syncAbout() {
    const windows = root.MediaCraftNative?.windows;
    if (!windows?.appInfo || aboutLoaded) return;
    try {
      const info = await windows.appInfo();
      $("#aboutVersion").textContent = `Vibepost ${info.version}`;
      about.hidden = !info.updates;
      aboutLoaded = true;
    } catch {
      about.hidden = true;
    }
  }
  $("#checkUpdatesBtn").addEventListener("click", () => {
    settings.open = false;
    root.MediaCraftNative?.windows?.checkForUpdates().catch((error) => showModelError(error.message || String(error)));
  });

  // 接别家模型的几个后端平时收着；这篇正用着其中一个时展开
  const moreBackends = $("#aiMoreBackends");

  function syncSettings() {
    void syncAbout();
    if (backend.protocol === "acp") moreBackends.open = true;
    for (const [id, { found, input: pathInput, error }] of Object.entries(pathGroups)) {
      const current = statuses[id];
      const label = ai.backends[id].label;
      error.hidden = true;
      pathInput.value = current?.source === "settings" ? current.path ?? "" : "";
      syncSaveButton(id);
      if (!current) found.textContent = "正在查找…";
      else if (current.available) {
        const where = current.source === "settings" ? "在这里指定的" : "在终端的 PATH 里找到的";
        found.textContent = `现在用的是 ${current.path}（${current.version}，${where}）`;
      } else found.textContent = current.error ?? `没有找到本机 ${label}`;
    }
  }

  // 「保存」平时是普通按钮，路径框里填了和现在不一样的才是主按钮：设置里不会同时摆着两个蓝色的「保存」
  function syncSaveButton(id) {
    const { group, input: pathInput } = pathGroups[id];
    const saved = statuses[id]?.source === "settings" ? statuses[id].path ?? "" : "";
    const dirty = pathInput.value.trim() !== saved;
    const button = group.querySelector("[data-path-save]");
    button.classList.toggle("primary-button", dirty);
    button.classList.toggle("pill-button", !dirty);
  }

  async function savePath(id, path) {
    const result = await ai.api.setPath(path, id);
    syncSettings();
    const { error } = pathGroups[id];
    error.hidden = result.available;
    error.textContent = result.available ? "" : result.error ?? `没有找到本机 ${ai.backends[id].label}`;
    if (result.available && id === backend.id) settings.open = false;
  }

  settings.addEventListener("toggle", () => {
    if (!settings.open) return;
    syncSettings();
    for (const id of Object.keys(pathGroups)) {
      if (!statuses[id]) void ai.api.status({ backend: id }).catch(() => undefined);
    }
    void syncImageSettings();
  });

  // ===== 生图的设置（用 Claude Code 时的 generate_image，走 OpenAI）：模型（空为默认），存在本机 =====

  async function syncImageSettings(error = null) {
    const current = await ai.api.imageSettings();
    imageModelInput.placeholder = current.defaultModel;
    // 出错时留着输入的字，改了再试
    if (!error) imageModelInput.value = current.model === current.defaultModel ? "" : current.model;
    imageError.hidden = !error;
    imageError.textContent = error ?? "";
    imageNote.textContent = `用 Claude Code 时，生图调 OpenAI 的接口，密钥用终端环境（或 ~/.env）里的 ${current.key}，不用在这里填；按张计费，记在你自己的账户上。用 Codex 时它用自带的生图，不用这里的设置；OpenCode、Oh My Pi、Kimi Code 不能生图。`;
  }

  async function saveImageSettings() {
    try {
      await ai.api.setImageSettings({ model: imageModelInput.value });
      await syncImageSettings();
    } catch (error) {
      await syncImageSettings(error.message || String(error));
    }
  }

  imageModelInput.addEventListener("change", () => void saveImageSettings());
  imageModelInput.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" || event.isComposing) return;
    event.preventDefault();
    void saveImageSettings();
  });
  for (const [id, { group, input: pathInput }] of Object.entries(pathGroups)) {
    group.querySelector("[data-path-save]").addEventListener("click", () => run(() => savePath(id, pathInput.value)));
    group.querySelector("[data-path-auto]").addEventListener("click", () => run(() => savePath(id, null)));
    pathInput.addEventListener("input", () => syncSaveButton(id));
    pathInput.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" || event.isComposing) return;
      event.preventDefault();
      run(() => savePath(id, pathInput.value));
    });
  }
  $("#aiRetryBtn").addEventListener("click", () => void checkStatus({ refresh: true }));
  // 指引里的「指定路径」：打开设置，聚焦这篇的后端那一组
  $("#aiSetPathBtn").addEventListener("click", () => {
    settings.open = true;
    pathGroups[backend.id].input.focus();
  });

  // ===== 跟着当前稿子走 =====

  async function followDraft(draftId) {
    if (draftId !== undefined && draftId === draft.id) return;
    const current = await mc.drafts.current();
    if (current.id === draft.id) return;
    draft = { id: current.id, readOnly: current.readOnly };
    writingSkills.set([]);
    writingSkills.close();
    setContext(null);
    showModelError(null);
    modelCustom.hidden = true;
    syncBackend();
    syncModel();
    renderThread();
    syncSessionTitle();
  }

  ai.on((event) => {
    if (event.type === "status") {
      statuses[event.backend] = event.status;
      // 没选过后端的新稿子：找到 Codex 之后默认就是它
      syncBackend();
      if (event.backend === backend.id && backend.id !== "claude") void loadModels();
      syncControls();
      if (settings.open) syncSettings();
    } else if (event.type === "providers") {
      // 在 App 里填的接口变了：它们的模型在 OpenCode 报的选单里
      if (backend.id === "opencode") void loadModels();
    } else if (event.draftId === draft.id) {
      if (event.type === "text") updateText(event);
      else if (event.type === "model") {
        syncBackend();
        syncModel();
        syncControls();
      } else renderThread();
    }
  });
  mc.on("change", ({ draftId }) => void followDraft(draftId));
  mc.on("rendered", ({ draftId }) => void followDraft(draftId));

  // 第一次看 AI 助手时才去找本机的程序（要跑一次登录 shell）：先找 Codex（没选过后端的新稿子默认用它），再找这篇的
  new MutationObserver(() => {
    if (panel.hidden || statuses.codex !== undefined) return;
    statuses.codex = null;
    void ai.api.status({ backend: "codex" }).catch(() => undefined).finally(() => void checkStatus());
  }).observe(panel, { attributes: true, attributeFilter: ["hidden"] });

  ai.start();
  syncBackendNames();
  void loadModels();
  void followDraft();
})(window);
