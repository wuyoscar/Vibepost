// 操作手册：Vibepost 自己的块样式、组件、记号、插入项与排版经验的唯一来源。中文名是规范写法，英文名永远照样认。
// 从这里取的：解析器认哪些记号（src/engine/markdown.js）、卡片渲染与块操作（src/cards/html.js、blocks.js）、编辑器左上角的「样式」
// 与「插入」、「/」菜单、卡片上的「换样式」、AI 的说明书与工具说明、工作副本里的 AGENTS.md、外部 Agent 的握手说明与 get_manual、
// docs/manual.md（scripts/build-manual.mjs 生成，测试比对）、内置说明书的「样式与写法」。改这里，那些都跟着变。
// 片段（写好的示范段落）另有一张登记表 src/engine/snippets.js，手册末尾的「片段」一节从它取。
// 只有数据和把它写成文字的函数，不碰 DOM；Node 里也能载入（生成 docs/manual.md）。
(function (root) {
  "use strict";

  const freeze = root.MediaCraftEngine?.deepFreeze ?? ((value) => value);

  // ===== 块样式 =====
  // 段落类（text）的块在段落类里互换，列表类（list）的在列表类里互换（也能拆回正文）。component 为真的是组件：
  // 单独一行「:::名字」开头、单独一行「:::」收尾。glyph 是菜单里的字形，keys 是「/」菜单认的拼音缩写，body 是插入组件时预先填好的一行。
  const STYLES = [
    {
      id: "p", name: "正文", family: "text", glyph: "文", syntax: "直接写",
      summary: "普通的一段话", when: "大多数内容",
    },
    {
      id: "h1", name: "大标题", family: "text", glyph: "H1", syntax: "# 文字",
      summary: "这一页最大的字", when: "一篇的主标题、一页的大字", avoid: "一页里只放一个",
    },
    {
      id: "h2", name: "小标题", family: "text", glyph: "H2", syntax: "## 文字",
      summary: "分段的标题", when: "把一页分成几段",
    },
    {
      id: "h3", name: "三级标题", family: "text", glyph: "H3", syntax: "### 文字",
      summary: "最小一级的标题", when: "章节名、一条资讯的标题",
    },
    {
      id: "quote", name: "引用", family: "text", glyph: "❝", syntax: "> 文字",
      summary: "别人说的话，左边一条竖线", when: "原话、摘录",
    },
    {
      id: "kicker", name: "小标签", aliases: ["kicker"], family: "text", component: true, glyph: "签", keys: ["xbq", "xiaobiaoqian"],
      summary: "标题上方或旁边的一行小字", when: "来源、论文名、栏目名、日期", avoid: "章节名用三级标题，不用小标签",
      example: "论文：When Do Models Admit They Are Wrong?",
    },
    {
      id: "note", name: "提示", aliases: ["note"], family: "text", component: true, glyph: "注", keys: ["ts", "tishi"],
      summary: "带底色的一块提示", when: "结论、要点、注意事项",
      example: "所有问题放在同一个请求里并行发出。",
    },
    {
      id: "footnote", name: "页尾", aliases: ["footnote"], family: "text", component: true, glyph: "脚", keys: ["yw", "yewei"],
      summary: "这一页最底下的一行小字", when: "出处、图片来源、免责声明：放在这一页的最后一块",
      avoid: "写在页中间只会原地显示成小字、不贴底；论文名用小标签",
      example: "图片来源：作者自摄",
    },
    {
      id: "mono", name: "等宽", aliases: ["mono"], family: "text", component: true, glyph: "M", keys: ["dk", "dengkuan", "prompt"],
      summary: "等宽字体的一块，空格与对齐照原样", when: "prompt、命令、需要对齐的文字",
      example: "You are a helpful assistant.",
    },
    {
      id: "ul", name: "无序列表", family: "list", glyph: "•", syntax: "- 一项",
      summary: "圆点开头的几项", when: "并列的几点",
    },
    {
      id: "ol", name: "有序列表", family: "list", glyph: "1.", syntax: "1. 第一项",
      summary: "带编号的几项", when: "有先后、要数清楚的几点",
    },
    {
      id: "rows", name: "标签列表", aliases: ["rows"], family: "list", component: true, glyph: "▤", keys: ["bqlb", "biaoqian"], body: "- [类别] ",
      summary: "每项开头一个彩色胶囊标签（写成 [类别]）", when: "分类、对比、清单",
      example: "- [保留] 一句话说清楚要做什么\n- [删掉] 「只输出 JSON」这类格式指令",
    },
    {
      id: "steps", name: "步骤", aliases: ["steps"], family: "list", component: true, glyph: "①", keys: ["bz", "buzhou"], body: "- ",
      summary: "自动编号的步骤", when: "操作步骤、流程",
      example: "- 先把问题拆开\n- 每一块单独问\n- 最后合起来",
    },
  ];

  // 组件的对齐：写在开头那行名字后面（「:::提示 居中」），靠左是默认、不用写；也认 align=center 这种写法
  const ALIGNS = [
    { id: "left", name: "靠左", aliases: ["left", "居左", "左"] },
    { id: "center", name: "居中", aliases: ["center", "中"] },
    { id: "right", name: "靠右", aliases: ["right", "居右", "右"] },
  ];

  // ===== 记号：Vibepost 自己的写法 =====
  // words：开头的关键词（规范的中文在前，英文照样认）；冒号也认全角的「：」。values：取值的中文与英文。
  const MARKERS = [
    {
      id: "image", name: "图片", words: ["图片", "image"], syntax: "[[图片:编号]]",
      summary: "一张图或一段实况，独占一行", note: "编号由 App 生成：插图、拖进图片时自动写，不用手写",
    },
    {
      id: "pair", name: "拼图", words: ["图片", "image"], syntax: "[[图片:甲|乙]]　[[图片:甲|乙|4x3]]",
      summary: "两张图并排，独占一行", note: "比例 1x1、4x3、3x2、16x9（不写就是 16x9）",
    },
    {
      id: "pageBreak", name: "分页", syntax: "[[分页]]",
      summary: "独占一行，后面的内容从下一张卡片开始", note: "也可以按 ⌘↩",
    },
    {
      id: "endPage", name: "结尾页", syntax: "[[结尾]]",
      summary: "独占一行，后面的内容排成结尾页（居中、留白，最后是署名）", note: "关注引导、下期预告写在它后面",
    },
    {
      id: "color", name: "字色", words: ["字色", "color"], syntax: "{{字色:#d9480f|文字}}",
      summary: "给几个字换颜色", note: "选中文字用浮动条点一下最省事",
    },
    {
      id: "bg", name: "高亮", words: ["高亮", "bg"], syntax: "{{高亮:#fff3bf|文字}}",
      summary: "给几个字加底色",
    },
    {
      id: "underline", name: "下划线", words: ["下划线", "underline"], syntax: "{{下划线:实线|文字}}　{{下划线:虚线|文字}}",
      summary: "实线或虚线的下划线",
      values: [{ id: "solid", name: "实线", aliases: ["solid"] }, { id: "dashed", name: "虚线", aliases: ["dashed"] }],
    },
    {
      id: "mark", name: "标注", words: ["标注", "mark"], syntax: "{{标注:类别|文字}}",
      summary: "按类别上色", note: "同一个类别在一篇里颜色固定，标签列表里同名的 [类别] 也是这个颜色",
    },
  ];

  // 通用的 Markdown 行内格式（照常写）
  const INLINE = [
    ["**加粗**", "加粗"], ["*斜体*", "斜体"], ["~~删除线~~", "删除线"], ["`代码`", "行内代码"], ["[文字](https://…)", "链接"],
  ];

  // ===== 插入：「插入」菜单与「/」菜单里不是样式的那几项（组件也能插入，见 STYLES）=====
  const INSERTS = [
    { id: "image", name: "图片或 PDF", glyph: "图", keys: ["image", "pdf", "tp", "tupian"], summary: "从这台 Mac 选图片或 PDF（PDF 每页一张图）" },
    { id: "live", name: "实况视频", glyph: "实", keys: ["live", "video", "sk", "shikuang"], summary: "选一段视频做成实况" },
    { id: "divider", name: "分割线", glyph: "—", keys: ["hr", "divider", "fgx", "fengexian"], summary: "一条细线隔开上下" },
    { id: "pageBreak", name: "分页", glyph: "页", keys: ["page", "fy", "fenye"], shortcut: "⌘↩", summary: "后面的内容从下一张卡片开始" },
    { id: "endPage", name: "结尾页", glyph: "尾", keys: ["end", "jw", "jiewei"], summary: "后面的内容排成结尾页：居中、留白，最后是署名" },
    { id: "code", name: "代码块", glyph: "</>", keys: ["code", "dm", "daima"], summary: "原样显示的代码" },
  ];

  // ===== 排版经验（跟模型无关，人和 Agent 都照着做）=====
  const LESSONS = [
    "来源、论文名这类挂在标题旁边的小字用小标签，不用页尾。",
    "页尾只放在一页的最后一块（出处、免责声明）；写在中间不贴底，只是原地的一行小字。",
    "章节名用三级标题。标题会带着后面第一段一起换页，不要让一页只剩一个章节名。",
    "一张卡片 180–280 字最好读，超过 300 字偏挤。一条一页（每条后面写 [[分页]]）时，溢出就收紧文字或拆成两页，太空就和上一条并成一页。",
    "颜色少而有用：同一类的词用同一个标注，关键的一句放提示框；不要整段上色。",
    "块与块之间的距离是这篇的段距（检查器「版式 › 段距」，set_style 的 blockGap，默认 0.55 行）；觉得太空就调小，不要靠连续空行、空段落或多余的 [[分页]] 撑开或拉开间距。",
    "排完版看一遍每页的问题（只有标题、太空、溢出），逐页处理好再交差。",
  ];

  // ===== 查找 =====

  const byKey = new Map();
  for (const style of STYLES) for (const key of [style.id, style.name, ...(style.aliases ?? [])]) byKey.set(key, style);
  const alignByKey = new Map();
  for (const align of ALIGNS) for (const key of [align.id, align.name, ...align.aliases]) alignByKey.set(key, align);

  // 块样式：id、中文名、英文名都认
  const style = (key) => byKey.get(String(key ?? "")) ?? null;
  // 组件（不是组件的样式为 null）
  const component = (key) => (style(key)?.component ? style(key) : null);
  const marker = (id) => MARKERS.find((item) => item.id === id) ?? null;

  // 组件的对齐：attrs 是解析器读出的属性（align=… 或单独一个词），认不出时 null
  function alignOf(attrs = {}) {
    if (typeof attrs.align === "string" && alignByKey.has(attrs.align)) return alignByKey.get(attrs.align).id;
    for (const [key, value] of Object.entries(attrs)) if (value === true && alignByKey.has(key)) return alignByKey.get(key).id;
    return null;
  }
  const alignName = (id) => ALIGNS.find((align) => align.id === id)?.name ?? null;

  // 对齐以外的属性（自定义样式用的 variant 之类）
  function otherAttrs(attrs = {}) {
    return Object.fromEntries(Object.entries(attrs).filter(([key, value]) => key !== "align" && !(value === true && alignByKey.has(key))));
  }

  // 组件开头一行（规范写法）：「:::中文名」，对齐写成一个词（靠左不写），别的属性照「键=值」
  function opener(name, attrs = {}) {
    const known = component(name);
    const align = alignOf(attrs);
    const parts = Object.entries(otherAttrs(attrs)).filter(([, value]) => value !== null && value !== undefined && value !== false)
      .map(([key, value]) => (value === true ? key : /[\s"]/.test(String(value)) ? `${key}="${String(value).replace(/"/g, "")}"` : `${key}=${value}`));
    return `:::${[known ? known.name : name, ...(align && align !== "left" ? [alignName(align)] : []), ...parts].join(" ")}`;
  }

  // 解析器用的词表：开头的关键词 → 记号 id；下划线的取值 → solid / dashed
  const markerWords = Object.fromEntries(MARKERS.filter((item) => item.words && item.id !== "pair").map((item) => [item.id, item.words]));
  const underlineValues = Object.fromEntries(marker("underline").values.flatMap((value) => [value.id, value.name, ...value.aliases].map((key) => [key, value.id])));
  // 规范写法（写进稿子用）
  const spanOpener = (id, value) => `{{${marker(id).name}:${id === "underline" ? marker("underline").values.find((item) => item.id === value)?.name ?? value : value}|`;
  const imageTag = (ids, ratio) => `[[图片:${ids.join("|")}${ratio ? `|${ratio}` : ""}]]`;

  // ===== 写成文字 =====

  const componentExample = (item) => `:::${item.name}\n${item.example ?? "内容"}\n:::`;
  // 「用在……」：后面紧跟英文时隔一个空格
  const how = (item) => [item.when && `用在${/^[A-Za-z]/.test(item.when) ? " " : ""}${item.when}`, item.avoid].filter(Boolean).join("；");
  // 行内代码（里面有反引号时用两个反引号包）；表格的格子里竖线要转义，不然表格会断
  const code = (text) => (text.includes("`") ? `\`\` ${text} \`\`` : `\`${text}\``);
  const cell = (text) => text.replace(/\|/g, "\\|");

  // 完整的操作手册（Markdown）：工作副本里的 AGENTS.md、外部 Agent 的 get_manual、docs/manual.md 都是它
  function document() {
    const lines = [
      "# Vibepost 操作手册",
      "",
      "Vibepost 把一篇 Markdown 排成小红书的图文卡片（也能排成公众号长文）。这份手册只讲 App 认得的写法与排版经验，跟用哪个模型无关；写什么内容、什么口味看写作手册。",
      "",
      "- 每一行在卡片上另起一行，空行分段；放不下自动换到下一张。",
      "- 下面的中文写法是规范写法，英文写法（`:::kicker`、`[[image:…]]`、`{{color:…|…}}`）也照样认，App 收下稿子时会换成中文。",
      "- 代码块、行内代码里的记号只是文字。",
      "",
      "## 块样式",
      "",
      "一块就是空行隔开的一段（或一个组件）。在编辑器左上角「样式」、卡片上点选一块后的「换样式」里都能换；同一类里互换（段落类在段落类里，列表类在列表类里），列表也能拆回正文。",
      "",
      "| 样式 | 写法 | 是什么 | 什么时候用 |",
      "| --- | --- | --- | --- |",
      ...STYLES.map((item) => {
        const syntax = item.component ? `${code(`:::${item.name}`)} … ${code(":::")}` : item.id === "p" ? item.syntax : code(item.syntax);
        return `| ${item.name} | ${syntax} | ${cell(item.summary)} | ${cell(how(item) || "—")} |`;
      }),
      "",
      "## 组件",
      "",
      "单独一行 `:::名字` 开头、单独一行 `:::` 收尾，中间照常写 Markdown（可以嵌套）；没有收尾时按普通文字显示。",
      "对齐写在名字后面：`:::提示 居中`、`:::提示 靠右`（靠左是默认，不用写）。认不出的名字不报错，渲染成 `class=\"mc-c c-名字\"` 的容器，留给这篇的卡片样式。",
      "",
      ...STYLES.filter((item) => item.component).flatMap((item) => [
        `### ${item.name}（${item.aliases.join("、")}）`,
        "",
        `${item.summary}。${how(item)}。`,
        "",
        "```",
        componentExample(item),
        "```",
        "",
      ]),
      "## 记号",
      "",
      // 列表而不是表格：记号里有竖线，表格要转义成 \|，Agent 照抄就写坏了
      ...MARKERS.map((item) => `- ${item.name} ${item.syntax.split("　").map(code).join("、")}：${[item.summary, item.note].filter(Boolean).join("；")}。`),
      "",
      "- 记号要照原样保留：改稿时不要改写、翻译、挪动或删掉它们（换样式、挪图片用 App 的工具）。",
      "- 冒号、竖线两侧不加空格；色值是 `#` 加 3–8 位十六进制数。",
      "",
      "## 行内格式",
      "",
      INLINE.map(([syntax, name]) => `${code(syntax)} ${name}`).join("、") + "；标题 `#`、引用 `>`、列表 `-` / `1.`、表格、分割线 `---` 照常写。",
      "",
      "## 排版经验",
      "",
      ...LESSONS.map((lesson) => `- ${lesson}`),
      "",
      // 片段（src/engine/snippets.js，在这个文件之后载入）：每个片段的名字、什么时候用、写法
      root.MediaCraftSnippets.document(),
      "",
    ];
    return lines.join("\n");
  }

  // 给 App 里 AI 的说明书用的短版（一行一项）；完整的在工作副本的 AGENTS.md
  function brief() {
    return [
      "- 块样式（段落类）：" + STYLES.filter((item) => item.family === "text").map((item) => `${item.name} ${item.component ? `:::${item.name}` : item.syntax}`).join("；") + "。",
      "- 块样式（列表类）：" + STYLES.filter((item) => item.family === "list").map((item) => `${item.name} ${item.component ? `:::${item.name}` : item.syntax}`).join("；") + "。",
      "- 组件：单独一行 :::名字（对齐写在后面，如 :::提示 居中）到单独一行 :::，开头和收尾两行都要留着。",
      "- 记号：" + MARKERS.map((item) => `${item.syntax.replace(/　/g, " 或 ")} ${item.name}`).join("；") + "。",
      "- 片段（写好的示范段落，用工具 insert_section 插，写法见 AGENTS.md 的「片段」一节）：" + root.MediaCraftSnippets.list.map((item) => item.name).join("、") + "。",
      ...LESSONS.map((lesson) => `- ${lesson}`),
    ].join("\n");
  }

  const manual = {
    styles: STYLES,
    aligns: ALIGNS,
    markers: MARKERS,
    inline: INLINE,
    inserts: INSERTS,
    lessons: LESSONS,
    style,
    component,
    marker,
    alignOf,
    alignName,
    otherAttrs,
    opener,
    markerWords,
    underlineValues,
    spanOpener,
    imageTag,
    document,
    brief,
  };
  freeze(STYLES);
  freeze(ALIGNS);
  freeze(MARKERS);
  freeze(INLINE);
  freeze(INSERTS);
  freeze(LESSONS);
  root.MediaCraftManual = Object.freeze(manual);
})(globalThis);
