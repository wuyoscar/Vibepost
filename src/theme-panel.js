// 主题面板（检查器「样式」标签里的「主题」）：8 个主题各一格，缩略图是当前稿子第一页换成这个主题的样子，
// 下面预告换过去是几页（「9 → 11 页」，页数不变时「9 页」）。点一格就换主题。
// 缩略图在停手后逐个主题生成，按（主题、正文与各项设置）缓存；一有按键、点按或输入就停下，停手后接着来，不跟打字抢时间。
// 只通过 App API（window.mediacraft）和界面元素工作，不碰 src/app.js 的内部名字。
(() => {
  const mc = window.mediacraft;
  const { ROLES } = window.MediaCraftEngine.colors;
  const group = document.getElementById("themeOptions");
  const status = document.getElementById("statusText");
  // 缩略图画布：2 倍图，显示时铺满格子
  const THUMB_WIDTH = 132;
  const THUMB_HEIGHT = 176;
  // 停手多久后开始（或接着）生成
  const IDLE_DELAY = 400;
  // 最多记住多少张缩略图（每张约 90 KB）
  const CACHE_LIMIT = 48;

  const tiles = new Map();
  const cache = new Map();
  let themes = [];
  // 最近一次出图时的稿子：{ theme, colors, mode, readOnly, content, pageCount }
  let snapshot = null;
  let refreshSeq = 0;
  // 每次停下都加一；跑着的那一轮发现变了就放弃
  let job = 0;
  let idleTimer = 0;

  // 32 位 FNV-1a
  function hash(text) {
    let value = 2166136261;
    for (let index = 0; index < text.length; index += 1) {
      value ^= text.charCodeAt(index);
      value = Math.imul(value, 16777619);
    }
    return (value >>> 0).toString(36);
  }

  // 图片、头像的 data URL 可能有几 MB：只取长度与首尾，够分辨换没换
  const fingerprint = (source) => (source ? `${source.length}:${source.slice(0, 96)}:${source.slice(-96)}` : "");

  // 影响出图的一切（主题与颜色除外，它们单独进缓存键）
  async function readDraft() {
    const [draft, profile, media] = await Promise.all([mc.drafts.current(), mc.profile.get(), mc.media.list()]);
    const sources = await Promise.all(media.map((item) => mc.media.src(item.id)));
    const content = JSON.stringify([
      draft.markdown, draft.fonts, draft.fontSize, draft.lineHeight, draft.imageMaxHeight,
      profile.name, profile.handle, fingerprint(profile.avatar), profile.avatarCrop,
      media.map((item, index) => [item.id, item.kind, item.layout, item.crop, fingerprint(sources[index])]),
    ]);
    const { theme, colors, tunedColors, mode, readOnly } = draft;
    return { theme, colors, tunedColors, mode, readOnly, content: hash(content) };
  }

  // 换到别的主题时这篇调过的配色会重置成那个主题的配色，所以只有当前主题要把它算进去
  // （连同单独调过的辅助、衬底：知识卡的底板上衬底怎么推跟着它）
  function cacheKey(themeId, draft) {
    const current = themeId === draft.theme;
    const colors = current ? draft.colors : themes.find((theme) => theme.id === themeId).colors;
    const tuned = current ? draft.tunedColors.join() : "";
    return `${themeId}|${draft.content}|${ROLES.map((role) => colors[role]).join("")}|${tuned}`;
  }

  const sameDraft = (a, b) => cacheKey(a.theme, a) === cacheKey(b.theme, b) && a.mode === b.mode;

  function shrink(canvas) {
    const thumb = document.createElement("canvas");
    thumb.width = THUMB_WIDTH;
    thumb.height = THUMB_HEIGHT;
    const context = thumb.getContext("2d");
    context.imageSmoothingQuality = "high";
    context.drawImage(canvas, 0, 0, THUMB_WIDTH, THUMB_HEIGHT);
    return thumb;
  }

  function store(key, entry) {
    cache.delete(key);
    cache.set(key, entry);
    if (cache.size > CACHE_LIMIT) cache.delete(cache.keys().next().value);
  }

  // ===== 格子 =====
  function createTile(theme) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "theme-option";
    button.dataset.theme = theme.id;
    button.title = `${theme.name} · ${theme.label}`;
    button.setAttribute("aria-pressed", "false");

    // 缩略图没出来之前，先用主题配色画一张示意小卡
    const thumb = document.createElement("span");
    thumb.className = "theme-thumb";
    thumb.setAttribute("aria-hidden", "true");
    thumb.style.setProperty("--thumb-bg", theme.colors.bg);
    thumb.style.setProperty("--thumb-text", theme.colors.text);
    thumb.style.setProperty("--thumb-accent", theme.colors.accent);
    const canvas = document.createElement("canvas");
    canvas.width = THUMB_WIDTH;
    canvas.height = THUMB_HEIGHT;
    thumb.append(canvas);

    // 名字是主题名；说明、换过去的页数作为描述读出
    const part = (className, text) => {
      const element = document.createElement("span");
      element.id = `theme-${theme.id}-${className}`;
      element.className = `theme-option-${className}`;
      element.textContent = text;
      return element;
    };
    const name = part("name", theme.name);
    const label = part("label", theme.label);
    label.classList.add("visually-hidden");
    const pages = part("pages", "");
    button.setAttribute("aria-labelledby", name.id);
    button.setAttribute("aria-describedby", `${label.id} ${pages.id}`);

    button.append(thumb, name, label, pages);
    // 换上的主题由 <html data-card-theme> 的变化标出来（见 init）；换不了（比如内置说明书只读）时在状态栏说原因
    button.addEventListener("click", () => {
      mc.themes.apply(theme.id).catch((error) => {
        status.textContent = error.message;
      });
    });
    return { button, canvas, pages, shown: null };
  }

  function markCurrent(themeId) {
    for (const [id, tile] of tiles) tile.button.setAttribute("aria-pressed", String(id === themeId));
  }

  // 按缓存把每一格画成最新：有缩略图就换上，页数写「现在 → 换过去」
  function paintTiles() {
    const draft = snapshot;
    let pending = 0;
    for (const theme of themes) {
      const tile = tiles.get(theme.id);
      const entry = draft?.mode === "cards" ? cache.get(cacheKey(theme.id, draft)) : undefined;
      if (draft?.mode === "cards" && !entry) pending += 1;
      const image = entry?.image ?? null;
      if (tile.shown !== image) {
        tile.shown = image;
        const context = tile.canvas.getContext("2d");
        context.clearRect(0, 0, THUMB_WIDTH, THUMB_HEIGHT);
        if (image) context.drawImage(image, 0, 0);
        tile.canvas.parentElement.classList.toggle("is-ready", Boolean(image));
      }
      let text = "";
      if (entry && theme.id === draft.theme) text = `${draft.pageCount} 页`;
      else if (entry) text = entry.pageCount === draft.pageCount ? `${entry.pageCount} 页` : `${draft.pageCount} → ${entry.pageCount} 页`;
      tile.pages.textContent = text;
    }
    group.setAttribute("aria-busy", String(pending > 0));
  }

  // ===== 生成 =====
  const shown = () => group.getClientRects().length > 0;
  const nextTask = () => new Promise((resolve) => setTimeout(resolve, 0));

  function stop() {
    job += 1;
    clearTimeout(idleTimer);
  }

  function schedule() {
    stop();
    // 缩略图出不来（页面正在换掉时进行中的出图会中断）就先空着，下次出图后再补
    if (snapshot?.mode === "cards" && shown()) idleTimer = setTimeout(() => void generate().catch(() => undefined), IDLE_DELAY);
  }

  // 一次出一个主题；出图期间稿子变了（按键、App API 改稿）这一张作废，等下一次出图后重来。
  async function generate() {
    const run = ++job;
    while (run === job) {
      const before = await readDraft();
      if (run !== job || !snapshot || !sameDraft(before, snapshot)) return;
      const theme = themes.find((item) => !cache.has(cacheKey(item.id, before)));
      if (!theme) return;
      const { pageCount, canvas } = await mc.themes.preview(theme.id);
      if (run !== job) return;
      const after = await readDraft();
      if (run !== job || !sameDraft(before, after)) return;
      store(cacheKey(theme.id, before), { pageCount, image: canvas ? shrink(canvas) : null });
      paintTiles();
      await nextTask();
    }
  }

  // 每次出图后：记下稿子，当前主题的缩略图直接用预览的第一页，其余主题停手后再生成。
  async function refresh(pageCount) {
    const seq = ++refreshSeq;
    stop();
    group.setAttribute("aria-busy", "true");
    const draft = await readDraft();
    const canvases = draft.mode === "cards" ? await mc.render.canvases() : [];
    if (seq !== refreshSeq) return;
    snapshot = { ...draft, pageCount };
    for (const { button } of tiles.values()) button.disabled = draft.readOnly;
    if (draft.mode === "cards") store(cacheKey(draft.theme, draft), { pageCount, image: canvases[0] ? shrink(canvases[0]) : null });
    paintTiles();
    schedule();
  }

  async function init() {
    themes = await mc.themes.list();
    for (const theme of themes) tiles.set(theme.id, createTile(theme));
    group.replaceChildren(...[...tiles.values()].map((tile) => tile.button));
    markCurrent(document.documentElement.dataset.cardTheme);
    // 选中的底色跟着换上的主题滑过去
    window.MediaCraftMotion.track(group, '[aria-pressed="true"]');

    mc.on("rendered", ({ pageCount }) => void refresh(pageCount).catch(() => undefined));
    // 这篇的主题一换（点格子、App API、切稿子）就标出来，不用等出图
    new MutationObserver(() => markCurrent(document.documentElement.dataset.cardTheme))
      .observe(document.documentElement, { attributes: true, attributeFilter: ["data-card-theme"] });
    // 打字、点按时停下，停手后接着生成
    for (const type of ["keydown", "pointerdown", "input"]) document.addEventListener(type, schedule, true);
    // 样式标签藏着时不生成，切回来再接着
    new MutationObserver(schedule).observe(group.closest('[role="tabpanel"]'), { attributes: true, attributeFilter: ["hidden"] });
  }

  void init();
})();
