// 图片在正文里的位置：删掉一张图、插到某一行之前或之后、挪到别处、两张拼成一组、改写拼图。
// 只算 Markdown 文本（写法见 docs/markdown-syntax.md），调用方把结果一次写进编辑器，撤销历史里是一步。
(() => {
  const { EditorState } = window.CodeMirror;
  const { commands } = window.MediaCraftEditor;

  const docOf = (text) => EditorState.create({ doc: text }).doc;

  // [[image:甲]]、[[image:甲|乙]]、[[image:甲|乙|4x3]]
  function imageTag(ids, ratio = null) {
    return `[[image:${ids.join("|")}${ratio ? `|${ratio}` : ""}]]`;
  }

  // 一块图片源码里标记本身的范围（块的源码含行首缩进）
  function tagRange(text, [start, end]) {
    const open = text.indexOf("[[", start);
    const close = text.lastIndexOf("]]", end);
    return open === -1 || close < open || close + 2 > end ? { from: start, to: end } : { from: open, to: close + 2 };
  }

  // 这块图片是否独占一行（拼图只能写在单独的一行）
  function standsAlone(text, source) {
    const doc = docOf(text);
    const line = doc.lineAt(source[0]);
    const { from, to } = tagRange(text, source);
    return !doc.sliceString(line.from, from).trim() && !doc.sliceString(to, line.to).trim();
  }

  // 拿掉一块图片时要删的范围：独占一行就删整行；上下都是空行（或稿子的头尾）时顺带删掉一个空行，
  // 免得删一次多一段空白。和文字写在同一行时只删标记本身。
  function removalRange(text, source) {
    const doc = docOf(text);
    const line = doc.lineAt(source[0]);
    const tag = tagRange(text, source);
    if (doc.sliceString(line.from, tag.from).trim() || doc.sliceString(tag.to, line.to).trim()) return tag;
    const blank = (number) => number >= 1 && number <= doc.lines && !doc.line(number).text.trim();
    let first = line.number;
    let last = line.number;
    const openAbove = first === 1 || blank(first - 1);
    const openBelow = last === doc.lines || blank(last + 1);
    if (openAbove && openBelow) {
      if (blank(last + 1)) last += 1;
      else if (blank(first - 1)) first -= 1;
    }
    if (last < doc.lines) return { from: doc.line(first).from, to: doc.line(last + 1).from };
    if (first > 1) return { from: doc.line(first - 1).to, to: doc.line(last).to };
    return { from: 0, to: doc.length };
  }

  function remove(text, source) {
    const { from, to } = removalRange(text, source);
    return text.slice(0, from) + text.slice(to);
  }

  // 在 at 处插入独占整行的 block（规则同编辑器的插入整行），返回 { text, caret }
  function insertBlock(text, at, block) {
    const state = EditorState.create({ doc: text });
    const { changes, caret } = commands.blockInsertion(state, block, Math.min(Math.max(0, at), text.length));
    return { text: text.slice(0, changes.from) + changes.insert + text.slice(changes.from), caret };
  }

  // 排版给出的落点（render.pages() 的 dropTargets 里的一项）→ 插入位置：
  // 之前是它第一行的行首，之后是它最后一行的行尾。
  function dropPosition(text, target, after) {
    const doc = docOf(text);
    const [start, end] = target.source;
    return after ? doc.lineAt(Math.max(start, end - 1)).to : doc.lineAt(start).from;
  }

  // 把 source 处的图片（或拼图）挪到 at：先拿掉，再按拿掉之后的正文插回去。落在自己身上或没变化时返回 null。
  function move(text, source, at) {
    const removal = removalRange(text, source);
    if (at > removal.from && at < removal.to) return null;
    const range = tagRange(text, source);
    const tag = text.slice(range.from, range.to);
    const shifted = at >= removal.to ? at - (removal.to - removal.from) : at;
    const next = insertBlock(text.slice(0, removal.from) + text.slice(removal.to), shifted, tag).text;
    return next === text ? null : next;
  }

  // 把拖着的单张图放到目标图旁边拼成一组（side：放在目标的 left / right），目标必须独占一行。
  function pairUp(text, dragged, target, side) {
    if (!standsAlone(text, target.source)) return null;
    const ids = side === "left" ? [dragged.id, target.id] : [target.id, dragged.id];
    const replace = tagRange(text, target.source);
    const removal = removalRange(text, dragged.source);
    if (removal.from < replace.to && replace.from < removal.to) return null;
    const edits = [
      { ...replace, insert: imageTag(ids) },
      { ...removal, insert: "" },
    ].sort((a, b) => b.from - a.from);
    return edits.reduce((result, edit) => result.slice(0, edit.from) + edit.insert + result.slice(edit.to), text);
  }

  // 拼图标记写的比例（第三段原文，如 "4x3"），没写为 null
  function pairRatio(text, source) {
    const { from, to } = tagRange(text, source);
    return /^\[\[image:[^|\]]+\|[^|\]]+\|([^|\]]+)\]\]$/.exec(text.slice(from, to))?.[1] ?? null;
  }

  // 把 source 处的图片标记换成 lines（一行或几行标记）
  function replaceTag(text, source, lines) {
    const { from, to } = tagRange(text, source);
    return text.slice(0, from) + lines.join("\n") + text.slice(to);
  }

  window.MediaCraftMedia = window.MediaCraftMedia || {};
  window.MediaCraftMedia.placement = {
    imageTag, tagRange, remove, dropPosition, move, pairUp, pairRatio, replaceTag,
  };
})();
