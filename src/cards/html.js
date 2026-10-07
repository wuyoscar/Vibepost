// HTML 卡片（ADR 0006）：语法树 → 一块一块的 HTML。只拼字符串、不碰 DOM；分页在 src/cards/paginate.js。
// 每块带 data-src="开头,结尾"（在稿子里的位置）：卡片上点中一块就知道对应哪段原文，人和 Agent 的编排都落回这份稿子。
// 所有来自稿子的文字都经 escape；颜色只收 #十六进制，链接只收 http(s) / mailto（解析器已经过滤）。
(function (root) {
  "use strict";

  const HEX = /^#[0-9a-fA-F]{3,8}$/;
  const TONES = 4;

  function escape(text) {
    return String(text).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
  }

  const src = (source) => (source ? ` data-src="${source[0]},${source[1]}"` : "");

  // ---------- 标注的颜色：同一个类别在一篇稿子里颜色固定，按第一次出现的先后轮流取 1…4 ----------

  const BADGE = /^\[([^\]\s][^\]]{0,23})\]\s*/;

  function collectTones(blocks, tones = new Map()) {
    const note = (label) => {
      if (label && !tones.has(label)) tones.set(label, (tones.size % TONES) + 1);
    };
    const runsOf = (block) => [
      ...(block.runs ?? []),
      ...(block.lines ?? []).flatMap((line) => line.runs),
      ...(block.items ?? []).flatMap((item) => item.runs),
      ...[block.header, ...(block.rows ?? [])].filter(Boolean).flatMap((row) => row.cells.flatMap((cell) => cell.runs)),
    ];
    for (const block of blocks) {
      if (block.type === "container") {
        if (componentOf(block.name)?.id === "rows") {
          for (const list of block.blocks) for (const item of list.items ?? []) note(BADGE.exec(item.runs[0]?.text ?? "")?.[1]);
        }
        collectTones(block.blocks, tones);
        continue;
      }
      for (const run of runsOf(block)) note(run.mark);
    }
    return tones;
  }

  // ---------- 行内 ----------

  // 一段一段套上格式；相邻同一个标注 / 链接的片段合进同一个元素，标注的底色才是连着的一整块
  function inline(runs, context) {
    let html = "";
    let index = 0;
    while (index < runs.length) {
      const run = runs[index];
      const group = [run];
      while (index + group.length < runs.length) {
        const next = runs[index + group.length];
        if (next.mark !== run.mark || next.link !== run.link) break;
        group.push(next);
      }
      let inner = group.map((piece) => styled(piece, context)).join("");
      if (run.link) inner = `<a href="${escape(run.link)}">${inner}</a>`;
      if (run.mark) inner = `<mark class="mc-mark" data-tone="${context.tones.get(run.mark) ?? 1}" data-mark="${escape(run.mark)}">${inner}</mark>`;
      html += inner;
      index += group.length;
    }
    return html;
  }

  // 高亮底上的字：context.inkOn(底色, 想用的字色) 换成看得清的颜色（src/engine/colors.js 的 readableOn）
  function styled(run, context) {
    // 每段字带着它在原文里的起点（data-s）：卡片上每一行、每个字都能对回原文
    let html = run.source ? `<span data-s="${run.source[0]}">${escape(run.text)}</span>` : escape(run.text);
    if (run.code) html = `<code>${html}</code>`;
    if (run.strike) html = `<del>${html}</del>`;
    if (run.italic) html = `<em>${html}</em>`;
    if (run.bold) html = `<strong>${html}</strong>`;
    if (run.underline) html = `<u class="mc-u" data-style="${run.underline === "dashed" ? "dashed" : "solid"}">${html}</u>`;
    const color = run.color && HEX.test(run.color) ? run.color : null;
    if (run.bg && HEX.test(run.bg)) {
      const ink = context.inkOn?.(run.bg, color) ?? color;
      return `<span class="mc-hl" style="--hl:${run.bg}${ink ? `;color:${ink}` : ""}"${color ? ` data-color="${color}"` : ""}>${html}</span>`;
    }
    if (color) html = `<span style="color:${color}" data-color="${color}">${html}</span>`;
    return html;
  }

  // 原文的每一行一个 span（带原文位置）：拖图片进来时能落在两行之间
  const lines = (list, context) => list.map((line) => `<span class="mc-line"${src(line.source)}>${inline(line.runs, context)}</span>`).join("<br>");

  // ---------- 图片 ----------

  // 在裁剪框里取一块宽高比为 aspect、居中的区域（object-fit: cover）
  function coverCrop(crop, aspect) {
    if (crop.width / crop.height > aspect) {
      const width = crop.height * aspect;
      return { x: crop.x + (crop.width - width) / 2, y: crop.y, width, height: crop.height };
    }
    const height = crop.width / aspect;
    return { x: crop.x, y: crop.y + (crop.height - height) / 2, width: crop.width, height };
  }

  // 图片记录（docs/storage.md）：{ src, width, height, crop, layout, kind }。裁剪用外框 overflow + 放大挪位的图片做。
  // aspect：格子的宽高比固定时（拼图），在裁剪框里居中取这个比例的一块。
  function picture(id, context, aspect = null) {
    const record = context.media[id];
    if (!record) return `<div class="mc-img is-missing"><span>图片不见了</span></div>`;
    const cropped = record.crop ?? { x: 0, y: 0, width: record.width || 1, height: record.height || 1 };
    const crop = aspect ? coverCrop(cropped, aspect) : cropped;
    const w = Math.max(1, crop.width);
    const h = Math.max(1, crop.height);
    const imgStyle = [
      `width:${(record.width / w) * 100}%`,
      `height:${(record.height / h) * 100}%`,
      `left:${(-crop.x / w) * 100}%`,
      `top:${(-crop.y / h) * 100}%`,
    ].join(";");
    const live = record.kind === "live" ? `<span class="mc-live-badge">LIVE</span>` : "";
    return `<div class="mc-img${record.kind === "live" ? " is-live" : ""}" data-image="${escape(id)}" style="aspect-ratio:${w}/${h};--ar:${w / h}">`
      + `<img alt="" data-media="${escape(id)}" style="${imgStyle}">${live}</div>`;
  }

  // 单张图的版式（src/engine/media.js 的 resolveImageLayout）：
  // 宽度按「基准宽」（正文宽与图片最大高折出的宽里小的那个）的百分比，或固定框（按框的比例取景）；左中右对齐
  const layoutOf = (record) => root.MediaCraftEngine.resolveImageLayout(record?.layout);
  const fixedOf = (layout) => (layout.fixedWidth && layout.fixedHeight ? layout : null);

  function figureAttrs(record) {
    const layout = layoutOf(record);
    const fixed = fixedOf(layout);
    const parts = [`--mc-fig-align:${{ left: "flex-start", right: "flex-end" }[layout.align] ?? "center"}`];
    if (fixed) parts.push(`--mc-fixed-w:${fixed.fixedWidth}px`);
    else parts.push(`--mc-fig-pct:${layout.widthPercent ? layout.widthPercent / 100 : layout.widthScale ?? 1}`);
    return `${fixed ? " is-fixed" : ""}" style="${parts.join(";")}`;
  }

  // ---------- 块 ----------

  function block(node, context) {
    switch (node.type) {
      case "heading": {
        const level = Math.min(3, node.level);
        const parts = node.merged ?? [node];
        const content = parts.map((part) => inline(part.runs, context)).join("<br>");
        // 标题文字在原文里从井号后面算（contentSource），整块（含井号）是 data-src
        const text = parts[0].contentSource ? ` data-content-src="${parts[0].contentSource[0]},${parts.at(-1).contentSource[1]}"` : "";
        return `<h${level}${src(node.source)}${text}>${content}</h${level}>`;
      }
      case "paragraph":
        return `<p${src(node.source)}>${lines(node.lines, context)}</p>`;
      case "quote":
        return `<blockquote${src(node.source)}><p>${lines(node.lines, context)}</p></blockquote>`;
      case "list": {
        // 编号照原文写（1. 2. 7.），无序项画圆点；有序、无序可以混在一个列表里。悬挂区按最长的编号放宽
        const tag = node.items[0]?.ordered ? "ol" : "ul";
        const widest = Math.max(0, ...node.items.filter((item) => item.ordered).map((item) => item.marker.length));
        const items = node.items.map((item) => {
          const source = item.markerSource ? [item.markerSource[0], item.source[1]] : item.source;
          const marker = item.ordered ? escape(item.marker) : "";
          return `<li data-marker="${escape(item.marker)}"${src(source)}><span class="mc-marker${item.ordered ? "" : " is-bullet"}" aria-hidden="true">${marker}</span>`
            + `<span class="mc-item">${inline(item.runs, context)}</span></li>`;
        }).join("");
        return `<${tag} class="mc-list" style="--mc-marker-chars:${widest}"${src(node.source)}>${items}</${tag}>`;
      }
      case "code":
        // 每行一个 span：页面结果按行给（空行也算一行）
        return `<pre${src(node.source)}><code>${node.text.split("\n").map((line) => `<span class="mc-code-line">${escape(line)}</span>`).join("\n")}</code></pre>`;
      case "table": {
        const align = (column) => (node.align[column] ? ` style="text-align:${node.align[column]}"` : "");
        const cells = (row, tag) => row.cells.map((cell, column) => `<${tag}${align(column)}>${inline(cell.runs, context)}</${tag}>`).join("");
        const body = node.rows.map((row) => `<tr${src(row.source)}>${cells(row, "td")}</tr>`).join("");
        return `<table${src(node.source)}><thead><tr>${cells(node.header, "th")}</tr></thead><tbody>${body}</tbody></table>`;
      }
      case "rule":
        return `<hr${src(node.source)}>`;
      case "image": {
        const id = node.imageId ?? context.lookup(node.path);
        const fixed = fixedOf(layoutOf(context.media[id]));
        return `<figure class="mc-figure${figureAttrs(context.media[id])}"${src(node.source)}>`
          + `${picture(id, context, fixed ? fixed.fixedWidth / fixed.fixedHeight : null)}</figure>`;
      }
      case "imagePair": {
        // 两格合起来的宽高比 → 每格的（两格等宽、一样高）
        const cell = (Number(context.pairRatio(node.ratio)) || 1) / 2;
        return `<figure class="mc-figure mc-pair" style="--ar:${cell * 2}"${src(node.source)}>`
          + `${picture(node.imageIds[0], context, cell)}${picture(node.imageIds[1], context, cell)}</figure>`;
      }
      case "container":
        return container(node, context);
      default:
        return "";
    }
  }

  // 相邻、中间没有空行的同级标题合成一个多行标题：大标题想在哪里换行，就在哪里另起一行写
  function mergeHeadings(blocks) {
    const merged = [];
    for (const node of blocks) {
      const previous = merged[merged.length - 1];
      if (node.type === "heading" && previous?.type === "heading" && previous.level === node.level && node.blankLinesBefore === 0) {
        const parts = previous.merged ?? [previous];
        merged[merged.length - 1] = { ...previous, source: [previous.source[0], node.source[1]], merged: [...parts, node] };
      } else {
        merged.push(node);
      }
    }
    return merged;
  }

  // ---------- 组件 ----------

  // 名字（中英文都认）→ 渲染。不认识的名字也不报错：渲染成 class="mc-c 名字" 的容器，
  // 这一篇的自定义样式（或 AI 写的样式）可以给它定样子——这是留给自由度的口子。
  // 内置组件的画法（按 id）；名字（中文、英文）、说明与写法在操作手册 src/engine/manual.js
  const manual = root.MediaCraftManual;
  const RENDER = {
    kicker: (node, context) => wrap("p", "mc-kicker", node, flatLines(node, context)),
    mono: (node, context) => wrap("div", "mc-mono", node, children(node, context)),
    rows: (node, context) => rows(node, context),
    note: (node, context) => wrap("div", "mc-note", node, children(node, context)),
    footnote: (node, context) => wrap("p", "mc-footnote", node, flatLines(node, context)),
    steps: (node, context) => steps(node, context),
  };
  const componentOf = (name) => {
    const entry = manual.component(name);
    return entry && RENDER[entry.id] ? { id: entry.id, render: RENDER[entry.id] } : null;
  };

  const children = (node, context) => mergeHeadings(node.blocks).map((child) => block(child, context)).join("");

  // 容器里所有段落的行连成一段（小标签、页尾这种一行两行的小字）
  function flatLines(node, context) {
    return node.blocks.flatMap((child) => child.lines ?? (child.runs ? [child] : child.items ?? [])).map((line) => inline(line.runs, context)).join("<br>");
  }

  // 对齐写成「:::提示 居中」或 align=center（操作手册的 alignOf）
  function wrap(tag, className, node, inner) {
    const variant = node.attrs.variant ? ` data-variant="${escape(node.attrs.variant)}"` : "";
    const aligned = manual.alignOf(node.attrs);
    const align = aligned ? ` data-align="${aligned}"` : "";
    return `<${tag} class="${className}"${variant}${align}${src(node.source)}>${inner}</${tag}>`;
  }

  // 标签列表：每一项开头的 [类别] 是胶囊标签，颜色与同名标注一样
  function rows(node, context) {
    const items = node.blocks.flatMap((child) => child.items ?? []).map((item) => {
      const first = item.runs[0];
      const match = first ? BADGE.exec(first.text) : null;
      const label = match?.[1] ?? "";
      const runs = match ? [{ ...first, text: first.text.slice(match[0].length) }, ...item.runs.slice(1)].filter((run) => run.text) : item.runs;
      const badge = label ? `<span class="mc-badge" data-tone="${context.tones.get(label) ?? 1}">${escape(label)}</span>` : "<span></span>";
      return `<li${src(item.source)}>${badge}<p>${inline(runs, context)}</p></li>`;
    }).join("");
    return wrap("ul", "mc-rows", node, items);
  }

  function steps(node, context) {
    const items = node.blocks.flatMap((child) => child.items ?? child.lines ?? []).map((item, index) =>
      `<li${src(item.source)}><span class="mc-step-no">${String(index + 1).padStart(2, "0")}</span><p>${inline(item.runs, context)}</p></li>`).join("");
    return wrap("ol", "mc-steps", node, items);
  }

  function container(node, context) {
    const component = componentOf(node.name);
    if (component) return component.render(node, context);
    const safe = String(node.name).replace(/[^\w一-鿿-]/g, "");
    return wrap("div", `mc-c c-${safe}`, node, children(node, context));
  }

  // doc：parseMarkdown(…, { containers: true }) 的结果。
  // options：{ media: { 编号: 图片记录 }, lookup(path) → 编号, pairRatio(ratio) → 数, inkOn(底色, 字色) → 高亮底上的字色 }
  // 得到 [{ type, html, source, node }]，分页一块一块放（分页符、结尾页标记也在其中）
  function blocks(doc, options) {
    const context = { media: options.media ?? {}, lookup: options.lookup ?? (() => null), pairRatio: options.pairRatio ?? (() => 1), inkOn: options.inkOn ?? null, tones: collectTones(doc.blocks) };
    return mergeHeadings(doc.blocks).map((node) => ({
      type: node.type === "container" ? `component:${componentOf(node.name)?.id ?? node.name}` : node.type,
      html: node.type === "pageBreak" || node.type === "endPage" ? "" : block(node, context),
      source: node.source,
      node,
    }));
  }

  root.MediaCraftCardHtml = { blocks, escape, picture };
})(globalThis);
