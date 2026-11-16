// 发布助手：页脚的「检查 · N」与它打开的面板（按分组列出提醒，逐个跳到标题框、正文栏或卡片内容里、替换、忽略），卡片内容里的标注；
// 点「发送到 iPhone」时先检查一遍、还有提醒就问一句；发完以后可以复制的话题；导出、发送用到系统字体时的一次提醒。
// 规则在 src/publish/check.js（词库与出处见 docs/publish-check.md）；稿子、AI 会话、出图都经 App API（window.mediacraft）读写。
// 忽略了哪些、发送前查不查、字体提醒还要不要，记在本机的 localStorage `mediacraft.publish.v1`（见 docs/storage.md）。
(function (root) {
  "use strict";

  const publish = root.MediaCraftPublish;
  const $ = (selector) => document.querySelector(selector);
  const PREFS_KEY = "mediacraft.publish.v1";
  const LEVELS = { warn: "警告", hint: "提示" };
  // 发送前的确认框里每组最多列几个名字
  const SHEET_NAMES = 4;
  // 改标题、正文栏时停一下再检查（它们不影响出图，没有「出图画完」可等）
  const TYPING_DELAY = 250;
  // 提醒落在哪里：跳过去时的说法
  const PLACES = { title: "标题里的", caption: "正文栏里的", body: "" };
  // 正文栏空着、署名还没填、排版的提示（src/publish/check.js）：只在检查面板里列，发送前不问
  const QUIET_KEYS = new Set(["caption:empty", "byline:empty"]);
  const quiet = (item) => QUIET_KEYS.has(item.key) || item.category === "layout";

  // { beforeSend: 发送前自动检查, fontNotice: 用到系统字体时提醒, ignored: { 稿子 id: [提醒的 key] } }
  function readPrefs() {
    try {
      const prefs = JSON.parse(root.localStorage.getItem(PREFS_KEY) || "{}");
      return { beforeSend: prefs.beforeSend !== false, fontNotice: prefs.fontNotice !== false, ignored: prefs.ignored ?? {} };
    } catch {
      return { beforeSend: true, fontNotice: true, ignored: {} };
    }
  }

  function writePrefs(patch) {
    try {
      root.localStorage.setItem(PREFS_KEY, JSON.stringify({ ...readPrefs(), ...patch }));
    } catch {
      // 写不进时这次照常用界面上的状态，下次启动退回默认（都提醒）。
    }
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  // 同一分组的提醒放在一起，分组按 check.js 的顺序
  function grouped(items, labels) {
    return publish.CATEGORY_ORDER
      .map((category) => ({ category, label: labels.get(category), items: items.filter((item) => item.category === category) }))
      .filter((group) => group.items.length);
  }

  // host：{ hints（MediaCraftEditor.bindHints 的返回值）, notify(message) 状态栏 }
  function createAssistant({ hints, notify }) {
    const mc = root.mediacraft;
    const badge = $("#publishCheckBtn");
    const panel = $("#publishCheck");
    const list = $("#publishCheckList");
    const summary = $("#publishCheckSummary");
    const autoToggle = $("#publishCheckAuto");
    const restoreButton = $("#publishCheckRestore");
    const titleInput = $("#titleInput");
    const captionInput = $("#captionInput");
    const sheet = {
      modal: $("#sendCheckDialog"),
      title: $("#sendCheckTitle"),
      list: $("#sendCheckList"),
      mute: $("#sendCheckMute"),
      review: $("#sendCheckReview"),
      go: $("#sendCheckGo"),
    };

    // 界面上正显示的这次结果（evaluate 的返回值）
    let shown = { draftId: null, readOnly: true };
    let lastPageCount = 0;
    let ticket = 0;
    let typingTimer = 0;
    // 这次打开 App 里已经提醒过的「稿子 + 字体」
    const noticed = new Set();

    // ===== 检查 =====

    async function evaluate(pageCount) {
      const [draft, lexicon, profile] = await Promise.all([mc.drafts.current(), publish.loadLexicon(), mc.profile.get()]);
      const pages = draft.mode === "cards" && !draft.readOnly ? await mc.render.pages() : [];
      const { messages } = await mc.ai.history(draft.id);
      const all = draft.readOnly ? [] : publish.check({
        title: draft.title,
        caption: draft.caption,
        markdown: draft.markdown,
        mode: draft.mode,
        pageCount,
        usedAI: messages.some((message) => message.role === "user"),
        signed: Boolean(profile.name.trim()),
        pageIssues: pages.map((page) => page.issues),
      }, lexicon);
      const ignored = new Set(readPrefs().ignored[draft.id] ?? []);
      const items = all.filter((item) => !ignored.has(item.key));
      return { draftId: draft.id, readOnly: draft.readOnly, markdown: draft.markdown, items, ignored: all.length - items.length, labels: lexicon.labels };
    }

    // 重新检查这篇并更新界面；连着来几次时只画最后一次。返回这次的结果。
    async function refresh(pageCount = lastPageCount) {
      lastPageCount = pageCount;
      const mine = ++ticket;
      const result = await evaluate(pageCount);
      if (mine === ticket) {
        shown = result;
        render(result);
      }
      return result;
    }

    const refreshLater = (pageCount) => {
      refresh(pageCount).catch((error) => notify(`发布检查没能完成：${error.message || error}`));
    };

    // ===== 界面 =====

    function renderBadge({ readOnly, items }) {
      badge.hidden = readOnly;
      badge.textContent = items.length ? `检查 · ${items.length}` : "检查";
      badge.dataset.level = items.some((item) => item.level === "warn") ? "warn" : items.length ? "hint" : "clear";
    }

    function contextOf(item) {
      const line = element("span", "check-context");
      const [before, after] = item.context;
      line.append(before && `…${before}`, element("mark", "", item.text), after && `${after}…`);
      return line;
    }

    function itemRow(item) {
      const row = element("div", `check-item is-${item.level}`);
      const head = element(item.where ? "button" : "div", "check-jump");
      head.append(element("span", "check-level", LEVELS[item.level]), element("span", "check-label", item.label));
      if (item.context) head.append(contextOf(item));
      if (item.where) {
        head.type = "button";
        head.setAttribute("aria-label", `跳到${PLACES[item.where]}「${item.label}」`);
        head.addEventListener("click", () => void jump(item));
      }
      const actions = element("div", "check-actions");
      if (typeof item.suggest === "string" && !shown.readOnly) {
        const replace = element("button", "text-button is-accent", item.suggest ? `改成「${item.suggest}」` : "删掉");
        replace.type = "button";
        replace.addEventListener("click", () => void replaceHit(item));
        actions.append(replace);
      }
      const ignore = element("button", "text-button", "忽略");
      ignore.type = "button";
      ignore.setAttribute("aria-label", `忽略「${item.label}」`);
      ignore.title = "这篇里不再提醒这一条";
      ignore.addEventListener("click", () => ignoreItem(item));
      actions.append(ignore);
      row.append(head, element("p", "check-reason", item.reason), actions);
      return row;
    }

    function renderList({ items, ignored, labels }) {
      const hadFocus = list.contains(document.activeElement);
      const warn = items.filter((item) => item.level === "warn").length;
      const hint = items.length - warn;
      summary.textContent = items.length ? [warn && `${warn} 处警告`, hint && `${hint} 处提示`].filter(Boolean).join(" · ") : "";
      if (!items.length) {
        const empty = element("p", "check-empty");
        empty.append(element("span", "check-empty-mark"), "没有要改的地方，可以发了");
        list.replaceChildren(empty);
      } else {
        list.replaceChildren(...grouped(items, labels).map((group) => {
          const section = element("section", "check-group");
          const heading = element("h3", "check-group-title", group.label);
          heading.append(element("span", "count", String(group.items.length)));
          section.append(heading, ...group.items.map(itemRow));
          return section;
        }));
      }
      restoreButton.hidden = !ignored;
      restoreButton.textContent = `恢复忽略的 ${ignored} 处`;
      // 点的那一行（替换、忽略）重画没了：焦点留在面板里，键盘接着用
      if (hadFocus && !list.contains(document.activeElement)) panel.focus();
    }

    function render(result) {
      renderBadge(result);
      hints.set(result.markdown, result.items
        .filter((item) => item.where === "body")
        .map((item) => ({ from: item.from, to: item.to, level: item.level, title: `${item.label}：${item.reason}` })));
      if (result.readOnly) setOpen(false);
      renderList(result);
    }

    function setOpen(open) {
      panel.hidden = !open;
      badge.setAttribute("aria-expanded", String(open));
      if (open) panel.focus();
    }

    // ===== 跳过去、替换、忽略 =====

    // 提醒在哪个字段里：标题、正文栏或卡片内容
    const fieldOf = (item) => ({ title: "title", caption: "caption" })[item.where] ?? "markdown";

    // 提醒还对得上现在的稿子吗（算完之后又改了字，下一次检查会跟上）
    function stillThere(item, draft) {
      return item.text === undefined || draft[fieldOf(item)].slice(item.from, item.to) === item.text;
    }

    async function jump(item) {
      const draft = await mc.drafts.current();
      if (!stillThere(item, draft)) {
        refreshLater();
        return;
      }
      if (item.where === "title") {
        titleInput.focus();
        titleInput.setSelectionRange(item.from, item.to);
      } else if (item.where === "caption") {
        root.MediaCraftCaption.focus(item.from, item.to);
      } else {
        await mc.editor.select(item.from, item.to);
      }
    }

    async function replaceHit(item) {
      const draft = await mc.drafts.current();
      if (!stillThere(item, draft)) {
        refreshLater();
        return;
      }
      const field = fieldOf(item);
      const source = draft[field];
      await mc.drafts.update({ [field]: `${source.slice(0, item.from)}${item.suggest}${source.slice(item.to)}` });
      const done = item.suggest ? `已把「${item.text}」改成「${item.suggest}」` : `已删掉「${item.text}」`;
      notify(field === "markdown" ? `${done}（${root.MediaCraftPlatform.keys("⌘Z")} 撤销）` : done);
      // 改标题、正文栏不出图：自己再查一遍
      if (field !== "markdown") refreshLater();
    }

    function ignoreItem(item) {
      const { ignored } = readPrefs();
      const keys = new Set([...(ignored[shown.draftId] ?? []), item.key]);
      writePrefs({ ignored: { ...ignored, [shown.draftId]: [...keys] } });
      refreshLater();
    }

    restoreButton.addEventListener("click", () => {
      const others = Object.entries(readPrefs().ignored).filter(([draftId]) => draftId !== shown.draftId);
      writePrefs({ ignored: Object.fromEntries(others) });
      refreshLater();
    });

    badge.addEventListener("click", () => setOpen(panel.hidden));
    panel.querySelector("[data-check-close]").addEventListener("click", () => {
      setOpen(false);
      badge.focus();
    });
    panel.addEventListener("keydown", (event) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      setOpen(false);
      badge.focus();
    });

    autoToggle.checked = readPrefs().beforeSend;
    autoToggle.addEventListener("change", () => writePrefs({ beforeSend: autoToggle.checked }));

    // ===== 发送前 =====

    let settle = null;

    function sheetLine({ label, items }) {
      const names = [...new Set(items.map((item) => item.label))];
      const shownNames = names.slice(0, SHEET_NAMES).join("、");
      const line = element("li");
      line.append(element("strong", "", label), names.length > SHEET_NAMES ? `${shownNames} 等 ${items.length} 处` : shownNames);
      return line;
    }

    // 问一句：「仍然发送」得到 true；「去看看」打开检查面板，得到 false；Esc、点遮罩得到 false
    function ask({ items, labels }) {
      settle?.("cancel");
      sheet.title.textContent = `还有 ${items.length} 处提醒，仍然发送？`;
      sheet.list.replaceChildren(...grouped(items, labels).map(sheetLine));
      sheet.mute.checked = false;
      const returnFocus = document.activeElement;
      sheet.modal.classList.remove("hidden");
      sheet.review.focus();
      return new Promise((resolve) => {
        settle = (answer) => {
          settle = null;
          sheet.modal.classList.add("hidden");
          if (sheet.mute.checked) {
            autoToggle.checked = false;
            writePrefs({ beforeSend: false });
          }
          root.MediaCraftMotion.returnFocus(sheet.modal, returnFocus);
          if (answer === "review") setOpen(true);
          resolve(answer === "send");
        };
      });
    }

    sheet.go.addEventListener("click", () => settle?.("send"));
    sheet.review.addEventListener("click", () => settle?.("review"));
    sheet.modal.addEventListener("click", (event) => {
      if (event.target === sheet.modal) settle?.("cancel");
    });
    document.addEventListener("keydown", (event) => {
      if (event.key !== "Escape" || !settle) return;
      event.preventDefault();
      settle("cancel");
    });

    // 点「发送到 iPhone」之后、真正发送之前（src/output/output.js）：没关掉自动检查时查一遍，还有提醒就问。返回要不要发
    async function beforeSend() {
      if (!autoToggle.checked) return true;
      const draft = await mc.drafts.current();
      const pageCount = draft.mode === "cards" ? (await mc.render.pages()).length : 0;
      const result = await refresh(pageCount);
      // 「正文还没写」「署名还没填」与排版提示不拦发送：正文栏可以一直空着（发完的提示卡会说剪贴板没动），不想署名也可以，
      // 排版是建议
      const items = result.items.filter((item) => !quiet(item));
      return items.length ? ask({ ...result, items }) : true;
    }

    // ===== 发完以后 =====

    // 要复制的话题：正文里的 #话题（图文卡片是正文栏，长文是全文），加上 AI 助手的快捷命令最近一次回复里建议的，去重
    async function topics() {
      const draft = await mc.drafts.current();
      const { messages } = await mc.ai.history(draft.id);
      const commands = new Set(messages.filter((message) => message.role === "user" && message.kind === "command").map((message) => message.turn));
      const reply = messages.filter((message) => message.role === "assistant" && commands.has(message.turn) && publish.topicsIn(message.text).length).at(-1);
      const own = draft.mode === "article" ? publish.bodyTopics(draft.markdown) : publish.topicsIn(draft.caption);
      return [...new Set([...own, ...(reply ? publish.topicsIn(reply.text) : [])])];
    }

    // 导出、发送时（src/output/output.js）：这篇用了只限个人使用的系统字体，就提醒一次（同一篇同样的字体这次打开 App 只提醒一次，
    // 「不再提醒」以后都不提醒）。返回进度卡片上的提醒，不用提醒时为 null
    async function fontNotice() {
      if (!readPrefs().fontNotice) return null;
      const draft = await mc.drafts.current();
      const scripts = draft.markdown.includes("`") ? ["zh", "en", "code"] : ["zh", "en"];
      const names = root.MediaCraftFonts.personalOnly(draft.fonts, root.MediaCraftThemes.get(draft.theme).fonts, scripts);
      const key = `${draft.id}|${names.join("|")}`;
      if (!names.length || noticed.has(key)) return null;
      noticed.add(key);
      return {
        text: `用了系统字体「${names.join("」「")}」，只限个人使用；商用请换成打包的开源字体`,
        action: { label: "不再提醒", run: () => writePrefs({ fontNotice: false }) },
      };
    }

    mc.on("rendered", ({ pageCount }) => refreshLater(pageCount));
    // 用了 AI（开始新的一轮）之后要提醒声明；AI 没改正文时不会出图，这里自己查
    mc.on("ai", (event) => {
      if (event.type === "turn") refreshLater();
    });
    for (const input of [titleInput, captionInput]) {
      input.addEventListener("input", () => {
        clearTimeout(typingTimer);
        typingTimer = setTimeout(refreshLater, TYPING_DELAY);
      });
    }

    return { beforeSend, topics, fontNotice };
  }

  publish.createAssistant = createAssistant;
})(globalThis);
