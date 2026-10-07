// 编辑命令：段落样式、行内格式、颜色、链接、插入整行的块与片段、回车续写列表。
// 只改 Markdown 文本（写法见 docs/markdown-syntax.md）；每条命令是撤销历史里单独的一步。
(() => {
  const { EditorSelection, isolateHistory } = window.CodeMirror;
  const { syntax } = window.MediaCraftEditor;

  const PAGE_BREAK = "[[分页]]";
  const END_PAGE = "[[结尾]]";
  // 行首的段落标记（缩进 + 标题 / 列表 / 引用标记）：换段落样式时整个换掉
  const LINE_MARKER = /^([ \t]*)(?:#{1,6}[ \t]+|[-*+][ \t]+|\d+[.)][ \t]+|>(?: |$))?/;
  const RULE_LINE = /^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
  const ORDERED_ITEM = /^[ \t]*(\d+)[.)][ \t]+\S/;
  const BLOCK_MARKERS = { h1: "# ", h2: "## ", h3: "### ", ul: "- ", quote: "> ", paragraph: "" };

  // ===== 行内格式的标记：怎么包、隐藏的标记里哪一段是它的开头 / 收尾 =====

  function findAll(pattern, text) {
    return [...text.matchAll(pattern)].map((match) => [match.index, match.index + match[0].length]);
  }

  const lastOf = (pattern) => (text) => findAll(pattern, text).at(-1) ?? null;
  const firstOf = (pattern) => (text) => findAll(pattern, text)[0] ?? null;
  const contains = (pattern) => (text) => findAll(pattern, text).length > 0;

  // 星号串：** 是加粗、* 是斜体，*** 两者都有；从串里摘掉属于这个格式的那几个星号。
  function stars(count) {
    const fits = ([start, end]) => (count === 2 ? end - start >= 2 : (end - start) % 2 === 1);
    const runs = (text) => findAll(/\*+/g, text).filter(fits);
    return {
      opener: (text) => {
        const run = runs(text).at(-1);
        return run ? [run[1] - count, run[1]] : null;
      },
      closer: (text) => {
        const run = runs(text)[0];
        return run ? [run[0], run[0] + count] : null;
      },
      splits: (text) => runs(text).length > 0,
    };
  }

  // 链接收尾「](网址 "标题")」：圆括号成对
  function linkCloser(text) {
    const start = text.indexOf("](");
    if (start === -1) return null;
    let depth = 0;
    let quote = "";
    for (let index = start + 2; index < text.length; index += 1) {
      const char = text[index];
      if (quote) {
        if (char === quote) quote = "";
      } else if (char === '"' || char === "'") {
        quote = char;
      } else if (char === "(") {
        depth += 1;
      } else if (char === ")") {
        if (depth === 0) return [start, index + 1];
        depth -= 1;
      }
    }
    return null;
  }

  // {{字色:…| 这类开头：中文、英文写法都认（操作手册 src/engine/manual.js 的词表），冒号也认全角的
  const span = (id) => {
    const word = `(?:${window.MediaCraftManual.markerWords[id].join("|")})[:：]`;
    return {
      opener: lastOf(new RegExp(`\\{\\{${word}[^|{}]+\\|`, "g")),
      closer: firstOf(/\}\}/g),
      splits: contains(new RegExp(`\\{\\{${word}`, "g")),
    };
  };

  const FORMATS = {
    bold: { open: "**", close: "**", ...stars(2) },
    italic: { open: "*", close: "*", ...stars(1) },
    strike: { open: "~~", close: "~~", opener: lastOf(/~~/g), closer: firstOf(/~~/g), splits: contains(/~~/g) },
    code: { open: "`", close: "`", opener: lastOf(/`+/g), closer: firstOf(/`+/g), splits: contains(/`/g) },
    underline: { open: window.MediaCraftManual.spanOpener("underline", "solid"), close: "}}", ...span("underline") },
    color: span("color"),
    bg: span("bg"),
    link: { opener: lastOf(/\[/g), closer: linkCloser, splits: contains(/\[|\]\(/g) },
  };

  // 一个行内容器里带着某个格式的连续片段，以及包着它的开头、收尾标记的位置。
  function formatSpans(state, item, key) {
    const format = FORMATS[key];
    const { runs } = item;
    const spans = [];
    for (let first = 0; first < runs.length;) {
      if (!runs[first][key]) {
        first += 1;
        continue;
      }
      let last = first;
      while (last + 1 < runs.length && runs[last + 1][key]
        && !format.splits(state.sliceDoc(runs[last].source[1], runs[last + 1].source[0]))) last += 1;
      const from = runs[first].source[0];
      const to = runs[last].source[1];
      const before = first > 0 ? runs[first - 1].source[1] : item.contentFrom;
      const after = last + 1 < runs.length ? runs[last + 1].source[0] : item.contentTo;
      const open = format.opener(state.sliceDoc(before, from));
      const close = format.closer(state.sliceDoc(to, after));
      if (open && close) spans.push({ from, to, open: [before + open[0], before + open[1]], close: [to + close[0], to + close[1]] });
      first = last + 1;
    }
    return spans;
  }

  function spansAround(state, segment, key) {
    return syntax.containersIn(state, segment.from, segment.to)
      .flatMap((item) => formatSpans(state, item, key))
      .filter((found) => (segment.from === segment.to
        ? found.from <= segment.from && segment.to <= found.to
        : found.from < segment.to && found.to > segment.from));
  }

  const unwrap = (found) => [{ from: found.open[0], to: found.open[1] }, { from: found.close[0], to: found.close[1] }];

  // ===== 选区与行 =====

  function edit(view, spec, userEvent = "input.format") {
    if (view.state.readOnly) return false;
    view.dispatch({ ...spec, userEvent, annotations: isolateHistory.of("full"), scrollIntoView: true });
    return true;
  }

  function contentStart(line) {
    return line.from + LINE_MARKER.exec(line.text)[0].length;
  }

  // 选区碰到的行（选到下一行行首不算那一行）
  function selectedLines(state) {
    const { from, to } = state.selection.main;
    const first = state.doc.lineAt(from).number;
    let last = state.doc.lineAt(to).number;
    if (to > from && to === state.doc.line(last).from && last > first) last -= 1;
    return Array.from({ length: last - first + 1 }, (_, index) => state.doc.line(first + index));
  }

  // 选区按行切成要加格式的片段：去掉段落标记与两端空白；光标时是光标处一个空片段。
  function targetSegments(state) {
    const { from, to } = state.selection.main;
    if (from === to) return [{ from, to }];
    const segments = [];
    for (const line of selectedLines(state)) {
      let start = Math.max(from, contentStart(line));
      let end = Math.min(to, line.to);
      while (start < end && /\s/.test(state.sliceDoc(start, start + 1))) start += 1;
      while (end > start && /\s/.test(state.sliceDoc(end - 1, end))) end -= 1;
      if (start < end) segments.push({ from: start, to: end });
    }
    return segments;
  }

  function cursor(pos) {
    return EditorSelection.cursor(pos);
  }

  // ===== 段落样式 =====

  function nextOrderedNumber(state, line) {
    for (let number = line.number - 1; number >= 1; number -= 1) {
      const text = state.doc.line(number).text;
      if (!text.trim()) continue;
      const match = ORDERED_ITEM.exec(text);
      return match ? Number(match[1]) + 1 : 1;
    }
    return 1;
  }

  // 大标题 / 小标题 / 三级标题 / 正文 / 无序列表 / 有序列表 / 引用：替换原来的标记而不叠加；
  // 选中的行都已经是这种样式时，再点一次回到正文。有序列表接着上一行的编号往下数。
  function setBlockStyle(view, style) {
    const { state } = view;
    const lines = selectedLines(state).filter((line) => line.text.trim() && !RULE_LINE.test(line.text));
    if (!lines.length) {
      const line = state.doc.lineAt(state.selection.main.head);
      if (style === "paragraph" || line.text.trim()) return false;
      const insert = style === "ol" ? `${nextOrderedNumber(state, line)}. ` : BLOCK_MARKERS[style];
      return edit(view, { changes: { from: line.from, to: line.to, insert }, selection: cursor(line.from + insert.length) });
    }
    const current = lines.map((line) => syntax.blockStyleAt(state, line.from));
    const target = style !== "paragraph" && current.every((each) => each === style) ? "paragraph" : style;
    let number = target === "ol" ? nextOrderedNumber(state, lines[0]) : 0;
    const changes = state.changes(lines.map((line) => {
      const [marker, indent] = LINE_MARKER.exec(line.text);
      const insert = target === "ol" ? `${number++}. ` : BLOCK_MARKERS[target];
      return { from: line.from + indent.length, to: line.from + marker.length, insert };
    }));
    return edit(view, { changes, selection: state.selection.map(changes, 1) });
  }

  // ===== 行内格式 =====

  // 选区外包一层标记；与它相交的同类格式先拆掉，并进这一层。选区留在新标记里面。
  function wrapSegments(state, segments, key, open, close) {
    const changes = [];
    const wrapped = [];
    for (const segment of segments) {
      let { from, to } = segment;
      for (const found of spansAround(state, segment, key)) {
        changes.push(...unwrap(found));
        from = Math.min(from, found.from);
        to = Math.max(to, found.to);
      }
      changes.push({ from, insert: open }, { from: to, insert: close });
      wrapped.push([from, to]);
    }
    const set = state.changes(changes);
    const selection = EditorSelection.range(set.mapPos(wrapped[0][0], 1), set.mapPos(wrapped.at(-1)[1], -1));
    return { changes: set, selection };
  }

  function removeFormat(state, segments, key) {
    const seen = new Set();
    const changes = [];
    for (const segment of segments) {
      for (const found of spansAround(state, segment, key)) {
        if (seen.has(found.open[0])) continue;
        seen.add(found.open[0]);
        changes.push(...unwrap(found));
      }
    }
    if (!changes.length) return null;
    const set = state.changes(changes);
    return { changes: set, selection: state.selection.map(set) };
  }

  // 加粗 / 斜体 / 删除线 / 行内代码 / 下划线：选中的字都已经有这个格式就去掉，否则加上。
  // 只有光标时：在格式里面就去掉这一段的格式，否则插入一对标记、光标放在中间。
  function toggleInline(view, key) {
    const { state } = view;
    const { open, close } = FORMATS[key];
    const segments = targetSegments(state);
    if (!segments.length) return false;
    const active = segments.every((segment) => syntax.formatsAt(state, segment.from, segment.to)[key]);
    if (active) {
      const removal = removeFormat(state, segments, key);
      return removal ? edit(view, removal) : false;
    }
    if (state.selection.main.empty) {
      const { from } = state.selection.main;
      return edit(view, { changes: { from, insert: open + close }, selection: cursor(from + open.length) });
    }
    return edit(view, wrapSegments(state, segments, key, open, close));
  }

  // 文字颜色 / 高亮底色：value 为 null 时去掉。刚好选中一段已上色的字时只换色值；
  // 选区落在一段颜色里面时套一层（里层优先）；其余情况把相交的同类颜色并成一层。
  function setInlineColor(view, kind, value) {
    const { state } = view;
    const segments = targetSegments(state);
    if (value === null) {
      const removal = removeFormat(state, segments, kind);
      return removal ? edit(view, removal) : false;
    }
    if (state.selection.main.empty) return false;
    const opener = window.MediaCraftManual.spanOpener(kind, value);
    const [segment] = segments;
    const spans = segments.length === 1 ? spansAround(state, segment, kind) : [];
    if (spans.length === 1 && spans[0].from === segment.from && spans[0].to === segment.to) {
      const [found] = spans;
      return edit(view, { changes: { from: found.open[0], to: found.open[1], insert: opener }, selection: state.selection });
    }
    if (spans.length === 1 && spans[0].from < segment.from && segment.to < spans[0].to) {
      const set = state.changes([{ from: segment.from, insert: opener }, { from: segment.to, insert: "}}" }]);
      return edit(view, { changes: set, selection: EditorSelection.range(set.mapPos(segment.from, 1), set.mapPos(segment.to, -1)) });
    }
    return edit(view, wrapSegments(state, segments, kind, opener, "}}"));
  }

  // ⌘K：在链接里就去掉链接（留下文字）；选中文字时包成 [文字]()，光标放进网址的括号里。
  function toggleLink(view) {
    const { state } = view;
    const segments = targetSegments(state);
    const removal = removeFormat(state, segments.slice(0, 1), "link");
    if (removal) return edit(view, removal);
    const { from, empty } = state.selection.main;
    if (empty) return edit(view, { changes: { from, insert: "[]()" }, selection: cursor(from + 1) });
    const [segment] = segments;
    if (!segment) return false;
    const set = state.changes([{ from: segment.from, insert: "[" }, { from: segment.to, insert: "]()" }]);
    return edit(view, { changes: set, selection: cursor(segment.to + 3) });
  }

  // ===== 插入整行的块 =====

  // 在 at 处插入独占整行的内容：不在行首就先换行，后面还有字就再换行；光标停在它下一行的开头。
  function blockInsertion(state, text, at) {
    const line = state.doc.lineAt(at);
    const prefix = at > line.from ? "\n" : "";
    const start = at + prefix.length;
    if (at === line.to && line.number < state.doc.lines) {
      return { changes: { from: at, insert: prefix + text }, start, caret: start + text.length + 1 };
    }
    const insert = `${prefix}${text}\n`;
    return { changes: { from: at, insert }, start, caret: at + insert.length };
  }

  function insertBlock(view, text, at = view.state.selection.main.head, userEvent = "input.insert") {
    const { changes, caret } = blockInsertion(view.state, text, at);
    return edit(view, { changes, selection: cursor(caret) }, userEvent);
  }

  // 分割线插在光标所在行之后，前后各空一行；光标行是空行时就写在这一行。
  function insertDivider(view) {
    const { state } = view;
    const line = state.doc.lineAt(state.selection.main.head);
    const hasNext = line.number < state.doc.lines;
    if (!line.text.trim()) {
      const insert = hasNext ? "---" : "---\n";
      return edit(view, { changes: { from: line.from, to: line.to, insert }, selection: cursor(line.from + 4) }, "input.insert");
    }
    const insert = "\n\n---\n";
    return edit(view, { changes: { from: line.to, insert }, selection: cursor(line.to + insert.length + (hasNext ? 1 : 0)) }, "input.insert");
  }

  function insertCodeBlock(view) {
    const { changes, start } = blockInsertion(view.state, "```\n\n```", view.state.selection.main.head);
    return edit(view, { changes, selection: cursor(start + 4) }, "input.insert");
  }

  // 组件（HTML 卡片，docs/markdown-syntax.md）：单独一行 :::名字 … 单独一行 :::，光标停在中间；body 是预先填好的一行
  function insertComponent(view, name, body = "") {
    const { changes, start } = blockInsertion(view.state, `:::${name}\n${body}\n:::`, view.state.selection.main.head);
    return edit(view, { changes, selection: cursor(start + name.length + 4 + body.length) }, "input.insert");
  }

  // 片段（src/engine/snippets.js 登记表里的 markdown，或任何一段 Markdown）：整段插在光标处，前后隔开空行、首尾多余的 [[分页]] 去掉
  // （规则都在 MediaCraftSnippets.insert）；一步历史，光标停在片段末尾。插不进去（结尾引导不在末尾、已有结尾页）时抛出说明，由调用方提示。
  function insertSnippet(view, markdown, at = view.state.selection.main.head) {
    if (view.state.readOnly) return false;
    const { change, end } = window.MediaCraftSnippets.insert(view.state.doc.toString(), at, markdown);
    if (!change) return false;
    return edit(view, { changes: change, selection: cursor(end) }, "input.insert");
  }

  // ===== 回车 =====

  // 列表项、引用行里回车：下一行接着写同样的标记（编号加一）；空着的列表项回车就结束列表。
  function continueMarkup(view) {
    const { state } = view;
    const range = state.selection.main;
    if (!range.empty || state.readOnly) return false;
    const line = state.doc.lineAt(range.head);
    if (syntax.blockAt(state, line.from)?.type === "code") return false;
    let marker = null;
    const list = /^([ \t]*)(?:([-*+])|(\d+)([.)]))([ \t]+)/.exec(line.text);
    if (list && !RULE_LINE.test(line.text)) {
      const next = list[2] ?? `${String(Number(list[3]) + 1).padStart(list[3].length, "0")}${list[4]}`;
      marker = { length: list[0].length, next: `${list[1]}${next}${list[5]}` };
    } else {
      const quote = /^([ \t]*)>(?: |$)/.exec(line.text);
      if (quote) marker = { length: quote[0].length, next: `${quote[1]}> ` };
    }
    if (!marker || range.head < line.from + marker.length) return false;
    if (!line.text.slice(marker.length).trim()) {
      return edit(view, { changes: { from: line.from, to: line.to }, selection: cursor(line.from) }, "input");
    }
    const insert = `\n${marker.next}`;
    return edit(view, { changes: { from: range.head, insert }, selection: cursor(range.head + insert.length) }, "input");
  }

  window.MediaCraftEditor.commands = {
    setBlockStyle,
    toggleInline,
    setInlineColor,
    toggleLink,
    insertPageBreak: (view) => insertBlock(view, PAGE_BREAK),
    insertEndPage: (view) => insertBlock(view, END_PAGE),
    insertDivider,
    insertCodeBlock,
    insertComponent,
    insertSnippet,
    continueMarkup,
    blockInsertion,
  };
})();
