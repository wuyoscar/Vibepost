// App 自己的工具：AI 会话里的 Claude 直接操作 MediaCraft（换主题、调样式、分页、挪段落、插片段、摆图片、看出图、放配图候选、列模板与照模板新建）。
// 这是一个 MCP 服务（服务名 mediacraft，工具全名 mcp__mediacraft__<名字>），不另起进程：claude 经控制通道发来
// mcp_message，src/ai/session.js 转给这里的 handle()，回答 initialize / tools/list / tools/call。
// 工具只经 App API（window.mediacraft）读写，页面是唯一的真相。改稿子的工具每次都是一个「动作」：会话里列一行、附上撤销的办法，
// 同时是撤销历史里的一步（⌘Z）；正文的结构改动（分页、段落顺序、图片位置）是纯函数 markdown → markdown，同样套到工作副本的
// draft.md 上，Claude 读到的与编辑器一致。
// 外部 Agent（MCP，src/mcp/）也用标了 shared 的这几个工具（经 shared.call），描述里 app 那一句只给 AI 助手、external 那一句只给外部 Agent。
(function (root) {
  "use strict";

  const mc = () => root.mediacraft;
  const native = root.MediaCraftNative?.ai ?? null;
  const { parseMarkdown } = root.MediaCraftEngine;
  // 五个颜色角色的名字与用处（src/engine/colors.js）
  const { ROLES, ROLE_INFO } = root.MediaCraftEngine.colors;

  const PROTOCOL_VERSION = "2025-06-18";
  const PAGE_BREAK = "[[分页]]";
  const CANDIDATE_LIMIT = 8;
  // 配图候选最多问几轮（第一轮是网上的、目录以外的，之后每轮是下载途中重定向到的别的站点）
  const APPROVAL_ROUNDS = 3;
  // 生图：一次最多几张、默认尺寸（竖图，配 3:4 卡片）、每边的像素范围
  const IMAGE_COUNT = [1, 4];
  const IMAGE_SIZE = "1024x1536";
  const IMAGE_EDGE = [256, 3840];
  const CLIP = 24;
  // 看一页时给 Claude 的图：864 × 1152 的卡片缩到这么宽（文字仍看得清）
  const VIEW_WIDTH = 540;
  const RANGES = { fontSize: [18, 40], lineHeight: [1, 2.4], blockGap: [0.1, 1.5], imageMaxHeight: [220, 1048], cardHeight: [1152, 1728] };
  const WIDTH_PERCENT = [25, 100];
  const FIXED_WIDTH = [80, 780];
  const FIXED_HEIGHT = [80, 1048];
  const ALIGNS = ["left", "center", "right"];
  const ALIGN_NAMES = { left: "靠左", center: "居中", right: "靠右" };
  const FONT_NAMES = { zh: "中文字体", en: "英文字体", code: "代码字体" };
  const BLOCK_NAMES = {
    heading: "标题", paragraph: "段落", quote: "引用", list: "列表", code: "代码块", table: "表格",
    image: "图片", imagePair: "拼图", rule: "分割线",
  };

  const clip = (text, length = CLIP) => {
    const flat = String(text ?? "").replace(/\s+/g, " ").trim();
    return flat.length > length ? `${flat.slice(0, length - 1)}…` : flat;
  };
  const reply = (text) => ({ content: [{ type: "text", text }] });
  const json = (value) => JSON.stringify(value, null, 1);

  // ===== 在正文里定位 =====

  const runsText = (runs = []) => runs.map((run) => run.text).join("");

  // 一块的文字（去掉标记），和源码一起用来找原文
  function blockText(block) {
    switch (block.type) {
      case "heading": return runsText(block.runs);
      case "paragraph":
      case "quote": return block.lines.map((line) => runsText(line.runs)).join("\n");
      case "list": return block.items.map((item) => runsText(item.runs)).join("\n");
      case "code": return block.text;
      case "table": return [block.header, ...block.rows].map((row) => row.cells.map((cell) => runsText(cell.runs)).join(" | ")).join("\n");
      case "image": return block.imageId ?? block.alt ?? "";
      case "imagePair": return block.imageIds.join(" ");
      default: return "";
    }
  }

  // 包含 anchor 这段原文的那一块（下标）；没有或不止一块时说明原因
  function findBlock(doc, markdown, anchor) {
    const wanted = String(anchor ?? "").trim();
    if (!wanted) throw new TypeError("要给一段稿子里的原文来定位");
    const hits = doc.blocks.flatMap((block, index) => (
      markdown.slice(...block.source).includes(wanted) || blockText(block).includes(wanted) ? [index] : []
    ));
    if (!hits.length) throw new Error(`稿子里找不到「${clip(wanted)}」（原文要照抄、不跨行）`);
    if (hits.length > 1) throw new Error(`「${clip(wanted)}」出现在 ${hits.length} 处，请给更长、只出现一次的一段原文`);
    return hits[0];
  }

  // 一块所在的「单元」：标题连同下面的内容（到下一个同级或更高级的标题为止，不含末尾的分页），其余的块就是它自己
  function unitOf(doc, index) {
    const block = doc.blocks[index];
    let last = index;
    if (block.type === "heading") {
      for (let next = index + 1; next < doc.blocks.length; next += 1) {
        const candidate = doc.blocks[next];
        if (candidate.type === "heading" && candidate.level <= block.level) break;
        last = next;
      }
      while (last > index && doc.blocks[last].type === "pageBreak") last -= 1;
    }
    return { start: block.source[0], end: doc.blocks[last].source[1] };
  }

  // 单元占的行：[第一行, 最后一行]（从 0 数）
  function lineRange(markdown, { start, end }) {
    const lineAt = (offset) => markdown.slice(0, offset).split("\n").length - 1;
    return [lineAt(start), lineAt(Math.max(start, end - 1))];
  }

  // before / after 两个里给一个：插在那一单元之前（第一行）或之后（最后一行的下一行）；anchorLines 是定位的那一块自己占的行
  function placeOf(markdown, args) {
    const keys = ["before", "after"].filter((key) => args[key] !== undefined && args[key] !== null && args[key] !== "");
    if (keys.length !== 1) throw new TypeError("before 与 after 要给、且只给一个");
    const doc = parseMarkdown(markdown);
    const index = findBlock(doc, markdown, args[keys[0]]);
    const [first, last] = lineRange(markdown, unitOf(doc, index));
    const [start, end] = doc.blocks[index].source;
    return {
      at: keys[0] === "before" ? first : last + 1,
      anchorLines: lineRange(markdown, { start, end }),
      key: keys[0],
      anchor: String(args[keys[0]]).trim(),
    };
  }

  const blank = (line) => line !== undefined && !line.trim();

  // 在第 at 行之前放进几行，和上下的内容之间各留一个空行（原来就有空行的不再加）
  function insertLines(lines, at, block) {
    const above = lines.slice(0, at);
    const below = lines.slice(at);
    const gapAbove = above.length && !blank(above.at(-1)) ? [""] : [];
    const gapBelow = below.length && !blank(below[0]) ? [""] : [];
    return [...above, ...gapAbove, ...block, ...gapBelow, ...below];
  }

  // 拿掉第 first–last 行：之后上下都是空行（或稿子头尾）时顺带删掉一个空行，免得多出一段空白；
  // 上下都是字时留一个空行，免得两段并成一段
  function removeLines(lines, first, last) {
    const next = [...lines.slice(0, first), ...lines.slice(last + 1)];
    const openAbove = first === 0 || blank(next[first - 1]);
    const openBelow = first >= next.length || blank(next[first]);
    if (openAbove && openBelow) {
      if (blank(next[first])) next.splice(first, 1);
      else if (blank(next[first - 1])) next.splice(first - 1, 1);
    } else if (!openAbove && !openBelow) {
      next.splice(first, 0, "");
    }
    return next;
  }

  // 只看有字的行：空行不同不算挪了位置
  const content = (markdown) => markdown.split("\n").filter((line) => line.trim()).join("\n");

  // 把 pick 选出的单元挪到 before / after 指的位置。单元要整行独占（和别的内容写在同一行时没法单独挪）
  function moveUnit(markdown, pick, args) {
    const doc = parseMarkdown(markdown);
    const unit = pick(doc, markdown);
    const [first, last] = lineRange(markdown, unit);
    const lines = markdown.split("\n");
    const moving = lines.slice(first, last + 1);
    if (moving.join("\n").trim() !== markdown.slice(unit.start, unit.end).trim()) throw new Error("这一块和别的内容写在同一行，没法单独挪");
    const [anchorFirst, anchorLast] = placeOf(markdown, args).anchorLines;
    if (anchorFirst >= first && anchorLast <= last) throw new Error("要挪到的位置就在它自己里面");
    const rest = removeLines(lines, first, last).join("\n");
    const result = insertLines(rest.split("\n"), placeOf(rest, args).at, moving).join("\n");
    if (content(result) === content(markdown)) throw new Error("已经在那个位置了");
    return result;
  }

  // 正文里这张图所在的那一块（单图或拼图）
  function imageUnit(id) {
    return (doc) => {
      const hits = doc.blocks.filter((block) => (block.type === "image" && block.imageId === id) || (block.type === "imagePair" && block.imageIds.includes(id)));
      if (!hits.length) throw new Error(`正文里没有图片 ${id}`);
      if (hits.length > 1) throw new Error(`图片 ${id} 在正文里出现了 ${hits.length} 次`);
      const [start, end] = hits[0].source;
      return { start, end };
    };
  }

  function referencedImages(doc) {
    return new Set(doc.blocks.flatMap((block) => (block.type === "image" && block.imageId ? [block.imageId] : block.type === "imagePair" ? block.imageIds : [])));
  }

  const where = ({ key, anchor }) => `在「${clip(anchor)}」${key === "before" ? "之前" : "之后"}`;

  // ===== 动作：改稿子，列一行，附上撤销 =====

  async function currentOf(draftId) {
    const draft = await mc().drafts.current();
    if (draft.id !== draftId) throw new Error("先打开这篇稿子再撤销");
    return draft;
  }

  // 正文从 before 改成了 after 的那一处单独撤回：之后别处的改动保留，同一处又改过时不撤
  function undoText(context, before, after) {
    return async () => {
      const current = await currentOf(context.draftId);
      const restored = context.merge(after, current.markdown, before);
      if (restored === null) throw new Error("这之后正文又改过同一处，没法单独撤销，可以用 ⌘Z 一步步撤回");
      if (restored !== current.markdown) await mc().drafts.update({ markdown: restored });
    };
  }

  // 正文结构的改动：编辑器里是一步可撤销的编辑，同样的改动同步到 draft.md（外部 Agent 没有 draft.md，context.sync 为空）；
  // 撤销时只撤这一处（之后别处的改动保留）
  async function editStructure(context, draft, text, op) {
    const before = draft.markdown;
    const after = op(before);
    await mc().drafts.update({ markdown: after });
    const synced = context.sync ? await context.sync(op) : null;
    context.action({ text, undo: undoText(context, before, after) });
    if (synced === null) return `${text}。`;
    return synced
      ? `${text}。draft.md 已同步。`
      : `${text}。注意：draft.md 没能同步这次改动（与你在 draft.md 里的修改对不上），这一轮结束时可能冲突。`;
  }

  const pick = (source, fields) => Object.fromEntries(fields.map((field) => [field, structuredClone(source[field] ?? null)]));
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

  // 稿子设置（主题、颜色、字体、字号……）的改动：撤销历史里的一步（⌘Z），撤销时把改过的字段（fields）换回原来的值。
  // checked 里的字段之后又被改过就不撤，免得冲掉后来的改动（换主题只看主题：配色本来就跟着主题走）
  async function editSettings(context, draft, text, patch, fields, checked = fields) {
    const before = pick(draft, fields);
    const after = pick(await mc().drafts.update(patch, { undoable: true }), checked);
    context.action({
      text,
      async undo() {
        const current = await currentOf(context.draftId);
        if (!same(pick(current, checked), after)) throw new Error("这之后又改过这些设置，没法单独撤销");
        await mc().drafts.update(before, { undoable: true });
      },
    });
    return `${text}。`;
  }

  // 图片的版式、裁剪：撤销规则同上；与编辑器里改图片一样也是 ⌘Z 撤销历史里的一步
  async function editImage(context, id, text, patch) {
    const fields = Object.keys(patch);
    const before = pick(await mc().media.get(id), fields);
    const after = pick(await mc().media.update(id, patch), fields);
    context.action({
      text,
      async undo() {
        await currentOf(context.draftId);
        const info = await mc().media.get(id);
        if (!info) throw new Error("这张图已经不在稿子里了");
        if (!same(pick(info, fields), after)) throw new Error("这张图之后又调过，没法单独撤销，可以用 ⌘Z 一步步撤回");
        await mc().media.update(id, before);
      },
    });
    return `${text}。`;
  }

  async function imageInfo(id) {
    const info = await mc().media.get(String(id ?? ""));
    if (!info) throw new Error(`稿子里没有图片 ${id}（图片 id 见 get_draft）`);
    return info;
  }

  const imageName = (info) => `「${clip(info.name || info.id, 16)}」`;

  async function naturalSize(id) {
    const src = await mc().media.src(id);
    if (!src) throw new Error(`图片 ${id} 没有画面`);
    const image = new Image();
    image.src = src;
    await image.decode();
    return { width: image.naturalWidth, height: image.naturalHeight };
  }

  function inRange(value, [min, max], label) {
    const number = Number(value);
    if (!Number.isFinite(number) || number < min || number > max) throw new RangeError(`${label}要在 ${min}–${max} 之间`);
    return number;
  }

  // ===== 读：稿子设置、分页摘要、看一页 =====

  // 稿子的设置与素材（不含卡片内容）：AI 助手里的 Claude 读 draft.md，外部 Agent 的 get_draft 另加卡片内容 markdown
  async function draftInfo(draft) {
    const [media, themes, fonts] = await Promise.all([mc().media.list(), mc().themes.list(), mc().fonts.list()]);
    const doc = parseMarkdown(draft.markdown);
    const referenced = referencedImages(doc);
    const images = await Promise.all(media.map(async (info) => ({
      id: info.id,
      kind: info.kind,
      name: info.name,
      // 解不出画面的图（比如缺了原图）只是不给尺寸
      ...(await naturalSize(info.id).catch(() => ({}))),
      layout: info.layout,
      crop: info.crop,
      inText: referenced.has(info.id),
    })));
    const pick = (list) => list.map(({ id, label }) => ({ id, label }));
    return {
      title: draft.title,
      caption: draft.caption,
      cardCss: draft.cardCss,
      mode: draft.mode,
      theme: draft.theme,
      colors: draft.colors,
      tunedColors: draft.tunedColors,
      fonts: draft.fonts,
      cardHeight: draft.cardHeight,
      fontSize: draft.fontSize,
      lineHeight: draft.lineHeight,
      blockGap: draft.blockGap,
      imageMaxHeight: draft.imageMaxHeight,
      cover: draft.cover,
      pageBreaks: doc.blocks.filter((block) => block.type === "pageBreak").length,
      images,
      options: {
        themes: themes.map(({ id, name, label }) => ({ id, name, label })),
        fonts: { zh: pick(fonts.zh), en: pick(fonts.en), code: pick(fonts.code) },
        ranges: { ...RANGES, widthPercent: WIDTH_PERCENT, fixedWidth: FIXED_WIDTH, fixedHeight: FIXED_HEIGHT },
      },
    };
  }

  async function getDraft(args, context, draft) {
    const info = await draftInfo(draft);
    context.line("查看稿子设置");
    return reply(json(info));
  }

  function blockLabel(block, markdown) {
    if (block.type === "image") return `图片 ${block.imageId ?? block.path}`;
    if (block.type === "imagePair") return `拼图 ${block.imageIds.join(" + ")}`;
    if (block.type === "rule") return "分割线";
    const name = block.type === "heading" ? `标题 ${block.level}` : block.type === "list" ? `列表 ${block.items.length} 项` : BLOCK_NAMES[block.type];
    return `${name}「${clip(blockText(block) || markdown.slice(...block.source))}」`;
  }

  // 每页放了哪些块（接上页 / 转下页）、正文区用了多少、怎么换的页：{ pages, text }
  async function pagesSummary(draft) {
    if (draft.mode === "article") throw new Error("长文模式没有分页（出一整张长图）；要看卡片分页，先用 set_mode 切到 cards");
    const pages = await mc().render.pages();
    const doc = parseMarkdown(draft.markdown);
    const blockOf = (offset) => doc.blocks.findIndex((block) => offset >= block.source[0] && offset < Math.max(block.source[1], block.source[0] + 1));
    const onPage = pages.map((page) => [...new Set(page.items.filter((item) => item.source).map((item) => blockOf(item.source[0])).filter((index) => index >= 0))]);
    const lines = [`共 ${pages.length} 页（卡片结构 ${pages[0]?.structure ?? "—"}，每页 864 × ${pages[0]?.height ?? 1152}）`];
    pages.forEach((page, number) => {
      if (page.role === "cover") {
        lines.push("", `第 ${number + 1} 页 · 封面（标题取自标题框，稿子设置 cover）`);
        return;
      }
      const { top, bottom } = page.contentBounds;
      const used = Math.max(top, ...page.items.map((item) => item.y + item.height));
      const blocks = onPage[number];
      const next = doc.blocks[(blocks.at(-1) ?? -1) + 1];
      const role = page.role === "end" ? " · 结尾页（[[结尾]] 之后）" : "";
      lines.push("", `第 ${number + 1} 页${role} · 正文区用了 ${Math.round(((used - top) / (bottom - top)) * 100)}%`);
      for (const issue of page.issues ?? []) lines.push(`  ⚠ ${issue.text}`);
      for (const index of blocks) {
        const from = number > 0 && onPage[number - 1].includes(index) ? "（接上页）" : "";
        const to = number < pages.length - 1 && onPage[number + 1].includes(index) ? "（转下页）" : "";
        lines.push(`- ${from}${blockLabel(doc.blocks[index], draft.markdown)}${to}`);
      }
      if (number < pages.length - 1 && pages[number + 1].role === "body") {
        lines.push(next?.type === "pageBreak" ? "  ↳ 这里有 [[分页]]" : "  ↳ 放不下，自动换页");
      }
    });
    return { pages, text: lines.join("\n") };
  }

  async function getPages(args, context, draft) {
    const { pages, text } = await pagesSummary(draft);
    context.line(`查看分页（共 ${pages.length} 页）`);
    return reply(text);
  }

  async function viewPage(args, context, draft) {
    if (draft.mode === "article") throw new Error("长文模式没有分页；要看卡片，先用 set_mode 切到 cards");
    const pages = await mc().render.pages();
    const number = Math.trunc(Number(args.page ?? 1));
    if (!(number >= 1 && number <= pages.length)) throw new RangeError(`只有 ${pages.length} 页`);
    const canvas = (await mc().render.canvases())[number - 1];
    const small = document.createElement("canvas");
    small.width = VIEW_WIDTH;
    small.height = Math.round((VIEW_WIDTH * canvas.height) / canvas.width);
    small.getContext("2d").drawImage(canvas, 0, 0, small.width, small.height);
    context.line(`查看第 ${number} 页`);
    return {
      content: [
        { type: "text", text: `第 ${number} 页（共 ${pages.length} 页）` },
        { type: "image", data: small.toDataURL("image/jpeg", 0.85).split(",")[1], mimeType: "image/jpeg" },
      ],
    };
  }

  // ===== 版式：主题、样式、模式 =====

  // 主题：id 或中文名
  async function findTheme(value) {
    const wanted = String(value ?? "").trim();
    const theme = (await mc().themes.list()).find(({ id, name, label }) => [id, name, label].includes(wanted));
    if (!theme) throw new Error(`没有主题「${wanted}」（可选的见 get_draft 的 options.themes）`);
    return theme;
  }

  async function setTheme(args, context, draft) {
    const theme = await findTheme(args.theme);
    if (theme.id === draft.theme) throw new Error(`已经是主题「${theme.name}」了`);
    return editSettings(context, draft, `换成主题「${theme.name}」`, { theme: theme.id }, ["theme", "colors", "tunedColors"], ["theme"]);
  }

  async function setStyle(args, context, draft) {
    const patch = {};
    const parts = [];
    if (args.colors !== undefined) {
      const entries = Object.entries(args.colors ?? {});
      for (const [key, value] of entries) {
        if (!ROLES.includes(key) || !/^#[0-9a-f]{6}$/i.test(String(value))) throw new TypeError(`颜色要写成 { ${ROLES.join(" | ")}: "#rrggbb" }：${key}`);
        parts.push(`${ROLE_INFO[key].name} ${value}`);
      }
      if (entries.length) patch.colors = Object.fromEntries(entries);
    }
    if (args.fonts !== undefined) {
      const options = await mc().fonts.list();
      const entries = Object.entries(args.fonts ?? {});
      for (const [script, id] of entries) {
        const font = options[script]?.find((option) => option.id === id);
        if (!font) throw new TypeError(`${FONT_NAMES[script] ?? script}没有「${id}」（可选的见 get_draft 的 options.fonts）`);
        parts.push(`${FONT_NAMES[script]}「${font.label}」`);
      }
      if (entries.length) patch.fonts = Object.fromEntries(entries);
    }
    for (const [key, label] of [["fontSize", "字号"], ["lineHeight", "行距"], ["blockGap", "段距"], ["imageMaxHeight", "图片最大高"], ["cardHeight", "页面高度"]]) {
      if (args[key] === undefined) continue;
      patch[key] = inRange(args[key], RANGES[key], label);
      parts.push(`${label} ${patch[key]}`);
    }
    if (!parts.length) throw new TypeError("没给要改的样式");
    // 颜色连同「单独调过」的标记一起撤销
    const fields = [...Object.keys(patch), ...(patch.colors ? ["tunedColors"] : [])];
    return editSettings(context, draft, `调整样式：${parts.join("、")}`, patch, fields);
  }

  // 这一篇自己的卡片样式（检查器「高级 · 卡片样式」）：整段换掉；append 为真时接在原来的后面
  function setCardCss(args, context, draft) {
    if (typeof args.css !== "string") throw new TypeError("css 要是一段 CSS 文字");
    const limit = root.MediaCraftCards.CARD_CSS_LIMIT;
    const css = args.append ? `${draft.cardCss ? `${draft.cardCss.trimEnd()}\n\n` : ""}${args.css}` : args.css;
    if (css.length > limit) throw new RangeError(`卡片样式最长 ${limit} 个字`);
    if (css === draft.cardCss) throw new Error("卡片样式没有变化");
    const rules = (css.match(/\{/g) ?? []).length;
    const text = css.trim() ? `${args.append ? "追加" : "设置"}卡片样式（${rules} 条规则）` : "清空卡片样式";
    return editSettings(context, draft, text, { cardCss: css }, ["cardCss"]);
  }

  async function setMode(args, context, draft) {
    if (!["cards", "article"].includes(args.mode)) throw new TypeError("mode 只能是 cards（图文卡片）或 article（长文）");
    if (args.mode === draft.mode) throw new Error(`已经是${args.mode === "cards" ? "图文卡片" : "长文"}了`);
    return editSettings(context, draft, args.mode === "cards" ? "切到图文卡片" : "切到长文", { mode: args.mode }, ["mode"]);
  }

  // ===== 结构：分页、挪段落 =====

  function insertPageBreak(args, context, draft) {
    const place = placeOf(draft.markdown, args);
    const op = (markdown) => {
      const { at } = placeOf(markdown, args);
      const lines = markdown.split("\n");
      const near = (from, step) => {
        let index = from;
        while (blank(lines[index])) index += step;
        return lines[index]?.trim();
      };
      const above = near(at - 1, -1);
      const below = near(at, 1);
      if (above === undefined || below === undefined) throw new Error("分页放在稿子开头或结尾没有用");
      if (above === PAGE_BREAK || below === PAGE_BREAK) throw new Error("那里已经有分页了");
      return insertLines(lines, at, [PAGE_BREAK]).join("\n");
    };
    return editStructure(context, draft, `插入分页：${where(place)}`, op);
  }

  function removePageBreak(args, context, draft) {
    const count = parseMarkdown(draft.markdown).blocks.filter((block) => block.type === "pageBreak").length;
    if (!count) throw new Error("稿子里没有 [[分页]]");
    const number = Math.trunc(Number(args.number));
    if (!args.all && !(number >= 1 && number <= count)) throw new RangeError(`number 要在 1–${count} 之间，或者给 all: true`);
    // 在别的文本上（draft.md）分页个数不一样时，第几个就对不上了，不套用
    const op = (markdown) => {
      const breaks = parseMarkdown(markdown).blocks.filter((block) => block.type === "pageBreak");
      if (breaks.length !== count) throw new Error("分页的个数不一样");
      // 从后往前删，前面的行号不受影响
      const targets = args.all ? [...breaks].reverse() : [breaks[number - 1]];
      return targets.reduce((lines, block) => {
        const [line] = lineRange(markdown, { start: block.source[0], end: block.source[1] });
        return removeLines(lines, line, line);
      }, markdown.split("\n")).join("\n");
    };
    return editStructure(context, draft, args.all ? `去掉全部 ${count} 个分页` : `去掉第 ${number} 个分页`, op);
  }

  function moveSection(args, context, draft) {
    const pick = (doc, markdown) => unitOf(doc, findBlock(doc, markdown, args.section));
    const op = (markdown) => moveUnit(markdown, pick, args);
    const doc = parseMarkdown(draft.markdown);
    const block = doc.blocks[findBlock(doc, draft.markdown, args.section)];
    const what = block.type === "heading" ? `「${clip(blockText(block), 16)}」一节` : `「${clip(blockText(block), 16)}」`;
    return editStructure(context, draft, `挪动${what}：${where(placeOf(draft.markdown, args))}`, op);
  }

  // ===== 换样式（HTML 卡片的组件，与舞台上点选一块后的「换样式」同一套，src/cards/blocks.js）=====

  // 与预览里点选一块后「换样式」同一套（src/cards/blocks.js 的 setStyle）；text 是正文
  // 块样式（操作手册 src/engine/manual.js）：给 id（正文是 text，也认 p）或中文名都行
  const manual = root.MediaCraftManual;
  const BLOCK_STYLES = [...manual.styles.map((style) => (style.id === "p" ? "text" : style.id)), ...manual.styles.map((style) => style.name)];
  const styleId = (value) => (value === "text" ? "p" : manual.style(value)?.id ?? null);
  const styleList = (family) => manual.styles.filter((style) => style.family === family)
    .map((style) => `${style.id === "p" ? "text" : style.id} ${style.name}${style.component ? "（组件）" : ""}`).join(" / ");

  // 用一段原文找顶层的一块（组件整个算一块）
  function topBlockOf(markdown, anchor) {
    const wanted = String(anchor ?? "").trim();
    if (!wanted) throw new TypeError("要给一段稿子里的原文来定位");
    const hits = root.MediaCraftCardBlocks.list(markdown).filter((block) => markdown.slice(...block.source).includes(wanted));
    if (!hits.length) throw new Error(`稿子里找不到「${clip(wanted)}」（原文要照抄、不跨行）`);
    if (hits.length > 1) throw new Error(`「${clip(wanted)}」出现在 ${hits.length} 处，请给更长、只出现一次的一段原文`);
    return hits[0];
  }

  function restyleBlock(args, context, draft) {
    const cards = root.MediaCraftCardBlocks;
    if (args.style !== undefined && !styleId(args.style)) throw new TypeError(`style 只能是 ${BLOCK_STYLES.join(" / ")}`);
    if (args.align !== undefined && !ALIGNS.includes(args.align)) throw new TypeError(`align 只能是 ${ALIGNS.join(" / ")}`);
    if (args.headingLevel !== undefined && ![1, 2, 3].includes(args.headingLevel)) throw new TypeError("headingLevel 只能是 1、2、3");
    if (args.style === undefined && args.align === undefined && args.headingLevel === undefined) throw new TypeError("style、align、headingLevel 至少给一个");
    const op = (markdown) => {
      let next = markdown;
      const current = () => topBlockOf(next, args.block);
      if (args.style !== undefined) {
        const block = current();
        if (styleId(args.style) === "p" && block.type === "paragraph") throw new Error("这一块已经是正文了");
        next = cards.setStyle(next, block.source, styleId(args.style)) ?? next;
      }
      if (args.headingLevel !== undefined) {
        const block = current();
        if (block.type !== "heading") throw new Error("headingLevel 只对标题有用");
        next = cards.setStyle(next, block.source, `h${args.headingLevel}`) ?? next;
      }
      if (args.align !== undefined) {
        const block = current();
        if (block.type !== "container") throw new Error("对齐只对组件有用（先用 style 换成组件）");
        next = cards.setAttr(next, block.source, "align", args.align === "left" ? null : args.align) ?? next;
      }
      if (next === markdown) throw new Error("这一块已经是这个样子了");
      return next;
    };
    const parts = [
      args.style !== undefined ? manual.style(styleId(args.style)).name : null,
      args.headingLevel !== undefined ? `${args.headingLevel} 级标题` : null,
      args.align !== undefined ? manual.alignName(args.align) : null,
    ].filter(Boolean);
    return editStructure(context, draft, `「${clip(args.block, 16)}」换成${parts.join("、")}`, op);
  }

  // ===== 片段与模板（登记表 src/engine/snippets.js；模板库 src/templates/，经 drafts.templates() / drafts.create({ template })）=====

  const snippets = () => root.MediaCraftSnippets;
  const POSITIONS = { start: "稿子开头", end: "稿子末尾" };

  // 要插的那段：片段（id 或中文名）或 Agent 自己写的一段 Markdown（英文记号先换成中文，和 create_draft / update_draft 收稿一样），二选一
  function sectionOf(args) {
    const given = ["snippet", "markdown"].filter((key) => args[key] !== undefined && args[key] !== null && args[key] !== "");
    if (given.length !== 1) throw new TypeError("snippet（片段的 id 或中文名）与 markdown（一段 Markdown）要给、且只给一个");
    if (given[0] === "snippet") {
      const snippet = snippets().get(String(args.snippet).trim());
      if (!snippet) throw new Error(`没有片段「${clip(args.snippet)}」（有这些：${snippets().list.map((item) => `${item.id} ${item.name}`).join("、")}）`);
      return { chunk: snippet.markdown, what: `片段「${snippet.name}」` };
    }
    if (typeof args.markdown !== "string") throw new TypeError("markdown 要是一段 Markdown 文字");
    const chunk = root.MediaCraftEngine.localizeMarkers(args.markdown).trim();
    if (!chunk) throw new TypeError("markdown 空着，没有要插的内容");
    return { chunk, what: `一段（${Array.from(chunk).length} 字）` };
  }

  // 插在哪：before / after 定位到一块（标题连同整节），或 position 是 start（稿子开头）/ end（稿子末尾）；只给一个，都不给是末尾。
  // 返回在这份 markdown 里的字符位置（片段的插入规则按光标处理：before 落在那一单元第一行的行首，after 落在最后一行的行尾，不拆开一行）
  // 与会话里写的位置
  function sectionPlace(markdown, args) {
    const keys = ["before", "after", "position"].filter((key) => args[key] !== undefined && args[key] !== null && args[key] !== "");
    if (keys.length > 1) throw new TypeError("before、after 与 position 只给一个");
    if (!keys.length || keys[0] === "position") {
      const position = keys.length ? String(args.position) : "end";
      if (!Object.hasOwn(POSITIONS, position)) throw new TypeError("position 只能是 start（稿子开头）或 end（稿子末尾）");
      return { at: position === "start" ? 0 : markdown.length, text: POSITIONS[position] };
    }
    const place = placeOf(markdown, args);
    const lines = markdown.split("\n");
    // 锚点落在组件（:::名字 … :::）里时整个组件算一单元：before 落到组件开头、after 落到组件结尾之后（和「换样式」把组件整个算一块一致），
    // 片段不会插进组件内部
    const box = containerAround(lines, place.key === "before" ? place.at : place.at - 1);
    if (box) place.at = place.key === "before" ? box.start : box.end + 1;
    // placeOf 给的是行号：before 是那一单元的第一行（插在它行首），after 是最后一行的下一行（插在上一行的行尾）
    const head = lines.slice(0, place.at).join("\n").length;
    return { at: place.key === "before" && place.at > 0 ? head + 1 : head, text: where(place) };
  }

  // 第 line 行所在的组件（:::名字 开头、单独一行 ::: 结尾）的首尾行号；不在组件里为 null
  function containerAround(lines, line) {
    let start = -1;
    for (let i = Math.min(line, lines.length - 1); i >= 0; i -= 1) {
      const text = lines[i].trim();
      if (text === ":::") return null; // 上面最近的是一个收尾：这一行在组件外面
      if (/^:::\S/.test(text)) { start = i; break; }
    }
    if (start < 0) return null;
    for (let i = Math.max(line, start) + 1; i < lines.length; i += 1) if (lines[i].trim() === ":::") return { start, end: i };
    return null;
  }

  // 插一个片段或一段 Markdown：前后隔开空行、首尾多余的 [[分页]] 去掉、含 [[结尾]] 的只能在末尾（规则都在 MediaCraftSnippets.insert，
  // 和「插入」菜单里插片段一样）；是一步可撤销的结构改动，同样套到 draft.md
  function insertSection(args, context, draft) {
    const { chunk, what } = sectionOf(args);
    const op = (markdown) => {
      const { text, change } = snippets().insert(markdown, sectionPlace(markdown, args).at, chunk);
      if (!change) throw new Error("没有要插的内容");
      return text;
    };
    return editStructure(context, draft, `插入${what}：${sectionPlace(draft.markdown, args).text}`, op);
  }

  // 模板：id 或名字（仓库自带的与用户自己存的都认）
  async function findTemplate(value) {
    const wanted = String(value ?? "").trim();
    if (!wanted) throw new TypeError("template 要给模板的 id 或名字（见 list_templates）");
    const template = (await mc().drafts.templates()).find(({ id, name }) => id === wanted || name === wanted);
    if (!template) throw new Error(`没有模板「${clip(wanted)}」（有哪些用 list_templates 看）`);
    return template;
  }

  async function listTemplates(args, context) {
    const [templates, themes] = await Promise.all([mc().drafts.templates(), mc().themes.list()]);
    const themeName = (id) => themes.find((theme) => theme.id === id)?.name ?? id;
    const own = templates.filter((template) => !template.builtIn).length;
    context.line(`查看模板（共 ${templates.length} 套）`);
    return reply([
      `共 ${templates.length} 套模板（自带 ${templates.length - own} 套，用户自己存的 ${own} 套），每套一行「名字（id）— 说明（题材 / 风格，主题）」：`,
      ...templates.map((template) => (
        `- ${template.name}（${template.id}）— ${template.description || "（没有说明）"}（${template.tags.join(" / ") || "没有标签"}，主题 ${themeName(template.theme)}${template.builtIn ? "" : "，自己存的"}）`
      )),
    ].join("\n"));
  }

  // 照模板在这个窗口里新建一篇并切过去（和稿件抽屉里点一套模板一样）：原来那篇已经存好、留在稿件抽屉里；
  // 这一轮仍属于原来那篇（工作副本、之后的工具都是它的），新稿子要在它自己的会话里改
  async function createDraftFromTemplate(args, context) {
    const template = await findTemplate(args.template);
    const draft = await mc().drafts.create({ template: template.id });
    const title = draft.title || (await mc().drafts.list()).find((item) => item.id === draft.id)?.title || template.name;
    context.line(`照模板「${template.name}」新建稿子「${clip(title, 16)}」`);
    return reply(
      `已照模板「${template.name}」新建稿子「${title}」（id ${draft.id}，主题 ${draft.theme}）并在这个窗口里打开；原来那篇已经保存，在稿件抽屉里。`
      + "这一轮改的仍是原来那篇（draft.md 与之后的工具都是它的），新稿子要在它自己的 AI 会话里改：告诉用户到新稿子里接着说。",
    );
  }

  // ===== 图片：挪、插、大小、裁剪、配图候选 =====

  async function moveImage(args, context, draft) {
    const info = await imageInfo(args.image);
    const op = (markdown) => moveUnit(markdown, imageUnit(info.id), args);
    return editStructure(context, draft, `挪动图片${imageName(info)}：${where(placeOf(draft.markdown, args))}`, op);
  }

  async function insertImage(args, context, draft) {
    const info = await imageInfo(args.image);
    const op = (markdown) => {
      if (referencedImages(parseMarkdown(markdown)).has(info.id)) throw new Error("这张图已经在正文里了，要换位置用 move_image");
      return insertLines(markdown.split("\n"), placeOf(markdown, args).at, [root.MediaCraftManual.imageTag([info.id])]).join("\n");
    };
    return editStructure(context, draft, `插入图片${imageName(info)}：${where(placeOf(draft.markdown, args))}`, op);
  }

  async function resizeImage(args, context) {
    const info = await imageInfo(args.image);
    if (args.reset) return editImage(context, info.id, `图片${imageName(info)}恢复默认大小`, { layout: null });
    const layout = { ...(info.layout ?? { align: "center", widthPercent: 100 }) };
    const parts = [];
    if (args.widthPercent !== undefined) {
      layout.widthPercent = Math.round(inRange(args.widthPercent, WIDTH_PERCENT, "widthPercent "));
      delete layout.fixedWidth;
      delete layout.fixedHeight;
      parts.push(`宽度 ${layout.widthPercent}%`);
    }
    if (args.fixedWidth !== undefined || args.fixedHeight !== undefined) {
      layout.fixedWidth = Math.round(inRange(args.fixedWidth, FIXED_WIDTH, "fixedWidth "));
      layout.fixedHeight = Math.round(inRange(args.fixedHeight, FIXED_HEIGHT, "fixedHeight "));
      parts.push(`固定 ${layout.fixedWidth} × ${layout.fixedHeight}`);
    }
    if (args.align !== undefined) {
      if (!ALIGNS.includes(args.align)) throw new TypeError("align 只能是 left / center / right");
      layout.align = args.align;
      parts.push(ALIGN_NAMES[args.align]);
    }
    if (!parts.length) throw new TypeError("没给要改的大小或对齐");
    return editImage(context, info.id, `图片${imageName(info)}${parts.join("、")}`, { layout });
  }

  async function cropImage(args, context) {
    const info = await imageInfo(args.image);
    if (info.kind === "live") throw new Error("实况图片不能裁剪");
    if (args.reset) return editImage(context, info.id, `图片${imageName(info)}取消裁剪`, { crop: null });
    const { width, height } = await naturalSize(info.id);
    let crop;
    let label;
    if (args.aspect !== undefined) {
      const match = /^\s*(\d+(?:\.\d+)?)\s*[:x×/]\s*(\d+(?:\.\d+)?)\s*$/.exec(String(args.aspect));
      if (!match || !(Number(match[1]) > 0 && Number(match[2]) > 0)) throw new TypeError("aspect 写成「宽:高」，比如 3:4、1:1");
      const ratio = Number(match[1]) / Number(match[2]);
      const cropWidth = Math.min(width, Math.round(height * ratio));
      const cropHeight = Math.min(height, Math.round(cropWidth / ratio));
      crop = { x: Math.round((width - cropWidth) / 2), y: Math.round((height - cropHeight) / 2), width: cropWidth, height: cropHeight };
      label = `裁剪图片${imageName(info)}为 ${match[1]}:${match[2]}`;
    } else {
      const [left, top, cropWidth, cropHeight] = ["left", "top", "width", "height"].map((key) => inRange(args[key], [0, 100], `${key} `) / 100);
      if (!(cropWidth > 0 && cropHeight > 0) || left + cropWidth > 1.0001 || top + cropHeight > 1.0001) throw new RangeError("裁剪框要在图片里面，宽高大于 0");
      crop = {
        x: Math.round(left * width),
        y: Math.round(top * height),
        width: Math.max(1, Math.min(width - Math.round(left * width), Math.round(cropWidth * width))),
        height: Math.max(1, Math.min(height - Math.round(top * height), Math.round(cropHeight * height))),
      };
      label = `裁剪图片${imageName(info)}`;
    }
    return editImage(context, info.id, label, { crop });
  }

  // 一批候选里要问的：网上的、目录以外的，以及下载途中重定向到别的站点的（壳回 needsApproval，redirect 是跳去的网址）
  const needsApproval = (entry) => Boolean(entry.result?.needsApproval);
  const approvalDetail = ({ item, result }) => (result.redirect ? `${item.source} → ${result.redirect}` : String(item.source));

  // 防提示词注入：被注入的模型想把读到的内容带出去时，网址多半带着一长串编码（base64、十六进制、百分号编码）或者特别长。
  // 这样的网址在确认框里单独点名，让用户看清楚再决定（正常的图床地址偶尔也会这样，所以只提醒、不拦）
  const ENCODED_RUN = /[A-Za-z0-9+/=_-]{48,}|(?:%[0-9A-Fa-f]{2}){12,}/;
  const LONG_ADDRESS = 300;
  function carriesData(address) {
    let url;
    try {
      url = new URL(address);
    } catch {
      return false;
    }
    if (url.protocol !== "http:" && url.protocol !== "https:") return false;
    return address.length > LONG_ADDRESS || ENCODED_RUN.test(`${url.pathname}${url.search}${url.hash}`);
  }
  function approvalNote(pending) {
    const flagged = [...new Set(pending.flatMap(({ item, result }) => [String(item.source), result.redirect].filter(Boolean)).filter(carriesData)
      .map((address) => new URL(address).host))];
    const base = "载入后只放进配图候选，你点了才会插进稿子。";
    return flagged.length
      ? `${base}留意：${flagged.join("、")} 的网址里带着一长串编码，可能是在把本机的内容带出去；不认得这个网站就拒绝。`
      : base;
  }

  // 先只载入不用问的（这篇工作目录里的、这篇的会话里放行过的目录里的）；要问的一批问一次，带着壳发的凭据再载入
  // （和终端里 claude 读目录外的文件要问一样；同意与放行的范围都由壳记）。网上的图每批都问，不能「本次会话都允许」：
  // 壳不给网上的图范围（scope），确认框也就不提供这个按钮。重定向到别的站点还要再问，最多问几轮。
  async function loadWithApproval(list, context) {
    const load = (item, grant) => native.candidate(context.draftId, context.turnId, String(item?.source ?? ""), grant)
      .then((result) => ({ item, result }), (error) => ({ item, error: error.message || String(error) }));
    let entries = [];
    for (const item of list) entries.push(await load(item));
    for (let round = 0; round < APPROVAL_ROUNDS && entries.some(needsApproval); round += 1) {
      const pending = entries.filter(needsApproval);
      const decision = await context.confirm({
        kind: "load-images",
        title: "载入网上或工作目录以外的图片",
        detail: pending.map(approvalDetail).join("\n"),
        note: approvalNote(pending),
        scope: [...new Set(pending.map(({ result }) => result.scope).filter(Boolean))],
      });
      const next = [];
      for (const entry of entries) {
        if (!needsApproval(entry)) next.push(entry);
        else if (decision === "deny") next.push({ item: entry.item, error: "用户没有同意载入" });
        else next.push(await load(entry.item, { approval: entry.result.approval, session: decision === "session" }));
      }
      entries = next;
    }
    return entries.map((entry) => (needsApproval(entry) ? { item: entry.item, error: "重定向太多次，没有载入" } : entry));
  }

  async function proposeImages(args, context) {
    if (!native) throw new Error("只有在 Vibepost App 里才能放配图候选");
    const list = Array.isArray(args.images) ? args.images.slice(0, CANDIDATE_LIMIT) : [];
    if (!list.length) throw new TypeError("images 要给至少一张：[{ source, caption?, after? }]");
    const results = await loadWithApproval(list, context);
    const loaded = ({ result }) => Boolean(result);
    const images = results.filter(loaded).map(({ item, result }) => ({
      id: result.id,
      name: result.name,
      width: result.width,
      height: result.height,
      thumb: result.thumb,
      ...(item.caption ? { caption: clip(item.caption, 60) } : {}),
      ...(item.after ? { after: String(item.after) } : {}),
    }));
    const problems = results.filter((entry) => !loaded(entry)).map(({ item, error }) => `${clip(item?.source, 60)}：${error ?? "没有得到同意"}`);
    if (!images.length) throw new Error(`一张都没载入：${problems.join("；")}`);
    context.candidates(images);
    return reply([
      `已把 ${images.length} 张图作为配图候选放在 AI 助手里；用户点了哪张才插进稿子，你不用再插。`,
      ...(problems.length ? [`没载入的：${problems.join("；")}`] : []),
    ].join("\n"));
  }

  // 生图：壳直接调生图接口（服务与模型在 AI 助手的设置里选），生成的图作为配图候选，用户点了才插入
  async function generateImage(args, context) {
    if (!native || !context.generate) throw new Error("只有在 Vibepost App 的 AI 助手里才能生图");
    const prompt = String(args.prompt ?? "").trim();
    if (!prompt) throw new TypeError("prompt 要写清楚画什么");
    const count = args.count === undefined ? 1 : Number(args.count);
    if (!Number.isInteger(count) || count < IMAGE_COUNT[0] || count > IMAGE_COUNT[1]) throw new RangeError(`count 要在 ${IMAGE_COUNT.join("–")} 之间`);
    const size = String(args.size ?? IMAGE_SIZE).trim().toLowerCase().replace("×", "x");
    const edges = /^(\d+)x(\d+)$/.exec(size)?.slice(1).map(Number);
    if (!edges || !edges.every((edge) => edge >= IMAGE_EDGE[0] && edge <= IMAGE_EDGE[1])) {
      throw new RangeError(`size 写成「宽x高」（如 ${IMAGE_SIZE}），每边 ${IMAGE_EDGE.join("–")} 像素`);
    }
    const style = String(args.style ?? "").trim();
    const images = await context.generate({ prompt: style ? `${prompt}\n\n风格：${style}` : prompt, count, size });
    context.candidates(images.map((image) => ({ ...image, caption: clip(prompt, 60) })));
    return reply(`已生成 ${images.length} 张图，作为配图候选放在 AI 助手里；用户点了哪张才插进稿子，你不用再插。`);
  }

  // ===== 写作手册（只管写什么、什么口味；文件在 App 支持目录，壳 WritingManuals.swift） =====

  // 和壳的检查一样（名字用作文件名），先在这里挡住，免得用户同意了才发现存不了
  const MANUAL_NAME_LIMIT = 40;
  const MANUAL_DESCRIPTION_LIMIT = 200;
  const MANUAL_BODY_LIMIT = 200_000;
  // 确认框里：新建的手册给看开头这么多字，修改的给看前几行改动
  const MANUAL_PREVIEW = 300;
  const MANUAL_CHANGED_LINES = 6;

  function manualFields(args) {
    const name = String(args.name ?? "").trim();
    if (!name) throw new TypeError("name 要写手册名");
    if (Array.from(name).length > MANUAL_NAME_LIMIT) throw new RangeError(`手册名最多 ${MANUAL_NAME_LIMIT} 字`);
    if (/[/\\:]/.test(name)) throw new TypeError("手册名里不能有 / \\ :");
    if (/\p{Cc}|\p{Cf}/u.test(name)) throw new TypeError("手册名里不能有换行、制表这类控制字符");
    if (name.startsWith(".")) throw new TypeError("手册名不能以「.」开头");
    const description = String(args.description ?? "").replace(/\s+/g, " ").trim();
    if (!description) throw new TypeError("description 要一句话写清这份手册管什么");
    if (Array.from(description).length > MANUAL_DESCRIPTION_LIMIT) throw new RangeError(`description 最多 ${MANUAL_DESCRIPTION_LIMIT} 字`);
    const content = String(args.content ?? "").replace(/\r\n/g, "\n");
    if (!content.trim()) throw new TypeError("content 要写手册的正文");
    if (new TextEncoder().encode(content).length > MANUAL_BODY_LIMIT) throw new RangeError(`正文太长了：最多 ${MANUAL_BODY_LIMIT / 1000} KB`);
    return { name, description, content };
  }

  // 正文按行比：去掉开头的空行与末尾的换行（壳存的时候也这样）
  const manualLines = (text) => text.replace(/\r\n/g, "\n").replace(/^\n+/, "").replace(/\n+$/, "").split("\n");

  // 确认框里的改动摘要：新建的给说明与正文开头；修改的给说明（改了的话前后都给）、正文 +N / −M 行与前几行改动
  function manualSummary(next, before) {
    if (!before) {
      const head = next.content.replace(/^\n+/, "");
      return [`说明：${next.description}`, "", head.length > MANUAL_PREVIEW ? `${head.slice(0, MANUAL_PREVIEW)}…` : head].join("\n");
    }
    const lines = [before.description === next.description ? `说明：${next.description}` : `说明：${before.description || "（空）"} → ${next.description}`];
    const old = manualLines(before.content);
    const fresh = manualLines(next.content);
    const changes = root.MediaCraftAI.diff.changes(old, fresh);
    if (!changes.length) return [...lines, "正文没有改动"].join("\n");
    const added = changes.reduce((sum, change) => sum + change.bTo - change.bFrom, 0);
    const removed = changes.reduce((sum, change) => sum + change.aTo - change.aFrom, 0);
    const shown = changes.flatMap((change) => [
      ...old.slice(change.aFrom, change.aTo).map((line) => `− ${clip(line, 60)}`),
      ...fresh.slice(change.bFrom, change.bTo).map((line) => `+ ${clip(line, 60)}`),
    ]);
    return [
      ...lines,
      `正文 +${added} / −${removed} 行：`,
      ...shown.slice(0, MANUAL_CHANGED_LINES),
      ...(shown.length > MANUAL_CHANGED_LINES ? [`……还有 ${shown.length - MANUAL_CHANGED_LINES} 行改动`] : []),
    ].join("\n");
  }

  // Agent 提议新建或修改一份写作手册：弹确认框给用户看改动，用户同意才经壳保存（App 里的 AI 与外部 Agent 都走这里）
  async function saveWritingManual(args, context) {
    const manuals = root.MediaCraftManualLibrary;
    if (!manuals.canEdit()) throw new Error("写作手册只在 Vibepost App 里能存（浏览器里存不了）");
    const next = manualFields(args);
    const { manuals: list } = await manuals.list();
    const before = list.some((manual) => manual.name === next.name) ? await manuals.read(next.name) : null;
    if (before && before.description === next.description && manualLines(before.content).join("\n") === manualLines(next.content).join("\n")) {
      return reply(`写作手册「${next.name}」和原来一样，没有改动。`);
    }
    const confirmed = await root.MediaCraftConfirm({
      title: before ? `修改写作手册「${next.name}」` : `新建写作手册「${next.name}」`,
      message: manualSummary(next, before),
      okLabel: "保存",
    });
    if (!confirmed) throw new Error("用户没有同意保存这份写作手册");
    const saved = await manuals.save(next);
    const text = `${before ? "修改" : "新建"}写作手册「${saved.name}」`;
    context.line(text);
    context.record?.(text);
    root.MediaCraftWritingManuals?.refresh();
    return reply(`已${before ? "修改" : "新建"}写作手册「${saved.name}」并保存，下一轮起生效。`);
  }

  // 用户在会话里点了一张候选：取原图插进稿子（一步可撤销的编辑）。给了 after 就插在那一块后面，找不到时插在光标处
  async function insertCandidate(draftId, candidate) {
    const { type, data } = await native.candidateFile(draftId, candidate.id);
    const extension = type.split("/")[1]?.replace("jpeg", "jpg") ?? "png";
    const name = /\.[a-z0-9]+$/i.test(candidate.name) ? candidate.name : `${candidate.name}.${extension}`;
    const file = new File([Uint8Array.from(atob(data), (char) => char.charCodeAt(0))], name, { type });
    const { markdown } = await mc().drafts.current();
    let at;
    if (candidate.after) {
      try {
        const { at: line } = placeOf(markdown, { after: candidate.after });
        at = markdown.split("\n").slice(0, line).join("\n").length;
      } catch {
        at = undefined; // 原文改掉了：插在光标处
      }
    }
    const [id] = await mc().media.import([file], at === undefined ? {} : { at });
    return id;
  }

  // ===== 工具清单 =====

  const anchor = (what) => ({ type: "string", description: `${what}：稿子里的一段原文（照抄正文、不跨行，只出现在一处）` });
  const imageId = { type: "string", description: "图片 id（见 get_draft 的 images）" };
  const target = { before: anchor("放在这一块之前"), after: anchor("放在这一块之后（标题指它连同下面的整节）") };

  const TOOLS = [
    {
      name: "get_draft",
      label: "查看稿子设置",
      description: "当前稿子的设置与素材：标题、小红书正文（caption，发布时图片下面的那段）、模式（cards 图文卡片 / article 长文）、主题、颜色、字体、字号、行距、图片最大高、封面（首页做封面、副标题、底图）、分页个数、图片（id、名字、原图尺寸、版式、裁剪、在不在正文里），以及可选的主题、字体和各项的取值范围。",
      inputSchema: { type: "object", properties: {} },
      run: getDraft,
    },
    {
      name: "get_pages",
      label: "查看分页",
      description: "按编辑器里当前的稿子出图，列出每页放了哪些块、正文区用了多少、是分页符换页还是放不下自动换页，以及这一页的问题（⚠ 只有标题、太空、偏挤、溢出）。"
        + "分页、挪段落、调图片、换样式之后用它检查，有 ⚠ 的页处理好再交差。",
      app: "你在 draft.md 里的文字修改要这一轮结束后才进编辑器，这里看不到。",
      external: "要看每页的图用 render_pages。",
      shared: true,
      inputSchema: { type: "object", properties: {} },
      run: getPages,
    },
    {
      name: "view_page",
      label: "查看这一页",
      description: "看某一页卡片的图（540 像素宽的 JPEG），检查排版、配色和图片效果。",
      inputSchema: { type: "object", properties: { page: { type: "integer", minimum: 1, description: "第几页，从 1 数，默认 1" } } },
      run: viewPage,
    },
    {
      name: "set_theme",
      shared: true,
      label: "换主题",
      description: "换主题（同时换卡片结构、配色与跟随主题的字体，这篇调过的配色重置）。theme 用 id 或中文名，如 notes / 备忘。",
      inputSchema: { type: "object", properties: { theme: { type: "string" } }, required: ["theme"] },
      run: setTheme,
    },
    {
      name: "set_style",
      shared: true,
      label: "调整样式",
      description: `在主题上微调这篇的样式，只改给了的项：colors（${ROLES.map((role) => `${role} ${ROLE_INFO[role].name}：${ROLE_INFO[role].use}`).join(" / ")}，#rrggbb；只给 bg、text、accent 三色时辅助与衬底按三色规则推出；没单独调过的辅助、衬底跟着背景与文字走）、fonts（zh / en / code 字体 id，"theme" 为跟随主题）、cardHeight（1152 标准3:4 / 1222 A4比例 / 1536 9:16 / 1728 1:2）、fontSize（18–40）、lineHeight（1–2.4）、blockGap（段距：块与块之间按行高的几倍，0.1–1.5，默认 0.55；块之间空得太开时调小，不要靠空行或分页撑开）、imageMaxHeight（220–1048）。`,
      inputSchema: {
        type: "object",
        properties: {
          colors: {
            type: "object",
            properties: Object.fromEntries(ROLES.map((role) => [role, { type: "string" }])),
            additionalProperties: false,
          },
          fonts: { type: "object", properties: { zh: { type: "string" }, en: { type: "string" }, code: { type: "string" } }, additionalProperties: false },
          cardHeight: { type: "number", enum: [1152, 1222, 1536, 1728] },
          fontSize: { type: "number", minimum: RANGES.fontSize[0], maximum: RANGES.fontSize[1] },
          lineHeight: { type: "number", minimum: RANGES.lineHeight[0], maximum: RANGES.lineHeight[1] },
          blockGap: { type: "number", minimum: RANGES.blockGap[0], maximum: RANGES.blockGap[1] },
          imageMaxHeight: { type: "number", minimum: RANGES.imageMaxHeight[0], maximum: RANGES.imageMaxHeight[1] },
        },
      },
      run: setStyle,
    },
    {
      name: "set_mode",
      shared: true,
      label: "切换模式",
      description: "切换这篇的模式：cards 图文卡片（分页的 3:4 卡片）或 article 长文（一整张长图 / 公众号）。",
      inputSchema: { type: "object", properties: { mode: { type: "string", enum: ["cards", "article"] } }, required: ["mode"] },
      run: setMode,
    },
    {
      name: "insert_page_break",
      label: "插入分页",
      description: "在某一块之前或之后插入 [[分页]]（手动换页），马上生效。before 与 after 给一个。",
      app: "改动同步到 draft.md。",
      shared: true,
      inputSchema: { type: "object", properties: target },
      run: insertPageBreak,
    },
    {
      name: "remove_page_break",
      shared: true,
      label: "去掉分页",
      description: "去掉第 number 个 [[分页]]（从 1 数，按在稿子里的先后），或 all: true 去掉全部。要挪分页就先去掉再插入。",
      inputSchema: { type: "object", properties: { number: { type: "integer", minimum: 1 }, all: { type: "boolean" } } },
      run: removePageBreak,
    },
    {
      name: "move_section",
      shared: true,
      label: "挪动段落",
      description: "调整结构：把一块挪到别处。section 指向标题时挪整节（到下一个同级或更高级的标题为止），指向别的块时只挪那一块（段落、列表、引用、表格……）。before 与 after 给一个。",
      inputSchema: { type: "object", properties: { section: anchor("要挪的那一块"), ...target }, required: ["section"] },
      run: moveSection,
    },
    {
      name: "set_card_css",
      shared: true,
      label: "改卡片样式",
      description: "这一篇自己的卡片样式（CSS，和检查器「高级 · 卡片样式」是同一处）：css 整段换掉（给空串清空），append: true 接在原来的后面。"
        + "只作用在这一篇的 HTML 卡片上：每页是 .mc-page（data-structure 是卡片结构、data-kind 是 cover / body / end），正文区 .mc-body，"
        + "组件 .mc-kicker / .mc-note / .mc-footnote / .mc-mono / .mc-rows / .mc-steps，自己起名的组件 :::名字 是 .c-名字；配色变量 --mc-bg、--mc-text、--mc-accent、--mc-muted、--mc-surface。"
        + "不能 @import、不能用外部图片。现在的样式见 get_draft 的 cardCss。",
      inputSchema: {
        type: "object",
        properties: { css: { type: "string" }, append: { type: "boolean" } },
        required: ["css"],
      },
      run: setCardCss,
    },
    {
      name: "restyle_block",
      shared: true,
      label: "换样式",
      description: `给一块换样式（和用户在卡片上点选一块后点「换样式」、编辑器左上角的「样式」一样）：style 给 id 或中文名，段落类 ${styleList("text")}，`
        + `列表类 ${styleList("list")}（标签列表每项开头写 [类别]）；align（left 靠左 / center 居中 / right 靠右）只对组件有用；`
        + "headingLevel（1–3）等同于 style h1–h3。写进稿子的是中文写法：单独一行「:::小标签」…单独一行「:::」，对齐写成「:::提示 居中」。"
        + `什么时候用哪种看操作手册：${manual.lessons[0]}${manual.lessons[1]}`,
      inputSchema: {
        type: "object",
        properties: {
          block: anchor("要换样式的那一块"),
          style: { type: "string", enum: BLOCK_STYLES },
          align: { type: "string", enum: ALIGNS },
          headingLevel: { type: "integer", minimum: 1, maximum: 3 },
        },
        required: ["block"],
      },
      run: restyleBlock,
    },
    {
      name: "insert_section",
      shared: true,
      label: "插入片段",
      description: `插一个写好的片段或一段 Markdown：snippet 给片段的 id 或中文名（${snippets().list.map((item) => `${item.id} ${item.name}`).join(" / ")}，各自什么时候用见操作手册的「片段」一节），`
        + "或 markdown 给你自己写的一段（中文记号是规范写法，英文写法收下时换成中文）；两者给一个。位置：before / after 给稿子里的一段原文（标题指它连同下面的整节），"
        + "或 position 为 start（稿子开头）/ end（稿子末尾），都不给时插在末尾。前后自动隔开空行，首尾多余的 [[分页]] 去掉；含 [[结尾]] 的（结尾引导）只能插在末尾、一篇只能有一个。"
        + "片段里没有图片：要配图用 insert_image（素材里已有的）或",
      app: " propose_images。马上生效，一步可撤销，改动同步到 draft.md。",
      external: " import_images（本机图片）。马上生效，一步可撤销。",
      inputSchema: {
        type: "object",
        properties: {
          snippet: { type: "string", description: "片段的 id 或中文名" },
          markdown: { type: "string", description: "一段 Markdown（和 snippet 二选一）" },
          ...target,
          position: { type: "string", enum: Object.keys(POSITIONS), description: "start 稿子开头 / end 稿子末尾（和 before / after 只给一个）" },
        },
      },
      run: insertSection,
    },
    {
      name: "move_image",
      shared: true,
      label: "挪动图片",
      description: "把正文里的一张图（或它所在的拼图）挪到某一块之前或之后。before 与 after 给一个。",
      inputSchema: { type: "object", properties: { image: imageId, ...target }, required: ["image"] },
      run: moveImage,
    },
    {
      name: "insert_image",
      label: "插入图片",
      description: "把稿子素材里已有、但不在正文里的一张图插回正文（get_draft 里 inText 为 false 的）。before 与 after 给一个。",
      app: "新图片用 propose_images。",
      external: "本机的新图片用 import_images。",
      shared: true,
      inputSchema: { type: "object", properties: { image: imageId, ...target }, required: ["image"] },
      run: insertImage,
    },
    {
      name: "resize_image",
      shared: true,
      label: "调整图片大小",
      description: "调整一张图在卡片上的大小与对齐：widthPercent（占正文宽度的 25–100%）或 fixedWidth + fixedHeight（像素，一起给），align（left / center / right）；reset: true 恢复默认（居中、100%）。",
      inputSchema: {
        type: "object",
        properties: {
          image: imageId,
          widthPercent: { type: "number", minimum: WIDTH_PERCENT[0], maximum: WIDTH_PERCENT[1] },
          fixedWidth: { type: "number", minimum: FIXED_WIDTH[0], maximum: FIXED_WIDTH[1] },
          fixedHeight: { type: "number", minimum: FIXED_HEIGHT[0], maximum: FIXED_HEIGHT[1] },
          align: { type: "string", enum: ALIGNS },
          reset: { type: "boolean" },
        },
        required: ["image"],
      },
      run: resizeImage,
    },
    {
      name: "crop_image",
      shared: true,
      label: "裁剪图片",
      description: "裁剪一张图：aspect 按比例居中裁（如 \"3:4\"、\"1:1\"），或给 left、top、width、height（占原图的百分比 0–100）；reset: true 取消裁剪。实况图片不能裁。",
      inputSchema: {
        type: "object",
        properties: {
          image: imageId,
          aspect: { type: "string" },
          left: { type: "number", minimum: 0, maximum: 100 },
          top: { type: "number", minimum: 0, maximum: 100 },
          width: { type: "number", minimum: 0, maximum: 100 },
          height: { type: "number", minimum: 0, maximum: 100 },
          reset: { type: "boolean" },
        },
        required: ["image"],
      },
      run: cropImage,
    },
    {
      name: "propose_images",
      label: "放配图候选",
      description: `把你生成或找到的图片作为配图候选放进 AI 助手（最多 ${CANDIDATE_LIMIT} 张），用户点了哪张才插进稿子。source 是本机图片路径（相对路径按当前目录算）或 http(s) 网址；caption 是给用户看的一句说明；after 是建议插在哪一块后面（稿子原文）。`,
      inputSchema: {
        type: "object",
        properties: {
          images: {
            type: "array",
            minItems: 1,
            maxItems: CANDIDATE_LIMIT,
            items: {
              type: "object",
              properties: { source: { type: "string" }, caption: { type: "string" }, after: { type: "string" } },
              required: ["source"],
            },
          },
        },
        required: ["images"],
      },
      run: proposeImages,
    },
    {
      name: "generate_image",
      label: "生成图片",
      description: `按提示词生成配图（OpenAI 的生图接口，模型由用户在 App 的设置里选），生成的图作为配图候选放进 AI 助手，用户点了哪张才插进稿子。按张计费，费用记在用户自己的 OpenAI 账户上：用户要图时才调用，count 默认 1（最多 ${IMAGE_COUNT[1]}）。prompt 写清楚画什么；size 是「宽x高」像素，默认 ${IMAGE_SIZE}（竖图，配 3:4 卡片）；style 是可选的风格说明。生成要几十秒，用户可以在 App 里停止。不要自己跑生图脚本或 curl。`,
      inputSchema: {
        type: "object",
        properties: {
          prompt: { type: "string" },
          count: { type: "integer", minimum: IMAGE_COUNT[0], maximum: IMAGE_COUNT[1] },
          size: { type: "string", description: `宽x高，默认 ${IMAGE_SIZE}` },
          style: { type: "string" },
        },
        required: ["prompt"],
      },
      run: generateImage,
    },
    {
      name: "save_writing_manual",
      label: "保存写作手册",
      shared: true,
      // 不看、不改稿子：用户切到别的稿子也能用（外部 Agent 也不用先认定一篇）
      free: true,
      description: "新建或修改一份写作手册（只管写什么、什么口味：读者、语气、结构、话题；排版写法不归它管）。"
        + "name 是手册名（已有的名字就是整份换掉，新名字就是新建；1–40 字，不能有 / \\ :），description 是一句话说明它管什么（Agent 按它挑手册，最多 200 字），"
        + "content 是正文 Markdown（不含开头的 name / description）。用户要你把这次的经验记进写作手册、或新建一份时用它：改已有的先读全文，在上面整份改好再交。"
        + "App 弹确认框给用户看改动，用户同意才保存，不同意时你会收到原因。",
      app: "现有的手册在当前目录的 写作手册/ 里（目录在 AGENTS.md 末尾），直接改那里的文件不会保存。",
      external: "现有的手册用 list_writing_manuals、read_writing_manual 看。",
      inputSchema: {
        type: "object",
        properties: {
          name: { type: "string", description: "手册名" },
          description: { type: "string", description: "一句话说明这份手册管什么" },
          content: { type: "string", description: "正文（Markdown）" },
        },
        required: ["name", "description", "content"],
      },
      run: saveWritingManual,
    },
    {
      name: "list_templates",
      label: "查看模板",
      shared: true,
      // 不看、不改稿子：用户切到别的稿子也能用（外部 Agent 也不用先认定一篇）
      free: true,
      description: "模板库里的模板（仓库自带的整篇示范稿，与用户自己存的）：每套一行「名字（id）— 说明（题材 / 风格，主题）」。用户要从模板开始、照某种题材写一篇时先看它，",
      app: "再用 create_draft_from_template 新建。",
      external: "再在 create_draft 里给 template（id 或名字）新建。",
      inputSchema: { type: "object", properties: {} },
      run: listTemplates,
    },
    {
      name: "create_draft_from_template",
      label: "照模板新建",
      free: true,
      description: "照一套模板新建一篇稿子并在这个窗口里打开它（和用户在稿件抽屉里点一套模板一样）：卡片内容、标题、小红书正文、主题、配色、字体、封面与示例图都照模板，之后照常可以换主题、改字。"
        + "template 给模板的 id 或名字（见 list_templates）。原来那篇已经保存、留在稿件抽屉里，不会丢；这一轮仍属于原来那篇（draft.md 与之后的工具都是它的），新稿子要在它自己的 AI 会话里改，告诉用户到新稿子里接着说。",
      inputSchema: { type: "object", properties: { template: { type: "string", description: "模板的 id 或名字" } }, required: ["template"] },
      run: createDraftFromTemplate,
    },
  ];

  // 描述：共用的一段，加上只给 AI 助手（app）或只给外部 Agent（external）的那一句
  const describe = (tool, surface) => [tool.description, tool[surface]].filter(Boolean).join("");

  async function callTool(name, args, context) {
    const tool = TOOLS.find((item) => item.name === name);
    if (!tool) return { content: [{ type: "text", text: `没有这个工具：${name}` }], isError: true };
    try {
      const draft = await mc().drafts.current();
      if (!tool.free && draft.id !== context.draftId) throw new Error("这篇稿子现在不在编辑器里（用户切到了别的稿子），这一轮先别动它");
      const outcome = await tool.run(args && typeof args === "object" ? args : {}, context, draft);
      return typeof outcome === "string" ? reply(outcome) : outcome;
    } catch (error) {
      const message = error?.message || String(error);
      context.line(`${tool.label}没成功：${message}`);
      return { content: [{ type: "text", text: message }], isError: true };
    }
  }

  // 一条 MCP JSON-RPC 消息 → 回答。context（src/ai/session.js 给）：
  //   draftId、turnId        这一轮的稿子与这一轮
  //   line(text)             会话里记一行（看了什么、哪个动作没成功）
  //   action({ text, undo }) 会话里记一个动作，undo() 撤销它
  //   candidates(images)     会话里放一组配图候选
  //   generate({ prompt, count, size })  生图（进度显示在面板里、可以停止），返回存成配图候选的图
  //   sync(op)               结构改动 op（markdown → markdown，套不上就抛错）同步到这一轮的 draft.md，返回是否同步了
  //   confirm({ kind, title, detail, note, scope })  用确认框问用户，返回回答 allow / session / deny（scope 是「本次会话都允许」放行的范围）
  //   merge(base, mine, theirs)  三方合并正文，重叠时为 null（撤销单个动作时用）
  async function handle(message, context) {
    const { id = 0, method, params = {} } = message ?? {};
    const result = (value) => ({ jsonrpc: "2.0", id, result: value });
    switch (method) {
      case "initialize":
        return result({
          protocolVersion: params.protocolVersion ?? PROTOCOL_VERSION,
          capabilities: { tools: {} },
          serverInfo: { name: "mediacraft", title: "Vibepost", version: "1" },
        });
      case "tools/list":
        return result({ tools: TOOLS.map((tool) => ({ name: tool.name, description: describe(tool, "app"), inputSchema: tool.inputSchema })) });
      case "tools/call":
        return result(await callTool(params.name, params.arguments ?? {}, context));
      case "ping":
        return result({});
      default:
        // 通知（没有 id，比如 notifications/initialized）只要回一个空结果
        if (message?.id === undefined) return result({});
        return { jsonrpc: "2.0", id, error: { code: -32601, message: `不支持 ${method}` } };
    }
  }

  root.MediaCraftAITools = {
    handle,
    // AI 助手的全部工具（name、description、inputSchema），except 里的不给（Codex 用自己的生图）；call 执行其中一个
    list: ({ except = [] } = {}) => TOOLS.filter((tool) => !except.includes(tool.name))
      .map((tool) => ({ name: tool.name, description: describe(tool, "app"), inputSchema: tool.inputSchema })),
    call: callTool,
    insertCandidate,
    // 外部 Agent（src/mcp/）共用的工具与零件
    shared: {
      // 共用的工具（name、description、inputSchema，free 的不用先认定稿子）；call(name, args, context) 执行其中一个，和 AI 助手里的一样
      definitions: () => TOOLS.filter((tool) => tool.shared)
        .map((tool) => ({ name: tool.name, description: describe(tool, "external"), inputSchema: tool.inputSchema, ...(tool.free ? { free: true } : {}) })),
      call: callTool,
      draftInfo,
      pagesSummary,
      findTheme,
      findTemplate,
      placeOf,
      undoText,
      currentOf,
      anchor,
      reply,
      json,
      clip,
    },
  };
})(window);
