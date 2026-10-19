// HTML 卡片（ADR 0006）的入口：稿子 → 分好页的 HTML → 舞台上可操作的卡片 DOM / 壳里截的 PNG。
//   await MediaCraftCards.layout(settings)   → { pages: [{ kind, html, sources }], theme, style }
//   MediaCraftCards.mount(result, index)      → 一张卡片的元素（Shadow DOM，864 × 1152 逻辑像素）
//   await MediaCraftCards.rasterize(result)   → 每页 { png（正文 PNG Blob）, strips（真实页码的页眉页脚条）}（壳里原生截图；浏览器里退回 html2canvas）
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
  // 缩略图（胶片、主题面板、手机预览）按出图键留着小图：一张 120×160 不到 80 KB，几百张也没多少
  const THUMB_CACHE_SIZE = 400;
  const SAMPLES = 48; // 图片指纹抽样的段数
  // 量过尺寸的图片按指纹记着：每次排版都重新载入几 MB 的 data URL 量一遍太贵（记录里有 width / height 的不用量）
  const SIZE_CACHE_SIZE = 500;

  // 出图的计数（测试与排查用：改一个字之后该只重出变了的页、图片不该再过桥、不该新建整页画布）
  const stats = { rasterized: 0, cacheHits: 0, strips: 0, bridgedImageBytes: 0, fullPaints: 0, thumbs: 0, thumbHits: 0 };

  const px = (value) => `${Math.round(value * 100) / 100}px`;

  // 这一页的版式变量：正文区四边、字号行距、标题、图片圆角
  function structureVars(structure, first, settings) {
    const pad = structure.pages[first ? "first" : "inner"];
    const size = (settings.fontSize ?? 34) * structure.body.scale;
    const vars = {
      "--mc-page-height": px(root.MediaCraftStyleForm.normalizeNumber("cardHeight", settings.cardHeight)),
      "--pad-t": px(pad.top), "--pad-r": px(pad.right), "--pad-b": px(pad.bottom), "--pad-l": px(pad.left),
      "--mc-size-body": px(size),
      "--mc-leading": String(settings.lineHeight ?? 1.85),
      // 段距：块与块之间按行高的几倍（structures.css 的 --mc-gap）
      "--mc-gap-ratio": String(root.MediaCraftStyleForm.normalizeNumber("blockGap", settings.blockGap)),
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
    Object.assign(measureCard.host.style, { position: "fixed", left: "-20000px", top: "0", width: `${WIDTH}px`, height: `${context.height}px`, pointerEvents: "none" });
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
      height: root.MediaCraftStyleForm.normalizeNumber("cardHeight", settings.cardHeight),
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

  // 图片的原始尺寸：记录里没有时量一次（分页要按比例留高度），量过的按指纹记着，同一张图不再重新载入
  const sizeCache = new Map();
  async function withSizes(settings) {
    const images = { ...(settings.images ?? {}) };
    await Promise.all(Object.entries(images).map(async ([id, record]) => {
      if (!record?.src || (record.width && record.height)) return;
      const key = fingerprint(record.src);
      let size = sizeCache.get(key);
      if (!size) {
        const image = new Image();
        image.src = record.src;
        await loaded(image);
        size = { width: image.naturalWidth || 1, height: image.naturalHeight || 1 };
        sizeCache.delete(key);
        sizeCache.set(key, size);
        while (sizeCache.size > SIZE_CACHE_SIZE) sizeCache.delete(sizeCache.keys().next().value);
      }
      images[id] = { ...record, ...size };
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

  // ---------- 出图缓存 ----------
  // 正文 PNG 按「占位页码」的整页 HTML 截：页眉页脚里的页码写成固定的占位（第一页仍是第一页，其余都当第二页，共 88 页），
  // 这样加减一页只有真变了的页要重出，不会因为「n / 总页数」全部失效。真实页码的页眉页脚另外截成小条（chrome）贴上去。
  // 图片在键里只放指纹（长度 + 均匀抽样的几段字符），不放整条 data URL：一张图几 MB，拼进键里每代都留一份，
  // 一篇十来张图的稿子审阅几轮就是几百 MB（2026-10-08 的卡顿）
  const rasterCache = new Map(); // 键 → 正文 PNG Blob
  let rasterBytes = 0;
  const stripCache = new Map(); // 键 → 这页页眉页脚的条 [{ x, y, width, height, png }]
  const STRIP_CACHE_SIZE = 600;
  function fingerprint(src) {
    const text = String(src ?? "");
    if (!text.startsWith("data:") || text.length < 2048) return text;
    const stride = Math.floor(text.length / SAMPLES);
    let sample = "";
    for (let i = 0; i < SAMPLES; i += 1) sample += text.substr(i * stride, 16);
    return `${text.length}:${sample}:${text.slice(-32)}`;
  }
  const placeholderPage = (result, index) => ({ ...result.pages[index], index: index === 0 ? 0 : 1, total: 88 });
  // 截正文 PNG 用的整页 HTML：占位页码，并去掉源码偏移（data-s 每段字的、data-src / data-content-src 每块的，只给舞台点选用）——
  // 改一个字后面所有块的偏移都变，留着会让后面每一页的出图键都变、全部重出
  const SOURCE_ATTRS = / data-(?:s|src|content-src)="[^"]*"/g;
  const rasterHtml = (result, index) => pageHtml(placeholderPage(result, index), result.context).replace(SOURCE_ATTRS, "");
  // 真实页码的页眉页脚；和占位的一样（没有页码的页，比如封面）时为 null
  function chromeOf(result, index) {
    const chrome = root.MediaCraftCardChrome.of(result.context.look);
    const real = { ...result.pages[index], index, total: result.pages.length };
    const placeholder = placeholderPage(result, index);
    const head = chrome.head(real, result.context);
    const foot = chrome.foot(real, result.context);
    if (head === chrome.head(placeholder, result.context) && foot === chrome.foot(placeholder, result.context)) return null;
    return { head, foot };
  }
  const cacheKey = (result, page) => `${result.style.length}|${page}|${mediaIds(page).map((id) => fingerprint(mediaSrc(result, id))).join("|")}`;
  // 条的键要带这一页的 <article …> 开头标签：配色、字体、版心都是它上面的变量（同结构、同署名、同页码的两个主题只差这个）
  const openingTag = (html) => html.slice(0, html.indexOf(">") + 1);
  const stripKey = (result, html, chrome) => `${result.style.length}|${openingTag(html)}|${chrome.head}|${chrome.foot}|${fingerprint(result.context.profile.avatar)}`;
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
  function rememberStrips(key, strips) {
    stripCache.delete(key);
    stripCache.set(key, strips);
    while (stripCache.size > STRIP_CACHE_SIZE) stripCache.delete(stripCache.keys().next().value);
  }

  // 每页一份 { png（正文 PNG Blob）, strips（页眉页脚的条）}。indexes：只出这几页（默认全部）。
  // 正文 PNG、条分别按键缓存：打字只重出变了的页；页数变了只重截各页的条。
  // 正在出的页（胶片、主题面板、手机预览常同时要同一批）记在 inflight 里，后来的等它，不再发一次
  const inflight = new Map();
  async function rasterize(result, indexes = result.pages.map((_, index) => index)) {
    const jobs = indexes.map((index) => {
      const html = rasterHtml(result, index);
      const chrome = chromeOf(result, index);
      const key = cacheKey(result, html);
      const strip = chrome ? stripKey(result, html, chrome) : null;
      return { index, html, chrome, key, stripKey: strip, id: `${key}|${strip ?? ""}` };
    });
    const found = jobs.map((job) => ({ png: rasterCache.get(job.key) ?? null, strips: job.stripKey ? stripCache.get(job.stripKey) ?? null : [] }));
    const missing = jobs.map((job, at) => (found[at].png && found[at].strips ? null : at)).filter((at) => at !== null);
    stats.cacheHits += jobs.length - missing.length;
    const waits = [];
    const fresh = [];
    for (const at of missing) {
      const pending = inflight.get(jobs[at].id);
      if (pending) waits.push(pending.then((page) => { found[at] = { ...page }; }));
      else fresh.push(at);
    }
    stats.rasterized += fresh.filter((at) => !found[at].png).length;
    stats.strips += fresh.filter((at) => !found[at].strips).length;
    if (fresh.length) {
      const deferred = fresh.map((at) => {
        let resolve, reject;
        const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
        promise.catch(() => undefined);
        inflight.set(jobs[at].id, promise);
        return { at, resolve, reject };
      });
      try {
        if (root.MediaCraftNative?.rasterCards) {
          const rendered = await rasterizeNatively(result, fresh.map((at) => ({ html: jobs[at].html, chrome: found[at].strips ? null : jobs[at].chrome, full: !found[at].png })));
          fresh.forEach((at, order) => {
            const page = rendered[order];
            if (page.png) {
              found[at].png = page.png;
              remember(jobs[at].key, page.png);
            }
            if (!found[at].strips) {
              found[at].strips = page.strips;
              rememberStrips(jobs[at].stripKey, page.strips);
            }
          });
        } else {
          // 浏览器里没有壳：html2canvas 按真实页码整页画（没有条；页数变了这页会重画）
          for (const at of fresh) {
            found[at].png = await rasterizeInBrowser(result, indexes[at]);
            found[at].strips = [];
            remember(jobs[at].key, found[at].png);
          }
        }
        for (const { at, resolve } of deferred) resolve(found[at]);
      } catch (error) {
        for (const { reject } of deferred) reject(error);
        throw error;
      } finally {
        for (const { at } of deferred) inflight.delete(jobs[at].id);
      }
    }
    await Promise.all(waits);
    return found;
  }

  // 图片只过一次桥：宿主页按编号留着，这里记着哪些发过（宿主页重建后 generation 变，重新发）；宿主页缺哪张就回 409，补发一次
  const hostMedia = { generation: null, sent: new Set() };
  async function rasterizeNatively(result, pages) {
    const ids = [...new Set(pages.flatMap((page) => mediaIds(page.html)))].filter((id) => mediaSrc(result, id));
    const payload = async (wanted) => {
      const media = {};
      await Promise.all(wanted.map(async (id) => {
        media[id] = await dataUrl(mediaSrc(result, id));
      }));
      for (const src of Object.values(media)) stats.bridgedImageBytes += src.length;
      return media;
    };
    const out = [];
    for (let start = 0; start < pages.length; start += RASTER_BATCH) {
      const batch = pages.slice(start, start + RASTER_BATCH);
      const batchIds = [...new Set(batch.flatMap((page) => mediaIds(page.html)))].filter((id) => ids.includes(id));
      let wanted = batchIds.filter((id) => !hostMedia.generation || !hostMedia.sent.has(id));
      let reply;
      for (let attempt = 0; ; attempt += 1) {
        const request = { pages: batch, style: result.style, media: await payload(wanted), mediaIds: batchIds, width: WIDTH, height: result.context.height, scale: SCALE };
        try {
          reply = await root.MediaCraftNative.rasterCards(request);
          break;
        } catch (error) {
          if (!Array.isArray(error.missing) || attempt) throw error;
          // 宿主页说缺图（重建过或挤掉了）：按它说的补发一次
          if (error.generation && error.generation !== hostMedia.generation) {
            hostMedia.generation = error.generation;
            hostMedia.sent.clear();
          }
          wanted = error.missing.filter((id) => ids.includes(id));
        }
      }
      if (reply.generation !== hostMedia.generation) {
        hostMedia.generation = reply.generation;
        hostMedia.sent.clear();
      }
      for (const id of batchIds) hostMedia.sent.add(id);
      out.push(...reply.pages);
    }
    return out;
  }

  // 把一页画进 2 倍图的画布：正文 PNG 铺满，页眉页脚的条按卡片坐标 × 倍数贴上
  async function paintPage(context, page) {
    const bitmap = await createImageBitmap(page.png);
    context.drawImage(bitmap, 0, 0, context.canvas.width, context.canvas.height);
    bitmap.close();
    for (const strip of page.strips ?? []) {
      const piece = await createImageBitmap(strip.png);
      context.drawImage(piece, strip.x * SCALE, strip.y * SCALE, strip.width * SCALE, strip.height * SCALE);
      piece.close();
    }
  }

  // 浏览器开发模式没有壳：用 html2canvas 画（只为开发时看效果，像素以壳为准）
  async function rasterizeInBrowser(result, index) {
    const host = mount(result, index);
    Object.assign(host.style, { position: "fixed", left: "-20000px", top: "0", width: `${WIDTH}px`, height: `${result.context.height}px` });
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
        Object.assign(host.style, { width: `${WIDTH}px`, height: `${result.context.height}px` });
        shelf.append(host);
        return host;
      });
      await Promise.all(hosts.flatMap((host) => [...host.shadowRoot.querySelectorAll("img[src]")].map(loaded)));
      // 一页一页量，页与页之间让出主线程
      const pages = [];
      for (const [index, host] of hosts.entries()) {
        if (index) await root.MediaCraftCardPaginate.yieldToPage();
        pages.push(root.MediaCraftCardSummary.summarize(host.shadowRoot.querySelector(".mc-page"), { index, kind: result.pages[index].kind, height: result.context.height }, result.context));
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
    const canvases = result.pages.slice(0, count).map(() => Object.assign(document.createElement("canvas"), { width: WIDTH * SCALE, height: result.context.height * SCALE }));
    let drawing = null;
    const draw = () => {
      // 一页一页画，页与页之间让出主线程（一次画几十张 2 倍图会卡住界面）
      drawing ??= rasterize(result, canvases.map((_, index) => index)).then(async (pages) => {
        for (const [index, page] of pages.entries()) {
          stats.fullPaints += 1;
          await paintPage(canvases[index].getContext("2d"), page);
          await root.MediaCraftCardPaginate.yieldToPage();
        }
      });
      return drawing;
    };
    return { pageCount: result.pages.length, canvases, pages, views: hosts.slice(0, count), draw, thumbnails: (options) => thumbnails(result, options) };
  }

  // 缩略图：每页一张 width × height 的小画布，从 PNG 解码后直接画小（整张位图用完就 close，不留 16 MB 的整页画布；
  // 胶片、主题面板、手机预览每次出图都要全部页，整页画布留着太贵）。小图按出图键 + 尺寸缓存，改一个字只重做变了的页。
  // 给出去的是拷贝（调用方可能把它放进界面）。indexes：只要这几页
  const thumbCache = new Map();
  async function thumbnails(result, { width, height, indexes = result.pages.map((_, index) => index) } = {}) {
    const pages = await rasterize(result, indexes);
    const keys = indexes.map((index) => {
      const html = rasterHtml(result, index);
      const chrome = chromeOf(result, index);
      return `${cacheKey(result, html)}|${chrome ? stripKey(result, html, chrome) : ""}|${width}x${height}`;
    });
    const canvases = [];
    for (const [order, page] of pages.entries()) {
      let small = thumbCache.get(keys[order]);
      if (small) {
        stats.thumbHits += 1;
      } else {
        stats.thumbs += 1;
        small = await shrinkPage(page, width, height, result.context.height);
        thumbCache.delete(keys[order]);
        thumbCache.set(keys[order], small);
        while (thumbCache.size > THUMB_CACHE_SIZE) thumbCache.delete(thumbCache.keys().next().value);
      }
      const copy = Object.assign(document.createElement("canvas"), { width, height });
      copy.getContext("2d").drawImage(small, 0, 0);
      canvases.push(copy);
      if (order) await root.MediaCraftCardPaginate.yieldToPage();
    }
    return canvases;
  }

  // PNG → 小画布：整张解码后先 1:1 画进一张复用的中转整页画布，再从画布缩（WebKit 从位图缩与从画布缩的重采样不同；
  // 从画布缩和导出、手机预览原来的路一致，像素一样）。中转画布只有一张，所以一次只缩一张（胶片、主题面板、手机预览常同时来，
  // 交错着清、画会互相抹掉）；整张位图随手关掉
  let scratch = null;
  let shrinking = Promise.resolve();
  function shrinkPage(page, width, height, cardHeight) {
    const run = shrinking.then(async () => {
      scratch ??= Object.assign(document.createElement("canvas"), { width: WIDTH * SCALE, height: HEIGHT * SCALE });
      if (scratch.height !== cardHeight * SCALE) scratch.height = cardHeight * SCALE;
      const full = scratch.getContext("2d");
      full.clearRect(0, 0, scratch.width, scratch.height);
      await paintPage(full, page);
      const canvas = Object.assign(document.createElement("canvas"), { width, height });
      const context = canvas.getContext("2d");
      context.imageSmoothingQuality = "high";
      const fit = Math.min(width / scratch.width, height / scratch.height);
      const w = scratch.width * fit, h = scratch.height * fit;
      context.drawImage(scratch, (width - w) / 2, (height - h) / 2, w, h);
      return canvas;
    });
    shrinking = run.catch(() => undefined);
    return run;
  }

  root.MediaCraftCards = {
    WIDTH, HEIGHT, SCALE, layout, mount, rasterize, paint, thumbnails, paintPage,
    cleanCss,
    CARD_CSS_LIMIT,
    stats,
    resetStats: () => { for (const key of Object.keys(stats)) stats[key] = 0; },
  };
})(globalThis);
