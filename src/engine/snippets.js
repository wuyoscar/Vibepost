// 片段：写好的几段示范文字（不是占位符），登记在这一张表里。「插入」与「/」菜单的「片段」一组、操作手册末尾的「片段」一节、
// Agent 插片段的工具都从它取；改这里，那些都跟着变。记号一律用操作手册（src/engine/manual.js）的中文写法。
// 只有数据和纯文本的插入规则，不碰 DOM；Node 里也能载入（scripts/build-manual.mjs 生成 docs/manual.md）。
(function (root) {
  "use strict";

  const freeze = root.MediaCraftEngine?.deepFreeze ?? ((value) => value);

  const PAGE_BREAK = "[[分页]]";
  const END_PAGE = "[[结尾]]";

  // ===== 登记表 =====
  // id 给 Agent 与菜单项用；name 是菜单里的名字；glyph 是菜单里的字形；keys 是「/」菜单认的拼音缩写（名字本身也认）；
  // summary 一句说明（菜单里名字下面那行）；when 什么时候用；markdown 插进稿子的示范文字。
  const SNIPPETS = [
    {
      id: "tutorial", name: "三步教程", glyph: "教", keys: ["sbjc", "jiaocheng", "tutorial"],
      summary: "三步做成一件事的小教程", when: "操作教程、方法分享",
      markdown: [
        "## 三步把一篇论文读薄",
        "",
        ":::步骤",
        "- 先读摘要和结论，用一句话写下它要解决什么问题",
        "- 只看图表：每张图回答了哪个问题、数据从哪来",
        "- 回到方法部分，补上第一步里没说清的地方",
        ":::",
      ].join("\n"),
    },
    {
      id: "compare", name: "对比", glyph: "比", keys: ["db", "duibi", "compare", "vs"],
      summary: "优点、缺点各几条的对比", when: "选型、要不要买、两种做法比一比",
      markdown: [
        "## 本地跑模型还是用 API",
        "",
        ":::标签列表",
        "- [优点] 数据不出本机，断网也能用",
        "- [优点] 跑得越多越划算，没有按量计费",
        "- [缺点] 显存决定上限，大模型跑不起来",
        "- [缺点] 换新模型要自己下载、自己调",
        ":::",
      ].join("\n"),
    },
    {
      id: "quote-page", name: "金句页", glyph: "句", keys: ["jjy", "jinju", "quote"],
      summary: "单独一页的大字金句加一句出处", when: "一篇的转折处、想让人截图的那句话",
      markdown: [
        PAGE_BREAK,
        "",
        "# 写不出来，往往是因为还没想清楚",
        "",
        "> 把想法说给一个外行听，说不明白的地方就是文章的空洞。",
        "",
        PAGE_BREAK,
      ].join("\n"),
    },
    {
      id: "paper", name: "论文卡", glyph: "论", keys: ["lwk", "lunwen", "paper"],
      summary: "一篇论文的小标题、原名与两段解读", when: "论文解读、读书笔记",
      markdown: [
        "## 模型会承认自己错了吗",
        "",
        ":::小标签",
        "论文：When Do Models Admit They Are Wrong?",
        ":::",
        "",
        "研究者让模型先回答，再给出一条反驳，看它会不会改口。结果是：反驳越具体，模型越容易放弃原本正确的答案。",
        "",
        "这说明「承认错误」和「判断对错」是两回事。想让模型可靠，不能只教它顺从，还要让它分得清哪些反驳站得住。",
      ].join("\n"),
    },
    {
      id: "timeline", name: "时间线", glyph: "时", keys: ["sjx", "shijianxian", "timeline"],
      summary: "按日期排的几件事", when: "事件回顾、新闻的来龙去脉",
      markdown: [
        "## 这件事的来龙去脉",
        "",
        "1. 3 月 12 日：论文上线 arXiv，当天只有几十次下载",
        "2. 3 月 20 日：一位博主写了解读，转发破万",
        "3. 4 月 2 日：作者公开代码，社区开始复现",
        "4. 4 月 15 日：复现结果出来，核心结论站住了",
      ].join("\n"),
    },
    {
      id: "faq", name: "FAQ", glyph: "问", keys: ["faq", "wd", "wenda"],
      summary: "三个常见问题与回答", when: "答疑、避坑指南",
      markdown: [
        "### 需要先学编程吗",
        "",
        "不用。先照着做出第一个结果，遇到看不懂的再查，比先学完再动手快得多。",
        "",
        "### 一天花多少时间合适",
        "",
        "半小时就够。关键是每天都碰一下，断了三天就得从头找感觉。",
        "",
        "### 卡住了怎么办",
        "",
        "把问题原样写下来发给 AI 或论坛。写清楚问题的过程，一半时候自己就想通了。",
      ].join("\n"),
    },
    {
      id: "checklist", name: "清单", glyph: "单", keys: ["qd", "qingdan", "checklist"],
      summary: "一张检查清单加一条提示", when: "发布前检查、行前准备、避坑要点",
      markdown: [
        "## 发布前最后一遍检查",
        "",
        "- 标题不超过 20 个字，含一个具体的数字或场景",
        "- 第一张卡片一眼能看出这篇讲什么",
        "- 每张卡片不超过 300 字，没有只有标题的页",
        "- 图片都换成了自己的，没有占位图",
        "- 正文里写了话题，不超过 5 个",
        "",
        ":::提示",
        "发布前把每张卡片放到手机上看一遍：电脑上好看不等于手机上好看。",
        ":::",
      ].join("\n"),
    },
    {
      id: "before-after", name: "前后对比", glyph: "前", keys: ["qhdb", "qianhou", "before"],
      summary: "改前、改后一张表", when: "改稿、改图、改方案前后的变化",
      markdown: [
        "## 改前改后",
        "",
        "| 项目 | 改前 | 改后 |",
        "| --- | --- | --- |",
        "| 标题 | 关于学习方法的一些思考 | 我用这 3 个方法把阅读速度翻了一倍 |",
        "| 首图 | 一张风景照 | 带结论的大字卡片 |",
        "| 结尾 | 没有 | 一句引导加下期预告 |",
      ].join("\n"),
    },
    {
      id: "data", name: "数据卡", glyph: "数", keys: ["sjk", "shuju", "data"],
      summary: "对齐的几行数字加一句结论", when: "周报、战报、实测数据",
      // 等宽里空格照原样：标签都是两个字，数字右对齐
      markdown: [
        "## 这周的数字",
        "",
        ":::等宽",
        "阅读  12,480  ↑ 36%",
        "点赞     893  ↑ 12%",
        "收藏     412  ↑ 58%",
        "涨粉     176  ↑ 21%",
        ":::",
        "",
        "收藏涨得最快：实用清单类的内容值得多做几篇。",
      ].join("\n"),
    },
    {
      id: "ending", name: "结尾引导", glyph: "引", keys: ["jwyd", "yindao", "ending", "cta"],
      summary: "结尾页：下期预告与关注、收藏引导", when: "一篇的最后（稿子里还没有结尾页时）",
      markdown: [
        END_PAGE,
        "",
        "## 下期预告",
        "",
        "讲讲怎么用 AI 把一篇论文整理成这样的卡片。",
        "",
        "觉得有用就点个收藏，关注我不错过下一期。",
      ].join("\n"),
    },
  ];

  // ===== 查找 =====

  const byKey = new Map();
  for (const snippet of SNIPPETS) for (const key of [snippet.id, snippet.name]) byKey.set(key, snippet);
  // id 或中文名都认
  const get = (key) => byKey.get(String(key ?? "")) ?? null;

  // ===== 插进稿子 =====

  const LEADING_BREAK = /^[ \t]*\[\[分页\]\][ \t]*(?:\n|$)\n*/;
  const TRAILING_BREAK = /\n*(?:^|\n)[ \t]*\[\[分页\]\][ \t]*$/;
  const isLine = (text, marker) => text.split("\n").some((line) => line.trim() === marker);
  // 前文最后一行、后文第一行的字（跳过空行）
  const lastLine = (text) => text.trimEnd().split("\n").pop().trim();
  const firstLine = (text) => text.trimStart().split("\n")[0].trim();

  // 光标落在哪：原文里让给片段的那一段 [from, to)。只有空白的一行整行换掉；行首就插在这一行前面；
  // 行尾、行中间都插在这一行后面（不把一行字拆开）
  function anchor(text, at) {
    const index = Math.min(Math.max(0, Math.trunc(Number(at)) || 0), text.length);
    const from = text.lastIndexOf("\n", index - 1) + 1;
    const next = text.indexOf("\n", index);
    const to = next === -1 ? text.length : next;
    if (!text.slice(from, to).trim()) return { from, to };
    return index === from ? { from, to: from } : { from: to, to };
  }

  // 把一段 Markdown（片段的 markdown，或 Agent 给的一段）插在 text 的 at 处：前后各隔一个空行（MediaCraftCardBlocks.insertAt）；
  // 开头、结尾的 [[分页]] 挨着已有的分页（结尾处也算 [[结尾]]）或稿子的头尾时去掉，不叠出空页；
  // 含 [[结尾]] 的只能插在稿子末尾，稿子里已经有结尾页时拒绝。
  // 返回 { text 新正文, start / end 片段在新正文里的范围, change 编辑器要做的那一处改动 { from, to, insert }（没变化时 null）}
  function insert(text, at, markdown) {
    const source = String(text ?? "");
    const { from, to } = anchor(source, at);
    const before = source.slice(0, from);
    const after = source.slice(to);
    let chunk = String(markdown ?? "").replace(/^(?:[ \t]*\n)+|(?:\n[ \t]*)+$/g, "");
    if (isLine(chunk, END_PAGE)) {
      if (isLine(source, END_PAGE)) throw new Error("稿子里已经有结尾页了：一篇只能有一个 [[结尾]]");
      if (after.trim()) throw new Error("结尾引导只能插在稿子末尾：把光标放到最后再插");
    }
    if (!before.trim() || lastLine(before) === PAGE_BREAK) chunk = chunk.replace(LEADING_BREAK, "");
    if (!after.trim() || [PAGE_BREAK, END_PAGE].includes(firstLine(after))) chunk = chunk.replace(TRAILING_BREAK, "");
    if (!chunk.trim()) return { text: source, start: from, end: from, change: null };
    const next = root.MediaCraftCardBlocks.insertAt(before + after, from, chunk);
    const head = before.replace(/\n*$/, "").length; // 前文留到这里
    const tail = after.length - after.replace(/^\n*/, "").length; // 后文从 to + tail 起留着
    const start = head + (head ? 2 : 0);
    return {
      text: next,
      start,
      end: start + chunk.length,
      change: { from: head, to: to + tail, insert: next.slice(head, next.length - (after.length - tail)) },
    };
  }

  // ===== 写成文字：操作手册末尾的「片段」一节 =====

  function document() {
    return [
      "## 片段",
      "",
      "写好的几段示范文字，在「插入」与「/」菜单的「片段」一组里：点一下插到光标处（一次 ⌘Z 撤回），改成自己的内容就行。"
        + "插在非空行后自动隔开空行；开头、结尾的 [[分页]] 挨着已有的分页或稿子头尾时自动去掉；含 [[结尾]] 的只能插在稿子末尾，一篇只能有一个。"
        + "Agent 用工具 insert_section 插（snippet 给下面括号里的 id 或名字，位置给 before / after 的原文或 position 的 start / end；也能给自己写的一段 markdown），同样的规则、一步可撤销。片段里没有图片，配图另用插图的工具。",
      "",
      ...SNIPPETS.flatMap((snippet) => [
        `### ${snippet.name}（${snippet.id}）`,
        "",
        `${snippet.summary}。用在${snippet.when}。`,
        "",
        "```",
        snippet.markdown,
        "```",
        "",
      ]),
    ].join("\n").replace(/\n$/, "");
  }

  const snippets = {
    list: SNIPPETS,
    get,
    insert,
    document,
  };
  freeze(SNIPPETS);
  root.MediaCraftSnippets = Object.freeze(snippets);
})(globalThis);
