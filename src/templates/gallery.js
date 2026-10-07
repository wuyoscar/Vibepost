// 模板画廊（「从模板新建」）：稿件抽屉「新建」旁的按钮与空白稿子的空状态里打开；每格是那套模板真实出的第一页（drafts.firstPage），
// 顶上两组胶囊按题材 / 风格（标签的第一个、第二个）筛，点一格（或方向键挪过去回车）就复制成自己的稿子并关上画廊。
// 自己存的模板排在自带的后面，能删（先确认）、能在 Finder 中显示。缩略图在画廊打开后逐个生成：看得见的先、一次一张；
// 自带的按 id 缓存，自己存的每次打开重出（文件夹里的可能改过），署名一变全部重出。
// 还管两件相关的事：空白稿子的空状态提示（正文空着、这篇能改时浮在编辑区里，一开始打字就收起），
// 稿件右键菜单「存为模板…」的对话框（名字、说明、题材与风格，存进支持目录的「模板」文件夹）。
// 只通过 App API（window.mediacraft）和界面元素工作，不碰 src/app.js 的内部名字。
(function (root) {
  "use strict";

  const mc = root.mediacraft;
  const $ = (selector) => document.querySelector(selector);
  const status = $("#statusText");
  // 模板只在 App 里能存、能删、能在 Finder 中显示（浏览器里没有模板文件夹）
  const native = Boolean(root.MediaCraftNative?.templates);

  // 缩略图画布：2 倍图，显示时铺满格子（格子宽约 150，3:4）
  const THUMB_WIDTH = 300;
  const THUMB_HEIGHT = 400;
  // 最多记住多少张缩略图（每张约 480 KB）
  const CACHE_LIMIT = 48;
  const UNTITLED = "未命名稿件";

  const report = (message) => {
    status.textContent = message;
  };

  // 两张缩略图之间让出主线程（走消息通道：窗口在屏幕外时连环定时器会被节流到一秒一次）
  const nextTask = () => new Promise((resolve) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = () => resolve();
    channel.port2.postMessage(0);
  });
  // 头像的 data URL 可能有几 MB：只取长度与首尾，够分辨换没换
  const fingerprint = (source) => (source ? `${source.length}:${source.slice(0, 96)}:${source.slice(-96)}` : "");

  let themesById = null;
  async function themeOf(id) {
    if (!themesById) themesById = new Map((await mc.themes.list()).map((theme) => [theme.id, theme]));
    return themesById.get(id) ?? [...themesById.values()][0];
  }

  // ===== 画廊 =====
  const modal = $("#templateGallery");
  const closeButton = $("#templateGalleryClose");
  const well = modal.querySelector(".gallery-well");
  const grid = $("#templateGalleryGrid");
  const emptyNote = $("#templateGalleryEmpty");
  const galleryStatus = $("#templateGalleryStatus");
  const revealButton = $("#templateGalleryReveal");
  const filterGroups = { topic: modal.querySelector('[data-gallery-filter="topic"]'), style: modal.querySelector('[data-gallery-filter="style"]') };

  // 上次读到的模板摘要（自带的在前）；每套一格：id → { summary, card, button, thumb, canvas, shown }
  let templates = [];
  const tiles = new Map();
  // 缩略图缓存：键（见 thumbKey）→ 缩好的画布；出不来的记 null，不再重试这一轮
  const cache = new Map();
  // 署名（名字、头像）进缓存键：卡片上印着它
  let profileKey = "";
  // 筛选：空字符串是「全部」
  const filter = { topic: "", style: "" };
  let refreshSeq = 0;
  // 生成缩略图的那一轮：关上画廊、换筛选就加一，跑着的那一轮发现变了就停
  let job = 0;
  // 打开的次数：自己存的模板每次打开重出一次
  let openSeq = 0;
  let returnFocus = null;
  let picking = false;
  let tileSeq = 0;

  const isOpen = () => !modal.classList.contains("hidden");
  const thumbKey = (summary) => `${summary.id}|${summary.builtIn ? "" : openSeq}|${profileKey}`;

  function store(key, image) {
    cache.delete(key);
    cache.set(key, image);
    if (cache.size > CACHE_LIMIT) cache.delete(cache.keys().next().value);
  }

  function shrink(canvas) {
    const thumb = document.createElement("canvas");
    thumb.width = THUMB_WIDTH;
    thumb.height = THUMB_HEIGHT;
    const context = thumb.getContext("2d");
    context.imageSmoothingQuality = "high";
    context.drawImage(canvas, 0, 0, THUMB_WIDTH, THUMB_HEIGHT);
    return thumb;
  }

  const part = (tag, className, text) => {
    const element = document.createElement(tag);
    element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  };

  // 一格：缩略图（没出来之前先用主题配色画一张示意小卡）、名字、说明、两个标签；自己存的下面多一行「在 Finder 中显示」「删除」
  function createTile(summary, theme) {
    const index = ++tileSeq;
    const card = part("div", "template-card");
    card.dataset.template = summary.id;
    card.classList.toggle("is-user", !summary.builtIn);

    const button = part("button", "template-tile");
    button.type = "button";
    button.dataset.template = summary.id;
    button.title = summary.builtIn ? `用「${summary.name}」新建稿子` : `用自己存的「${summary.name}」新建稿子`;

    const thumb = part("span", "theme-thumb template-thumb");
    thumb.setAttribute("aria-hidden", "true");
    thumb.style.setProperty("--thumb-bg", theme.colors.bg);
    thumb.style.setProperty("--thumb-text", theme.colors.text);
    thumb.style.setProperty("--thumb-accent", theme.colors.accent);
    const canvas = document.createElement("canvas");
    canvas.width = THUMB_WIDTH;
    canvas.height = THUMB_HEIGHT;
    thumb.append(canvas);

    const name = part("span", "template-tile-name", summary.name);
    name.id = `template-tile-${index}-name`;
    const description = part("span", "template-tile-description", summary.description);
    description.id = `template-tile-${index}-description`;
    const tags = part("span", "template-tile-tags");
    tags.id = `template-tile-${index}-tags`;
    for (const tag of summary.tags) tags.append(part("span", "template-tag", tag));
    if (!summary.builtIn) tags.append(part("span", "template-tag template-tag-user", "自己存的"));
    button.setAttribute("aria-labelledby", name.id);
    button.setAttribute("aria-describedby", `${description.id} ${tags.id}`);
    button.append(thumb, name, description, tags);
    button.addEventListener("click", () => void pick(summary));
    card.append(button);

    if (!summary.builtIn) {
      const actions = part("div", "template-card-actions");
      actions.setAttribute("role", "group");
      actions.setAttribute("aria-label", `模板「${summary.name}」`);
      const reveal = part("button", "text-button", "在 Finder 中显示");
      reveal.type = "button";
      reveal.setAttribute("aria-label", `在 Finder 中显示模板「${summary.name}」`);
      reveal.addEventListener("click", () => mc.drafts.revealTemplate(summary.id).catch((error) => report(error.message)));
      const remove = part("button", "text-button is-danger", "删除");
      remove.type = "button";
      remove.setAttribute("aria-label", `删除模板「${summary.name}」`);
      remove.addEventListener("click", () => void removeTemplate(summary));
      actions.append(reveal, remove);
      card.append(actions);
    }
    return { summary, card, button, thumb, canvas, shown: null };
  }

  // 列表变了：新的建格子、没了的拿掉、顺序照摘要；摘要（名字、说明、标签、主题）变了的重建。
  // 读主题要等一下：这期间又来了一次 refresh（seq 变了）就作废，返回 false
  async function rebuild(seq) {
    const next = new Map();
    for (const summary of templates) {
      const existing = tiles.get(summary.id);
      if (existing && JSON.stringify(existing.summary) === JSON.stringify(summary)) next.set(summary.id, existing);
      else next.set(summary.id, createTile(summary, await themeOf(summary.theme)));
      if (seq !== refreshSeq) return false;
    }
    tiles.clear();
    for (const [id, tile] of next) tiles.set(id, tile);
    // 只有多了、少了或顺序变了才动 DOM：拿出来再放回去的格子会丢焦点，所以焦点在里面时再给回去
    const cards = [...tiles.values()].map((tile) => tile.card);
    const children = [...grid.children];
    if (cards.length === children.length && cards.every((card, index) => card === children[index])) return true;
    const focused = document.activeElement;
    grid.replaceChildren(...cards);
    if (focused instanceof Element && grid.contains(focused)) focused.focus({ preventScroll: true });
    return true;
  }

  // 两组胶囊：题材是标签的第一个、风格是第二个，按出现的先后；「全部」在前
  function buildFilters() {
    for (const [kind, index] of [["topic", 0], ["style", 1]]) {
      const values = [...new Set(templates.map((summary) => summary.tags[index]).filter(Boolean))];
      if (filter[kind] && !values.includes(filter[kind])) filter[kind] = "";
      const chips = ["", ...values].map((value) => {
        const chip = part("button", "chip chip-small", value || "全部");
        chip.type = "button";
        chip.dataset.value = value;
        chip.setAttribute("aria-pressed", String(filter[kind] === value));
        chip.addEventListener("click", () => {
          filter[kind] = value;
          for (const sibling of filterGroups[kind].children) sibling.setAttribute("aria-pressed", String(sibling.dataset.value === value));
          applyFilter();
          schedule();
        });
        return chip;
      });
      filterGroups[kind].replaceChildren(...chips);
    }
  }

  const matches = (summary) => (!filter.topic || summary.tags[0] === filter.topic) && (!filter.style || summary.tags[1] === filter.style);

  function applyFilter() {
    let shown = 0;
    for (const tile of tiles.values()) {
      const visible = matches(tile.summary);
      tile.card.hidden = !visible;
      if (visible) shown += 1;
    }
    emptyNote.hidden = shown > 0;
  }

  const visibleTiles = () => [...tiles.values()].filter((tile) => !tile.card.hidden);

  // 按缓存把每一格画成最新：有缩略图就换上
  function paintTiles() {
    let pending = 0;
    for (const tile of tiles.values()) {
      const entry = cache.get(thumbKey(tile.summary));
      if (entry === undefined && !tile.card.hidden) pending += 1;
      const image = entry ?? null;
      if (tile.shown !== image) {
        tile.shown = image;
        const context = tile.canvas.getContext("2d");
        context.clearRect(0, 0, THUMB_WIDTH, THUMB_HEIGHT);
        if (image) context.drawImage(image, 0, 0);
        tile.thumb.classList.toggle("is-ready", Boolean(image));
      }
    }
    grid.setAttribute("aria-busy", String(pending > 0));
  }

  // 还没有缩略图的格子：看得见的（在画廊的滚动区里露出来的）先，其余按顺序；筛掉的最后
  function pendingTiles() {
    const box = well.getBoundingClientRect();
    const inView = (tile) => {
      if (tile.card.hidden) return 2;
      const rect = tile.card.getBoundingClientRect();
      return rect.bottom > box.top && rect.top < box.bottom ? 0 : 1;
    };
    return [...tiles.values()]
      .filter((tile) => !cache.has(thumbKey(tile.summary)))
      .map((tile, order) => ({ tile, rank: inView(tile), order }))
      .sort((a, b) => a.rank - b.rank || a.order - b.order)
      .map(({ tile }) => tile);
  }

  function stop() {
    job += 1;
  }

  function schedule() {
    stop();
    if (isOpen()) void generate().catch(() => undefined);
  }

  // 一次出一张；画廊关上、换了筛选（顺序要重排）就停，再打开接着来
  async function generate() {
    const run = ++job;
    paintTiles();
    while (run === job && isOpen()) {
      const [tile] = pendingTiles();
      if (!tile) return;
      const key = thumbKey(tile.summary);
      let image = null;
      try {
        const { canvas } = await mc.drafts.firstPage(tile.summary.id);
        image = canvas ? shrink(canvas) : null;
      } catch {
        image = null; // 出不来（比如自己存的模板文件坏了）：留着示意小卡
      }
      if (run !== job) return;
      store(key, image);
      paintTiles();
      await nextTask();
    }
  }

  // 重新读模板列表（自己存的每次都重新读目录），建格子、胶囊，开始出缩略图；刚打开时焦点落到第一格
  async function refresh({ focusFirst = false } = {}) {
    const seq = ++refreshSeq;
    const [list, profile] = await Promise.all([mc.drafts.templates(), mc.profile.get()]);
    if (seq !== refreshSeq || !isOpen()) return;
    templates = list;
    profileKey = `${profile.name}|${profile.handle}|${fingerprint(profile.avatar)}|${JSON.stringify(profile.avatarCrop ?? null)}`;
    if (!(await rebuild(seq)) || !isOpen()) return;
    buildFilters();
    applyFilter();
    galleryStatus.textContent = native ? `自带 ${list.filter((item) => item.builtIn).length} 套，自己存的 ${list.filter((item) => !item.builtIn).length} 套` : "";
    if (focusFirst) (visibleTiles()[0]?.button ?? closeButton).focus({ preventScroll: true });
    schedule();
  }

  function open() {
    if (isOpen()) return;
    returnFocus = document.activeElement;
    openSeq += 1;
    modal.classList.remove("hidden");
    closeButton.focus({ preventScroll: true });
    void refresh({ focusFirst: true }).catch((error) => report(error.message));
  }

  function close() {
    if (!isOpen()) return;
    stop();
    modal.classList.add("hidden");
    root.MediaCraftMotion.returnFocus(modal, returnFocus);
    returnFocus = null;
  }

  // 点一格：复制成自己的稿子，关上画廊，光标进正文；存满了（或模板读不出）时说原因
  async function pick(summary) {
    if (picking) return;
    picking = true;
    grid.classList.add("is-picking");
    try {
      await mc.drafts.create({ template: summary.id });
      close();
      report(`已用「${summary.name}」新建稿子`);
      await mc.editor.focus();
    } catch (error) {
      await root.MediaCraftConfirm({ title: "没能新建", message: error.message || String(error), okLabel: "知道了", cancelLabel: "" });
    } finally {
      picking = false;
      grid.classList.remove("is-picking");
    }
  }

  async function removeTemplate(summary) {
    const confirmed = await root.MediaCraftConfirm({
      title: `删除模板「${summary.name}」？`,
      message: "这套模板的文件夹（模板.md 与图片）会从这台 Mac 上删掉，删除后找不回来。用它新建过的稿子不受影响。",
      okLabel: "删除",
      danger: true,
    });
    if (!confirmed) return;
    try {
      await mc.drafts.removeTemplate(summary.id);
      report(`已删除模板：${summary.name}`);
      // 焦点还在这一格上时先挪到旁边，格子拿掉后不会掉到 body 上
      if (tiles.get(summary.id)?.card.contains(document.activeElement)) (visibleTiles().find((tile) => tile.summary.id !== summary.id)?.button ?? closeButton).focus();
      await refresh();
    } catch (error) {
      report(error.message);
    }
  }

  // 方向键在看得见的格子间走（上下按一行几格算），Home / End 到头尾，回车、空格选这一套
  grid.addEventListener("keydown", (event) => {
    const current = event.target.closest?.(".template-tile");
    if (!current) return;
    const buttons = visibleTiles().map((tile) => tile.button);
    const at = buttons.indexOf(current);
    if (at < 0) return;
    const columns = Math.max(1, getComputedStyle(grid).gridTemplateColumns.split(" ").length);
    const moves = {
      ArrowRight: at + 1,
      ArrowLeft: at - 1,
      ArrowDown: at + columns,
      ArrowUp: at - columns,
      Home: 0,
      End: buttons.length - 1,
    };
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      current.click();
      return;
    }
    if (!(event.key in moves)) return;
    event.preventDefault();
    const target = buttons[Math.max(0, Math.min(moves[event.key], buttons.length - 1))];
    target?.focus({ preventScroll: false });
  });

  closeButton.addEventListener("click", close);
  modal.addEventListener("click", (event) => {
    if (event.target === modal) close();
  });
  revealButton.hidden = !native;
  revealButton.addEventListener("click", () => mc.drafts.revealTemplate().catch((error) => report(error.message)));
  $("#templateGalleryBtn").addEventListener("click", open);

  // ===== 存为模板：稿件右键菜单「存为模板…」（src/drafts/drawer.js 发 mediacraft:save-template）=====
  const saveModal = $("#saveTemplateDialog");
  const saveForm = $("#saveTemplateForm");
  const nameInput = $("#saveTemplateName");
  const descriptionInput = $("#saveTemplateDescription");
  const topicSelect = $("#saveTemplateTopic");
  const styleSelect = $("#saveTemplateStyle");
  const saveError = $("#saveTemplateError");
  const saveCancel = $("#saveTemplateCancel");
  const saveOk = $("#saveTemplateOk");
  // 要存的是哪一篇（不是正在编辑的那篇时，存之前先切过去）
  let saveFor = null;
  let saveReturn = null;
  let saving = false;

  const isSaveOpen = () => !saveModal.classList.contains("hidden");

  function showSaveError(message) {
    saveError.textContent = message;
    saveError.hidden = !message;
  }

  // 题材与风格的选项来自已有模板的标签（自带的与自己存的）；第一项「不填」
  function fillSelect(select, values, selected) {
    const options = ["", ...values].map((value) => {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value || "不填";
      return option;
    });
    select.replaceChildren(...options);
    select.value = values.includes(selected) ? selected : "";
  }

  async function openSaveDialog({ draftId, title }) {
    if (!native) {
      report("模板只在 Vibepost App 里能存");
      return;
    }
    const list = await mc.drafts.templates();
    saveFor = draftId;
    saveReturn = document.activeElement;
    nameInput.value = title && title !== UNTITLED ? title : "";
    descriptionInput.value = "";
    fillSelect(topicSelect, [...new Set(list.map((item) => item.tags[0]).filter(Boolean))], "");
    fillSelect(styleSelect, [...new Set(list.map((item) => item.tags[1]).filter(Boolean))], "");
    showSaveError("");
    saveOk.disabled = false;
    saveModal.classList.remove("hidden");
    nameInput.focus({ preventScroll: true });
    nameInput.select();
  }

  function closeSaveDialog() {
    if (!isSaveOpen()) return;
    saveModal.classList.add("hidden");
    root.MediaCraftMotion.returnFocus(saveModal, saveReturn);
    saveReturn = null;
    saveFor = null;
  }

  saveForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (saving) return;
    const name = nameInput.value.trim();
    if (!name) {
      showSaveError("先给模板起个名字");
      nameInput.focus();
      return;
    }
    saving = true;
    saveOk.disabled = true;
    try {
      // 同名的会整套换掉（App API 的规矩）：先问一句
      const taken = (await mc.drafts.templates()).find((item) => !item.builtIn && item.name === name);
      if (taken) {
        const replace = await root.MediaCraftConfirm({
          title: `已有模板「${name}」`,
          message: "自己存的模板里已经有一套叫这个名字。换掉它？原来那套的内容与图片会被这篇的替换。",
          okLabel: "换掉",
          danger: true,
        });
        if (!replace) return;
      }
      const draftId = saveFor;
      if (draftId && (await mc.drafts.current()).id !== draftId) await mc.drafts.open(draftId);
      const template = await mc.drafts.saveAsTemplate({
        name,
        description: descriptionInput.value,
        tags: [topicSelect.value, styleSelect.value].filter(Boolean),
      });
      closeSaveDialog();
      report(`已存为模板「${template.name}」，在「从模板新建」里能看到`);
    } catch (error) {
      showSaveError(error.message || String(error));
    } finally {
      saving = false;
      saveOk.disabled = false;
    }
  });
  saveCancel.addEventListener("click", closeSaveDialog);
  saveModal.addEventListener("click", (event) => {
    if (event.target === saveModal) closeSaveDialog();
  });
  document.addEventListener("mediacraft:save-template", (event) => void openSaveDialog(event.detail).catch((error) => report(error.message)));

  // Esc：确认框开着时它自己处理（已经 preventDefault），这里不管；否则先关存为模板的对话框，再关画廊
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || event.defaultPrevented) return;
    if (isSaveOpen()) {
      event.preventDefault();
      closeSaveDialog();
    } else if (isOpen()) {
      event.preventDefault();
      close();
    }
  });

  // ===== 空白稿子的空状态：正文空着、这篇能改（不是说明书）时浮在编辑区里；一开始打字就收起，换一篇再看 =====
  const hint = $("#editorEmptyHint");
  const editorRoot = $("#markdownEditor");
  // 这篇已经开始打字（或点过「从模板开始」）：不再提示
  let dismissedFor = null;
  let hintDraftId = null;
  let hintSeq = 0;

  async function updateHint() {
    const seq = ++hintSeq;
    const draft = await mc.drafts.current();
    if (seq !== hintSeq) return;
    hintDraftId = draft.id;
    hint.hidden = draft.readOnly || Boolean(draft.markdown.trim()) || dismissedFor === draft.id;
  }

  function dismissHint() {
    if (hint.hidden) return;
    dismissedFor = hintDraftId;
    hint.hidden = true;
  }

  for (const type of ["beforeinput", "compositionstart", "paste", "drop"]) editorRoot.addEventListener(type, dismissHint, true);
  mc.on("rendered", () => void updateHint().catch(() => undefined));
  mc.on("change", () => void updateHint().catch(() => undefined));
  $("#editorHintTemplate").addEventListener("click", open);
  $("#editorHintGuide").addEventListener("click", async () => {
    try {
      const guide = (await mc.drafts.list()).find((item) => item.builtIn);
      if (guide) await mc.drafts.open(guide.id);
    } catch (error) {
      report(error.message);
    }
  });
  void updateHint().catch(() => undefined);

  root.MediaCraftTemplateGallery = Object.freeze({ open, close });
})(window);
