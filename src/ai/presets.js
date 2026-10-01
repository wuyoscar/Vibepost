// AI 预设命令：针对小红书的几条固定的话，和一键润色一样发进当前稿子的同一个会话（src/ai/session.js）。
// 「封面标题 5 选 1」不改稿子，回复里给 5 个候选（JSON 数组），这里读出来、按显示宽度（全角 2、半角 1，
// 小红书标题上限 20 个全角字）算长度，点一个写进标题框（撤销历史里的一步）；
// 「首图文案」「去 AI 味」「按要点重新分页」直接改 draft.md，「写小红书正文」照着卡片内容写 caption.txt（图片下面的那段），
// 改动照常进修改对比逐处确认。
// 对外是 mediacraft.ai.preset / useTitle，见 docs/app-api.md。
(function (root) {
  "use strict";

  const ai = (root.MediaCraftAI ||= {});
  const mc = () => root.mediacraft;

  // 小红书标题最多 20 个全角字，也就是 40 个显示宽度
  const TITLE_WIDTH_LIMIT = 40;
  const TITLE_COUNT = 5;
  const MARKERS = "保留所有自定义标记（[[image:…]] 图片、[[分页]]、{{color:…|…}} 字色、{{bg:…|…}} 高亮、{{underline:…|…}} 下划线）和 #话题标签，原样不动";
  const OTHER_MARKERS = "其余自定义标记（[[image:…]] 图片、{{color:…|…}} 字色、{{bg:…|…}} 高亮、{{underline:…|…}} 下划线）和 #话题标签原样保留";

  // 设计方向（借鉴设计师常说的几个词）：都先看再改、改完再看，用和用户在卡片上点选一块后一样的操作
  const DESIGN_STEPS = [
    "先用 get_pages 与 view_page 看现在每页的样子，想清楚再动手；",
    "用 restyle_block 给块换样式（小标签、提示、页尾、等宽、标签列表、步骤、对齐、标题级别），move_section 调顺序，",
    "set_style 调字号行距配色，set_card_css 写这一篇自己的卡片样式（要新的样子时）；措辞的改动直接改 draft.md；",
    "不改变内容的意思、不编造，所有自定义标记原样保留；改完再用 view_page 看一眼，用一两句话说明改了什么、为什么。",
  ].join("");
  const design = (label, goal) => ({ label, prompt: `把这篇卡片的设计往「${label}」的方向改：${goal}\n${DESIGN_STEPS}` });

  const PRESETS = {
    coverTitles: {
      label: "封面标题 5 选 1",
      prompt: [
        "根据这篇稿子起 5 个小红书封面标题，给我挑一个。",
        "- 每个不超过 20 个字（按显示宽度算：汉字、全角标点、emoji 算 1 个字，字母、数字、半角符号算半个字）；",
        "- 具体、有信息量，说清楚读者能得到什么；不用「绝绝子」「天花板」「保姆级」这类夸张的营销词，不堆 emoji；",
        "- 5 个角度各不相同（比如结果、方法、反差、提问、清单）。",
        "不要修改 draft.md 和 title.txt。回复里只写一个 ```json 代码块，里面是正好 5 个字符串的 JSON 数组，不要编号、不要别的说明，例如：",
        "```json",
        '["标题一", "标题二", "标题三", "标题四", "标题五"]',
        "```",
      ].join("\n"),
    },
    hook: {
      label: "首图文案",
      prompt: [
        "给第一张卡片（首图）写一句抓人的文案，让人在信息流里愿意点进来：",
        "- 15 个字以内、口语，有具体的好处、反差或悬念，不夸张、不用营销腔；",
        "- 直接修改 draft.md：写成一级标题（# 文案）放在正文最前面；正文第一行已经是一级标题的，就换掉那一行；",
        `- 别处一个字都不改，${MARKERS}。`,
        "改完用一句话说明为什么这样写。",
      ].join("\n"),
    },
    humanize: {
      label: "去 AI 味",
      prompt: [
        "把 draft.md 改得像一个真人在分享自己的经历，去掉 AI 味：",
        "- 去掉「首先 / 其次 / 总之」「值得一提的是」「让我们一起」「不仅……而且……」这类套话，排比和对仗的堆砌，空泛的形容词、感叹和每段结尾的总结升华；",
        "- 换成自然、具体、带个人口吻的说法，句子长短错落，可以有一点口语和小情绪；",
        "- 事实、数字、观点、段落顺序和结构都不变，不编造没有的经历；",
        `- ${MARKERS}。`,
        "直接修改 draft.md，改完用一两句话说明主要改了什么。",
      ].join("\n"),
    },
    bolder: design("更醒目", "层次更分明、重点一眼能看到：标题更有分量，关键句换成提示或小标签，并列的要点排成标签列表或步骤，用 {{mark:类别|文字}} 标出关键词；不是每一块都要加重，留出对比。"),
    quieter: design("更安静", "去掉多余的强调与装饰：少用颜色和组件，标注只留最关键的，留白更多，读起来更从容。"),
    distill: design("精简", "每页只讲一件事：删掉重复和可有可无的句子，合并相近的段落，太挤的页拆开或挪走次要内容；每页控制在 180–280 字。"),
    colorize: design("上色", "给颜色一点作用：用 {{mark:类别|文字}} 把同一类的词标成同一种颜色，关键提示用提示框；颜色少而有用，不花哨。"),
    typeset: design("调字", "把字排得更好读：标题级别分明（用 restyle_block 的 headingLevel），字号与行距合适（set_style），长段拆短，数字、英文与中文混排不挤；需要时用 set_card_css 调字重与间距。"),
    layout: design("理版式", "让每一页有主次：开头一句点题（可换成小标签或大标题），要点用标签列表或步骤，结尾用页尾收一句；分页落在要点之间，不把一个要点拆到两页。"),
    caption: {
      label: "写小红书正文",
      prompt: [
        "照着这篇的卡片内容（draft.md）和标题，写发布时图片下面的那段小红书正文，直接写进 caption.txt（整个换掉原来的）：",
        "- 纯文本，不用 Markdown 和自定义标记；200–500 字，口语、像本人在分享，分两三段，开头一两句说清楚这篇讲什么、为什么值得看；",
        "- 不照抄卡片上的字，补一点卡片上没写的感受、背景或建议；不编造没有的经历，不用营销腔，emoji 最多两三个；",
        "- 最后一行写 3–5 个 #话题（# 紧跟词、话题之间空一格），caption.txt 里原来就有的话题留着；",
        "- 不要修改 draft.md 和 title.txt。",
        "写完用一句话说明这段正文的思路。",
      ].join("\n"),
    },
    repaginate: {
      label: "按要点重新分页",
      prompt: [
        "按要点重新分页：先用 get_pages 看看现在每页放了什么，再直接修改 draft.md 里的 [[分页]]（独占一行）：",
        "- 在要点之间插入、挪动或删掉多余的 [[分页]]，让每张卡片讲清一个要点，不要太满也不要只剩一两行；标题不要落在一页的最后；",
        "- 不要用 insert_page_break / remove_page_break / move_section 这些工具（改动要交给我逐处确认），也不要改文字内容；",
        `- ${OTHER_MARKERS}。`,
        "改完用一两句话说明分成了几页、每页讲什么。",
      ].join("\n"),
    },
  };

  // 显示宽度：一个字形（emoji 组合、带变体符的字算一个）按它的第一个码点：
  // 拉丁、希腊、西里尔等（U+1100 以前）与半角片假名、半角符号算 1，其余（汉字、全角标点、emoji……）算 2。
  const segmenter = new Intl.Segmenter("zh", { granularity: "grapheme" });
  function titleWidth(text) {
    let width = 0;
    for (const { segment } of segmenter.segment(String(text))) {
      const code = segment.codePointAt(0);
      width += code < 0x1100 || (code >= 0xff61 && code <= 0xffdc) || (code >= 0xffe8 && code <= 0xffee) ? 1 : 2;
    }
    return width;
  }

  function titleOption(text) {
    const width = titleWidth(text);
    return { text, width, over: width > TITLE_WIDTH_LIMIT };
  }

  // 一个候选：去掉加粗记号、「标题 1：」这类前缀、末尾的「（18 字）」与两头的空白和引号
  function cleanTitle(value) {
    return String(value)
      .replace(/\*\*/g, "")
      .replace(/^\s*标题\s*[\d一二三四五]?\s*[:：]/, "")
      .replace(/[（(]\s*\d+(?:\.\d+)?\s*字\s*[)）]\s*$/, "")
      .replace(/^["'“”‘’「」『』\s]+|["'“”‘’「」『』\s]+$/g, "");
  }

  // JSON 数组（代码块里的，或回复里裸写的）：合法的直接用；像数组却不合法（多了逗号、用了中文引号……）
  // 就取里面引号括起来的每一段。都不是时为 null。
  function fromArray(text) {
    const fenced = /```[a-z]*\s*([\s\S]*?)```/i.exec(text)?.[1];
    const array = /\[[\s\S]*\]/.exec(fenced ?? text)?.[0];
    if (!array) return null;
    try {
      const value = JSON.parse(array);
      if (Array.isArray(value)) return value.map((item) => (item && typeof item === "object" ? item.title ?? item.text : item));
    } catch {
      // 不是合法的 JSON：退而取引号里的
    }
    const quoted = [...array.matchAll(/"([^"\n]+)"|“([^”\n]+)”|「([^」\n]+)」/g)].map((match) => match[1] ?? match[2] ?? match[3]);
    return quoted.length ? quoted : null;
  }

  // 编号、圆点列表逐行读
  function fromList(text) {
    return text.split("\n").map((line) => /^\s*(?:\d+\s*[.)、．]|[-*•])\s*(.+)$/.exec(line)?.[1]).filter(Boolean);
  }

  // 回复里的标题候选：先找 JSON 数组，读不出再按列表逐行读；去重、去空，最多 5 个。什么都读不出时为 []。
  function parseTitles(text) {
    const reply = String(text || "");
    const titles = [];
    for (const value of fromArray(reply) ?? fromList(reply)) {
      const title = typeof value === "string" ? cleanTitle(value) : "";
      if (title && !titles.includes(title)) titles.push(title);
    }
    return titles.slice(0, TITLE_COUNT).map(titleOption);
  }

  // 应用给的适配（src/ai/host.js）：edit(patch) 一步可撤销地改稿子
  let host = null;

  // 在当前稿子的会话里发一条预设命令；「封面标题 5 选 1」的结果另带读出来的候选 titles
  async function run(name) {
    const preset = Object.hasOwn(PRESETS, name) ? PRESETS[name] : null;
    if (!preset) throw new TypeError(`没有这个预设命令：${name}（可用：${Object.keys(PRESETS).join("、")}）`);
    const result = await ai.api.send(preset.prompt, { kind: "command", label: preset.label, preset: name });
    return name === "coverTitles" ? { ...result, titles: parseTitles(result.reply) } : result;
  }

  // 把标题换成这个（点候选时）：撤销历史里的一步，⌘Z 撤回
  async function useTitle(title) {
    if (typeof title !== "string" || !title.trim()) throw new TypeError("标题需要是不空的字符串");
    const text = title.trim();
    await host.edit({ title: text });
    return mc().drafts.current();
  }

  ai.presets = {
    connect(adapter) {
      host = adapter;
    },
    PRESETS,
    TITLE_WIDTH_LIMIT,
    parseTitles,
    run,
    useTitle,
  };
})(window);
