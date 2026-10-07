// 外部 Agent（MCP）另外要的工具：操作手册与写作手册、列稿子、新建、打开、写正文、配色库、从本机路径插图、出图（PNG）、导出到目录、发送到 iPhone。
// 换主题、调样式、分页、挪段落、摆图片这些直接用 AI 助手的工具（src/ai/tools.js 里标了 shared 的），分派与操作记录在 src/mcp/server.js。
// 只经 App API（window.mediacraft）读写。本机文件只由壳碰：插图时壳按 Agent 给的路径读好、校验过交过来（request.files），
// 导出时页面把做好的文件交给壳（MediaCraftNative.mcp.write），写进 Agent 指定、壳校验过的目录。
(function (root) {
  "use strict";

  const mc = () => root.mediacraft;
  const native = root.MediaCraftNative?.mcp ?? null;
  const shared = root.MediaCraftAITools.shared;
  const { reply, json, clip } = shared;

  // 出图给 Agent 看的 PNG：卡片缩到这么宽（默认 540，文字看得清），一次最多附这么多页
  const RENDER_WIDTH = [270, 864];
  const DEFAULT_RENDER_WIDTH = 540;
  const RENDER_LIMIT = 9;
  const FORMATS = { zip: "整组卡片 ZIP", png: "单页 PNG", long: "长文长图" };

  const target = { before: shared.anchor("放在这一块之前"), after: shared.anchor("放在这一块之后（标题指它连同下面的整节）") };

  // 稿件列表里的名字（没填标题时是正文第一行）
  async function listedTitle(id) {
    return (await mc().drafts.list()).find((item) => item.id === id)?.title || "未命名";
  }

  // 一篇稿子给 Agent 看的样子：id、只读、设置与素材（含小红书正文 caption）、卡片内容 markdown
  async function draftView(draft) {
    return { id: draft.id, readOnly: draft.readOnly, ...(await shared.draftInfo(draft)), markdown: draft.markdown };
  }

  // ===== 稿子 =====

  async function listDrafts() {
    const list = await mc().drafts.list();
    return reply(json(list.map(({ id, title, mode, updatedAt, builtIn, current }) => ({
      id, title, mode, builtIn, current, updatedAt: updatedAt ? new Date(updatedAt).toISOString() : null,
    }))));
  }

  async function getDraft(args, context, draft) {
    return reply(json(await draftView(draft)));
  }

  // Agent 写来的卡片内容：英文记号换成中文写法（App 收下的都是中文写法，用户在编辑器里看到的也是）
  const localized = (markdown) => root.MediaCraftEngine.localizeMarkers(String(markdown));

  async function createDraft(args, context) {
    const init = {};
    if (args.title !== undefined) init.title = String(args.title);
    if (args.caption !== undefined) init.caption = String(args.caption);
    if (args.markdown !== undefined) init.markdown = localized(args.markdown);
    if (args.mode !== undefined) {
      if (!["cards", "article"].includes(args.mode)) throw new TypeError("mode 只能是 cards（图文卡片）或 article（长文）");
      init.mode = args.mode;
    }
    if (args.theme !== undefined) init.theme = (await shared.findTheme(args.theme)).id;
    // 壳为这次新建开的新窗口里已经有一篇刚新建的空稿子：就用它（只认那一篇，别的稿子不会被改）；否则新建一篇
    const blank = context.reuseBlank && root.MediaCraftDrafts.freshId();
    const draft = blank ? await mc().drafts.update(init) : await mc().drafts.create(init);
    await context.bind(draft.id);
    context.record(`新建稿子「${clip(await listedTitle(draft.id))}」`);
    return reply(json({ id: draft.id, title: draft.title, mode: draft.mode, theme: draft.theme }));
  }

  async function openDraft(args, context) {
    const draft = await mc().drafts.open(String(args.id ?? ""), { focus: false });
    await context.bind(draft.id);
    context.record(`打开稿子「${clip(await listedTitle(draft.id))}」`);
    return reply(json(await draftView(draft)));
  }

  async function updateDraft(args, context, draft) {
    const patch = {};
    const parts = [];
    if (args.title !== undefined) {
      patch.title = String(args.title);
      parts.push(`标题改成「${clip(patch.title, 16)}」`);
    }
    if (args.caption !== undefined) {
      patch.caption = String(args.caption);
      parts.push(`小红书正文改写（${patch.caption.length} 字）`);
    }
    if (args.markdown !== undefined) {
      patch.markdown = localized(args.markdown);
      parts.push(`卡片内容改写（${patch.markdown.length} 字）`);
    }
    if (!parts.length) throw new TypeError("title、caption 与 markdown 至少给一个");
    const next = await mc().drafts.update(patch, { undoable: true });
    const undoMarkdown = "markdown" in patch ? shared.undoText(context, draft.markdown, next.markdown) : null;
    context.action({
      text: parts.join("、"),
      async undo() {
        const current = await shared.currentOf(context.draftId);
        const fields = ["title", "caption"].filter((field) => field in patch);
        const changed = fields.find((field) => current[field] !== next[field]);
        if (changed) throw new Error(`这之后${changed === "title" ? "标题" : "小红书正文"}又改过，没法单独撤销，可以用 ⌘Z 一步步撤回`);
        await undoMarkdown?.();
        if (fields.length) await mc().drafts.update(Object.fromEntries(fields.map((field) => [field, draft[field]])), { undoable: true });
      },
    });
    const pages = next.mode === "cards" ? (await mc().render.pages()).length : 0;
    return `已更新：${parts.join("、")}。${pages ? `现在排成 ${pages} 页，用 render_pages 看看效果。` : "长文模式，没有分页。"}`;
  }

  // ===== 写作手册（只管写什么、什么口味；壳 WritingManuals.swift 读 App 支持目录里的文件）=====
  // 新建、修改用共用的 save_writing_manual（src/ai/tools.js，要用户确认）

  const manualsNative = () => {
    const manuals = root.MediaCraftNative?.manuals;
    if (!manuals) throw new Error("写作手册只在 Vibepost App 里有");
    return manuals;
  };

  async function listWritingManuals() {
    const { manuals } = await manualsNative().list();
    if (!manuals.length) return "还没有写作手册。用户要新建时用 save_writing_manual。";
    return [
      `共 ${manuals.length} 份写作手册（只管写什么、什么口味；按这篇的题材挑一份，用户点名的优先，用 read_writing_manual 读全文）：`,
      ...manuals.map(({ name, description }) => (description ? `- ${name}：${description}` : `- ${name}`)),
    ].join("\n");
  }

  async function readWritingManual(args) {
    const name = String(args.name ?? "").trim();
    if (!name) throw new TypeError("name 要写手册名（见 list_writing_manuals）");
    const manual = await manualsNative().read(name);
    // 和文件一样的样子：开头 name / description，后面是正文
    return `---\nname: ${manual.name}\ndescription: ${manual.description}\n---\n\n${manual.content}`;
  }

  // ===== 配色库 =====

  async function listPalettes(args) {
    if (args.tone !== undefined && !["light", "dark"].includes(args.tone)) throw new TypeError("tone 只能是 light 或 dark");
    const list = (await mc().palettes.list()).filter((palette) => args.tone === undefined || palette.tone === args.tone);
    return reply(json(list.map(({ id, name, category, tone, colors }) => ({ id, name, category, tone, colors }))));
  }

  async function applyPalette(args, context, draft) {
    const given = ["palette", "colors"].filter((key) => args[key] !== undefined);
    if (given.length !== 1) throw new TypeError("palette（配色 id）与 colors（色值数组）要给、且只给一个");
    const target = args.palette !== undefined ? String(args.palette) : args.colors;
    const before = draft.colors;
    const after = (await mc().palettes.apply(target)).colors;
    const name = args.palette !== undefined
      ? (await mc().palettes.list()).find((palette) => palette.id === target)?.name ?? target
      : Object.values(after).slice(0, 3).join(" ");
    context.action({
      text: `套用配色「${clip(name, 20)}」`,
      async undo() {
        const current = await shared.currentOf(context.draftId);
        if (JSON.stringify(current.colors) !== JSON.stringify(after)) throw new Error("这之后又改过配色，没法单独撤销");
        await mc().drafts.update({ colors: before }, { undoable: true });
      },
    });
    return reply(json({ colors: after }));
  }

  // ===== 从本机路径插图（壳已经按路径读好、校验过：request.files） =====

  async function importImages(args, context, draft) {
    const files = (context.files ?? []).map(({ name, type, data }) => (
      new File([Uint8Array.from(atob(data), (char) => char.charCodeAt(0))], name, { type })
    ));
    if (!files.length) throw new TypeError("paths 要给一个或几个图片文件的绝对路径");
    const keys = ["before", "after"].filter((key) => args[key] !== undefined && args[key] !== "");
    let at = draft.markdown.length;
    if (keys.length) {
      const { at: line } = shared.placeOf(draft.markdown, args);
      at = draft.markdown.split("\n").slice(0, line).join("\n").length;
    }
    const ids = await mc().media.import(files, { at });
    const after = (await mc().drafts.current()).markdown;
    const names = files.map((file) => file.name).join("、");
    context.action({ text: `插入 ${files.length} 张图片：${clip(names, 40)}`, undo: shared.undoText(context, draft.markdown, after) });
    return reply(json({ imageIds: ids, note: "用 resize_image / crop_image 调大小与裁剪，render_pages 看效果" }));
  }

  // ===== 出图、导出、发送 =====

  async function renderPages(args, context, draft) {
    const { pages, text } = await shared.pagesSummary(draft);
    const width = args.width === undefined ? DEFAULT_RENDER_WIDTH : Math.round(Number(args.width));
    if (!(width >= RENDER_WIDTH[0] && width <= RENDER_WIDTH[1])) throw new RangeError(`width 要在 ${RENDER_WIDTH[0]}–${RENDER_WIDTH[1]} 之间`);
    const wanted = args.pages === undefined ? pages.map((page, index) => index + 1) : [...new Set([].concat(args.pages).map((page) => Math.trunc(Number(page))))];
    const outside = wanted.filter((number) => !(number >= 1 && number <= pages.length));
    if (outside.length) throw new RangeError(`只有 ${pages.length} 页，没有第 ${outside.join("、")} 页`);
    const shown = wanted.slice(0, RENDER_LIMIT);
    const canvases = await mc().render.canvases();
    const images = shown.flatMap((number) => {
      const canvas = canvases[number - 1];
      const small = document.createElement("canvas");
      small.width = width;
      small.height = Math.round((width * canvas.height) / canvas.width);
      small.getContext("2d").drawImage(canvas, 0, 0, small.width, small.height);
      return [
        { type: "text", text: `第 ${number} 页` },
        { type: "image", data: small.toDataURL("image/png").split(",")[1], mimeType: "image/png" },
      ];
    });
    const rest = wanted.length - shown.length;
    const more = rest ? `\n（还有 ${rest} 页没附图：一次最多 ${RENDER_LIMIT} 页，用 pages 指定要看的页）` : "";
    return { content: [{ type: "text", text: text + more }, ...images] };
  }

  async function exportFiles(args, context) {
    if (!native || !context.exportRequest) throw new Error("导出到文件夹只能经 Vibepost 的 MCP 服务调用");
    if (!FORMATS[args.format]) throw new TypeError("format 只能是 zip（整组卡片）、png（一页）或 long（长文长图）");
    const paths = [];
    const save = async (blob, filename) => {
      const { path, name } = await native.write(context.exportRequest, filename, blob);
      paths.push(path);
      return name;
    };
    if (args.format === "zip") await mc().output.exportZip({ save });
    else if (args.format === "long") await mc().output.exportLongImage({ save });
    else {
      const page = Math.trunc(Number(args.page ?? 1));
      if (!(page >= 1)) throw new RangeError("page 从 1 数");
      await mc().output.exportPng(page - 1, { save });
    }
    context.record(`导出${FORMATS[args.format]}：${paths.join("、")}`);
    return reply(json({ files: paths }));
  }

  async function sendToIPhone(args, context) {
    const { pageCount, copied } = await mc().output.sendToIPhone();
    context.record(`发送到 iPhone（${pageCount} 页）`);
    const clipboard = copied ? "小红书正文已放进剪贴板，发布时直接粘贴" : "这篇的小红书正文（caption）还空着，剪贴板没动";
    return `已在 Vibepost 里弹出隔空投送（共 ${pageCount} 张，按页序），请用户在 Mac 上选自己的 iPhone；${clipboard}。`;
  }

  // ===== 工具清单 =====
  // free：不用先认定是哪篇稿子（手册、列表、新建、打开、配色库）；其余（看、改、出图、导出、发送）只对这次会话认定的那篇动手（见 src/mcp/server.js）

  const TOOLS = [
    {
      name: "get_manual",
      free: true,
      description: "Vibepost 的操作手册全文（Markdown）：块样式、组件（:::小标签、:::提示……）、记号（[[图片:编号]]、[[分页]]、{{字色:#色值|文字}}……）的写法、"
        + "什么时候用哪种、排版经验。改稿、排版之前读一遍；只讲 App 认得的写法，写什么内容看写作手册。",
      inputSchema: { type: "object", properties: {} },
      run: async () => reply(root.MediaCraftManual.document()),
    },
    {
      name: "list_writing_manuals",
      free: true,
      description: "列出用户的写作手册：每份一行「名字：说明」。写作手册只管写什么、什么口味（读者、语气、结构、话题），排版写法看 get_manual。"
        + "写稿之前按这篇的题材挑一份（用户点名的优先），用 read_writing_manual 读全文照着写；都不合适就按常识写。",
      inputSchema: { type: "object", properties: {} },
      run: listWritingManuals,
    },
    {
      name: "read_writing_manual",
      free: true,
      description: "读一份写作手册的全文（开头 name / description，后面是正文 Markdown）。name 用 list_writing_manuals 列出的名字。",
      inputSchema: { type: "object", properties: { name: { type: "string", description: "手册名" } }, required: ["name"] },
      run: readWritingManual,
    },
    {
      name: "list_drafts",
      free: true,
      description: "列出 Vibepost 里的全部稿子：id、标题（没填时是正文第一行）、模式、是不是内置说明书（builtIn，只读）、是不是正在编辑的那篇（current）、最近修改时间。",
      inputSchema: { type: "object", properties: {} },
      run: listDrafts,
    },
    {
      name: "get_draft",
      description: "这次会话在改的那篇稿子（还没新建、打开过稿子时是 App 里正在编辑的那篇，之后的工具都改它）：id、是否只读（内置说明书）、标题、小红书正文 caption（发布时图片下面的那段纯文本，#话题 写在这里）、卡片内容 markdown（排在图片上的字）、模式（cards 图文卡片 / article 长文）、主题、颜色、字体、字号、行距、图片最大高、分页个数、图片（id、名字、原图尺寸、版式、裁剪、在不在正文里），以及可选的主题、字体和各项的取值范围。",
      inputSchema: { type: "object", properties: {} },
      run: getDraft,
    },
    {
      name: "create_draft",
      free: true,
      description: "新建一篇稿子并在 App 里打开它，之后的工具都改这篇。可以同时给标题、卡片内容 markdown、小红书正文 caption、模式与主题（id 或中文名，不给时沿用用户上次选的）。写法看操作手册（工具 get_manual）：中文是规范写法（:::小标签、{{字色:#色值|文字}}、[[分页]]），英文写法也认、App 收下时换成中文；图片用 import_images 插。",
      inputSchema: {
        type: "object",
        properties: {
          title: { type: "string", description: "标题，建议不超过 20 字" },
          markdown: { type: "string", description: "卡片内容 Markdown：排在一张张图片上的字" },
          caption: { type: "string", description: "小红书正文：发布时图片下面的那段纯文本（不用 Markdown，可以有 emoji、换行，#话题 写在这里，最多 1000 字）" },
          mode: { type: "string", enum: ["cards", "article"] },
          theme: { type: "string" },
        },
      },
      run: createDraft,
    },
    {
      name: "open_draft",
      free: true,
      description: "在 App 里打开一篇稿子（id 见 list_drafts），之后的工具都改这篇；返回同 get_draft。内置说明书只能看，不能改。用户在 App 里切到了别的稿子时，改稿的工具会报错，先用它打开要改的那篇。",
      inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
      run: openDraft,
    },
    {
      name: "update_draft",
      description: "改这篇的标题、小红书正文 caption（图片下面的那段纯文本）和 / 或整篇卡片内容 markdown（整篇替换；只想改一处也要给完整的内容）。马上出图，是一步可撤销（⌘Z）的编辑。",
      inputSchema: {
        type: "object",
        properties: {
          title: { type: "string" },
          caption: { type: "string", description: "小红书正文：纯文本，可以有 emoji、换行与 #话题，最多 1000 字" },
          markdown: { type: "string", description: "卡片内容 Markdown" },
        },
      },
      run: updateDraft,
    },
    {
      name: "list_palettes",
      free: true,
      description: "配色库：内置的 48 组配色（莫兰迪、日系、复古胶片、自然、霓虹赛博、黑白极简）与用户存的「我的配色」，每组五个颜色（bg 底色、text 文字、accent 强调、secondary 辅助 / 标题、surface 衬底）。tone 可只列浅色（light）或深色（dark）底的。",
      inputSchema: { type: "object", properties: { tone: { type: "string", enum: ["light", "dark"] } } },
      run: listPalettes,
    },
    {
      name: "apply_palette",
      description: "给这篇套一组配色（只改颜色，不换主题的卡片结构）：palette 是配色 id（见 list_palettes），或 colors 给一串色值（至少三个，如 [\"#264653\", \"#2a9d8f\", \"#e9c46a\"]，按明暗自动分给五个角色）。一步可撤销的编辑。",
      inputSchema: {
        type: "object",
        properties: {
          palette: { type: "string" },
          colors: { type: "array", minItems: 3, items: { type: "string" } },
        },
      },
      run: applyPalette,
    },
    {
      name: "import_images",
      description: "把本机的图片（PNG、JPEG、WebP、GIF、HEIC……，每张不超过 20 MB）插进这篇正文，每张一行。paths 是绝对路径；before / after 给稿子里的一段原文定位，都不给时插在正文末尾。返回新图片的 id。",
      inputSchema: {
        type: "object",
        properties: {
          paths: { type: "array", minItems: 1, maxItems: 20, items: { type: "string" }, description: "图片文件的绝对路径" },
          ...target,
        },
        required: ["paths"],
      },
      run: importImages,
    },
    {
      name: "render_pages",
      description: `按这篇现在的样子出图：每页放了哪些块、怎么换的页，并附上每页卡片的 PNG（默认 ${DEFAULT_RENDER_WIDTH} 像素宽，一次最多 ${RENDER_LIMIT} 页）。改完正文、主题、分页、图片后用它检查。长文模式没有分页，要看长图用 export 的 long。`,
      inputSchema: {
        type: "object",
        properties: {
          pages: { type: "array", items: { type: "integer", minimum: 1 }, description: "要看第几页（从 1 数），默认全部" },
          width: { type: "integer", minimum: RENDER_WIDTH[0], maximum: RENDER_WIDTH[1], description: `图宽（像素），默认 ${DEFAULT_RENDER_WIDTH}` },
        },
      },
      run: renderPages,
    },
    {
      name: "export",
      description: "把这篇导出成文件，写进 directory（已经存在的文件夹的绝对路径）：format 为 zip（整组卡片打包，1728 × 2304 的 PNG，实况页是 .pvt）、png（第 page 页，从 1 数，默认 1）或 long（长文长图，不在长文模式时会先切过去）。文件名以标题开头；同名文件已经存在时报错，给 overwrite: true 才覆盖。返回写下的文件路径。",
      inputSchema: {
        type: "object",
        properties: {
          format: { type: "string", enum: Object.keys(FORMATS) },
          directory: { type: "string" },
          page: { type: "integer", minimum: 1 },
          overwrite: { type: "boolean" },
        },
        required: ["format", "directory"],
      },
      run: exportFiles,
    },
    {
      name: "send_to_iphone",
      description: "把这篇按页序交给隔空投送（AirDrop），小红书正文（caption）放进剪贴板（空着时不动剪贴板）。只会在 Vibepost 里弹出隔空投送面板，由用户在 Mac 上选自己的 iPhone 并确认——你不能替用户选设备，也不知道对方收没收；调用前先用 render_pages 确认排版，并告诉用户去点。",
      inputSchema: { type: "object", properties: {} },
      run: sendToIPhone,
    },
  ];

  root.MediaCraftMCPTools = { TOOLS };
})(window);
