// 内置说明书「样式与写法」：一张卡片讲一种写法，先看排出来的样子，再看怎么写、什么时候用；最后是排版经验。
// 正文由操作手册登记表（src/engine/manual.js，window.MediaCraftManual）写出：登记表里的样式、组件、对齐、记号与排版经验
// 改了，这篇跟着变，不用另外改。index.html 里 manual.js 排在 markdown.js 前面（解析器也要它），所以这里载入时就能写出来。
// 卡片上的字大，一张放一块示范加百来字说明正好；逐条列的（记号、排版经验）按字数分到几张卡片上。
(function (root) {
  "use strict";

  const manual = root.MediaCraftManual;
  const PAGE_BREAK = "[[分页]]";
  // 一张卡片上逐条列的说明最多多少字（Markdown 原文，不算空白）：默认主题里排到六七成，字大的主题也放得下
  const LIST_BUDGET = 150;

  // 行内代码（里面有反引号时用两个反引号包，同 manual.js）
  const code = (text) => (text.includes("`") ? `\`\` ${text} \`\`` : `\`${text}\``);
  // 「用在……；别这样……」（when 开头是英文时隔一个空格）
  const how = (item) => [item.when && `用在${/^[A-Za-z]/.test(item.when) ? " " : ""}${item.when}`, item.avoid].filter(Boolean).join("；");
  // 几句连成一段，句号收尾
  const sentence = (...parts) => `${parts.filter(Boolean).join("。")}。`;
  // 写法里的前缀（「# 文字」的 #、「1. 第一项」的 1.），没有前缀（正文「直接写」）时 null
  const prefixOf = (style) => (/^\S+ /.test(style.syntax ?? "") ? style.syntax.split(" ")[0] : null);
  // 组件的一整块：开头一行、内容、收尾一行
  const componentBlock = (item, body, attrs) => [manual.opener(item.name, attrs), ...String(body).split("\n"), ":::"];
  const length = (text) => text.replace(/\s/g, "").length;

  // 逐条的说明按字数分成几组，每组一张卡片（一条再长也自成一组）
  function pack(entries, size = length) {
    const groups = [];
    let used = Infinity;
    for (const entry of entries) {
      if (used + size(entry) > LIST_BUDGET) {
        groups.push([]);
        used = 0;
      }
      groups.at(-1).push(entry);
      used += size(entry);
    }
    return groups;
  }

  // 第一张：这篇讲什么、三类写法
  function cover() {
    return [
      ...componentBlock(manual.component("kicker") ?? { name: "小标签" }, "内置说明书"),
      "",
      "# 样式与写法",
      "",
      "一张卡片一种写法：先看排出来的样子，再看怎么写、什么时候用。",
      "",
      "- **块样式**：整块换个样子，左上角「样式」里点选",
      "- **组件**：`:::名字` 开头、`:::` 收尾的一块",
      "- **记号**：写在行里的 `[[…]]` 与 `{{…}}`",
      "",
      "中文是规范写法，英文的也照样认。这篇只读，点 **+** 新建一篇边看边试。",
    ];
  }

  // 不是组件的块样式：有前缀的排一块看样子，下面一行写法与用处；没有前缀的（正文）只写短短一行「正文直接写，用在……」
  function plainStyle(style) {
    const prefix = prefixOf(style);
    if (!prefix) return [`${style.name}${style.syntax}${how(style) ? `，${how(style)}` : ""}。`];
    return [`${prefix} ${style.name}`, "", sentence(`${code(style.syntax)}：${style.summary}`, how(style))];
  }

  // 标题一张（大标题打头，就是这张的标题），引用与列表一张（引用打头，正文那一行垫底）
  function plainStyles() {
    const plain = manual.styles.filter((style) => !style.component);
    const headings = plain.filter((style) => prefixOf(style)?.startsWith("#"));
    const text = plain.filter((style) => !prefixOf(style));
    const rest = plain.filter((style) => !headings.includes(style) && !text.includes(style));
    const join = (styles) => styles.flatMap((style) => ["", ...plainStyle(style)]).slice(1);
    return [join(headings), join([...rest, ...text])];
  }

  // 组件：一张一个，名字做标题，排一块看样子，再写用处、写法（代码块里照原样）与从哪里插、英文名。
  // 小标签挂在标题上方，示范也放在标题上方；页尾只在一页最后一块时贴底，示范放在最后。
  function componentCard(item) {
    const live = componentBlock(item, item.example ?? item.name);
    const written = ["```", ...componentBlock(item, item.example ?? "内容"), "```"];
    const slash = code(item.keys?.length ? `/${item.keys[0]}` : "/");
    const insert = `「插入」或行首 ${slash} 都能插${item.aliases?.length ? `，英文 ${code(`:::${item.aliases[0]}`)} 也认` : ""}`;
    const said = sentence(item.summary, how(item), insert);
    if (item.id === "kicker") return [...live, "", `## ${item.name}`, "", said, "", ...written];
    if (item.id === "footnote") return [`## ${item.name}`, "", said, "", ...written, "", ...live];
    return [`## ${item.name}`, "", ...live, "", said, "", ...written];
  }

  // 组件的对齐：拿提示框排一遍每种不是默认的对齐，再写写法
  function alignCard() {
    const target = manual.component("note") ?? manual.styles.find((style) => style.component);
    const aligned = manual.aligns.filter((align) => align.id !== "left");
    return [
      "## 对齐",
      "",
      ...aligned.flatMap((align) => [...componentBlock(target, `${align.name}的${target.name}`, { align: align.id }), ""]),
      `组件的对齐写在名字后面：${aligned.map((align) => code(manual.opener(target.name, { align: align.id }))).join("、")}；${manual.alignName("left")}是默认，不用写。也可以在左上角「样式」里点。`,
    ];
  }

  // 通用的行内格式：排出来的样子在前，写法在后（排出来的字不是格式的名字时再写名字）；代码与记号的关系也在这里说
  function inlineCard() {
    const shown = (syntax) => syntax.replace(/\[([^\]]*)\]\([^)]*\)/, "$1").replace(/[*~`]/g, "");
    return [
      "## 行内格式",
      "",
      ...manual.inline.map(([syntax, name]) => `- ${syntax} ${code(syntax)}${shown(syntax) === name ? "" : `：${name}`}`),
      "",
      "标题 `#`、引用 `>`、列表、表格、分割线 `---` 照常写。",
      "",
      "代码块、行内代码里的记号只是文字：要在稿子里写出 `[[分页]]` 这几个字，就放进反引号。",
    ];
  }

  // 一个记号的几种写法（登记表里用全角空格隔开）
  const variants = (item) => item.syntax.split("　");
  // 行内记号排出来的样子：一种写法时字就是记号的名字，几种写法时是各自的取值（实线、虚线）
  const rendered = (item) => variants(item).map((syntax) => {
    const value = syntax.match(/^\{\{[^:]+:([^|]+)\|/)?.[1];
    return syntax.replace(/\|[^|]*\}\}$/, `|${variants(item).length > 1 ? value : item.name}}}`);
  });
  const isSpan = (item) => item.syntax.startsWith("{{");
  const said = (item) => [item.summary, item.note].filter(Boolean).join("；");

  // 记号：行内的（字色、高亮……）先排出来看样子再写写法，整行的（图片、分页……）在卡片上就不是字了，只写写法与用处。
  // 按字数分几张，每张的标题是这张上记号的名字；第一张行内记号说一句色值怎么写，最后一张说一句这篇自己的分页
  function markerCards() {
    const entries = manual.markers.map((item) => ({
      item,
      line: `- ${isSpan(item) ? rendered(item).join(" ") : item.name} ${variants(item).map(code).join("、")}：${said(item)}。`,
    }));
    const groups = [
      ...pack(entries.filter((entry) => isSpan(entry.item)), (entry) => length(entry.line)),
      ...pack(entries.filter((entry) => !isSpan(entry.item)), (entry) => length(entry.line)),
    ];
    const cards = groups.map((group) => [`## ${group.map((entry) => entry.item.name).join("、")}`, "", ...group.map((entry) => entry.line)]);
    const spans = groups.findIndex((group) => isSpan(group[0].item));
    if (spans >= 0) cards[spans].push("", "冒号、竖线两侧不加空格；色值是 `#` 加 3–8 位十六进制数。");
    cards.at(-1).push("", `这篇每两张卡片之间就是单独一行 ${code(PAGE_BREAK)}。`);
    return cards;
  }

  // 排版经验：一条一项，接着编号；放不下一张时分几张，后面的标题写「续」
  function lessonCards() {
    let number = 0;
    return pack(manual.lessons).map((group, index) => [
      `## 排版经验${index ? "（续）" : ""}`,
      "",
      ...group.map((lesson) => `${number += 1}. ${lesson}`),
    ]);
  }

  // 一张卡片一节，节与节之间单独一行 [[分页]]
  function markdown() {
    const cards = [
      cover(),
      ...plainStyles(),
      ...manual.styles.filter((style) => style.component).map(componentCard),
      alignCard(),
      inlineCard(),
      ...markerCards(),
      ...lessonCards(),
    ];
    return cards.flatMap((card, index) => (index ? ["", PAGE_BREAK, "", ...card] : card));
  }

  root.MediaCraftGuides.define({
    id: "guide_styles",
    title: "样式与写法",
    mode: "cards",
    markdown: markdown(),
    images: {},
  });
})(window);
