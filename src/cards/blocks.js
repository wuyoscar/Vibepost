// 卡片上的「一块」在原文里怎么改（ADR 0006 的直接编排）：挪到别处、和上下相邻的一块换位置、删掉、换样式（套成组件、换组件、拆回正文）、
// 改组件的属性。只算 Markdown 文本，调用方一次写进编辑器（撤销历史里是一步）；舞台上的点选、App API 与 AI 的工具都用这一套。
// 一块用它的原文范围 source（[开头, 结尾]，卡片元素的 data-src、render.pages() 里的 source）指认，按整行算。
(function (root) {
  "use strict";

  const PLACEHOLDER = ""; // 挪动时先占住目标位置（私用区的字，稿子里不会有）

  const lineStart = (text, index) => text.lastIndexOf("\n", index - 1) + 1;
  const lineEnd = (text, index) => {
    const next = text.indexOf("\n", index);
    return next === -1 ? text.length : next;
  };

  // 一块占的整行：[from, to)，to 是最后一行的行尾（不含换行）
  function span(text, [start, end]) {
    return { from: lineStart(text, start), to: lineEnd(text, Math.max(start, end - 1)) };
  }

  // 接缝处（at 两侧）连着的换行收成一个空行；在稿子开头或结尾时不留
  function squeeze(text, at) {
    let left = at;
    let right = at;
    while (left > 0 && text[left - 1] === "\n") left -= 1;
    while (right < text.length && text[right] === "\n") right += 1;
    const joint = left === 0 || right === text.length ? "" : "\n\n";
    return text.slice(0, left) + joint + text.slice(right);
  }

  // 顶层的块（组件整个算一块）：{ type, name?, attrs?, source }；分页符、结尾页标记也在里面
  function list(text) {
    return root.MediaCraftEngine.parseMarkdown(text, { containers: true }).blocks
      .map(({ type, name, attrs, source }) => ({ type, ...(name ? { name, attrs: { ...attrs } } : {}), source: [...source] }));
  }

  // source 所在的那一块（按开头落在哪一块里找）
  function blockAt(text, source) {
    return list(text).find((block) => source[0] >= block.source[0] && source[0] < Math.max(block.source[1], block.source[0] + 1)) ?? null;
  }

  function remove(text, source) {
    const { from, to } = span(text, source);
    return squeeze(text.slice(0, from) + text.slice(to), from);
  }

  // 在 at（行首或行尾）插入一块，前后各隔一个空行
  function insertAt(text, at, chunk) {
    const before = text.slice(0, at).replace(/\n*$/, "");
    const after = text.slice(at).replace(/^\n*/, "");
    return `${before}${before ? "\n\n" : ""}${chunk}${after ? "\n\n" : ""}${after}`;
  }

  // 把 source 这块挪到 target 那块之前（after 为真时之后）；挪不动（落在自己身上）时为 null
  function move(text, source, target, after = false) {
    const own = span(text, source);
    const goal = span(text, target);
    if (goal.from >= own.from && goal.to <= own.to) return null;
    const chunk = text.slice(own.from, own.to);
    const at = after ? goal.to : goal.from;
    const marked = text.slice(0, at) + PLACEHOLDER + text.slice(at);
    const shift = at <= own.from ? 1 : 0;
    const without = remove(marked, [source[0] + shift, source[1] + shift]);
    const index = without.indexOf(PLACEHOLDER);
    const next = insertAt(without.slice(0, index) + without.slice(index + 1), index, chunk);
    return next === text ? null : next;
  }

  // 和上一块（direction -1）或下一块（+1）换位置；已经在头尾时为 null
  function shift(text, source, direction) {
    const blocks = list(text);
    const index = blocks.findIndex((block) => source[0] >= block.source[0] && source[0] < Math.max(block.source[1], block.source[0] + 1));
    const neighbor = blocks[index + direction];
    if (index === -1 || !neighbor) return null;
    return move(text, blocks[index].source, neighbor.source, direction > 0);
  }

  // 组件开头一行：:::名字 属性
  function opener(name, attrs = {}) {
    const parts = Object.entries(attrs).filter(([, value]) => value !== null && value !== undefined && value !== false)
      .map(([key, value]) => (value === true ? key : /[\s"]/.test(String(value)) ? `${key}="${String(value).replace(/"/g, "")}"` : `${key}=${value}`));
    return `:::${[name, ...parts].join(" ")}`;
  }

  // 能换成的样式：段落类（正文、标题、引用、组件）与列表类（列表、标签列表、步骤）
  const COMPONENT_STYLES = new Set(["kicker", "note", "footnote", "mono", "rows", "steps"]);
  const STYLES = new Set(["p", "h1", "h2", "h3", "quote", "ul", "ol", ...COMPONENT_STYLES]);
  const HEADING = /^\s{0,3}#{1,6}\s+/;
  const QUOTE = /^\s{0,3}>\s?/;
  const ITEM = /^\s{0,3}(?:[-*+]|\d+[.)])\s+/;

  // 一块去掉样式记号之后的内容行（标题的井号、引用的 >、列表记号、组件的开头与收尾两行）
  function contentLines(text, block, from, to) {
    let lines = text.slice(from, to).split("\n");
    if (block.type === "container") lines = lines.slice(1, -1);
    return lines.map((line) => line.replace(HEADING, "").replace(QUOTE, "").replace(ITEM, ""));
  }

  // 按样式把内容行写回去
  function styled(lines, style, attrs = {}) {
    const filled = lines.filter((line) => line.trim());
    switch (style) {
      case "p": return lines.join("\n");
      case "h1": case "h2": case "h3": return filled.map((line) => `${"#".repeat(Number(style[1]))} ${line}`).join("\n");
      case "quote": return lines.map((line) => (line.trim() ? `> ${line}` : ">")).join("\n");
      case "ul": return filled.map((line) => `- ${line}`).join("\n");
      case "ol": return filled.map((line, index) => `${index + 1}. ${line}`).join("\n");
      case "rows": case "steps": return `${opener(style, attrs)}\n${filled.map((line) => `- ${line}`).join("\n")}\n:::`;
      default: return `${opener(style, attrs)}\n${lines.join("\n")}\n:::`;
    }
  }

  // 给一块换样式（style 见 STYLES）：先去掉原来的记号，再按新样式写回去；组件之间互换时属性（对齐）留着。
  // 舞台上连着的几行标题是一块（src/cards/html.js 合并的），source 覆盖它们。没变化时为 null
  function setStyle(text, source, style) {
    if (!STYLES.has(style)) throw new TypeError(`样式只能是 ${[...STYLES].join(" / ")}`);
    const block = blockAt(text, source);
    if (!block || !["paragraph", "heading", "quote", "list", "container"].includes(block.type)) return null;
    const { from, to } = span(text, [Math.min(block.source[0], source[0]), Math.max(block.source[1], source[1])]);
    const attrs = block.type === "container" && COMPONENT_STYLES.has(style) ? block.attrs : {};
    const next = text.slice(0, from) + styled(contentLines(text, block, from, to), style, attrs) + text.slice(to);
    return next === text ? null : next;
  }

  // 改组件的一个属性（value 为 null 时去掉）；不是组件时为 null
  function setAttr(text, source, key, value) {
    const block = blockAt(text, source);
    if (block?.type !== "container") return null;
    const { from } = span(text, block.source);
    const end = lineEnd(text, from);
    const next = text.slice(0, from) + opener(block.name, { ...block.attrs, [key]: value }) + text.slice(end);
    return next === text ? null : next;
  }

  root.MediaCraftCardBlocks = { list, blockAt, span, remove, move, shift, setStyle, setAttr, insertAt, STYLES };
})(globalThis);
