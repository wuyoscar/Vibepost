// HTML 卡片的页面结果：从排好的一页卡片 DOM 量出来（App API 的 PageSummary 见 docs/app-api.md）——
// 舞台上的图片与实况操作层、胶片的字数与填满、render.pages()、AI 与 MCP 的工具都照常用。
// 坐标是卡片的逻辑像素（864 × 1152）。文字逐行给（按每个字的位置分行）；拖放落点按块给：HTML 卡片只知道每一块在原文里的范围。
(function (root) {
  "use strict";

  const WIDTH = 864;

  const sourceOf = (element) => {
    const value = element.dataset?.contentSrc ?? element.dataset?.src;
    if (!value) return null;
    const [start, end] = value.split(",").map(Number);
    return Number.isFinite(start) && Number.isFinite(end) ? [start, end] : null;
  };
  const countChars = (text) => text.replace(/\s/g, "").length;

  // 这一页里的矩形 → 卡片坐标
  function frameOf(article) {
    const origin = article.getBoundingClientRect();
    const scale = origin.width / WIDTH || 1;
    // 取整：给整数的逻辑像素
    const box = (rect) => ({
      x: Math.round((rect.left - origin.left) / scale),
      y: Math.round((rect.top - origin.top) / scale),
      width: Math.round(rect.width / scale),
      height: Math.round(rect.height / scale),
    });
    return { box, scale };
  }

  // 一行文字的种类：看它在哪种块里
  function blockTypeOf(element, body) {
    for (let node = element; node && node !== body; node = node.parentElement) {
      if (node.tagName === "PRE") return "code";
      if (node.tagName === "BLOCKQUOTE") return "quote";
      if (node.tagName === "LI") return "li";
      if (/^H[1-3]$/.test(node.tagName)) return node.tagName.toLowerCase();
    }
    return "p";
  }

  // 一个字的格式（App API 的 runs 里的那几项）
  function marksOf(element, body) {
    const marks = {};
    for (let node = element; node && node !== body; node = node.parentElement) {
      const tag = node.tagName;
      if (tag === "STRONG") marks.bold = true;
      else if (tag === "EM") marks.italic = true;
      else if (tag === "CODE" && node.parentElement?.tagName !== "PRE") marks.code = true;
      else if (tag === "DEL") marks.strike = true;
      else if (tag === "U") marks.underline = node.dataset.style || "solid";
      else if (tag === "A") marks.link = node.getAttribute("href");
      else if (node.classList?.contains("mc-hl")) marks.bg = node.style.getPropertyValue("--hl").trim();
      if (node.dataset?.color && !marks.color) marks.color = node.dataset.color;
    }
    return marks;
  }

  // 一个文字节点折成的几段：整个节点的 getClientRects 每行一个框，再二分找出每一行从第几个字开始
  function fragmentsOf(node, range) {
    range.selectNodeContents(node);
    const rects = [...range.getClientRects()].filter((rect) => rect.width > 0 || rect.height > 0);
    if (rects.length <= 1) return rects.length ? [{ start: 0, end: node.data.length, rect: rects[0] }] : [];
    const topAt = (offset) => {
      range.setStart(node, offset);
      range.setEnd(node, offset + 1);
      const rect = [...range.getClientRects()].at(-1);
      return rect ? rect.top : -Infinity;
    };
    const starts = [0];
    for (let index = 1; index < rects.length; index += 1) {
      // 第一个顶边比上一行低的字
      const floor = rects[index - 1].top + 1;
      let low = starts[index - 1] + 1;
      let high = node.data.length;
      while (low < high) {
        const middle = (low + high) >> 1;
        if (topAt(middle) > floor) high = middle;
        else low = middle + 1;
      }
      starts.push(Math.min(low, node.data.length));
    }
    return rects.map((rect, index) => ({ start: starts[index], end: starts[index + 1] ?? node.data.length, rect }));
  }

  // 一块里的文字按行分：同一个文字块（段落、列表项、表格格子……）里底边相同的片段是一行
  function textLines(element, body) {
    const lines = [];
    const range = document.createRange();
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    let current = null;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (node.parentElement.closest(".mc-marker")) continue; // 列表的编号另给（marker）
      const block = node.parentElement.closest("p, h1, h2, h3, li, pre, blockquote, td, th, .mc-c, figcaption") ?? element;
      const marks = marksOf(node.parentElement, body);
      const runStart = Number(node.parentElement.dataset.s);
      for (const { start, end, rect } of fragmentsOf(node, range)) {
        const text = node.data.slice(start, end).replace(/\n/g, "");
        const bottom = Math.round(rect.bottom);
        if (!current || current.block !== block || Math.abs(current.bottom - bottom) > 1) {
          current = { block, anchor: node.parentElement, bottom, rects: [], runs: [] };
          lines.push(current);
        }
        current.rects.push(rect);
        if (text) {
          current.runs.push({ text, marks });
          // 这一行在原文里的范围：第一个字到最后一个字（行首行尾的空白不算）
          if (Number.isFinite(runStart)) {
            const lead = text.length - text.trimStart().length;
            const trail = text.length - text.trimEnd().length;
            if (text.trim()) {
              current.from ??= runStart + start + lead;
              current.to = runStart + end - trail;
            }
          }
        }
      }
    }
    return lines;
  }

  // 整行的框：字形的框上下各补半个行距（CSS 的半行距），是整行的高
  function lineBoxes(element, body, frame) {
    return textLines(element, body).filter((line) => line.block.tagName === "PRE" || line.runs.some((run) => run.text.trim())).map((line) => {
      const left = line.rects.reduce((min, rect) => Math.min(min, rect.left), Infinity);
      const top = line.rects.reduce((min, rect) => Math.min(min, rect.top), Infinity);
      const bottom = line.rects.reduce((max, rect) => Math.max(max, rect.bottom), -Infinity);
      const leading = parseFloat(getComputedStyle(line.block).lineHeight) * frame.scale || bottom - top;
      const middle = (top + bottom) / 2;
      const blockRect = line.block.getBoundingClientRect();
      const box = frame.box({ left, top: middle - leading / 2, width: blockRect.right - left, height: leading });
      return { line, box };
    });
  }

  // 代码块：每行一个 span（src/cards/html.js），原样给出（空行、行首空格都留着）；空行接在上一行下面一个行高
  function codeItems(pre, frame, source) {
    const style = getComputedStyle(pre);
    const leading = parseFloat(style.lineHeight) * frame.scale;
    const preRect = pre.getBoundingClientRect();
    let next = preRect.top + (parseFloat(style.paddingTop) + parseFloat(style.borderTopWidth)) * frame.scale;
    return [...pre.querySelectorAll(".mc-code-line")].map((span) => {
      const rect = [...span.getClientRects()].find((each) => each.height > 0);
      const top = rect ? (rect.top + rect.bottom) / 2 - leading / 2 : next;
      next = top + leading;
      const left = rect?.left ?? preRect.left + parseFloat(style.paddingLeft) * frame.scale;
      const box = frame.box({ left, top, width: preRect.right - left, height: leading });
      const text = span.textContent;
      return {
        kind: "text", ...box, source, blockType: "code", text, marker: null,
        fontSize: parseFloat(style.fontSize), pieces: [{ text, marks: {} }],
      };
    });
  }

  // 列表项第一行前面的编号或圆点
  function markerOf(li, first) {
    return first && li.dataset.marker ? li.dataset.marker : null;
  }

  // 引用里单独一个 > 的空行：同一段引用里两行之间空出整行时补上空行（给一行空文字）
  function withBlankLines(boxes) {
    const filled = [];
    for (const entry of boxes) {
      const previous = filled.at(-1);
      if (previous && previous.line.block === entry.line.block && entry.line.block.closest("blockquote")) {
        for (let y = previous.box.y + previous.box.height; y + previous.box.height <= entry.box.y; y += previous.box.height) {
          filled.push({ line: { block: entry.line.block, runs: [] }, box: { ...previous.box, y } });
        }
      }
      filled.push(entry);
    }
    return filled;
  }

  function lineSource(line, li, first) {
    if (line.from === undefined) return null;
    const start = li && first && li.dataset.marker ? sourceOf(li)?.[0] ?? line.from : line.from;
    return [start, line.to];
  }

  function textItems(element, body, frame, source) {
    const seen = new Set();
    return withBlankLines(lineBoxes(element, body, frame)).map(({ line, box }) => {
      const li = line.block.closest("li");
      const first = li ? !seen.has(li) : false;
      if (li) seen.add(li);
      const text = line.runs.map((run) => run.text).join("");
      return {
        kind: "text",
        ...box,
        // 原文位置：这一行的字在原文里的范围；列表项第一行从编号算起；量不出时取往上最近的带位置的元素
        source: lineSource(line, li, first) ?? sourceOf((line.anchor ?? line.block).closest("[data-content-src], [data-src]") ?? element) ?? source,
        blockType: blockTypeOf(line.block, body),
        text,
        marker: li ? markerOf(li, first) : null,
        fontSize: parseFloat(getComputedStyle(line.block).fontSize),
        pieces: line.runs.map((run) => ({ text: run.text, marks: run.marks })),
      };
    });
  }

  function tableItem(table, frame, source) {
    const rows = [...table.rows].map((row) => ({
      header: row.parentElement.tagName === "THEAD",
      height: frame.box(row.getBoundingClientRect()).height,
      cells: [...row.cells].map((cell) => ({ text: cell.textContent })),
    }));
    const columns = rows[0]?.cells.length ?? 0;
    const box = frame.box(table.getBoundingClientRect());
    return { kind: "table", ...box, source, columns, cellWidth: columns ? box.width / columns : 0, rows };
  }

  // 单张图：可缩放的基准宽（100% 时的宽）是正文区宽与图片最大高允许的宽里小的那个
  function imageParts(figure, frame, source, bounds, context) {
    const cell = figure.querySelector(".mc-img");
    const box = frame.box(cell.getBoundingClientRect());
    const imageId = cell.dataset.image ?? null;
    const live = cell.classList.contains("is-live");
    const width = bounds.right - bounds.left;
    const aspect = box.width / (box.height || 1);
    const baseWidth = Math.min(width, (context.imageMaxHeight ?? Infinity) * aspect);
    const radius = context.structure.imageRadius;
    return {
      item: { kind: "image", ...box, source, imageId, live, radius },
      hit: { imageId, live, ...box, baseWidth, maxWidth: width, resizeMaxWidth: baseWidth, radius, source },
    };
  }

  function pairItem(figure, frame, source) {
    const cells = [...figure.querySelectorAll(":scope > .mc-img")].map((cell) => ({
      imageId: cell.dataset.image ?? null,
      ...frame.box(cell.getBoundingClientRect()),
    }));
    // 高按整组比例由宽算，免得宽高各自取整后比例偏了
    const box = frame.box(figure.getBoundingClientRect());
    const ratio = parseFloat(figure.style.getPropertyValue("--ar")) || box.width / (box.height || 1);
    return { kind: "imagePair", ...box, height: Math.round(box.width / ratio), source, imageIds: cells.map((cell) => cell.imageId), cells };
  }

  // 拖放落点：列表逐项、段落与引用逐个原文行（text-line，能落在两行之间），其余整块
  function dropTargetsOf(element, frame, source, box, imageId) {
    const lines = element.matches(".mc-list") ? [...element.children] : element.matches("p, blockquote") ? [...element.querySelectorAll(".mc-line")] : [];
    const targets = lines.map((line) => {
      const rects = [...line.getClientRects()];
      if (!rects.length || !sourceOf(line)) return null;
      const top = Math.min(...rects.map((rect) => rect.top));
      const bottom = Math.max(...rects.map((rect) => rect.bottom));
      const lineBox = frame.box({ left: rects[0].left, top, width: 0, height: bottom - top });
      return { kind: "text-line", imageId: null, y: lineBox.y, height: lineBox.height, source: sourceOf(line) };
    }).filter(Boolean);
    if (targets.length) return targets;
    return source ? [{ kind: "block", imageId, y: box.y, height: box.height, source }] : [];
  }

  // 一块是什么：heading / paragraph / list / quote / code / table / rule，组件是 component 加它的名字
  function blockKind(element) {
    const component = [...element.classList].find((name) => /^mc-(kicker|mono|rows|note|footnote|steps)$/.test(name))?.slice(3)
      ?? [...element.classList].find((name) => name.startsWith("c-"))?.slice(2);
    if (component) return { kind: "component", name: component, align: element.dataset.align ?? "left" };
    const tag = element.tagName;
    if (/^H[1-3]$/.test(tag)) return { kind: "heading", level: Number(tag[1]) };
    if (tag === "UL" || tag === "OL") return { kind: "list", ordered: tag === "OL" };
    return { kind: { P: "paragraph", BLOCKQUOTE: "quote", PRE: "code", TABLE: "table", HR: "rule" }[tag] ?? "block" };
  }

  // article：一页卡片的 .mc-page（已挂进文档、排好）。page：{ index, kind }。context：cards.js 的 context
  // 封面：role cover，正文区是标题所在的区域；标题、副标题逐行（blockType title / subtitle，不在正文里，source 为 null）；
  // 底图的点选框 cover: true（预览里不能拖、缩放，在检查器的「封面」里换）；没有落点、不算填满
  function summarizeCover(article, page, context, frame) {
    const body = article.querySelector(".mc-body");
    const text = article.querySelector(".mc-cover-text");
    const textBox = frame.box(text.getBoundingClientRect());
    const result = {
      index: page.index, first: true, role: "cover", structure: context.look,
      bounds: { left: textBox.x, top: textBox.y, right: textBox.x + textBox.width, bottom: textBox.y + textBox.height },
      items: [], imageHits: [], dropTargets: [], blocks: [], live: false, fill: null, chars: 0,
    };
    const cell = article.querySelector(".mc-cover-image .mc-img[data-image]");
    if (cell) {
      const box = frame.box(cell.getBoundingClientRect());
      const imageId = cell.dataset.image;
      const live = cell.classList.contains("is-live");
      const radius = parseFloat(getComputedStyle(cell).borderTopLeftRadius) || 0;
      result.items.push({ kind: "image", ...box, source: null, imageId, live, radius });
      result.imageHits.push({ imageId, live, ...box, baseWidth: box.width, maxWidth: box.width, resizeMaxWidth: box.width, radius, source: null, cover: true });
      result.live = live;
    }
    for (const [selector, blockType] of [[".mc-cover-title", "title"], [".mc-cover-subtitle", "subtitle"]]) {
      const element = article.querySelector(selector);
      if (!element) continue;
      for (const { line, box } of lineBoxes(element, body, frame)) {
        const textOf = line.runs.map((run) => run.text).join("");
        result.items.push({
          kind: "text", ...box, source: null, blockType, text: textOf, marker: null,
          fontSize: parseFloat(getComputedStyle(element).fontSize), pieces: line.runs.map((run) => ({ text: run.text, marks: {} })),
        });
        result.chars += countChars(textOf);
      }
    }
    return result;
  }

  function summarize(article, page, context) {
    const frame = frameOf(article);
    if (page.kind === "cover") return summarizeCover(article, page, context, frame);
    const body = article.querySelector(".mc-body");
    const bodyBox = frame.box(body.getBoundingClientRect());
    const bounds = { left: bodyBox.x, top: bodyBox.y, right: bodyBox.x + bodyBox.width, bottom: bodyBox.y + bodyBox.height };
    const role = page.kind === "end" ? "end" : "body";
    const result = {
      index: page.index,
      first: page.index === 0 && role === "body",
      role,
      structure: context.look,
      bounds,
      items: [],
      imageHits: [],
      dropTargets: [],
      blocks: [], // 能在卡片上点选、挪动的块（图片另有 imageHits）：{ kind, name, source, x, y, width, height }
      live: false,
      fill: 0,
      chars: 0,
    };
    let lowest = bounds.top;
    result.signature = Boolean(body.querySelector(":scope > .mc-signature"));
    for (const element of body.children) {
      if (element.hasAttribute("data-chrome")) continue;
      const source = sourceOf(element);
      const box = frame.box(element.getBoundingClientRect());
      lowest = Math.max(lowest, box.y + box.height);
      let imageId = null;
      if (element.matches("figure.mc-pair")) {
        result.items.push(pairItem(element, frame, source));
      } else if (element.matches("figure.mc-figure") && element.querySelector(".mc-img[data-image]")) {
        const { item, hit } = imageParts(element, frame, source, bounds, context);
        result.items.push(item);
        result.imageHits.push(hit);
        imageId = hit.imageId;
      } else if (element.tagName === "HR") {
        result.items.push({ kind: "rule", ...box, source });
      } else if (element.tagName === "TABLE") {
        result.items.push(tableItem(element, frame, source));
      } else {
        if (element.tagName === "PRE") {
          result.items.push({ kind: "code", ...box, source }, ...codeItems(element, frame, source));
        } else {
          if (element.tagName === "BLOCKQUOTE") result.items.push({ kind: "quote", ...box, source });
          result.items.push(...textItems(element, body, frame, source));
        }
      }
      result.dropTargets.push(...dropTargetsOf(element, frame, source, box, imageId));
      const blockSource = element.dataset.src ? sourceOf({ dataset: { src: element.dataset.src } }) : null;
      if (blockSource && !element.matches("figure")) result.blocks.push({ ...blockKind(element), source: blockSource, ...box });
    }
    result.live = result.imageHits.some((hit) => hit.live);
    result.fill = Math.min(1, Math.max(0, (lowest - bounds.top) / (bounds.bottom - bounds.top || 1)));
    result.chars = result.items.reduce((sum, item) => {
      if (item.kind === "text") return sum + countChars(item.text);
      if (item.kind === "table") return sum + item.rows.reduce((total, row) => total + row.cells.reduce((cells, cell) => cells + countChars(cell.text), 0), 0);
      return sum;
    }, 0);
    return result;
  }

  root.MediaCraftCardSummary = { summarize };
})(globalThis);
