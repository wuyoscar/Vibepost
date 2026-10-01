// 编辑器眼里的稿子结构：每次改动整篇重新解析（src/engine/markdown.js，两万字几毫秒），
// 再摊平成按位置排好的「行内容器」——标题、段落行、引用行、列表项、表格格子——
// 实时预览、格式命令和工具条都从这里查「某个位置是什么块、带哪些格式」。
(() => {
  const { StateField } = window.CodeMirror;
  const { parseMarkdown } = window.MediaCraftEngine;

  const INLINE_FORMATS = ["bold", "italic", "strike", "code", "underline", "color", "bg", "link"];

  function container(entry, block, kind) {
    const [contentFrom, contentTo] = entry.contentSource ?? entry.source;
    return { from: entry.source[0], to: entry.source[1], contentFrom, contentTo, runs: entry.runs, kind, block, entry };
  }

  function containersOf(tree) {
    const list = [];
    for (const block of tree.blocks) {
      if (block.type === "heading") list.push(container(block, block, "heading"));
      else if (block.type === "paragraph" || block.type === "quote") {
        for (const line of block.lines) list.push(container(line, block, block.type));
      } else if (block.type === "list") {
        for (const item of block.items) list.push(container(item, block, "list"));
      } else if (block.type === "table") {
        for (const row of [block.header, ...block.rows]) {
          for (const cell of row.cells) list.push(container(cell, block, "table"));
        }
      }
    }
    return list;
  }

  function analyze(text) {
    const tree = parseMarkdown(text);
    return { tree, containers: containersOf(tree) };
  }

  const syntaxField = StateField.define({
    create: (state) => analyze(state.doc.toString()),
    update: (value, transaction) => (transaction.docChanged ? analyze(transaction.state.doc.toString()) : value),
  });

  // 按起点排好的列表里，最后一个起点不超过 pos 的下标（没有时为 -1）。
  function lastStartingBefore(list, pos, startOf) {
    let low = 0;
    let high = list.length - 1;
    let found = -1;
    while (low <= high) {
      const middle = (low + high) >> 1;
      if (startOf(list[middle]) <= pos) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return found;
  }

  function syntaxOf(state) {
    return state.field(syntaxField);
  }

  // pos 所在的块（块的源码范围含两端）
  function blockAt(state, pos) {
    const { blocks } = syntaxOf(state).tree;
    const index = lastStartingBefore(blocks, pos, (block) => block.source[0]);
    const block = blocks[index];
    return block && pos <= block.source[1] ? block : null;
  }

  // 与 [from, to] 相交的行内容器
  function containersIn(state, from, to) {
    const { containers } = syntaxOf(state);
    const result = [];
    for (let index = Math.max(0, lastStartingBefore(containers, from, (item) => item.from)); index < containers.length; index += 1) {
      const item = containers[index];
      if (item.from > to) break;
      if (item.to >= from) result.push(item);
    }
    return result;
  }

  // 光标所在行的段落样式：h1 / h2 / h3 / ul / ol / quote / paragraph；代码块、表格、图片等为 other。
  function blockStyleAt(state, pos) {
    const line = state.doc.lineAt(pos);
    if (!line.text.trim()) return "paragraph";
    const block = blockAt(state, line.from);
    if (!block) return "paragraph";
    if (block.type === "heading") return `h${Math.min(block.level, 3)}`;
    if (block.type === "quote") return "quote";
    if (block.type === "paragraph") return "paragraph";
    if (block.type === "list") {
      const item = block.items.find((entry) => entry.source[0] <= line.from && line.from <= entry.source[1]);
      return item?.ordered ? "ol" : "ul";
    }
    return "other";
  }

  // 选区里看得见的字共同带着的格式（光标时取光标前一个字，行首取后一个字）。
  function formatsAt(state, from, to) {
    const runs = [];
    for (const item of containersIn(state, from, to)) {
      for (const run of item.runs) {
        const [start, end] = run.source;
        const overlaps = from === to ? start < from && from <= end : start < to && end > from;
        if (overlaps) runs.push(run);
      }
      if (from === to && !runs.length) {
        const next = item.runs.find((run) => run.source[0] === from);
        if (next) runs.push(next);
      }
    }
    if (!runs.length) return {};
    const shared = {};
    for (const key of INLINE_FORMATS) {
      if (runs.every((run) => run[key] && run[key] === runs[0][key])) shared[key] = runs[0][key];
    }
    return shared;
  }

  const editor = window.MediaCraftEditor || (window.MediaCraftEditor = {});
  editor.syntax = { field: syntaxField, of: syntaxOf, blockAt, containersIn, blockStyleAt, formatsAt };
})();
