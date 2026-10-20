// AI 预设命令：针对小红书的几条固定的话，和一键润色一样发进当前稿子的同一个会话（src/ai/session.js）。
// 「封面标题 5 选 1」不改稿子，回复里给 5 个候选（JSON 数组），这里读出来、按显示宽度（全角 2、半角 1，
// 小红书标题上限 20 个全角字）算长度，点一个写进标题框（撤销历史里的一步）；
// 「首图文案」「去 AI 味」「按要点重新分页」直接改 draft.md，「写小红书正文」照着卡片内容写 caption.txt（图片下面的那段），
// 「一键排版」与设计方向（收紧留白、更醒目……）先看每页再用排版工具改（分页、换样式、字号行距段距），不动措辞；
// 改动照常进修改对比逐处确认。写字的几条（标题、首图、去 AI 味、正文、精简）照内置写作技能（src/skills/写作.md）的说法。
// 对外是 mediacraft.ai.preset / useTitle，见 docs/app-api.md。
(function (root) {
  "use strict";

  const ai = (root.MediaCraftAI ||= {});
  const mc = () => root.mediacraft;

  // 小红书标题最多 20 个全角字，也就是 40 个显示宽度
  const TITLE_WIDTH_LIMIT = 40;
  const TITLE_COUNT = 5;
  // 要原样保留的自定义标记：写法照操作手册（src/engine/manual.js）
  const manual = root.MediaCraftManual;
  const markers = (ids) => ids.map((id) => `${manual.marker(id).syntax.split("　")[0]} ${manual.marker(id).name}`).join("、");
  const MARKERS = `保留所有自定义标记（${markers(["image", "pageBreak", "color", "bg", "underline", "mark"])}、:::组件）和 #话题标签，原样不动`;
  const OTHER_MARKERS = `其余自定义标记（${markers(["image", "color", "bg", "underline", "mark"])}、:::组件）和 #话题标签原样保留`;
  const MARK = manual.marker("mark").syntax;

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
        "- 照写作技能「标题」那几条：说具体的事（谁、做了什么、发现了什么），从正文里来、正文能兑现；不用「震惊」「绝绝子」「天花板」「保姆级」这类夸张的营销词，不堆 emoji；",
        "- 5 个角度各不相同（比如结果、反差、一个数字、一个问题、清单），不只换近义词。",
        "不要修改 draft.md 和 title.txt。回复里只写一个 ```json 代码块，里面是正好 5 个字符串的 JSON 数组，不要编号、不要别的说明，例如：",
        "```json",
        '["标题一", "标题二", "标题三", "标题四", "标题五"]',
        "```",
      ].join("\n"),
    },
    hook: {
      label: "首图文案",
      prompt: [
        "给第一张卡片（首图）写一句文案，让人在信息流里一眼看出这篇讲的是什么事：",
        "- 15 个字以内、口语，是一句具体的话（一件事、一个结果、一个数字或反差），从正文里来、正文能兑现；不夸张、不用营销腔，不写成抽象的概念；",
        "- 直接修改 draft.md：写成一级标题（# 文案）放在正文最前面；正文第一行已经是一级标题的，就换掉那一行；",
        `- 别处一个字都不改，${MARKERS}。`,
        "改完用一句话说明为什么这样写。",
      ].join("\n"),
    },
    humanize: {
      label: "去 AI 味",
      prompt: [
        "照写作技能的「AI 腔清单」把 draft.md 里的 AI 味去掉：",
        "- 改掉「不是……而是……」的假翻转、排比金句、「首先 / 其次 / 总之」「值得注意的是」「这提醒我们」、成串的「标签：内容」冒号句、空泛的不确定和大词，删掉结尾的总结升华；",
        "- 删完读不通的地方用作者原来的说法补上，用作者自己的词（圈内说法、中英夹杂照留）；不加假口语、口癖和没有的情绪；",
        "- 事实、数字、观点、段落顺序和结构都不变，不编造没有的经历；",
        `- ${MARKERS}。`,
        "直接修改 draft.md，改完用一两句话说明主要改了什么。",
      ].join("\n"),
    },
    // 一键排版：AI 助手主要是帮着排版的。只动版式（分页、块的样式、字号行距段距），不动措辞
    autoLayout: {
      label: "一键排版",
      prompt: [
        "把这篇卡片排版好，只动版式、不改措辞：",
        "- 先用 get_pages 看每页的摘要、填充（fill）和排版自检的问题（⚠），再用 view_page 看几页实际的样子，想清楚再动手；",
        "- 分页：每页讲清一个要点，分页落在要点之间，不把一个要点拆到两页，标题不落在一页的最后；太空的页合并，太挤的拆开（insert_page_break / remove_page_break / move_section）；",
        "- 块的样式（restyle_block）：开头点题的一句可以做小标签或大标题，并列的要点做成标签列表或步骤，补充说明用提示，出处、来源放这一页最后的页尾；不是每块都要加样式；",
        "- 间距：块与块之间不要空得太开，用 set_style 的 blockGap 调（一般 0.4–0.7），不要靠空行、空段落或多余的分页撑开；字号、行距（set_style）让每页读起来舒服，一页别只剩两三行；",
        "- 不改、不删、不编造文字，所有自定义标记原样保留；需要时可以用 set_card_css 做这一篇自己的细调。",
        "做完再用 get_pages 看一遍，用两三句话说明改了什么。",
      ].join("\n"),
    },
    tighten: design("收紧留白", "块与块之间空得太开、页面下半截空着时收紧：用 set_style 把 blockGap 调到 0.35–0.5，去掉多余的空行、空段落和不必要的 [[分页]]，让本该在一页的内容回到一页；措辞一个字都不改，也不删内容。"),
    bolder: design("更醒目", `层次更分明、重点一眼能看到：标题更有分量，关键句换成提示或小标签，并列的要点排成标签列表或步骤，用 ${MARK} 标出关键词；不是每一块都要加重，留出对比。`),
    quieter: design("更安静", "去掉多余的强调与装饰：少用颜色和组件，标注只留最关键的，留白更多，读起来更从容。"),
    distill: design("精简", "每页只讲一件事：删掉套话、重复的总结和同一件事说了两遍的句子，合并重复的版块；过程、失败的版本和例子不删，太挤的页拆开；每页控制在 180–280 字。"),
    colorize: design("上色", `给颜色一点作用：用 ${MARK} 把同一类的词标成同一种颜色，关键提示用提示框；颜色少而有用，不花哨。`),
    typeset: design("调字", "把字排得更好读：标题级别分明（用 restyle_block 的 headingLevel），字号与行距合适（set_style），长段拆短，数字、英文与中文混排不挤；需要时用 set_card_css 调字重与间距。"),
    layout: design("理版式", "让每一页有主次：开头一句点题（可换成小标签或大标题），要点用标签列表或步骤，出处、来源放在这一页最后的页尾；分页落在要点之间，不把一个要点拆到两页。"),
    caption: {
      label: "写小红书正文",
      prompt: [
        "照着这篇的卡片内容（draft.md）和标题，写发布时图片下面的那段小红书正文，直接写进 caption.txt（整个换掉原来的）：",
        "- 照写作技能「小红书正文」那几条：纯文本，不用 Markdown 和自定义标记；200–500 字，像发帖时在图片下面跟朋友说两句，分两三段，开头一两句说清楚这篇讲的是什么事、为什么发；",
        "- 不照抄卡片上的字，可以补卡片上放不下的背景、出处；不编造卡片和素材里都没有的经历、感受，不用营销腔，不升华，emoji 最多两三个；",
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
  async function run(name, options = {}) {
    const preset = Object.hasOwn(PRESETS, name) ? PRESETS[name] : null;
    if (!preset) throw new TypeError(`没有这个预设命令：${name}（可用：${Object.keys(PRESETS).join("、")}）`);
    const result = await ai.api.send(preset.prompt, { skills: options.skills, kind: "command", label: preset.label, preset: name });
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
