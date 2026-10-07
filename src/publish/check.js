// 发布检查的规则（纯函数，不碰界面）：标题按小红书的显示宽度计字，正文栏（图片下面的那段）里的 #话题与字数，
// 按本地词库（src/publish/lexicon.json，规则与出处见 docs/publish-check.md）在标题、正文栏与卡片文字里找极限词、医疗用语、收益承诺与引流，
// 再加上话题数、图片数、标题与正文字数、正文还没写、署名还没填、排版（每页的自检问题，src/stage/layout-check.js）与 AI 声明提醒。
// 界面在 src/publish/assistant.js。
//
// 卡片文字只查读者看得到的字：Markdown 标记、代码（行内与代码块）、图片与分页标记、链接的网址都不查（链接网址另按「网址」规则整条算一处）；
// 正文栏是纯文本，整段照原样查；
// 中文词直接按字比对，西文词要整词（vx 不会在 vxworks 里命中）；同一处被几条规则命中时只留最长的一条。
(function (root) {
  "use strict";

  const LIMITS = Object.freeze({ title: 20, caption: 1000, topics: 10, images: 18 });
  // 分组的顺序；词库里的分组（极限词、医疗用语、收益承诺、引流）的名字取自词库
  const CATEGORY_ORDER = ["limit", "layout", "caption", "byline", "absolute", "medical", "finance", "traffic", "ai"];
  const BUILT_IN_CATEGORIES = { limit: "数量上限", layout: "排版", caption: "正文", byline: "署名", ai: "AI 声明" };
  // 排版自检的问题在面板里的说法：第几页 + 这几个字
  const LAYOUT_LABELS = { headingOnly: "只有标题", sparse: "太空", dense: "偏挤", overflow: "溢出" };
  // 同一分组里按位置排：标题在前，正文栏其次，卡片文字按在 Markdown 里的位置，没有位置的最后
  const PLACE_ORDER = { title: 0, caption: 1, body: 2 };
  const LEXICON_URL = "src/publish/lexicon.json";
  const CONTEXT_CHARS = 8;
  const LATIN = /[A-Za-z0-9]/;

  // ===== 标题宽度 =====
  // 中文、全角符号与 emoji 占 2 个单位，英文、数字、半角符号与空格占 1 个；小红书的「20 字」是 40 个单位。
  const graphemes = new Intl.Segmenter("zh", { granularity: "grapheme" });
  const EMOJI = /\p{Extended_Pictographic}|\p{Regional_Indicator}|⃣|️/u;
  const WIDE = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Bopomofo}　-〿︰-﹏！-｠￠-￦—‘’“”…·]/u;

  function displayWidth(text) {
    let width = 0;
    for (const { segment } of graphemes.segment(String(text ?? "").trim())) width += EMOJI.test(segment) || WIDE.test(segment) ? 2 : 1;
    return width;
  }

  // 标题折合成几个字（半个字向上取整），和上限 20 比
  const titleLength = (text) => Math.ceil(displayWidth(text) / 2);

  // 正文栏按小红书口径计字：空白不计，emoji 这类增补平面字符算 2 个字（即 UTF-16 长度），和上限 1000 比
  const captionLength = (text) => String(text ?? "").replace(/\s/g, "").length;

  // ===== 话题 =====
  // # 后面接中文、字母、数字或下划线，至少有一个不是数字；前面紧挨着字母数字时不算（C#、a#b、&#123;）。
  const TOPIC = /(?<![\p{L}\p{N}_&])#([\p{L}\p{N}_]*\p{L}[\p{L}\p{N}_]*)/gu;

  function topicsIn(text) {
    return [...String(text ?? "").matchAll(TOPIC)].map((match) => ({ name: match[1], index: match.index, length: match[0].length }));
  }

  // 去重后的话题名，按先后
  const uniqueNames = (lists) => [...new Set(lists.flat())];

  // ===== 正文里看得到的字 =====

  function runLists(block) {
    switch (block.type) {
      case "heading":
        return [block.runs];
      case "paragraph":
      case "quote":
        return block.lines.map((line) => line.runs);
      case "list":
        return block.items.map((item) => item.runs);
      case "table":
        return [block.header, ...block.rows].flatMap((row) => row.cells.map((cell) => cell.runs));
      default:
        return [];
    }
  }

  // 正文拆成要查的片段：{ text, from }（from 是它在 Markdown 里的偏移）；代码不查。
  // 链接另列出来：{ url, from, to, text }，同一个链接里被格式拆开的几段合成一条。
  function visibleText(markdown) {
    const pieces = [];
    const links = [];
    for (const block of root.MediaCraftEngine.parseMarkdown(markdown).blocks) {
      for (const runs of runLists(block)) {
        let link = null;
        for (const run of runs) {
          if (!run.code) pieces.push({ text: run.text, from: run.source[0] });
          if (run.link && link?.url === run.link && !markdown.slice(link.to, run.source[0]).includes("](")) {
            link.to = run.source[1];
            link.text += run.text;
          } else {
            link = run.link ? { url: run.link, from: run.source[0], to: run.source[1], text: run.text } : null;
            if (link) links.push(link);
          }
        }
      }
    }
    return { pieces, links };
  }

  // 卡片文字里的话题名（去重，按先后）：长文没有正文栏，发完复制的话题从这里取
  const bodyTopics = (markdown) => uniqueNames(visibleText(markdown).pieces.map((piece) => topicsIn(piece.text).map((topic) => topic.name)));

  // ===== 词库 =====

  const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

  // 西文开头 / 结尾的词要整词匹配：前后不能紧挨着字母数字
  function wordPattern(word) {
    const before = LATIN.test(word[0]) ? "(?<![A-Za-z0-9])" : "";
    const after = LATIN.test(word.at(-1)) ? "(?![A-Za-z0-9])" : "";
    return `${before}${escapeRegExp(word)}${after}`;
  }

  // 词库 JSON → 可以直接比对的规则。words 按长度从长到短排进一个正则，同一处先命中长的。
  function compile(lexicon) {
    const labels = new Map([...lexicon.categories.map((category) => [category.id, category.label]), ...Object.entries(BUILT_IN_CATEGORIES)]);
    const rules = lexicon.rules.map((rule) => {
      const base = { category: rule.category, level: rule.level, reason: rule.reason };
      if (rule.pattern) return { ...base, name: rule.name, suggest: rule.suggest ?? null, regex: new RegExp(rule.pattern, "giu") };
      const words = Object.entries(rule.words).sort(([a], [b]) => b.length - a.length);
      return {
        ...base,
        name: null,
        suggestions: new Map(words.map(([word, suggest]) => [word.toLowerCase(), suggest])),
        regex: new RegExp(words.map(([word]) => wordPattern(word)).join("|"), "giu"),
      };
    });
    return { labels, rules };
  }

  let lexiconPromise = null;
  // 随页面打包的词库，只读一次
  function loadLexicon() {
    lexiconPromise ??= fetch(LEXICON_URL)
      .then((response) => {
        if (!response.ok) throw new Error(`词库没能读出来（${response.status}）`);
        return response.json();
      })
      .then(compile)
      .catch((error) => {
        lexiconPromise = null;
        throw error;
      });
    return lexiconPromise;
  }

  // ===== 比对 =====

  function hitOf(rule, text, index, piece, where) {
    return {
      key: `${rule.category}:${text.toLowerCase()}`,
      category: rule.category,
      level: rule.level,
      reason: rule.reason,
      label: rule.name ?? text,
      text,
      where,
      from: piece.from + index,
      to: piece.from + index + text.length,
      suggest: rule.suggestions ? rule.suggestions.get(text.toLowerCase()) ?? null : rule.suggest,
      context: [piece.text.slice(Math.max(0, index - CONTEXT_CHARS), index), piece.text.slice(index + text.length, index + text.length + CONTEXT_CHARS)],
    };
  }

  function matchPieces(pieces, rules, where) {
    return pieces.flatMap((piece) => rules.flatMap((rule) => (
      [...piece.text.matchAll(rule.regex)].map((match) => hitOf(rule, match[0], match.index, piece, where))
    )));
  }

  // 链接的网址不在卡片上，但复制出去的正文里有：网址从头按词库里的正则规则（网址、邮箱）比，命中就把整段链接文字算一处
  function matchLinks(links, rules) {
    return links.flatMap((link) => {
      const target = link.url.replace(/^mailto:/i, "");
      const rule = rules.find((item) => item.name && new RegExp(`^(?:${item.regex.source})`, "iu").test(target));
      if (!rule) return [];
      const hit = hitOf(rule, link.text, 0, { text: link.text, from: link.from }, "body");
      return [{ ...hit, key: `${rule.category}:${link.url.toLowerCase()}`, suggest: null }];
    });
  }

  // 重叠的命中只留一处：先到先得，同一起点留长的，再一样长留警告
  function withoutOverlaps(hits) {
    const sorted = [...hits].sort((a, b) => a.from - b.from || (b.to - b.from) - (a.to - a.from) || (a.level === "warn" ? -1 : 1));
    const kept = [];
    for (const hit of sorted) {
      if (!kept.length || hit.from >= kept.at(-1).to) kept.push(hit);
    }
    return kept;
  }

  // 图文卡片才查：标题字数、正文栏的字数与话题数、图片数（长文不发小红书）
  function limitItems({ title, caption, pageCount }) {
    const items = [];
    const length = titleLength(title);
    if (length > LIMITS.title) {
      items.push({
        key: "limit:title", category: "limit", level: "warn", label: `标题 ${length}/${LIMITS.title}`,
        reason: "小红书标题最多 20 字：中文、全角符号、emoji 算 1 个字，英文、数字、半角符号算半个", where: "title", from: 0, to: title.length,
      });
    }
    const count = captionLength(caption);
    if (count > LIMITS.caption) {
      items.push({
        key: "limit:caption", category: "limit", level: "warn", label: `正文 ${count}/${LIMITS.caption}`,
        reason: "小红书正文最多 1000 字（空白不计），多出来的发不出去", where: "caption",
      });
    }
    const topics = topicsIn(caption);
    const names = uniqueNames(topics.map((topic) => topic.name));
    if (names.length > LIMITS.topics) {
      const extra = topics.find((topic) => topic.name === names[LIMITS.topics]);
      items.push({
        key: "limit:topics", category: "limit", level: "warn", label: `话题 ${names.length} 个`,
        reason: `一篇笔记最多带 ${LIMITS.topics} 个话题，从「#${extra.name}」起的发不出去`, where: "caption", from: extra.index, to: extra.index + extra.length,
      });
    }
    if (pageCount > LIMITS.images) {
      items.push({
        key: "limit:images", category: "limit", level: "warn", label: `${pageCount} 张图片`,
        reason: `一篇笔记最多 ${LIMITS.images} 张图片，多出来的发不出去；试试合并几页或删掉一些分页`, where: null,
      });
    }
    return items;
  }

  // 正文栏空着：小红书图片下面的那段要单独写，发送时它进剪贴板
  const emptyCaptionItem = () => ({
    key: "caption:empty", category: "caption", level: "hint", label: "正文还没写",
    reason: "图片下面的那段正文在标题下面的「正文」栏里单独写（#话题 也写在那里）；发送到 iPhone 时它进剪贴板，空着就不动剪贴板", where: "caption",
  });

  // 署名还没填：卡片上只有头像、没有名字
  const unsignedItem = () => ({
    key: "byline:empty", category: "byline", level: "hint", label: "署名还没填",
    reason: "卡片上只有头像、没有名字；在「样式 › 署名」里填上你的名字（也可以就这样发）", where: null,
  });

  // 排版：每页的自检问题（pageIssues 是 App API 页面摘要里每页的 issues），只提醒、不拦发送
  function layoutItems(pageIssues = []) {
    return pageIssues.flatMap((issues, index) => (issues ?? []).map((issue) => ({
      key: `layout:${issue.id}:${index + 1}`, category: "layout", level: "hint", label: `第 ${index + 1} 页${LAYOUT_LABELS[issue.id] ?? "排版"}`,
      reason: issue.text, where: null, page: index,
    })));
  }

  const aiItem = () => ({
    key: "ai:declare", category: "ai", level: "hint", label: "用过 AI 助手",
    reason: "发布时在小红书里勾选「笔记含 AI 合成内容」（《人工智能生成合成内容标识办法》要求标识）", where: null,
  });

  // input：{ title, caption, markdown, mode, pageCount, usedAI, signed, pageIssues }；lexicon：compile() 的结果。长文没有正文栏，不查它与数量。
  // signed 为 false 时（署名的名字空着）提醒一句；没给时不查。pageIssues 是每页的排版问题（没给时不查）。
  // 返回提醒的列表，按分组、再按位置排好。每条：{ key, category, level: "warn" | "hint", label, reason,
  //   where: "title" | "caption" | "body" | null（标题、正文栏、卡片文字、不在字里）, from?, to?（在那一处的偏移）, text?,
  //   suggest?（建议改成的字，"" 是删掉，null 是没有通用改法）, context?: [前文, 后文] }
  function check(input, lexicon) {
    const { pieces, links } = visibleText(input.markdown);
    const title = String(input.title ?? "");
    const caption = String(input.caption ?? "");
    const cards = input.mode !== "article";
    const hits = [
      ...withoutOverlaps(matchPieces([{ text: title, from: 0 }], lexicon.rules, "title")),
      ...(cards ? withoutOverlaps(matchPieces([{ text: caption, from: 0 }], lexicon.rules, "caption")) : []),
      ...withoutOverlaps([...matchPieces(pieces, lexicon.rules, "body"), ...matchLinks(links, lexicon.rules)]),
    ];
    const items = [
      ...(cards ? limitItems({ ...input, title, caption }) : []),
      ...(cards && !caption.trim() ? [emptyCaptionItem()] : []),
      ...(cards && input.signed === false ? [unsignedItem()] : []),
      ...(cards ? layoutItems(input.pageIssues) : []),
      ...hits,
      ...(input.usedAI ? [aiItem()] : []),
    ];
    const rank = (item) => CATEGORY_ORDER.indexOf(item.category);
    const where = (item) => PLACE_ORDER[item.where] ?? Object.keys(PLACE_ORDER).length;
    const place = (item) => item.from ?? Number.MAX_SAFE_INTEGER;
    return items.sort((a, b) => rank(a) - rank(b) || where(a) - where(b) || place(a) - place(b));
  }

  root.MediaCraftPublish = {
    LIMITS,
    CATEGORY_ORDER,
    displayWidth,
    titleLength,
    captionLength,
    topicsIn: (text) => uniqueNames(topicsIn(text).map((topic) => topic.name)),
    bodyTopics,
    compile,
    loadLexicon,
    check,
  };
})(globalThis);
