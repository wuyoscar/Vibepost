// MediaCraft 长文（公众号）：把 parseMarkdown 的语法树排成一篇长文。同一棵树出三种结果——
//   html(doc, media)            语义 HTML（App API render.articleHtml），不带样式；
//   view(doc, options)          预览与长图用的页面：配色、字体、字号行距都跟随这篇稿子（主题 + 单篇微调）；
//   longImage(doc, options)     把 view 画成一张长图（html2canvas），宽 1080；
//   wechat(doc, options)        复制进公众号编辑器的富文本：只用行内样式，字体换成系统字体（公众号用不了自带字体）。
// options：{ media, look }。media 是稿子的图片 { id: { kind, src, crop, layout, name, sourcePath } }；
// look 是 { colors: { bg, text, accent, secondary, surface }, fonts: { body, code }, zhFont, boldWeight, fontSize, lineHeight }：
// fonts 是 CSS 字体栈，zhFont 是中文字体的 id（公众号里按它挑同类的系统字体），fontSize 按卡片的逻辑像素（24–40）给，长文按版心宽折算。
(function (root) {
  "use strict";

  const engine = root.MediaCraftEngine;

  const PAGE_WIDTH = 540; // 预览与长图的版心宽（逻辑像素）
  const PAGE_PADDING = 36;
  const CARD_WIDTH = 864; // 卡片逻辑宽：字号设置按它定
  const LONG_IMAGE_SCALE = 2; // 长图宽 1080
  const MAX_CANVAS_AREA = 268_000_000; // WebKit 画布面积上限约 2^28 像素
  const IMAGE_RENDER_WIDTH = 1080; // 裁剪后的图最多这么宽，够长图用
  const PAIR_CELL = 0.49; // 拼图每格占版心宽的比例，中间留缝

  // 公众号里的字体：自带字体换成同一类的系统字体。
  const SYSTEM_FONTS = {
    sans: '-apple-system, BlinkMacSystemFont, "Helvetica Neue", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif',
    serif: 'Georgia, "Songti SC", STSong, SimSun, serif',
    kai: '"Kaiti SC", STKaiti, KaiTi, serif',
    mono: 'Menlo, Consolas, "Courier New", monospace',
  };
  const ZH_FONT_KINDS = { "noto-serif-sc": "serif", "zh-song": "serif", "lxgw-wenkai": "kai" };

  const ENTITIES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
  const escape = (text) => String(text).replace(/[&<>"']/g, (char) => ENTITIES[char]);
  const styleAttr = (style) => (style ? ` style="${escape(style)}"` : "");
  const px = (value) => `${Math.round(value * 100) / 100}px`;
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

  // ===== 外观：从配色与字体推出每种元素的行内样式 =====

  // 公众号正文是白底：浅色配色换底色，衬底对着白底重新推（没单独调过的按三色规则，调过的保持与底色的差，
  // 同知识卡的底板）；深色配色换成白底深字，强调色保留，辅助色与衬底按三色规则重新推。
  function wechatColors(colors, tuned) {
    const white = "#ffffff";
    if (engine.colors.luminance(colors.bg) >= 0.4) return { ...colors, bg: white, surface: engine.colors.surfaceOn(white, colors, tuned) };
    const light = { bg: white, text: "#1f1f1f", accent: colors.accent };
    return { ...light, ...engine.colors.derive(light) };
  }

  // target：page（预览与长图）或 wechat（公众号）。
  function skinFor(look, target) {
    const wechat = target === "wechat";
    const roles = engine.colors.roles(wechat ? wechatColors(look.colors, look.tunedColors) : look.colors, {}, look.tunedColors);
    const fonts = wechat
      ? { body: SYSTEM_FONTS[ZH_FONT_KINDS[look.zhFont] || "sans"], code: SYSTEM_FONTS.mono }
      : look.fonts;
    // 公众号正文 14–18px；预览按卡片字号折算到 540 宽的版心
    const size = wechat ? clamp(Math.round(look.fontSize / 2), 14, 18) : (look.fontSize * PAGE_WIDTH) / CARD_WIDTH;
    const base = { wechat, roles, fonts, size, gap: px(size * 0.9), bold: look.boldWeight || 700, headingBold: wechat ? look.boldWeight || 700 : look.displayBold || look.boldWeight || 700 };
    return {
      wechat,
      roles,
      size,
      // 带底色的行内片段（行内代码、高亮）登记在这里，长图前按行拆开（见 splitWrappedRuns）
      backgroundRuns: wechat ? null : [],
      root: `font-family:${fonts.body};font-size:${px(size)};line-height:${look.lineHeight};color:${roles.text};`
        + "letter-spacing:0.02em;text-align:justify;word-break:break-word;overflow-wrap:break-word;",
      page: `box-sizing:border-box;width:${PAGE_WIDTH}px;padding:${PAGE_PADDING}px ${PAGE_PADDING}px ${PAGE_PADDING + 8}px;`
        + `background-color:${roles.paper};`,
      ...textStyles(base),
      ...blockStyles(base),
      ...mediaStyles(base),
    };
  }

  // 段落、标题与行内（加粗、链接、行内代码、高亮）的样式
  function textStyles({ roles, fonts, size, gap, bold, headingBold }) {
    const heading = (scale, top, bottom) =>
      `margin:${px(size * top)} 0 ${px(size * bottom)};font-size:${px(size * scale)};line-height:1.4;font-weight:${headingBold};`
      + (fonts.display ? `font-family:${fonts.display};` : "");
    return {
      p: `margin:0 0 ${gap};`,
      blank: "margin:0;",
      h1: `${heading(1.55, 1.4, 0.8)}color:${roles.heading};`,
      h2: `${heading(1.28, 1.4, 0.7)}padding-left:${px(size * 0.55)};border-left:4px solid ${roles.accent};color:${roles.heading};`,
      h3: `${heading(1.1, 1.2, 0.6)}color:${roles.accentText};`, // 长文的三级标题一直是强调色
      strong: `font-weight:${bold};`,
      link: `color:${roles.accentText};text-decoration:underline;`,
      inlineCode: `font-family:${fonts.code};font-size:0.9em;letter-spacing:0;padding-top:0.1em;padding-bottom:0.1em;`
        + `background-color:${roles.chip};`,
      codeEdge: { pad: "0.35em", radius: "4px" },
      highlightEdge: { pad: "0.15em", radius: "3px" },
    };
  }

  // 引用、列表、代码块、表格与分割线的样式
  function blockStyles({ wechat, roles, fonts, size, gap, bold }) {
    return {
      quote: `margin:0 0 ${gap};padding:${px(size * 0.7)} ${px(size * 0.9)};border-left:3px solid ${roles.accent};`
        + `border-radius:0 6px 6px 0;background-color:${roles.surface};color:${roles.surfaceText};`,
      quoteLine: "margin:0;",
      quoteLineAfter: `margin:${px(size * 0.6)} 0 0;`,
      list: `margin:0 0 ${gap};`,
      item: (marker) => `margin:0 0 ${px(size * 0.35)};padding-left:${marker}em;text-indent:-${marker}em;`,
      marker: (marker) => `display:inline-block;width:${marker}em;text-indent:0;color:${roles.accentText};`,
      pre: `margin:0 0 ${gap};padding:${px(size * 0.8)} ${px(size * 0.9)};border-radius:8px;background-color:${roles.surface};`
        + "overflow-x:auto;text-align:left;",
      preCode: `display:block;font-family:${fonts.code};font-size:${px(size * 0.82)};line-height:1.6;color:${roles.surfaceText};`
        + `letter-spacing:0;white-space:${wechat ? "nowrap" : "pre-wrap"};word-break:break-all;`,
      tableWrap: `margin:0 0 ${gap};overflow-x:auto;`,
      table: `width:100%;border-collapse:collapse;font-size:${px(size * 0.9)};line-height:1.6;`,
      th: (align) => `padding:${px(size * 0.4)} ${px(size * 0.55)};border:1px solid ${roles.rule};`
        + `background-color:${roles.surface};color:${roles.surfaceText};font-weight:${bold};text-align:${align || "left"};`,
      td: (align) => `padding:${px(size * 0.4)} ${px(size * 0.55)};border:1px solid ${roles.rule};text-align:${align || "left"};`,
      hr: `margin:${px(size * 1.6)} 0;border:0;border-top:1px solid ${roles.rule};height:0;`,
    };
  }

  // 图片、实况与拼图的样式
  function mediaStyles({ fonts, size }) {
    return {
      figure: (align) => `margin:${px(size * 1.1)} 0 ${px(size * 1.1)};text-align:${align};line-height:0;`,
      image: (percent) => `display:inline-block;width:${percent}%;max-width:100%;height:auto;border-radius:6px;vertical-align:top;`,
      liveFrame: (percent) => `position:relative;display:inline-block;width:${percent}%;max-width:100%;line-height:0;vertical-align:top;`,
      liveImage: "display:block;width:100%;height:auto;border-radius:6px;",
      liveBadge: `position:absolute;left:10px;top:10px;padding:3px 8px;border-radius:999px;background-color:rgba(0,0,0,0.5);`
        + `color:#ffffff;font-family:${fonts.body};font-size:11px;font-weight:600;line-height:1.4;letter-spacing:0.08em;`,
      pair: `margin:${px(size * 1.1)} 0 ${px(size * 1.1)};display:flex;justify-content:space-between;line-height:0;`,
      pairImage: `display:block;width:${PAIR_CELL * 100}%;height:auto;border-radius:6px;`,
    };
  }

  // ===== 行内 =====

  // 行内底色（行内代码、高亮）两端留边、带圆角；edges 说明这一截是不是整段的头、尾。
  const edgeStyle = ({ pad, radius }, { first, last }) =>
    `padding-left:${first ? pad : 0};padding-right:${last ? pad : 0};`
    + `border-radius:${first ? radius : 0} ${last ? radius : 0} ${last ? radius : 0} ${first ? radius : 0};`;

  function styledRun(run, skin, edges) {
    let html = escape(run.text);
    if (run.code) html = `<code${styleAttr(skin && skin.inlineCode + edgeStyle(skin.codeEdge, edges))}>${html}</code>`;
    if (run.strike) html = `<s>${html}</s>`;
    if (run.underline) html = `<u${styleAttr(run.underline === "dashed" ? "text-decoration-style:dashed;" : "")}>${html}</u>`;
    if (run.italic) html = `<em>${html}</em>`;
    if (run.bold) html = `<strong${styleAttr(skin?.strong)}>${html}</strong>`;
    const styles = [];
    if (run.color) styles.push(`color:${run.color};`);
    if (run.bg) {
      styles.push(`background-color:${run.bg};`);
      if (skin) {
        const text = engine.colors.readableOn(run.bg, run.color || skin.roles.text, skin.roles);
        styles.push(`color:${text};${edgeStyle(skin.highlightEdge, edges)}`);
      }
    }
    if (styles.length) html = `<span${styleAttr(styles.join(""))}>${html}</span>`;
    if (run.link) html = `<a href="${escape(run.link)}"${styleAttr(skin?.link)}>${html}</a>`;
    return html;
  }

  function runHtml(run, skin) {
    const html = styledRun(run, skin, { first: true, last: true });
    if (!skin?.backgroundRuns || !(run.code || run.bg)) return html;
    return `<span data-run="${skin.backgroundRuns.push(run) - 1}">${html}</span>`;
  }

  // html2canvas 按元素的外框画底色，跨行的行内底色会画成盖住两行的一整块：
  // 长图前把跨行的底色片段按行拆成几段，每段只在一行里（两端的留边与圆角照旧只在头尾）。
  function splitWrappedRuns(page, skin) {
    for (const wrapper of page.querySelectorAll("[data-run]")) {
      if (wrapper.getClientRects().length < 2) continue;
      const node = document.createTreeWalker(wrapper, NodeFilter.SHOW_TEXT).nextNode();
      const range = document.createRange();
      const lines = [];
      let top = null;
      let offset = 0;
      for (const char of node.data) {
        range.setStart(node, offset);
        range.setEnd(node, offset + char.length);
        offset += char.length;
        const rect = range.getClientRects()[0];
        if (rect && (top === null || Math.abs(rect.top - top) > 2)) {
          lines.push("");
          top = rect.top;
        }
        if (!lines.length) lines.push("");
        lines[lines.length - 1] += char;
      }
      const run = skin.backgroundRuns[wrapper.dataset.run];
      wrapper.innerHTML = lines
        .map((text, index) => styledRun({ ...run, text }, skin, { first: index === 0, last: index === lines.length - 1 }))
        .join("");
    }
  }

  const runsHtml = (runs, skin) => runs.map((run) => runHtml(run, skin)).join("");

  // ===== 图片 =====

  // 标准 Markdown 图片按文件名找回稿子里的图；找不到或没有画面时不显示。
  function imageFor(block, media) {
    const id = block.imageId ?? engine.mediaLookup(media).get(engine.imageFileKey(block.path));
    const image = id === undefined ? null : media[id];
    return image?.src ? { id, image } : null;
  }

  function loadImage(src) {
    return new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve(image);
      image.onerror = () => reject(new Error("图片读取失败"));
      image.src = src;
    });
  }

  // 裁好的图：按 crop 取图（拼图再按格子比例取中间），画成 data URL。同一张图同样的裁法只画一次。
  const renditions = new Map();
  const RENDITION_CACHE = 64;

  function rendition(image, aspect) {
    const key = `${image.src.length}:${image.src.slice(-48)}|${JSON.stringify(image.crop)}|${aspect}`;
    if (!renditions.has(key)) {
      if (renditions.size >= RENDITION_CACHE) renditions.delete(renditions.keys().next().value);
      renditions.set(key, drawRendition(image, aspect).catch(() => image.src));
    }
    return renditions.get(key);
  }

  async function drawRendition(image, aspect) {
    const element = await loadImage(image.src);
    const size = { width: element.naturalWidth, height: element.naturalHeight };
    const crop = engine.imageCropRect(size, image.crop);
    const ratio = aspect ?? crop.width / crop.height;
    // 宽度不超过原图裁剪框、也不超过长文用得到的最大宽度；高度按要的比例，至少 1 像素
    const width = Math.round(Math.min(IMAGE_RENDER_WIDTH, crop.width));
    const height = Math.max(1, Math.round(width / ratio));
    const canvas = Object.assign(document.createElement("canvas"), { width, height });
    const context = canvas.getContext("2d");
    context.imageSmoothingQuality = "high";
    engine.drawCover(context, element, crop, 0, 0, width, height);
    return canvas.toDataURL("image/png");
  }

  const isUncropped = (image) => !image.crop;

  // 这篇用到的每张图、每格拼图先准备好画面：没裁过的单图直接用原图。
  async function prepareImages(doc, media) {
    const jobs = new Map();
    const need = (key, image, aspect) => {
      if (!jobs.has(key)) jobs.set(key, rendition(image, aspect));
    };
    for (const block of doc.blocks) {
      if (block.type === "image") {
        const found = imageFor(block, media);
        if (found && !isUncropped(found.image)) need(found.id, found.image);
      } else if (block.type === "imagePair") {
        const found = pairImages(block, media);
        if (found.length === 1 && !isUncropped(found[0].image)) need(found[0].id, found[0].image);
        if (found.length === 2) found.forEach(({ id, image }) => need(`${id}|${block.ratio}`, image, pairCellAspect(block)));
      }
    }
    const entries = await Promise.all([...jobs].map(async ([key, job]) => [key, await job]));
    return new Map(entries);
  }

  function pairImages(block, media) {
    return block.imageIds.map((id) => ({ id, image: media[id] })).filter(({ image }) => image?.src);
  }

  const pairCellAspect = (block) => engine.pairRatio(block.ratio) * PAIR_CELL;

  function figureHtml(found, skin, prepared) {
    const { id, image } = found;
    if (!skin) {
      return `<figure${image.kind === "live" ? " data-live" : ""}><img src="${escape(image.src)}" alt="${escape(image.name || "")}"></figure>`;
    }
    const src = escape(prepared.get(id) ?? image.src);
    const layout = engine.resolveImageLayout(image.layout);
    const percent = layout.widthPercent ?? (layout.widthScale ? layout.widthScale * 100 : 100);
    const open = `<section${styleAttr(skin.figure(layout.align))}>`;
    // 实况：长文里放封面，左上角标 LIVE；公众号里只放封面。
    if (image.kind === "live" && !skin.wechat) {
      return `${open}<span${styleAttr(skin.liveFrame(percent))}><img src="${src}" alt=""${styleAttr(skin.liveImage)}>`
        + `<span${styleAttr(skin.liveBadge)}>LIVE</span></span></section>`;
    }
    return `${open}<img src="${src}" alt=""${styleAttr(skin.image(percent))}></section>`;
  }

  function pairHtml(block, media, skin, prepared) {
    const found = pairImages(block, media);
    if (found.length === 1) return figureHtml(found[0], skin, prepared);
    if (!found.length) return "";
    if (!skin) return `<figure>${found.map(({ image }) => `<img src="${escape(image.src)}" alt="${escape(image.name || "")}">`).join("")}</figure>`;
    const cells = found.map(({ id }) => `<img src="${escape(prepared.get(`${id}|${block.ratio}`))}" alt=""${styleAttr(skin.pairImage)}>`);
    return `<section${styleAttr(skin.pair)}>${cells.join("")}</section>`;
  }

  // ===== 块 =====

  // 引用里单独一个「>」的行是段落分隔。
  function quoteGroups(lines) {
    const groups = [[]];
    for (const line of lines) {
      if (line.runs.length) groups[groups.length - 1].push(line);
      else if (groups[groups.length - 1].length) groups.push([]);
    }
    return groups.filter((group) => group.length);
  }

  function quoteHtml(block, skin) {
    const paragraphs = quoteGroups(block.lines).map((group, index) => {
      const style = skin && (index ? skin.quoteLineAfter : skin.quoteLine);
      return `<p${styleAttr(style)}>${group.map((line) => runsHtml(line.runs, skin)).join("<br>")}</p>`;
    });
    return `<blockquote${styleAttr(skin?.quote)}>${paragraphs.join("")}</blockquote>`;
  }

  // 语义 HTML：有序、无序各成一组；编号不从 1 起或跳号时写明。
  function semanticList(block) {
    const groups = [];
    for (const item of block.items) {
      const last = groups[groups.length - 1];
      if (last && last.ordered === item.ordered) last.items.push(item);
      else groups.push({ ordered: item.ordered, items: [item] });
    }
    return groups.map(({ ordered, items }) => {
      const tag = ordered ? "ol" : "ul";
      const start = ordered && items[0].number !== 1 ? ` start="${items[0].number}"` : "";
      const rows = items.map((item, index) => {
        const value = ordered && index && item.number !== items[index - 1].number + 1 ? ` value="${item.number}"` : "";
        return `<li${value}>${runsHtml(item.runs, null)}</li>`;
      });
      return `<${tag}${start}>${rows.join("")}</${tag}>`;
    }).join("");
  }

  // 排版后的列表：编号照原文显示（7.、2)、2024.），整组悬挂宽度一致。
  function styledList(block, skin) {
    const markers = block.items.map((item) => (item.ordered ? item.marker : "•"));
    const width = Math.max(1.4, Math.max(...markers.map((marker) => marker.length)) * 0.56 + 0.5);
    const rows = block.items.map((item, index) =>
      `<p${styleAttr(skin.item(width))}><span${styleAttr(skin.marker(width))}>${escape(markers[index])}</span>${runsHtml(item.runs, skin)}</p>`);
    return `<section${styleAttr(skin.list)}>${rows.join("")}</section>`;
  }

  // 公众号编辑器会吞掉换行与连续空格：换行写成 <br>，行首与连续的空格写成 &nbsp;。
  function wechatCode(text) {
    return text.split("\n").map((line) => escape(line.replace(/\t/g, "    "))
      .replace(/^ +| {2,}/g, (spaces) => "&nbsp;".repeat(spaces.length))).join("<br>");
  }

  function codeHtml(block, skin) {
    const lang = block.lang && !skin ? ` class="language-${escape(block.lang)}"` : "";
    const body = skin?.wechat ? wechatCode(block.text) : escape(block.text);
    return `<pre${styleAttr(skin?.pre)}><code${lang}${styleAttr(skin?.preCode)}>${body}</code></pre>`;
  }

  function tableHtml(block, skin) {
    const cells = (row, tag) => Array.from({ length: block.columns }, (_, index) => {
      const align = block.align[index];
      const style = skin ? skin[tag](align) : align ? `text-align:${align};` : "";
      return `<${tag}${styleAttr(style)}>${runsHtml(row.cells[index]?.runs ?? [], skin)}</${tag}>`;
    }).join("");
    const head = `<thead><tr>${cells(block.header, "th")}</tr></thead>`;
    const body = block.rows.length ? `<tbody>${block.rows.map((row) => `<tr>${cells(row, "td")}</tr>`).join("")}</tbody>` : "";
    const table = `<table${styleAttr(skin?.table)}>${head}${body}</table>`;
    return skin ? `<section${styleAttr(skin.tableWrap)}>${table}</section>` : table;
  }

  function blockHtml(block, context) {
    const { skin, media, prepared } = context;
    switch (block.type) {
      case "heading":
        return `<h${block.level}${styleAttr(skin?.[`h${Math.min(block.level, 3)}`])}>${runsHtml(block.runs, skin)}</h${block.level}>`;
      case "paragraph":
        return `<p${styleAttr(skin?.p)}>${block.lines.map((line) => runsHtml(line.runs, skin)).join("<br>")}</p>`;
      case "quote":
        return quoteHtml(block, skin);
      case "list":
        return skin ? styledList(block, skin) : semanticList(block);
      case "code":
        return codeHtml(block, skin);
      case "table":
        return tableHtml(block, skin);
      case "image": {
        const found = imageFor(block, media);
        return found ? figureHtml(found, skin, prepared) : "";
      }
      case "imagePair":
        return pairHtml(block, media, skin, prepared);
      case "rule":
        return `<hr${styleAttr(skin?.hr)}>`;
      default:
        return ""; // [[分页]] 在长文里没有意义
    }
  }

  // 第一块顶上不留外边距（版心已有内边距）。块的样式都以「margin:上 右 下」开头。
  const withoutTopMargin = (html) => html.replace(/^(<\w+ style=")margin:[^ ]+ /, "$1margin:0 ");

  // 排版后的正文：多空的行各留一行空白。
  function styledBody(doc, context) {
    const parts = [];
    for (const block of doc.blocks) {
      const html = blockHtml(block, context);
      if (!html) continue;
      if (parts.length) {
        for (let blank = 1; blank < block.blankLinesBefore; blank += 1) parts.push(`<p${styleAttr(context.skin.blank)}><br></p>`);
      }
      parts.push(parts.length ? html : withoutTopMargin(html));
    }
    return parts.join("");
  }

  // ===== 对外 =====

  function html(doc, media = {}) {
    return doc.blocks.map((block) => blockHtml(block, { skin: null, media, prepared: new Map() })).join("");
  }

  async function buildPage(doc, { media, look }) {
    const skin = skinFor(look, "page");
    const prepared = await prepareImages(doc, media);
    const page = document.createElement("article");
    page.className = "article-page";
    page.setAttribute("aria-label", "长文预览");
    page.style.cssText = skin.root + skin.page;
    page.innerHTML = styledBody(doc, { skin, media, prepared });
    return { page, skin };
  }

  async function view(doc, options) {
    return (await buildPage(doc, options)).page;
  }

  // 长图：页面放进一个看不见的容器里排好，等图片解码、字体加载完，再按 2 倍画出来（太长时按画布上限缩小）。
  async function longImage(doc, options) {
    const { page, skin } = await buildPage(doc, options);
    const holder = document.createElement("div");
    holder.dataset.longImage = "";
    holder.style.cssText = "position:fixed;left:0;top:0;z-index:-1;visibility:hidden;pointer-events:none;";
    holder.append(page);
    document.body.append(holder);
    try {
      await Promise.all([...page.querySelectorAll("img")].map((image) => image.decode().catch(() => undefined)));
      await document.fonts.ready;
      splitWrappedRuns(page, skin);
      const { width, height } = page.getBoundingClientRect();
      const scale = Math.min(LONG_IMAGE_SCALE, Math.sqrt(MAX_CANVAS_AREA / (width * height)));
      if (scale < 0.5) throw new Error("长文太长，超出了长图的最大尺寸，请分成几篇");
      return await root.html2canvas(page, {
        scale,
        backgroundColor: skin.roles.paper,
        logging: false,
        windowWidth: Math.ceil(width),
        windowHeight: Math.ceil(height),
        // 只克隆长图这一块（样式表与字体在 head 里），别的界面不带进去
        ignoreElements: (element) => element.parentElement === document.body && element !== holder,
        onclone: (clone) => {
          clone.querySelector("[data-long-image]").style.visibility = "visible";
        },
      });
    } finally {
      holder.remove();
    }
  }

  async function wechat(doc, { media, look }) {
    const skin = skinFor(look, "wechat");
    const prepared = await prepareImages(doc, media);
    return `<section${styleAttr(skin.root)}>${styledBody(doc, { skin, media, prepared })}</section>`;
  }

  root.MediaCraftArticle = { html, view, longImage, wechat, PAGE_WIDTH };
})(globalThis);
