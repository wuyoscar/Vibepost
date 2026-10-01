// MediaCraft Markdown 解析器：把稿子解析成「块 + 行内片段」的语法树，每个节点都带源码位置。
// 纯函数、不碰 DOM，每次按键都会整篇重新解析（稿子通常不超过两万字）。
// 语法说明见 docs/markdown-syntax.md；页面里通过 window.mediacraft.engine.parse 对外提供。
//
// 方言要点（与通用 Markdown 不同的地方）：
// - 以行为单位：正文里每一行都是硬换行；列表项只占一行，缩进不产生嵌套；
// - 行内格式（加粗、颜色、链接……）不跨行，光标所在行露出标记时不会牵连别的行；
// - 自有语法：[[image:编号]] 图片、[[image:甲|乙|比例]] 拼图、[[分页]]、[[结尾]]、{{color|bg|underline|mark:…|文字}}，
//   组件容器「:::名字 属性」…「:::」（默认摊开成里面的块；HTML 卡片要容器时传 { containers: true }）。
(function (root) {
  "use strict";

  const PAGE_BREAK = "[[分页]]";
  const END_PAGE = "[[结尾]]";
  const IMAGE_ID = "[A-Za-z0-9_-]+";
  const WHOLE_IMAGE = new RegExp(`^\\[\\[image:(${IMAGE_ID})\\]\\]$`);
  const WHOLE_PAIR = new RegExp(`^\\[\\[image:(${IMAGE_ID})\\|(${IMAGE_ID})(?:\\|(${IMAGE_ID}))?\\]\\]$`);
  const INLINE_IMAGE = new RegExp(`\\[\\[image:(${IMAGE_ID})\\]\\]`, "y");
  const MARKDOWN_IMAGE = /^!\[([^\]]*)\]\(([^\s)]+)(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)$/;
  const FENCE_OPEN = /^(`{3,})([^`]*)$/;
  const RULE = /^([-*_])(?:[ \t]*\1){2,}$/;
  const HEADING = /^(#{1,6})[ \t]+/;
  const LIST_ITEM = /^([-*+]|(\d+)[.)])[ \t]+/;
  const TABLE_DELIMITER = /^:?-{3,}:?$/;
  const SPAN_OPEN = /\{\{(?:(color|bg):(#[0-9a-fA-F]{3,8})|(underline):(solid|dashed)|(mark):([^|{}\s]{1,24}))\|/y;
  // 组件容器：「:::名字 属性」开头，单独一行「:::」收尾（ADR 0006）
  const CONTAINER_OPEN = /^:::[ \t]*([^\s:]+)(?:[ \t]+(.*))?$/;
  const CONTAINER_CLOSE = /^:::$/;
  const LINK_TARGET = /^(?:https?:|mailto:)/i;
  const MARK_KEYS = ["bold", "italic", "strike", "code", "color", "bg", "underline", "link", "mark"];

  // 与 JS 正则 \s 相同的空白（含全角空格、不换行空格）
  function isSpace(code) {
    return code === 32 || (code >= 9 && code <= 13) || code === 0xa0 || code === 0x1680
      || (code >= 0x2000 && code <= 0x200a) || code === 0x2028 || code === 0x2029
      || code === 0x202f || code === 0x205f || code === 0x3000 || code === 0xfeff;
  }

  function trimStart(src, start, end) {
    while (start < end && isSpace(src.charCodeAt(start))) start += 1;
    return start;
  }

  function trimEnd(src, start, end) {
    while (end > start && isSpace(src.charCodeAt(end - 1))) end -= 1;
    return end;
  }

  // 按 \n 切行；行尾的 \r 不算内容。
  function splitLines(src) {
    const lines = [];
    let start = 0;
    for (;;) {
      const newline = src.indexOf("\n", start);
      const stop = newline === -1 ? src.length : newline;
      const end = stop > start && src.charCodeAt(stop - 1) === 13 ? stop - 1 : stop;
      const contentStart = trimStart(src, start, end);
      const contentEnd = trimEnd(src, contentStart, end);
      lines.push({ start, end, contentStart, contentEnd, text: src.slice(contentStart, contentEnd) });
      if (newline === -1) return lines;
      start = newline + 1;
    }
  }

  // ===== 行内 =====

  // 一段行内文字切成记号：文字、行内代码、* 定界符、~~、{{…| 与 }}、[ 与 ](网址)、行内图片。
  function tokenize(src, start, end) {
    const tokens = [];
    const scanner = { src, start, end, ticks: backtickRuns(src, start, end), tick: 0 };
    let textStart = start;
    let i = start;
    while (i < end) {
      const found = scanAt(scanner, i);
      if (!found) {
        i += 1;
        continue;
      }
      const { token } = found;
      if (token) {
        if (token.s > textStart) tokens.push({ t: "text", s: textStart, e: token.s });
        tokens.push(token);
        textStart = token.e;
      }
      i = found.next;
    }
    if (end > textStart) tokens.push({ t: "text", s: textStart, e: end });
    return tokens;
  }

  // 第 i 个字符起的记号：{ token, next }（token 为 null 时这一串按原文显示，从 next 接着看）；不是记号的开头时为 null。
  function scanAt(scanner, i) {
    const { src, end } = scanner;
    const code = src.charCodeAt(i);
    if (code === 96) return scanCode(scanner, i); // `
    if (code === 42) return scanStars(scanner, i); // *
    if (code === 126) return scanTildes(scanner, i); // ~
    if (code === 123 && src.charCodeAt(i + 1) === 123) return scanSpanOpen(scanner, i); // {{
    if (code === 125 && src.charCodeAt(i + 1) === 125 && i + 2 <= end) return { token: { t: "spanClose", s: i, e: i + 2 }, next: i + 2 }; // }}
    if (code === 91) return scanBracket(scanner, i); // [
    if (code === 93) return scanBracketClose(scanner, i); // ]
    return null;
  }

  const shownAsText = (next) => ({ token: null, next });

  // 连着的同一个字符（* 或 ~）到哪里为止
  function runEnd(src, i, end, code) {
    let j = i;
    while (j < end && src.charCodeAt(j) === code) j += 1;
    return j;
  }

  // 反引号串：和它之后第一个等长的串配成行内代码；没有配对的按原文显示
  function scanCode(scanner, i) {
    const { runs, next } = scanner.ticks;
    while (runs[scanner.tick].s < i) scanner.tick += 1;
    const run = runs[scanner.tick];
    const closer = next[scanner.tick];
    if (!closer) return shownAsText(run.e);
    return { token: { t: "code", s: i, e: closer.e, cs: run.e, ce: closer.s }, next: closer.e };
  }

  // * 串：三个以内是强调的定界符，更长的按原文显示
  function scanStars({ src, end }, i) {
    const j = runEnd(src, i, end, 42);
    return j - i <= 3 ? { token: { t: "emph", s: i, e: j, n: j - i }, next: j } : shownAsText(j);
  }

  // ~ 串：正好两个才是删除线的定界符；后面贴着字才能开头，前面贴着字才能收尾
  function scanTildes({ src, start, end }, i) {
    const j = runEnd(src, i, end, 126);
    if (j - i !== 2) return shownAsText(j);
    const canOpen = j < end && !isSpace(src.charCodeAt(j));
    const canClose = i > start && !isSpace(src.charCodeAt(i - 1));
    return { token: { t: "strike", s: i, e: j, canOpen, canClose }, next: j };
  }

  // {{color:#…| / {{bg:#…| / {{underline:solid|dashed| / {{mark:类别|
  function scanSpanOpen({ src, end }, i) {
    SPAN_OPEN.lastIndex = i;
    const match = SPAN_OPEN.exec(src);
    if (!match || i + match[0].length > end) return shownAsText(i + 1); // 「{{{color:…」里真正的开头从下一个 { 起
    const e = i + match[0].length;
    return { token: { t: "spanOpen", s: i, e, mark: match[1] || match[3] || match[5], value: match[2] || match[4] || match[6] }, next: e };
  }

  // [：行内图片 [[image:…]]，否则是链接文字的开头
  function scanBracket({ src, end }, i) {
    INLINE_IMAGE.lastIndex = i;
    const image = INLINE_IMAGE.exec(src);
    if (!image || i + image[0].length > end) return { token: { t: "linkOpen", s: i, e: i + 1 }, next: i + 1 };
    const e = i + image[0].length;
    return { token: { t: "image", s: i, e, id: image[1] }, next: e };
  }

  // ]：后面跟着 (网址) 是链接的收尾，否则是一个普通的方括号
  function scanBracketClose({ src, end }, i) {
    const target = linkTarget(src, i, end);
    if (!target) return { token: { t: "bracket", s: i, e: i + 1 }, next: i + 1 };
    return { token: { t: "linkClose", s: i, e: target.e, url: target.url }, next: target.e };
  }

  // 反引号串，以及每一串之后第一个等长的串（行内代码的收尾）。一遍扫完，避免长行上的平方复杂度。
  function backtickRuns(src, start, end) {
    const runs = [];
    for (let i = start; i < end; i += 1) {
      if (src.charCodeAt(i) !== 96) continue;
      let j = i;
      while (j < end && src.charCodeAt(j) === 96) j += 1;
      runs.push({ s: i, e: j });
      i = j - 1;
    }
    const next = new Array(runs.length).fill(null);
    const lastOfLength = new Map();
    for (let k = runs.length - 1; k >= 0; k -= 1) {
      const length = runs[k].e - runs[k].s;
      next[k] = lastOfLength.get(length) ?? null;
      lastOfLength.set(length, runs[k]);
    }
    runs.push({ s: Infinity, e: Infinity });
    return { runs, next };
  }

  // ] 之后紧跟 (网址) 或 (网址 "标题")：网址里不能有空白和方括号，圆括号要成对。
  // 遇到方括号就停，长行上满是 ]( 时也只扫到下一个括号为止。
  function linkTarget(src, at, end) {
    if (src.charCodeAt(at + 1) !== 40) return null; // (
    let i = at + 2;
    let depth = 0;
    while (i < end) {
      const code = src.charCodeAt(i);
      if (isSpace(code) || code === 91 || code === 93) break;
      if (code === 40) depth += 1;
      if (code === 41) {
        if (depth === 0) break;
        depth -= 1;
      }
      i += 1;
    }
    const url = src.slice(at + 2, i);
    i = trimStart(src, i, end);
    const quote = src.charCodeAt(i);
    if ((quote === 34 || quote === 39) && i > at + 2 + url.length) {
      const close = src.indexOf(String.fromCharCode(quote), i + 1);
      if (close === -1 || close >= end) return null;
      i = trimStart(src, close + 1, end);
    }
    if (i >= end || src.charCodeAt(i) !== 41) return null;
    return { e: i + 1, url };
  }

  function findLast(stack, test) {
    for (let j = stack.length - 1; j >= 0; j -= 1) if (test(stack[j])) return j;
    return -1;
  }

  // 给定界符配对。必须成对且正确嵌套：收尾时，夹在中间还没配上的开头一律按原文显示；到行尾还没配上的也按原文显示。
  // 返回每个记号的处理结果：shown（非 * 记号是否按原文显示）、closeUsed / openMatched（* 记号左侧收尾、右侧开头各用掉几个星号），
  // 以及每个记号处开始 / 结束的格式。
  function matchDelimiters(tokens) {
    const count = tokens.length;
    const plan = {
      shown: new Array(count).fill(true),
      closeUsed: new Array(count).fill(0),
      openMatched: new Array(count).fill(0),
      starts: new Array(count).fill(null),
      ends: new Array(count).fill(null),
    };
    const pair = (from, to, mark, value) => {
      (plan.starts[from] ||= []).push({ mark, value });
      (plan.ends[to] ||= []).push(mark);
    };
    const stack = [];
    // 收掉最近一个还开着的 * / ** 开头；它上面没配上的开头作废（按原文显示）
    const closeEmph = (k, flag, stars, mark) => {
      const index = findLast(stack, (entry) => entry.type === "emph" && entry[flag]);
      if (index < 0) return false;
      const entry = stack[index];
      stack.length = index + 1;
      entry[flag] = false;
      plan.openMatched[entry.k] += stars;
      plan.closeUsed[k] += stars;
      pair(entry.k, k, mark, true);
      if (!entry.b && !entry.i) stack.pop();
      return true;
    };
    const closeAt = (index, k, mark, value) => {
      const opener = stack[index];
      stack.length = index;
      plan.shown[opener.k] = plan.shown[k] = false;
      pair(opener.k, k, mark, value);
    };
    const dropLinkOpeners = () => {
      for (let j = stack.length - 1; j >= 0; j -= 1) if (stack[j].type === "link") stack.splice(j, 1);
    };

    for (let k = 0; k < count; k += 1) {
      const token = tokens[k];
      if (token.t === "emph") {
        matchStars(stack, token.n, k, closeEmph);
      } else if (token.t === "strike") {
        // 删除线不嵌套：开着时下一个能收尾的 ~~ 就收尾，其余 ~~ 按原文显示
        const index = findLast(stack, (entry) => entry.type === "strike");
        if (index >= 0 && token.canClose) closeAt(index, k, "strike", true);
        else if (index < 0 && token.canOpen) stack.push({ type: "strike", k });
      } else if (token.t === "spanOpen" || token.t === "linkOpen") {
        stack.push({ type: token.t === "spanOpen" ? "span" : "link", k });
      } else if (token.t === "spanClose") {
        const index = findLast(stack, (entry) => entry.type === "span");
        if (index >= 0) closeAt(index, k, tokens[stack[index].k].mark, tokens[stack[index].k].value);
      } else if (token.t === "linkClose") {
        const index = findLast(stack, (entry) => entry.type === "link");
        if (index >= 0 && stack[index].k < k - 1) closeAt(index, k, "link", LINK_TARGET.test(token.url) ? token.url : null);
        dropLinkOpeners(); // 链接文字里不能再有链接，也不能有落单的 ]
      } else if (token.t === "bracket") {
        dropLinkOpeners();
      }
    }
    return plan;
  }

  // 一串 1–3 个星号：* 斜体、** 加粗、*** 两者；有开着的同类就收尾，否则开头。
  function matchStars(stack, stars, k, closeEmph) {
    if (stars === 1) {
      if (!closeEmph(k, "i", 1, "italic")) stack.push({ type: "emph", k, i: true, b: false });
      return;
    }
    if (stars === 2) {
      if (!closeEmph(k, "b", 2, "bold")) stack.push({ type: "emph", k, i: false, b: true });
      return;
    }
    const italic = findLast(stack, (entry) => entry.type === "emph" && entry.i);
    const bold = findLast(stack, (entry) => entry.type === "emph" && entry.b);
    if (italic >= 0 && bold >= 0) {
      // 两层都开着：先收里层
      const [first, second] = italic >= bold ? [["i", 1, "italic"], ["b", 2, "bold"]] : [["b", 2, "bold"], ["i", 1, "italic"]];
      closeEmph(k, ...first);
      closeEmph(k, ...second);
    } else if (italic >= 0) {
      closeEmph(k, "i", 1, "italic");
      stack.push({ type: "emph", k, i: false, b: true });
    } else if (bold >= 0) {
      closeEmph(k, "b", 2, "bold");
      stack.push({ type: "emph", k, i: true, b: false });
    } else {
      stack.push({ type: "emph", k, i: true, b: true });
    }
  }

  // 按配对结果从左到右扫一遍，切出行内片段。
  // 片段满足 text === markdown.slice(source[0], source[1])；两段之间被跳过的字就是隐藏的标记。
  function buildRuns(src, tokens) {
    const plan = matchDelimiters(tokens);
    const runs = [];
    const flags = { bold: 0, italic: 0, strike: 0 };
    const values = { color: [], bg: [], underline: [], link: [], mark: [] };
    const emit = (s, e, isCode) => {
      if (s >= e) return;
      const run = { text: "", source: [s, e] }; // text 最后统一切出，免得一路合并一路复制长字符串
      if (flags.bold) run.bold = true;
      if (flags.italic) run.italic = true;
      if (flags.strike) run.strike = true;
      if (isCode) run.code = true;
      for (const key of ["color", "bg", "underline", "link", "mark"]) {
        const value = values[key][values[key].length - 1];
        if (value) run[key] = value;
      }
      // 与前一段首尾相接、格式相同就并成一段（中间没有被隐藏的标记）
      const previous = runs[runs.length - 1];
      if (previous && previous.source[1] === s && sameMarks(previous, run)) previous.source[1] = e;
      else runs.push(run);
    };
    tokens.forEach((token, k) => {
      for (const mark of plan.ends[k] || []) {
        if (mark in flags) flags[mark] -= 1;
        else values[mark].pop();
      }
      if (token.t === "text") emit(token.s, token.e, false);
      else if (token.t === "code") emit(token.cs, token.ce, true);
      else if (token.t === "emph") emit(token.s + plan.closeUsed[k], token.e - plan.openMatched[k], false);
      else if (token.t !== "image" && plan.shown[k]) emit(token.s, token.e, false);
      for (const { mark, value } of plan.starts[k] || []) {
        if (mark in flags) flags[mark] += 1;
        else values[mark].push(value);
      }
    });
    for (const run of runs) run.text = src.slice(run.source[0], run.source[1]);
    return runs;
  }

  function sameMarks(a, b) {
    return MARK_KEYS.every((key) => a[key] === b[key]);
  }

  // 一行的内容先按行内图片切开：图片单独成段，两侧的文字各自成段（内容两端去空白）。
  // 第一段的 source 从行首算起，最后一段到行尾为止；中间各段以图片为界。
  function linePieces(src, line, contentStart) {
    const tokens = tokenize(src, contentStart, line.contentEnd);
    const images = tokens.filter((token) => token.t === "image");
    if (!images.length) {
      return [{ kind: "text", start: line.start, end: line.end, contentStart, contentEnd: line.contentEnd, tokens }];
    }
    const pieces = [];
    let from = contentStart;
    let sourceFrom = line.start;
    const text = (to, sourceTo) => {
      const s = trimStart(src, from, to);
      const e = trimEnd(src, s, to);
      pieces.push({ kind: "text", start: sourceFrom, end: sourceTo, contentStart: s, contentEnd: e, tokens: tokenize(src, s, e) });
    };
    for (const image of images) {
      text(image.s, image.s);
      pieces.push({ kind: "image", start: image.s, end: image.e, id: image.id });
      from = sourceFrom = image.e;
    }
    text(line.contentEnd, line.end);
    return pieces;
  }

  // ===== 块 =====

  function tableCells(src, line) {
    let start = line.contentStart;
    let end = line.contentEnd;
    if (src.charCodeAt(start) === 124) start += 1; // |
    if (end > start && src.charCodeAt(end - 1) === 124) end -= 1;
    const cells = [];
    let cellStart = start;
    for (let i = start; i <= end; i += 1) {
      if (i === end || src.charCodeAt(i) === 124) {
        cells.push({ start: cellStart, end: i });
        cellStart = i + 1;
      }
    }
    return cells;
  }

  // 表格行：至少两格（去掉首尾各一个 | 后按 | 切开）；整行拼图标记不算。
  function isTableRow(src, line) {
    return line.text !== "" && !WHOLE_PAIR.test(line.text) && tableCells(src, line).length >= 2;
  }

  // 表头下的分隔行：至少两格，每格都是至少三个 -，可带冒号表示对齐。不是分隔行时返回 null。
  function delimiterAligns(src, line) {
    if (!line || line.text === "") return null;
    const cells = tableCells(src, line);
    if (cells.length < 2) return null;
    const aligns = [];
    for (const cell of cells) {
      const text = src.slice(trimStart(src, cell.start, cell.end), trimEnd(src, cell.start, cell.end));
      if (!TABLE_DELIMITER.test(text)) return null;
      const left = text.startsWith(":");
      const right = text.endsWith(":");
      aligns.push(left && right ? "center" : right ? "right" : left ? "left" : null);
    }
    return aligns;
  }

  // 单元格里的行内图片不显示（与表格里放不下图片一致）。
  function tableRow(src, line) {
    return {
      source: [line.start, line.end],
      cells: tableCells(src, line).map((cell) => {
        const s = trimStart(src, cell.start, cell.end);
        const e = trimEnd(src, s, cell.end);
        return { source: [s, e], runs: buildRuns(src, tokenize(src, s, e)) };
      }),
    };
  }

  function findFenceEnd(lines, from, ticks) {
    for (let j = from; j < lines.length; j += 1) {
      const text = lines[j].text;
      if (text.length >= ticks && /^`+$/.test(text)) return j;
    }
    return -1;
  }

  function isQuoteLine(text) {
    return text.charCodeAt(0) === 62 && (text.length === 1 || text.charCodeAt(1) === 32); // > 后跟空格或行尾
  }

  // 逐行收集块。段落行、引用行、列表项：紧挨着（中间没有空行）的同类行并成一块。
  function createBuilder(src) {
    const blocks = [];
    let blank = 0;
    let open = null; // 还能接着往下续行的段落 / 引用 / 列表

    const add = (type, start, end, fields) => {
      const block = { type, source: [start, end], blankLinesBefore: blank, ...fields };
      blank = 0;
      open = null;
      blocks.push(block);
      return block;
    };
    const append = (type, key, entry) => {
      if (open && open.type === type && blank === 0) {
        open[key].push(entry);
        open.source[1] = entry.source[1];
        return;
      }
      open = add(type, entry.source[0], entry.source[1], { [key]: [entry] });
    };
    const textLine = (piece, extra) => ({
      source: [piece.start, piece.end],
      ...extra,
      contentSource: [piece.contentStart, piece.contentEnd],
      runs: buildRuns(src, piece.tokens),
    });
    // 一行里夹着 [[image:…]]：图片前的文字交给 first 放进本来的块，图片单独成块，
    // 图片后的文字成段落（引用里仍是引用）。切开后空着的文字段不成块。
    const placeLine = (line, contentStart, restType, first) => {
      const pieces = linePieces(src, line, contentStart);
      const split = pieces.length > 1;
      pieces.forEach((piece, index) => {
        const empty = piece.contentStart === piece.contentEnd;
        if (piece.kind === "image") add("image", piece.start, piece.end, { imageId: piece.id });
        else if (index === 0) first(piece, split && empty);
        else if (!empty) append(restType, "lines", textLine(piece));
      });
    };

    return {
      blocks,
      blankLine: () => { blank += 1; }, // 空行之后不再续行：append 看到 blank > 0 就另起一块
      add,
      heading(line, match) {
        const markerStart = line.contentStart;
        placeLine(line, markerStart + match[0].length, "paragraph", (piece, skip) => {
          if (skip) return;
          add("heading", piece.start, piece.end, {
            level: match[1].length,
            marker: match[1],
            markerSource: [markerStart, markerStart + match[1].length],
            contentSource: [piece.contentStart, piece.contentEnd],
            runs: buildRuns(src, piece.tokens),
          });
        });
      },
      listItem(line, match) {
        const markerStart = line.contentStart;
        const ordered = match[2] !== undefined;
        // 列表项即使只剩一张图也保留编号（与原来的卡片一致）
        placeLine(line, markerStart + match[0].length, "paragraph", (piece) => append("list", "items", {
          source: [piece.start, piece.end],
          marker: match[1],
          markerSource: [markerStart, markerStart + match[1].length],
          ordered,
          ...(ordered ? { number: Number(match[2]) } : {}),
          indent: line.contentStart - line.start,
          contentSource: [piece.contentStart, piece.contentEnd],
          runs: buildRuns(src, piece.tokens),
        }));
      },
      quoteLine(line) {
        const markerStart = line.contentStart;
        const marker = { marker: ">", markerSource: [markerStart, markerStart + 1] };
        placeLine(line, trimStart(src, markerStart + 1, line.contentEnd), "quote", (piece, skip) => {
          if (!skip) append("quote", "lines", textLine(piece, marker));
        });
      },
      paragraphLine(line) {
        placeLine(line, line.contentStart, "paragraph", (piece, skip) => {
          if (!skip) append("paragraph", "lines", textLine(piece));
        });
      },
    };
  }

  // ``` 围起来的代码块；没有收尾的 ``` 不算（按普通文字显示），免得打字途中把后文全变成代码。
  function parseFence(src, lines, index, builder) {
    const line = lines[index];
    const fence = FENCE_OPEN.exec(line.text);
    const close = fence ? findFenceEnd(lines, index + 1, fence[1].length) : -1;
    if (close === -1) return -1;
    const contentSource = close > index + 1 ? [lines[index + 1].start, lines[close - 1].end] : null;
    builder.add("code", line.start, lines[close].end, {
      lang: fence[2].trim(),
      text: contentSource ? src.slice(contentSource[0], contentSource[1]) : "",
      contentSource,
    });
    return close;
  }

  // 表头 + 分隔行 + 紧跟着的表格行。不是表格时返回 -1，否则返回表格最后一行的行号。
  function parseTable(src, lines, index, builder) {
    const line = lines[index];
    const aligns = isTableRow(src, line) ? delimiterAligns(src, lines[index + 1]) : null;
    if (!aligns) return -1;
    const header = tableRow(src, line);
    const rows = [];
    let last = index + 1;
    while (last + 1 < lines.length && isTableRow(src, lines[last + 1])) {
      last += 1;
      rows.push(tableRow(src, lines[last]));
    }
    const columns = Math.max(header.cells.length, ...rows.map((row) => row.cells.length));
    builder.add("table", line.start, lines[last].end, {
      columns,
      align: Array.from({ length: columns }, (_, column) => aligns[column] ?? null),
      header,
      rows,
    });
    return last;
  }

  // 整行就是一个标记的块：分页、结尾页、拼图、单张图片、标准 Markdown 图片、分割线。认出来返回 true。
  function parseWholeLine(line, builder) {
    const { text, start, end } = line;
    if (text === PAGE_BREAK || text === END_PAGE) {
      builder.add(text === PAGE_BREAK ? "pageBreak" : "endPage", start, end, {});
      return true;
    }
    const pair = WHOLE_PAIR.exec(text);
    if (pair) {
      const [, first, second, ratio = null] = pair;
      builder.add("imagePair", start, end, { imageIds: [first, second], ratio });
      return true;
    }
    const single = WHOLE_IMAGE.exec(text);
    if (single) {
      builder.add("image", start, end, { imageId: single[1] });
      return true;
    }
    const picture = MARKDOWN_IMAGE.exec(text);
    if (picture) {
      builder.add("image", start, end, { path: picture[2], alt: picture[1] });
      return true;
    }
    if (RULE.test(text)) {
      builder.add("rule", start, end, {});
      return true;
    }
    return false;
  }

  // 容器的属性：「键=值」「键="有 空格"」或单独一个词（记为 true）
  function parseAttrs(text) {
    const attrs = {};
    const pattern = /([^\s=]+)(?:=(?:"([^"]*)"|(\S+)))?/g;
    for (const match of String(text || "").matchAll(pattern)) {
      attrs[match[1]] = match[2] ?? match[3] ?? true;
    }
    return attrs;
  }

  // 与开头配对的收尾行：中间再有开头时要多收一层；找不到时为 -1
  function findContainerEnd(lines, from) {
    let depth = 0;
    for (let j = from; j < lines.length; j += 1) {
      const text = lines[j].text;
      if (CONTAINER_CLOSE.test(text)) {
        if (depth === 0) return j;
        depth -= 1;
      } else if (CONTAINER_OPEN.test(text)) {
        depth += 1;
      }
    }
    return -1;
  }

  // 「:::名字 属性」到配对的「:::」：里面的行按同样的规则另成一组块。没有收尾时开头这行按普通文字显示，
  // 免得打字途中把后文全收进去（与没收尾的代码块一样）。
  function parseContainer(src, lines, index, builder) {
    const line = lines[index];
    const open = CONTAINER_OPEN.exec(line.text);
    if (!open) return -1;
    const close = findContainerEnd(lines, index + 1);
    if (close === -1) return -1;
    const inner = createBuilder(src);
    parseLines(src, lines.slice(index + 1, close), inner);
    builder.add("container", line.start, lines[close].end, {
      name: open[1],
      attrs: parseAttrs(open[2]),
      markerSource: [line.start, line.end],
      closeSource: [lines[close].start, lines[close].end],
      blocks: inner.blocks,
    });
    return close;
  }

  function parseLines(src, lines, builder) {
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      const { text } = line;
      if (text === "") {
        builder.blankLine();
        continue;
      }
      const containerEnd = parseContainer(src, lines, index, builder);
      if (containerEnd !== -1) {
        index = containerEnd;
        continue;
      }
      const blockEnd = parseFence(src, lines, index, builder);
      if (blockEnd !== -1) {
        index = blockEnd;
        continue;
      }
      const tableEnd = parseTable(src, lines, index, builder);
      if (tableEnd !== -1) {
        index = tableEnd;
        continue;
      }
      if (parseWholeLine(line, builder)) continue;
      const heading = HEADING.exec(text);
      const item = LIST_ITEM.exec(text);
      // 标记后面要有内容：「# 」「- 」「1. 」单独一行按普通文字显示
      if (heading && heading[0].length < text.length) builder.heading(line, heading);
      else if (item && item[0].length < text.length) builder.listItem(line, item);
      else if (isQuoteLine(text)) builder.quoteLine(line);
      else builder.paragraphLine(line);
    }
  }

  // 容器原地摊开成里面的块（「:::」两行不成块）。只认识普通块的地方（Canvas 排版、长文、纯文本……）用这一种。
  function flatten(blocks) {
    return blocks.flatMap((block) => (block.type === "container" ? flatten(block.blocks) : [block]));
  }

  // options.containers 为 true 时保留组件容器（HTML 卡片用，ADR 0006）；默认摊开。
  function parseMarkdown(markdown, options = {}) {
    if (typeof markdown !== "string") throw new TypeError("parseMarkdown 需要 Markdown 字符串");
    const builder = createBuilder(markdown);
    parseLines(markdown, splitLines(markdown), builder);
    const blocks = options.containers ? builder.blocks : flatten(builder.blocks);
    return { type: "document", source: [0, markdown.length], blocks };
  }

  const engine = root.MediaCraftEngine || (root.MediaCraftEngine = {});
  engine.parseMarkdown = parseMarkdown;
})(globalThis);
