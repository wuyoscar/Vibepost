// 稿件抽屉：最近改过的在前，按名字与正文搜、按类型筛；新建、打开、删除（页内确认）；稿子存满时明说。
// App 里一个窗口一篇稿子：⌘ 点一篇、或右键「在新窗口打开」，在新窗口里打开它。
(function (root) {
  "use strict";

  const drafts = root.MediaCraftDrafts;
  const $ = (selector) => document.querySelector(selector);
  const workspace = $(".workspace");
  const drawer = $("#draftsDrawer");
  const toggle = $("#draftsToggleBtn");
  const newButton = $("#newDraftBtn");
  const searchInput = $("#draftSearch");
  const filterButtons = [...document.querySelectorAll("[data-draft-filter]")];
  const listRoot = $("#draftList");
  const emptyNote = $("#draftSearchEmpty");
  const status = $("#statusText");
  let filter = "all";
  let renderQueued = false;
  // 开新窗口（只在 App 里有）
  const windows = root.MediaCraftNative?.windows ?? null;

  // ===== 页内确认框（不用系统弹窗） =====
  const modal = $("#confirmDialog");
  const modalTitle = $("#confirmTitle");
  const modalMessage = $("#confirmMessage");
  const okButton = $("#confirmOk");
  const cancelButton = $("#confirmCancel");
  let settle = null;

  // 问一句，点确认得到 true；取消、Esc、点遮罩得到 false。cancelLabel 为空时只有一个按钮（只是告知）。
  function ask({ title, message, okLabel, cancelLabel = "取消", danger = false }) {
    settle?.(false);
    modalTitle.textContent = title;
    modalMessage.textContent = message;
    okButton.textContent = okLabel;
    okButton.classList.toggle("is-danger", danger);
    cancelButton.textContent = cancelLabel;
    cancelButton.hidden = !cancelLabel;
    const returnFocus = document.activeElement;
    modal.classList.remove("hidden");
    (cancelLabel ? cancelButton : okButton).focus();
    return new Promise((resolve) => {
      settle = (answer) => {
        settle = null;
        modal.classList.add("hidden");
        root.MediaCraftMotion.returnFocus(modal, returnFocus);
        resolve(answer);
      };
    });
  }

  // 别处要问一句时也用这个确认框（AI 助手的「新会话」）
  root.MediaCraftConfirm = ask;

  okButton.addEventListener("click", () => settle?.(true));
  cancelButton.addEventListener("click", () => settle?.(false));
  modal.addEventListener("click", (event) => {
    if (event.target === modal) settle?.(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !settle) return;
    event.preventDefault();
    settle(false);
  });

  // ===== 列表 =====

  const pad = (value) => String(value).padStart(2, "0");

  function formatTime(ms) {
    const date = new Date(ms);
    const now = new Date();
    const time = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
    const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    if (ms >= startOfToday) return `今天 ${time}`;
    if (ms >= startOfToday - 24 * 60 * 60 * 1000) return `昨天 ${time}`;
    if (date.getFullYear() === now.getFullYear()) return `${date.getMonth() + 1}月${date.getDate()}日`;
    return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
  }

  function icon(name) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "icon");
    svg.setAttribute("aria-hidden", "true");
    const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
    use.setAttribute("href", `#${name}`);
    svg.append(use);
    return svg;
  }

  function item(summary) {
    const row = document.createElement("div");
    row.className = "draft-row";
    row.setAttribute("role", "listitem");
    row.classList.toggle("is-current", summary.current);
    row.classList.toggle("built-in", summary.builtIn);
    row.dataset.draftId = summary.id;

    const open = document.createElement("button");
    open.type = "button";
    open.className = "draft-row-open";
    if (summary.current) open.setAttribute("aria-current", "true");
    const name = document.createElement("span");
    name.textContent = summary.title;
    const meta = document.createElement("small");
    const kind = document.createElement("b");
    kind.textContent = summary.builtIn ? "说明" : summary.mode === "article" ? "长文" : "图文";
    meta.append(kind, summary.builtIn ? (summary.mode === "article" ? "长文" : "图文") : formatTime(summary.updatedAt));
    open.append(name, meta);
    open.title = windows ? "⌘ 点按在新窗口打开" : "";
    open.addEventListener("click", (event) => void (event.metaKey && windows ? openInWindow(summary) : openDraft(summary)));
    row.addEventListener("contextmenu", (event) => showMenu(event, summary));
    row.append(open);

    if (summary.builtIn) {
      const lock = document.createElement("span");
      lock.className = "draft-row-lock";
      lock.title = "内置说明书只能看，不能改";
      lock.append(icon("i-lock"));
      row.append(lock);
    } else {
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "draft-row-delete";
      remove.title = "删除";
      remove.setAttribute("aria-label", `删除 ${summary.title}`);
      remove.append(icon("i-trash"));
      remove.addEventListener("click", () => void removeDraft(summary));
      row.append(remove);
    }
    return row;
  }

  // 每一行按内容缓存：只有名字、类型、时间或是不是当前这篇变了才重建，列表很长时边打字边存也不卡。
  const rows = new Map();

  function rowFor(summary) {
    const key = `${new Date().toDateString()}\n${JSON.stringify(summary)}`;
    const cached = rows.get(summary.id);
    if (cached?.key === key) return cached.row;
    const row = item(summary);
    rows.set(summary.id, { key, row });
    return row;
  }

  // 自己的稿子按最近修改在前，内置说明书垫底。
  function render() {
    renderQueued = false;
    const query = searchInput.value.trim();
    const found = drafts.search(query, filter);
    const shown = [...found.filter((summary) => !summary.builtIn), ...found.filter((summary) => summary.builtIn)].map(rowFor);
    const children = listRoot.children;
    if (shown.length !== children.length || shown.some((row, index) => children[index] !== row)) listRoot.replaceChildren(...shown);
    for (const id of rows.keys()) if (!drafts.get(id)) rows.delete(id);
    emptyNote.textContent = query ? "没有找到这篇稿件" : "这一类还没有稿件";
    emptyNote.hidden = shown.length > 0;
    for (const button of filterButtons) button.setAttribute("aria-pressed", String(button.dataset.draftFilter === filter));
  }

  // 抽屉收着时不画，打开时再画；同一轮里的连续改动只画一次。
  function scheduleRender() {
    if (!isOpen() || renderQueued) return;
    renderQueued = true;
    queueMicrotask(() => {
      if (renderQueued) render();
    });
  }

  function isOpen() {
    return drawer.classList.contains("open");
  }

  // 开合立即生效；编辑区与舞台上的卡片、页码、胶片从原来的位置滑到新位置（抽屉自己的展开在 styles.css）
  const FOLLOWERS = ".editor-pane, .stage-nav, .card-frame, .article-page, .stage-spec, .filmstrip";

  function setOpen(open) {
    root.MediaCraftMotion.flip([...workspace.querySelectorAll(FOLLOWERS)], () => {
      drawer.classList.toggle("open", open);
      workspace.classList.toggle("is-drawer-open", open);
      toggle.setAttribute("aria-expanded", String(open));
    });
    if (open) render();
  }

  // ===== 操作 =====

  function report(message) {
    status.textContent = message;
  }

  async function openDraft(summary) {
    if (summary.current) return;
    try {
      await drafts.open(summary.id);
      report(summary.builtIn ? `已打开内置说明书：${summary.title}` : `已打开：${summary.title}`);
    } catch (error) {
      report(error.message);
    }
  }

  // 在新窗口里打开这篇（「新建窗口」里的那篇由壳开窗口、新窗口的页面自己打开）
  async function openInWindow(summary) {
    try {
      const { elsewhere } = await windows.open({ draftId: summary.id });
      report(elsewhere ? `「${summary.title}」在另一个窗口里开着，已经切到那个窗口` : `已在新窗口打开：${summary.title}`);
    } catch (error) {
      report(error.message);
    }
  }

  // ===== 右键菜单：在新窗口打开、删除 =====
  const menu = $("#draftMenu");
  const menuWindow = menu.querySelector('[data-draft-action="window"]');
  const menuDelete = menu.querySelector('[data-draft-action="delete"]');
  const MENU_EDGE = 8;
  let menuFor = null;
  let menuReturn = null;

  function showMenu(event, summary) {
    event.preventDefault();
    menuFor = summary;
    menuReturn = document.activeElement;
    menuWindow.hidden = !windows;
    menuDelete.hidden = summary.builtIn;
    if (menuWindow.hidden && menuDelete.hidden) return;
    menu.hidden = false;
    // 开在点按的地方，放不下时往窗口里挪；键盘打开（没有坐标）时开在这一行下面
    const anchor = event.clientX || event.clientY ? { x: event.clientX, y: event.clientY } : (() => {
      const box = event.currentTarget.getBoundingClientRect();
      return { x: box.left + 12, y: box.bottom };
    })();
    menu.style.left = `${Math.max(MENU_EDGE, Math.min(anchor.x, root.innerWidth - menu.offsetWidth - MENU_EDGE))}px`;
    menu.style.top = `${Math.max(MENU_EDGE, Math.min(anchor.y, root.innerHeight - menu.offsetHeight - MENU_EDGE))}px`;
    menu.querySelector(".menu-item:not([hidden])").focus();
  }

  function hideMenu({ restoreFocus = false } = {}) {
    if (menu.hidden) return;
    menu.hidden = true;
    if (restoreFocus && menuReturn?.isConnected) menuReturn.focus();
    menuFor = null;
  }

  menuWindow.addEventListener("click", () => {
    const summary = menuFor;
    hideMenu();
    if (summary) void openInWindow(summary);
  });
  menuDelete.addEventListener("click", () => {
    const summary = menuFor;
    hideMenu();
    if (summary) void removeDraft(summary);
  });
  document.addEventListener("pointerdown", (event) => {
    if (!menu.contains(event.target)) hideMenu();
  });
  document.addEventListener("keydown", (event) => {
    if (menu.hidden) return;
    if (event.key === "Escape") {
      event.preventDefault();
      hideMenu({ restoreFocus: true });
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const items = [...menu.querySelectorAll(".menu-item:not([hidden])")];
      const at = items.indexOf(document.activeElement);
      items[(at + (event.key === "ArrowDown" ? 1 : items.length - 1)) % items.length]?.focus();
    }
  });
  listRoot.addEventListener("scroll", () => hideMenu());
  root.addEventListener("blur", () => hideMenu());
  root.addEventListener("resize", () => hideMenu());

  async function removeDraft(summary) {
    const confirmed = await ask({
      title: `删除《${summary.title}》？`,
      message: "这篇稿子连同它的图片、实况视频与 AI 的工作副本会从这台 Mac 上删掉，删除后找不回来。Claude Code、Codex 自己的会话记录不在此列。",
      okLabel: "删除",
      danger: true,
    });
    if (!confirmed) return;
    try {
      await drafts.remove(summary.id);
      report(`已删除：${summary.title}`);
    } catch (error) {
      report(error.message);
    }
  }

  async function createDraft() {
    if (drafts.count() >= drafts.limit) {
      await ask({
        title: "稿件已经存满",
        message: `最多存 ${drafts.limit} 篇稿子，现在已经满了。先删掉不需要的稿子再新建，旧稿子不会被自动删掉。`,
        okLabel: "知道了",
        cancelLabel: "",
      });
      return;
    }
    try {
      await drafts.create();
      report("已新建稿子");
      await root.mediacraft.editor.focus();
    } catch (error) {
      report(error.message);
    }
  }

  toggle.addEventListener("click", () => setOpen(!isOpen()));
  newButton.addEventListener("click", () => void createDraft());
  searchInput.addEventListener("input", render);
  for (const button of filterButtons) {
    button.addEventListener("click", () => {
      filter = button.dataset.draftFilter;
      render();
    });
  }
  drafts.on("list", scheduleRender);

  drafts.drawer = { setOpen };
})(window);
