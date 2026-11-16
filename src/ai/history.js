// AI 助手顶上的「会话历史」（<details id="aiHistory">）：聊过的稿子按最近一次 AI 活动排，最近的在前；每行是标题、
// 多久以前、后端与最后一句话，可以按标题和对话里的字搜。点一篇在这个窗口打开（它在别的窗口里开着时跳到那个窗口），
// ⌘ 点按或行尾的按钮在新窗口打开；↑↓ 在搜索框与各行之间走，↩ 打开，⌘↩ 在新窗口打开，Esc 收起（src/workspace/menus.js）。
// 只经 App API（mediacraft.ai.sessions、drafts.open）与原生桥的开窗口。
(function (root) {
  "use strict";

  const mc = root.mediacraft;
  const ai = root.MediaCraftAI;
  const windows = root.MediaCraftNative?.windows ?? null;
  const $ = (selector) => document.querySelector(selector);
  const menu = $("#aiHistory");
  const search = $("#aiHistorySearch");
  const list = $("#aiHistoryList");
  const emptyNote = $("#aiHistoryEmpty");
  const appStatus = $("#statusText");

  const MINUTE = 60 * 1000;
  const HOUR = 60 * MINUTE;
  const pad = (value) => String(value).padStart(2, "0");

  // 多久以前：刚刚、N 分钟前、今天以内 N 小时前、昨天 HH:mm、今年 M月D日、更早 YYYY年M月D日
  function ago(time, now = Date.now()) {
    const elapsed = now - time;
    if (elapsed < MINUTE) return "刚刚";
    if (elapsed < HOUR) return `${Math.floor(elapsed / MINUTE)} 分钟前`;
    const date = new Date(time);
    const today = new Date(now);
    const startOfToday = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
    if (time >= startOfToday) return `${Math.floor(elapsed / HOUR)} 小时前`;
    if (time >= startOfToday - 24 * HOUR) return `昨天 ${pad(date.getHours())}:${pad(date.getMinutes())}`;
    if (date.getFullYear() === today.getFullYear()) return `${date.getMonth() + 1}月${date.getDate()}日`;
    return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
  }

  const element = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  function icon(name) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "icon icon-small");
    svg.setAttribute("aria-hidden", "true");
    const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
    use.setAttribute("href", `#${name}`);
    svg.append(use);
    return svg;
  }

  // ===== 打开 =====

  async function open(session, { newWindow = false } = {}) {
    menu.open = false;
    if (newWindow && windows) {
      try {
        const { elsewhere } = await windows.open({ draftId: session.draftId });
        appStatus.textContent = elsewhere ? `「${session.title}」在另一个窗口里开着，已经切到那个窗口` : `已在新窗口打开：${session.title}`;
      } catch (error) {
        appStatus.textContent = error.message || String(error);
      }
      return;
    }
    if (session.current) return;
    try {
      await mc.drafts.open(session.draftId);
      appStatus.textContent = `已打开：${session.title}`;
    } catch (error) {
      // 在别的窗口里开着：那个窗口已经到了前面，这里说一声
      appStatus.textContent = error.message || String(error);
    }
  }

  // ===== 列表 =====

  function row(session) {
    const item = element("li", "ai-history-item");
    item.dataset.draftId = session.draftId;
    item.classList.toggle("is-current", session.current);
    const button = element("button", "ai-history-open");
    button.type = "button";
    if (session.current) button.setAttribute("aria-current", "true");
    if (windows) button.title = "⌘ 点按在新窗口打开";
    const head = element("span", "ai-history-line");
    const time = element("time", "ai-history-time", ago(session.lastActive));
    time.dateTime = new Date(session.lastActive).toISOString();
    head.append(element("span", "ai-history-title", session.title), time);
    const meta = element("span", "ai-history-meta");
    if (session.running) meta.append(element("span", "ai-history-running", "回复中"));
    else if (session.current) meta.append(element("span", "ai-history-here", "当前"));
    meta.append(
      element("b", "ai-history-backend", ai.backends[session.backend]?.label ?? session.backend),
      element("span", "ai-history-said", `${session.last.role === "user" ? "你：" : ""}${session.last.text}`),
    );
    button.append(head, meta);
    button.addEventListener("click", (event) => void open(session, { newWindow: root.MediaCraftPlatform.mod(event) }));
    button.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" || !root.MediaCraftPlatform.mod(event)) return;
      event.preventDefault();
      void open(session, { newWindow: true });
    });
    item.append(button);
    if (windows) {
      const other = element("button", "ai-history-window");
      other.type = "button";
      other.setAttribute("aria-label", `在新窗口打开「${session.title}」`);
      other.title = "在新窗口打开";
      other.tabIndex = -1; // 键盘用 ⌘↩
      other.append(icon("i-window"));
      other.addEventListener("click", () => void open(session, { newWindow: true }));
      item.append(other);
    }
    return item;
  }

  let sessions = [];
  let seq = 0;

  async function refresh() {
    const mine = ++seq;
    const query = search.value.trim();
    const found = await mc.ai.sessions({ query });
    if (mine !== seq) return;
    sessions = found;
    // 焦点在某一行上时，重画后回到同一篇（它还在的话）
    const focused = document.activeElement?.closest?.(".ai-history-item")?.dataset.draftId;
    list.replaceChildren(...sessions.map(row));
    if (focused) list.querySelector(`[data-draft-id="${CSS.escape(focused)}"] .ai-history-open`)?.focus();
    emptyNote.hidden = sessions.length > 0;
    emptyNote.textContent = query ? `没有找到「${query}」` : "还没有和 AI 聊过的稿子。在任意一篇里和 AI 说句话，这里就会记下。";
  }

  // ===== 键盘：搜索框 ↓ 进列表、↩ 打开第一篇；列表里 ↑↓ 走，最上面再 ↑ 回搜索框 =====

  const buttons = () => [...list.querySelectorAll(".ai-history-open")];

  search.addEventListener("keydown", (event) => {
    if (event.isComposing) return;
    if (event.key === "ArrowDown") {
      event.preventDefault();
      buttons()[0]?.focus();
    } else if (event.key === "Enter" && sessions.length) {
      event.preventDefault();
      void open(sessions[0], { newWindow: root.MediaCraftPlatform.mod(event) });
    }
  });

  list.addEventListener("keydown", (event) => {
    if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
    const all = buttons();
    const at = all.indexOf(document.activeElement);
    if (at < 0) return;
    event.preventDefault();
    const next = event.key === "Home" ? 0 : event.key === "End" ? all.length - 1 : at + (event.key === "ArrowDown" ? 1 : -1);
    if (next < 0) search.focus();
    else all[Math.min(next, all.length - 1)].focus();
  });

  search.addEventListener("input", () => void refresh());

  // 打开时清空搜索、从头列、光标进搜索框；开着的时候会话有了新动静（别的窗口也算）就重列
  menu.addEventListener("toggle", () => {
    if (!menu.open) return;
    search.value = "";
    void refresh();
    search.focus();
  });
  const refreshIfOpen = () => {
    if (menu.open) void refresh();
  };
  ai.on((event) => {
    if (event.type !== "text" && event.type !== "status") refreshIfOpen();
  });
  root.MediaCraftDrafts.on("list", refreshIfOpen);
})(window);
