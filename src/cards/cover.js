// 卡片的封面（首页做封面，检查器「封面」）：标题、副标题、底图按卡片结构的 cover 规格（src/engine/structures.js）摆：
// - 标题在 max 到 min 之间取放得下的最大字号（最多 maxLines 行、最长的英文单词放得进一行），最小字号也放不下时末行截断；
//   副标题最多几行。文字区在 area 里按 anchor 靠上、居中或靠下；副标题可以钉在某个高度（pin）。
// - 底图 plate 放进结构给的框（below 的框跟在文字下面一直到页底），bleed 铺满整张、文字压在底部渐变到底色的遮罩上；
//   实况铺满时视频盖不住字：图框只到文字区上沿。
// 这里只拼 HTML、量标题；变量与样式在 src/cards/structures.css（[data-kind="cover"]）。
(function (root) {
  "use strict";

  const TITLE_STEP = 2;
  const SCRIM_FADE = 280;
  const SCRIM_PAD = 40;
  const escape = (text) => root.MediaCraftCardHtml.escape(text);
  const px = (value) => `${Math.round(value * 100) / 100}px`;

  // 一块里第一行字（标题取标题框，没填时取正文第一行）
  function firstLine(block) {
    const lines = block.type === "heading" ? [block] : block.lines ?? block.items ?? [];
    for (const line of lines) {
      const text = line.runs.map((run) => run.text).join("").trim();
      if (text) return text;
    }
    return "";
  }

  // 封面：没开时为 null
  function of(settings, doc) {
    if (!settings.cover?.enabled) return null;
    const own = String(settings.title || "").trim();
    const title = own || doc.blocks.map(firstLine).find(Boolean) || "";
    return { title, subtitle: String(settings.cover.subtitle || "").trim(), imageId: settings.cover.image ?? null };
  }

  // 底图怎么放：none / plate / below（跟在文字下面）/ bleed
  function modeOf(spec, image) {
    if (!image) return "none";
    if (spec.image.mode === "bleed") return "bleed";
    return spec.image.box?.below ? "below" : "plate";
  }

  // 底图：铺满它的框（object-fit: cover），对准裁剪框的中心
  function coverPicture(id, image) {
    const crop = image.crop ?? { x: 0, y: 0, width: image.width || 1, height: image.height || 1 };
    // object-position 的百分比：裁剪框在原图里还能往哪边挪（裁满一边时居中）
    const focus = (start, length, full) => (full > length ? (start / (full - length)) * 100 : 50);
    const x = focus(crop.x, crop.width, image.width || crop.width);
    const y = focus(crop.y, crop.height, image.height || crop.height);
    const live = image.kind === "live";
    return `<figure class="mc-cover-image" data-live="${live}"><div class="mc-img${live ? " is-live" : ""}" data-image="${escape(id)}">`
      + `<img alt="" data-media="${escape(id)}" style="object-position:${x}% ${y}%"></div></figure>`;
  }

  // 封面这一页正文区里的 HTML（字号先按最大的写，fit() 再量）
  function markup(cover, context) {
    const spec = context.structure.cover;
    const image = cover.imageId ? context.media[cover.imageId] : null;
    const mode = modeOf(spec, image);
    const title = mode === "none" ? spec.title : { ...spec.title, max: Math.max(spec.title.min, Math.min(spec.title.max, spec.image.titleMax)) };
    const area = mode === "none" ? spec.area : spec.image.area;
    const subtitleLines = mode === "none" ? spec.subtitle.maxLines : Math.min(spec.subtitle.maxLines, spec.image.subtitleLines);
    const vars = {
      "--cover-left": px(spec.column.left), "--cover-right": px(spec.column.right),
      "--cover-top": px(area.top), "--cover-bottom": px(root.MediaCraftCards.HEIGHT - area.bottom),
      "--cover-title-max": px(title.max), "--cover-title-min": px(title.min), "--cover-title-weight": String(title.weight),
      "--cover-title-leading": String(title.lineHeight), "--cover-title-lines": String(title.maxLines),
      "--cover-sub-size": px(spec.subtitle.size), "--cover-sub-weight": String(spec.subtitle.weight),
      "--cover-sub-leading": String(spec.subtitle.lineHeight), "--cover-sub-gap": px(spec.subtitle.gap), "--cover-sub-lines": String(subtitleLines),
      ...(spec.subtitle.pin !== null && mode === "none" ? { "--cover-sub-pin": px(spec.subtitle.pin) } : {}),
      ...(mode === "bleed" ? { "--cover-lead": px(spec.image.lead), "--cover-fade": px(SCRIM_FADE), "--cover-pad": px(SCRIM_PAD) } : {}),
    };
    const box = spec.image.box;
    if (mode === "plate") Object.assign(vars, { "--plate-x": px(box.x), "--plate-y": px(box.y), "--plate-w": px(box.width), "--plate-h": px(box.height), "--plate-radius": px(box.radius) });
    if (mode === "below") Object.assign(vars, { "--plate-gap": px(box.gap), "--plate-bottom": px(box.bottom), "--plate-min": px(box.minHeight), "--plate-radius": px(box.radius) });
    const style = Object.entries(vars).map(([key, value]) => `${key}:${value}`).join(";");
    const picture = image ? coverPicture(cover.imageId, image) : "";
    // 标题旁的装饰（样子按结构写在 structures.css）：标题上方的粗短线、标题下的线、便签横格、淡色大引号、瑞士的底线
    const deco = (name) => `<span class="mc-cover-${name}" aria-hidden="true"></span>`;
    const texts = (cover.title ? `${deco("mark")}<h1 class="mc-cover-title" style="font-size:${px(title.max)}">${escape(cover.title)}</h1>${deco("rule")}` : "")
      + (cover.subtitle ? `<p class="mc-cover-subtitle">${escape(cover.subtitle)}</p>` : "")
      + (mode === "none" ? deco("lines") : "");
    const pinned = spec.subtitle.pin !== null && mode === "none";
    return `<div class="mc-cover" data-image="${mode}" data-anchor="${area.anchor}" data-align="${spec.align}"${pinned ? " data-pinned" : ""} style="${escape(style)}">`
      + (mode === "below" ? "" : picture)
      + (mode === "bleed" ? `<div class="mc-cover-scrim"></div>` : "")
      + deco("quote") + deco("base")
      + `<div class="mc-cover-text">${texts}${mode === "below" ? picture : ""}</div></div>`;
  }

  // 量标题：从最大字号往下试，放得下（不超过 maxLines 行、没有横向溢出）就停；最小字号也放不下时截断（CSS 的 line-clamp）
  function fit(page) {
    const title = page.querySelector(".mc-cover-title");
    if (title) {
      fitTitle(page, title);
      markWidest(page, title);
    }
    fitSubtitle(page);
    markSolid(page);
  }

  // 标题最宽的一行有多宽（结构样式里标题下的线可以跟着它）
  function markWidest(page, title) {
    const range = document.createRange();
    range.selectNodeContents(title);
    const widest = Math.max(0, ...[...range.getClientRects()].map((rect) => rect.width));
    const scale = page.querySelector(".mc-page").getBoundingClientRect().width / root.MediaCraftCards.WIDTH || 1;
    page.querySelector(".mc-cover").style.setProperty("--cover-title-width", px(widest / scale));
  }

  // 铺满的底图：文字区上沿再往上 lead + pad 是遮罩最不透的地方（实况的图框只到这里，视频盖不住字）
  function markSolid(page) {
    const cover = page.querySelector(".mc-cover");
    const first = page.querySelector(".mc-cover-title, .mc-cover-subtitle");
    if (!cover || cover.dataset.image !== "bleed" || !first) return;
    const style = getComputedStyle(cover);
    const top = first.getBoundingClientRect().top - cover.getBoundingClientRect().top;
    const solid = Math.max(0, top - parseFloat(style.getPropertyValue("--cover-lead")) - parseFloat(style.getPropertyValue("--cover-pad")));
    cover.style.setProperty("--cover-solid", px(solid));
  }

  function fitTitle(page, title) {
    const style = getComputedStyle(page.querySelector(".mc-cover"));
    const max = parseFloat(style.getPropertyValue("--cover-title-max"));
    const min = parseFloat(style.getPropertyValue("--cover-title-min"));
    const leading = parseFloat(style.getPropertyValue("--cover-title-leading"));
    const lines = Number(style.getPropertyValue("--cover-title-lines"));
    const column = page.querySelector(".mc-cover-text");
    for (let size = max; size >= min; size -= TITLE_STEP) {
      title.style.fontSize = px(size);
      // 宽度和文字区比：居中时标题是 flex 项，会撑到比文字区还宽而不算溢出
      if (rowsOf(title, size * leading) <= lines && title.scrollWidth <= column.clientWidth + 0.5) return;
    }
    // 最小字号也放不下：单词只好拆开，多出来的收进最后一行、末尾换成省略号
    title.style.fontSize = px(min);
    title.dataset.clamped = "true";
    clamp(title, lines, min * leading);
  }

  const rowsOf = (element, leading) => Math.round(element.scrollHeight / leading);

  // 折成最多 rows 行：二分出放得下的字数，末尾加省略号
  function clamp(element, rows, leading) {
    const text = Array.from(element.textContent);
    if (rowsOf(element, leading) <= rows) return;
    let low = 0;
    let high = text.length;
    while (low < high) {
      const middle = Math.ceil((low + high) / 2);
      element.textContent = `${text.slice(0, middle).join("").trimEnd()}…`;
      if (rowsOf(element, leading) <= rows) low = middle;
      else high = middle - 1;
    }
    element.textContent = `${text.slice(0, low).join("").trimEnd()}…`;
  }

  // 副标题最多几行，放不下同样截断
  function fitSubtitle(page) {
    const subtitle = page.querySelector(".mc-cover-subtitle");
    if (!subtitle) return;
    const style = getComputedStyle(subtitle);
    const cover = getComputedStyle(page.querySelector(".mc-cover"));
    clamp(subtitle, Number(cover.getPropertyValue("--cover-sub-lines")), parseFloat(style.lineHeight));
  }

  root.MediaCraftCardCover = { of, markup, fit, SCRIM_FADE };
})(globalThis);
