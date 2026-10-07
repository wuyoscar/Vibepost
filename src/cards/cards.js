// HTML 卡片（ADR 0006）的入口：稿子 → 分好页的 HTML → 舞台上可操作的卡片 DOM / 壳里截的 PNG。
//   await MediaCraftCards.layout(settings)   → { pages: [{ kind, html, sources }], theme, style }
//   MediaCraftCards.mount(result, index)      → 一张卡片的元素（Shadow DOM，864 × 1152 逻辑像素）
//   await MediaCraftCards.rasterize(result)   → 每页一个 PNG Blob（壳里原生截图；浏览器里退回 html2canvas）
// settings 与 src/stage/render.js 的相同：{ title, markdown, theme, images, profile: { name, handle, avatar }, … }。
(function (root) {
  "use strict";

  const WIDTH = 864;
  const HEIGHT = 1152;
  const SCALE = 2;
  const html = root.MediaCraftCardHtml;
  const escape = html.escape;

  // 卡片结构（src/engine/structures.js）决定版心、标题比例与页面框架，样子在这两份样式里
  const STYLE_FILES = ["src/cards/card.css", "src/cards/structures.css"];

  const IMAGE_MAX_HEIGHT = 1048; // 图片最大高的默认值（与检查器的滑杆一致）
  const RASTER_CACHE_SIZE = 160;
  // 出图缓存按字节也封顶：每页 PNG 2–4 MB，只按条数留 160 条会吃掉几百 MB
  const RASTER_CACHE_BYTES = 160 * 1024 * 1024;
  const RASTER_BATCH = 40; // 一次交给壳出这么多页（壳一次最多收 200 页） // 出过的页按整页 HTML 留着 PNG：打字时只重出变了的页

  const px = (value) => `${Math.round(value * 100) / 100}px`;

  // 这一页的版式变量：正文区四边、字号行距、标题、图片圆角
  function structureVars(structure, first, settings) {
    const pad = structure.pages[first ? "first" : "inner"];
    const size = (settings.fontSize ?? 34) * structure.body.scale;
    const vars = {
      "--pad-t": px(pad.top), "--pad-r": px(pad.right), "--pad-b": px(pad.bottom), "--pad-l": px(pad.left),
      "--mc-size-body": px(size),
      "--mc-leading": String(settings.lineHeight ?? 1.85),
      "--mc-radius": px(structure.imageRadius),
      "--mc-img-max": px(settings.imageMaxHeight ?? IMAGE_MAX_HEIGHT),
    };
    for (const level of ["h1", "h2", "h3"]) {
      const heading = structure.headings[level];
      Object.assign(vars, {
        [`--${level}`]: String(heading.scale),
        [`--${level}-leading`]: String(heading.lineHeight),
        [`--${level}-weight`]: String(heading.weight),
        [`--${level}-align`]: heading.align ?? "start",
      });
    }
    const sign = structure.end?.signature;
    if (sign) {
      Object.assign(vars, {
        "--end-inset": px(structure.end.inset ?? 48),
        "--sig-avatar": px(sign.avatar),
        "--sig-name-size": px(sign.name.size),
        "--sig-name-weight": String(sign.name.weight),
        "--sig-name-spacing": px(sign.name.spacing ?? 0),
        "--sig-name-case": sign.name.upper ? "uppercase" : "none",
        "--sig-name-font": sign.name.font === "label" ? "var(--mc-font-label)" : "var(--mc-font-body)",
        "--sig-handle-size": px(sign.handle.size),
      });
    }
    return vars;
  }

  // 整篇的配色与字体变量（engine.colors.roles、fonts.cardSetup），配色库、色轮、字体选择都照常起作用
  function lookVars(roles, setup) {
    return {
      "--mc-bg": roles.background, "--mc-paper": roles.paper, "--mc-text": roles.text, "--mc-muted": roles.muted,
      "--mc-rule": roles.rule, "--mc-accent": roles.accent, "--mc-accent-text": roles.accentText, "--mc-tint": roles.tint,
      "--mc-secondary": roles.heading, "--mc-surface": roles.surface, "--mc-surface-text": roles.surfaceText, "--mc-chip": roles.chip,
      "--mc-on-accent": roles.onAccent, "--mc-mark-1": roles.accentText, "--mc-mark-2": roles.heading, "--mc-mark-3": roles.muted, "--mc-mark-4": roles.text,
      "--mc-font-body": setup.fonts.latin, "--mc-font-display": setup.fonts.display, "--mc-font-mono": setup.fonts.code,
      "--mc-font-label": setup.fonts.label, "--mc-bold": String(setup.boldWeight),
    };
  }

  const styleAttr = (vars) => escape(Object.entries(vars).map(([key, value]) => `${key}:${value}`).join(";"));

  // ---------- 样式：读成文本，舞台上每张卡片与壳里出图都用同一份 ----------

  const cssCache = new Map();
  async function cssText(path) {
    if (!cssCache.has(path)) cssCache.set(path, fetch(path).then((response) => response.text()));
    return cssCache.get(path);
  }

  async function styleFor(context) {
    const parts = await Promise.all(STYLE_FILES.map(cssText));
    return [...parts, cleanCss(context.settings.cardCss)].join("\n");
  }

  // 这一篇自己的卡片样式（稿子的 cardCss）进卡片之前过滤，最长 CARD_CSS_LIMIT 个字：先交给浏览器的 CSS 解析器
  // （@import 在这一步就丢掉，认不出的写法也丢掉），再去掉能带地址的声明：url() 只留 data: 图片，image-set() 这类
  // 不写 url 也能带地址的函数一律不要。检查前先把 CSS 转义（u\72l( 这种）还原：自定义属性按原样保留转义，经 var() 用到时才认出来。
  // 卡片样式经 adoptedStyleSheets / textContent 放进卡片，不拼进 HTML。
  const CARD_CSS_LIMIT = 20000;
  const ADDRESS_FUNCTIONS = /(?:^|[^\w-])(?:-webkit-)?(?:image-set|cross-fade|image|element|src)\(/;
  function unescapeCss(text) {
    return text.replace(/\\(?:([0-9a-f]{1,6})\s?|([^\n]))/gi, (_, hex, char) => {
      if (!hex) return char;
      const code = parseInt(hex, 16);
      return code > 0 && code <= 0x10ffff && (code < 0xd800 || code > 0xdfff) ? String.fromCodePoint(code) : "\ufffd";
    });
  }
  function fetchesNothing(text) {
    const value = unescapeCss(text).toLowerCase();
    for (const [, target] of value.matchAll(/url\(\s*["']?\s*([^"')\s]*)/g)) {
      if (!target.startsWith("data:image/")) return false;
    }
    return !ADDRESS_FUNCTIONS.test(value);
  }
  function cleanRules(rules) {
    for (const rule of rules) {
      for (const name of rule.style ? [...rule.style] : []) {
        if (!fetchesNothing(rule.style.getPropertyValue(name))) rule.style.removeProperty(name);
      }
      if (rule.cssRules) cleanRules(rule.cssRules);
    }
  }
  function cleanCss(text) {
    const sheet = new CSSStyleSheet();
    try {
      sheet.replaceSync(String(text ?? "").slice(0, CARD_CSS_LIMIT));
    } catch {
      return "";
    }
    cleanRules(sheet.cssRules);
    // 声明以外还能带地址的（@font-face 的 src、@property 的初始值、@namespace……）整条不要
    return [...sheet.cssRules].map((rule) => rule.cssText).filter(fetchesNothing).join("\n");
  }

  // ---------- 一页的完整 HTML ----------

  function pageHtml(page, context) {
    const chrome = root.MediaCraftCardChrome.of(context.look);
    const first = page.index === 0 && page.kind === "body";
    const header = chrome.head(page, context);
    const footer = chrome.foot(page, context);
    const vars = { ...context.vars, ...structureVars(context.structure, first, context.settings) };
    // 封面底图铺满时，页眉也要知道文字区在哪（src/cards/cover.js 量好写在封面里）
    const solid = page.kind === "cover" ? /--cover-solid:\s*([\d.]+px)/.exec(page.html)?.[1] : null;
    if (solid) vars["--cover-solid"] = solid;
    return `<article class="mc-page" data-structure="${escape(context.look)}" data-kind="${page.kind}"${first ? " data-first" : ""} style="${styleAttr(vars)}">`
      + (header ? `<header class="mc-head">${header}</header>` : "")
      + `<div class="mc-body">${page.html}${page.kind === "end" ? root.MediaCraftCardChrome.signature(context) : ""}</div>`
      + (footer ? `<footer class="mc-foot">${footer}</footer>` : "")
      + "</article>";
  }

  // 同一份卡片样式只解析一次，所有卡片的 Shadow DOM 共用（舞台上几十页也不会各解析一遍）
  const sheets = new Map();
  const SHEET_CACHE_SIZE = 8;
  function sheetFor(style) {
    let sheet = sheets.get(style);
    if (!sheet) {
      sheet = new CSSStyleSheet();
      sheet.replaceSync(style);
      sheets.set(style, sheet);
      while (sheets.size > SHEET_CACHE_SIZE) sheets.delete(sheets.keys().next().value);
    }
    return sheet;
  }

  // ---------- 卡片元素：Shadow DOM 把卡片样式与 App 界面互相隔开 ----------

  function cardElement(style) {
    const host = document.createElement("div");
    host.className = "mc-card-host";
    const shadow = host.attachShadow({ mode: "open" });
    const slot = document.createElement("div");
    slot.className = "mc-root";
    shadow.adoptedStyleSheets = [sheetFor(style)];
    shadow.append(slot);
    return { host, shadow, slot };
  }

  // 图片：data-media="编号" 换成这篇图片的地址（头像是 __avatar）
  function fillMedia(scope, context) {
    for (const image of scope.querySelectorAll("img[data-media]")) {
      const id = image.dataset.media;
      const src = id === "__avatar" ? context.profile.avatar : context.images[id]?.src;
      if (src) image.src = src;
    }
  }

  // 屏幕外的量尺卡：分页器按页型换上页眉页脚，量正文区还剩多高。
  // 每次排版一张自己的（分页中途会让出主线程，舞台与缩略图的排版可能交错），排完 dispose() 拆掉
  function measurer(style, context) {
    const measureCard = cardElement(style);
    Object.assign(measureCard.host.style, { position: "fixed", left: "-20000px", top: "0", width: `${WIDTH}px`, height: `${HEIGHT}px`, pointerEvents: "none" });
    measureCard.host.setAttribute("aria-hidden", "true");
    document.body.append(measureCard.host);
    return {
      dispose: () => measureCard.host.remove(),
      // 封面这一页：放进量尺卡量好标题字号，得到它正文区的 HTML
      cover(html) {
        measureCard.slot.innerHTML = pageHtml({ kind: "cover", index: 0, total: 88, html }, context);
        fillMedia(measureCard.slot, context);
        root.MediaCraftCardCover.fit(measureCard.slot);
        return measureCard.slot.querySelector(".mc-body").innerHTML;
      },
      page(kind, index) {
        // 量的时候总页数写成两位数的占位：要排完才知道
        measureCard.slot.innerHTML = pageHtml({ kind, index, total: 88, html: "" }, context);
        fillMedia(measureCard.slot, context);
        return { body: measureCard.slot.querySelector(".mc-body") };
      },
    };
  }

  function contextOf(settings) {
    const engine = root.MediaCraftEngine;
    const images = settings.images ?? {};
    const media = {};
    for (const [id, record] of Object.entries(images)) {
      if (record?.src) media[id] = { ...record, width: record.width ?? record.naturalWidth ?? 1, height: record.height ?? record.naturalHeight ?? 1 };
    }
    const lookup = engine.mediaLookup ? ((path) => engine.mediaLookup(images).get(engine.imageFileKey(path))) : () => null;
    const fonts = root.MediaCraftFonts;
    const follow = fonts.FOLLOW_THEME;
    const theme = root.MediaCraftThemes.get(settings.theme);
    // settings.structureId：指定卡片结构（主题面板的缩略图、render.offscreen），否则按主题
    const look = settings.structureId ?? theme.structure;
    const structure = engine.cardStructures[look] ?? engine.cardStructures[theme.structure];
    const roles = engine.colors.roles(settings.colors ?? theme.colors, structure, settings.tunedColors ?? []);
    const setup = fonts.cardSetup(fonts.resolve(settings.fonts ?? { zh: follow, en: follow, code: follow }, theme.fonts, theme.titleFonts), structure);
    return {
      look,
      structure,
      setup,
      settings,
      vars: lookVars(roles, setup),
      profile: settings.profile ?? { name: "", handle: "", avatar: "" },
      images,
      media,
      lookup,
      pairRatio: engine.pairRatio ?? (() => 1),
      imageMaxHeight: settings.imageMaxHeight ?? IMAGE_MAX_HEIGHT,
      inkOn: (background, preferred) => engine.colors.readableOn(background, preferred ?? roles.text, roles),
    };
  }

  // 图片的原始尺寸：记录里没有时量一次（分页要按比例留高度）
  async function withSizes(settings) {
    const images = { ...(settings.images ?? {}) };
    await Promise.all(Object.entries(images).map(async ([id, record]) => {
      if (!record?.src || (record.width && record.height)) return;
      const image = new Image();
      image.src = record.src;
      await loaded(image);
      images[id] = { ...record, width: image.naturalWidth || 1, height: image.naturalHeight || 1 };
    }));
    return { ...settings, images };
  }

  async function layout(input) {
    const settings = await withSizes(input);
    const context = contextOf(settings);
    const style = await styleFor(context);
    const doc = root.MediaCraftEngine.parseMarkdown(settings.markdown, { containers: true });
    const blocks = html.blocks(doc, context);
    const profile = context.profile;
    await root.MediaCraftFonts.load(context.setup.keys, `${settings.markdown}${settings.title ?? ""}${settings.cover?.subtitle ?? ""}${profile.name}${String(profile.name).toUpperCase()}${profile.handle ?? ""}“”— /0123456789LOGENDFIELDNOTE知识卡`);
    // 只等这篇用到的字体（上面的 load）；不等 document.fonts.ready：别的主题缩略图正在载的字体会拖住它
    const cover = root.MediaCraftCardCover.of(settings, doc);
    const ruler = measurer(style, context);
    try {
      const pages = await root.MediaCraftCardPaginate.paginate(blocks, ruler, { offset: cover ? 1 : 0 });
      if (cover) pages.unshift({ kind: "cover", html: ruler.cover(root.MediaCraftCardCover.markup(cover, context)), sources: [] });
      return { pages, style, context };
    } finally {
      ruler.dispose();
    }
  }

  function fullHtml(result, index) {
    const page = result.pages[index];
    return pageHtml({ ...page, index, total: result.pages.length }, result.context);
  }

  function mount(result, index) {
    const card = cardElement(result.style);
    card.slot.innerHTML = fullHtml(result, index);
    fillMedia(card.slot, result.context);
    card.host.dataset.page = String(index);
    return card.host;
  }

  async function dataUrl(src) {
    if (!src || src.startsWith("data:")) return src;
    const blob = await fetch(src).then((response) => response.blob());
    return new Promise((resolve) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.readAsDataURL(blob);
    });
  }

  const mediaIds = (page) => [...new Set([...page.matchAll(/data-media="([^"]+)"/g)].map((match) => match[1]))];
  const mediaSrc = (result, id) => (id === "__avatar" ? result.context.profile.avatar : result.context.images[id]?.src);

  // 出过的页：整页 HTML、样式与用到的图片都一样就是同一张图。
  // 图片在键里只放指纹（长度 + 均匀抽样的几段字符），不放整条 data URL：一张图几 MB，拼进键里每代都留一份，
  // 一篇十来张图的稿子审阅几轮就是几百 MB（2026-10-08 的卡顿）
  const rasterCache = new Map();
  let rasterBytes = 0;
  const SAMPLES = 48;
  function fingerprint(src) {
    const text = String(src ?? "");
    if (!text.startsWith("data:") || text.length < 2048) return text;
    const stride = Math.floor(text.length / SAMPLES);
    let sample = "";
    for (let i = 0; i < SAMPLES; i += 1) sample += text.substr(i * stride, 16);
    return `${text.length}:${sample}:${text.slice(-32)}`;
  }
  const cacheKey = (result, page) => `${result.style.length}|${page}|${mediaIds(page).map((id) => fingerprint(mediaSrc(result, id))).join("|")}`;
  function remember(key, png) {
    const previous = rasterCache.get(key);
    if (previous) {
      rasterBytes -= previous.size ?? 0;
      rasterCache.delete(key);
    }
    rasterCache.set(key, png);
    rasterBytes += png.size ?? 0;
    while (rasterCache.size > RASTER_CACHE_SIZE || (rasterBytes > RASTER_CACHE_BYTES && rasterCache.size > 1)) {
      const oldest = rasterCache.keys().next().value;
      rasterBytes -= rasterCache.get(oldest)?.size ?? 0;
      rasterCache.delete(oldest);
    }
  }

  // 每页一个 PNG Blob（2 倍图）。indexes：只出这几页（默认全部）
  async function rasterize(result, indexes = result.pages.map((_, index) => index)) {
    const pages = indexes.map((index) => fullHtml(result, index));
    const keys = pages.map((page) => cacheKey(result, page));
    // 先取出缓存里有的（页数比缓存多时，新出的页会把它们挤掉）
    const found = keys.map((key) => rasterCache.get(key) ?? null);
    const missing = found.map((png, at) => (png ? null : at)).filter((at) => at !== null);
    if (missing.length) {
      const pngs = root.MediaCraftNative?.rasterCards
        ? await rasterizeNatively(result, missing.map((at) => pages[at]))
        : await Promise.all(missing.map((at) => rasterizeInBrowser(result, indexes[at])));
      missing.forEach((at, order) => {
        found[at] = pngs[order];
        remember(keys[at], pngs[order]);
      });
    }
    return found;
  }

  // 图片换成 data URL 交给壳（壳里的宿主页读不到页面内存里的 Blob）
  async function rasterizeNatively(result, pages) {
    const media = {};
    await Promise.all([...new Set(pages.flatMap(mediaIds))].map(async (id) => {
      const src = mediaSrc(result, id);
      if (src) media[id] = await dataUrl(src);
    }));
    const pngs = [];
    for (let start = 0; start < pages.length; start += RASTER_BATCH) {
      const batch = pages.slice(start, start + RASTER_BATCH);
      const reply = await root.MediaCraftNative.rasterCards({ pages: batch, style: result.style, media, width: WIDTH, height: HEIGHT, scale: SCALE });
      pngs.push(...reply.pages);
    }
    return pngs;
  }

  // 浏览器开发模式没有壳：用 html2canvas 画（只为开发时看效果，像素以壳为准）
  async function rasterizeInBrowser(result, index) {
    const host = mount(result, index);
    Object.assign(host.style, { position: "fixed", left: "-20000px", top: "0", width: `${WIDTH}px`, height: `${HEIGHT}px` });
    document.body.append(host);
    try {
      const page = host.shadowRoot.querySelector(".mc-page");
      const canvas = await root.html2canvas(page, { scale: SCALE, backgroundColor: null, logging: false });
      return await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
    } finally {
      host.remove();
    }
  }

  // 等一张图载完（载不出来也算完）：用 load 而不是 decode()，窗口在后台时 decode() 可能一直不回来
  const loaded = (image) => (image.complete ? Promise.resolve() : new Promise((resolve) => {
    image.addEventListener("load", resolve, { once: true });
    image.addEventListener("error", resolve, { once: true });
  }));

  // 每页挂到屏幕外、原大排好，量出页面结果（src/cards/summary.js）；量完的卡片元素留给舞台用
  // count：只量前几页（缩略图只要第一页）
  async function measurePages(result, count = Infinity) {
    const shelf = document.createElement("div");
    Object.assign(shelf.style, { position: "fixed", left: "-40000px", top: "0", width: `${WIDTH}px`, pointerEvents: "none" });
    shelf.setAttribute("aria-hidden", "true");
    document.body.append(shelf);
    try {
      const hosts = result.pages.slice(0, count).map((_, index) => {
        const host = mount(result, index);
        Object.assign(host.style, { width: `${WIDTH}px`, height: `${HEIGHT}px` });
        shelf.append(host);
        return host;
      });
      await Promise.all(hosts.flatMap((host) => [...host.shadowRoot.querySelectorAll("img[src]")].map(loaded)));
      // 一页一页量，页与页之间让出主线程
      const pages = [];
      for (const [index, host] of hosts.entries()) {
        if (index) await root.MediaCraftCardPaginate.yieldToPage();
        pages.push(root.MediaCraftCardSummary.summarize(host.shadowRoot.querySelector(".mc-page"), { index, kind: result.pages[index].kind }, result.context));
      }
      hosts.forEach((host) => {
        host.remove();
        host.style.removeProperty("width");
        host.style.removeProperty("height");
      });
      return { pages, hosts };
    } finally {
      shelf.remove();
    }
  }

  // 一套卡片：前 paint 页各一张 2 倍图画布、每页的页面结果、每页的卡片元素（舞台上放它）。
  // 画布先是空的，draw() 出图后画上（只出一次；出过的页有缓存，打字时只重出变了的页）。
  async function paint(result, { paint: count = Infinity } = {}) {
    const { pages, hosts } = await measurePages(result, count);
    const canvases = result.pages.slice(0, count).map(() => Object.assign(document.createElement("canvas"), { width: WIDTH * SCALE, height: HEIGHT * SCALE }));
    let drawing = null;
    const draw = () => {
      // 一页一页画，页与页之间让出主线程（一次画几十张 2 倍图会卡住界面）
      drawing ??= rasterize(result, canvases.map((_, index) => index)).then(async (pngs) => {
        for (const [index, png] of pngs.entries()) {
          const bitmap = await createImageBitmap(png);
          canvases[index].getContext("2d").drawImage(bitmap, 0, 0, canvases[index].width, canvases[index].height);
          bitmap.close();
          await root.MediaCraftCardPaginate.yieldToPage();
        }
      });
      return drawing;
    };
    return { pageCount: result.pages.length, canvases, pages, views: hosts.slice(0, count), draw };
  }

  root.MediaCraftCards = {
    WIDTH, HEIGHT, SCALE, layout, mount, rasterize, paint,
    cleanCss,
    CARD_CSS_LIMIT,
  };
})(globalThis);
