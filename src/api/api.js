// App API：window.mediacraft，页面对外唯一的稳定接口。测试、AI 会话与外部 Agent（MCP，src/mcp/）都只走这里，文档见 docs/app-api.md。
// 破坏性改动要升 version。图片与实况在 src/api/media.js，配色在 src/api/palettes.js；这里是其余几组与共用的校验。
(function (root) {
  "use strict";

  const DRAFT_FIELDS = ["title", "caption", "markdown", "mode", "theme", "colors", "tunedColors", "fonts", "fontSize", "lineHeight", "imageMaxHeight", "cover", "cardCss"];
  const NUMBER_FIELDS = ["fontSize", "lineHeight", "imageMaxHeight"];
  // update(patch, { undoable: true }) 时随正文一起进撤销历史的字段
  const HISTORY_FIELDS = ["title", "caption", "mode", "theme", "colors", "tunedColors", "fonts", "cardCss", ...NUMBER_FIELDS];
  const HEX_COLOR = /^#[0-9a-f]{6}$/i;
  const EVENTS = ["change", "rendered", "ai", "save-state"];
  const { deepFreeze } = root.MediaCraftEngine;

  // ===== 校验：先整体校验再落地，不会只改一半 =====

  function assertFields(value, allowed, label) {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new TypeError(`${label}需要一个对象`);
    const unknown = Object.keys(value).filter((key) => !allowed.includes(key));
    if (unknown.length) throw new TypeError(`${label}不认识的字段：${unknown.join("、")}`);
  }

  // 配色：五个角色里的任意几个，都是 #rrggbb
  function assertColors(colors, label) {
    assertFields(colors, root.MediaCraftPalettes.ROLES, label);
    Object.values(colors).forEach((color) => {
      if (!HEX_COLOR.test(color)) throw new TypeError(`颜色需要是 #rrggbb：${color}`);
    });
  }

  // 单独调过的辅助、衬底：只能列 secondary、surface
  function assertTuned(tuned) {
    const { DERIVABLE } = root.MediaCraftEngine.colors;
    if (!Array.isArray(tuned) || tuned.some((role) => !DERIVABLE.includes(role))) {
      throw new TypeError(`tunedColors 需要是数组，只能列 ${DERIVABLE.join("、")}`);
    }
  }

  // 封面：enabled、subtitle、image 里的任意几个；image 是这篇里的一张图（或 null 不要底图）
  function assertCover(cover, images) {
    assertFields(cover, ["enabled", "subtitle", "image"], "cover：");
    if ("enabled" in cover && typeof cover.enabled !== "boolean") throw new TypeError("cover.enabled 需要是 true 或 false");
    if ("subtitle" in cover && typeof cover.subtitle !== "string") throw new TypeError("cover.subtitle 需要是字符串");
    if ("image" in cover && cover.image !== null && typeof cover.image !== "string") throw new TypeError("cover.image 需要是图片 id 或 null");
    if (cover.image && !images[cover.image]) throw new Error(`这篇稿子里没有这张图：${cover.image}`);
  }

  // images：这篇的图片记录（封面底图要在里面）
  function assertDraftPatch(patch, images) {
    assertFields(patch, DRAFT_FIELDS, "稿子字段：");
    for (const key of ["title", "caption", "markdown"]) {
      if (key in patch && typeof patch[key] !== "string") throw new TypeError(`${key} 需要是字符串`);
    }
    if ("mode" in patch && !["cards", "article"].includes(patch.mode)) throw new TypeError("mode 只能是 cards 或 article");
    if ("theme" in patch && !root.MediaCraftThemes.has(patch.theme)) throw new Error(`没有这个主题：${patch.theme}`);
    if ("colors" in patch) assertColors(patch.colors, "colors：");
    if ("tunedColors" in patch) assertTuned(patch.tunedColors);
    if ("fonts" in patch) assertFields(patch.fonts, ["zh", "en", "code"], "fonts：");
    if ("cover" in patch) assertCover(patch.cover, images);
    if ("cardCss" in patch && typeof patch.cardCss !== "string") throw new TypeError("cardCss 需要是字符串");
    if ("cardCss" in patch && patch.cardCss.length > root.MediaCraftCards.CARD_CSS_LIMIT) throw new RangeError(`cardCss 最长 ${root.MediaCraftCards.CARD_CSS_LIMIT} 个字`);
    for (const key of NUMBER_FIELDS) {
      if (key in patch && !Number.isFinite(Number(patch[key]))) throw new TypeError(`${key} 需要是数字`);
    }
  }

  // 稿件记录形状的字段（界面上这篇，或稿件模块里的一篇）→ API 的 Draft；缺的按主题与默认值补，数值收进界面上的范围。
  // 这版之前存的稿子没有「单独调过」的标记：按值推断（MediaCraftPalettes.inferTuned）。
  function apiDraft(id, fields) {
    const theme = root.MediaCraftThemes.get(fields.theme);
    const fonts = fields.fonts || {};
    const palettes = root.MediaCraftPalettes;
    const { colors, tunedColors } = palettes.complete(
      fields.colors, { colors: theme.colors }, fields.tunedColors ?? palettes.inferTuned(fields.colors),
    );
    return {
      id,
      title: String(fields.title || ""),
      caption: String(fields.caption || ""),
      markdown: String(fields.markdown ?? ""),
      mode: fields.mode === "article" ? "article" : "cards",
      theme: theme.id,
      colors,
      tunedColors,
      fonts: Object.fromEntries(["zh", "en", "code"].map((script) => [script, root.MediaCraftFonts.normalize(script, fonts[script])])),
      ...Object.fromEntries(NUMBER_FIELDS.map((field) => [field, root.MediaCraftStyleForm.normalizeNumber(field, fields[field])])),
      cover: { ...root.MediaCraftCoverForm.normalize(fields.cover) },
      cardCss: String(fields.cardCss ?? ""),
      readOnly: root.MediaCraftGuides.isGuide(id),
    };
  }

  // 稿件存储准备好之前（首次启动时要先搬旧稿子、打开上次那篇），API 的调用先等着；就绪后直接调用。on 与常量不用等。
  function afterDraftsReady(api, app) {
    const wrap = (namespace) => Object.fromEntries(Object.entries(namespace).map(([key, value]) => [
      key,
      typeof value === "function" ? (...args) => (app.isReady() ? value(...args) : app.ready().then(() => value(...args))) : value,
    ]));
    return Object.fromEntries(Object.entries(api).map(([key, value]) => [key, value && typeof value === "object" ? wrap(value) : value]));
  }

  // 卡片上的一块内容（逻辑坐标，864x1152），只留 App API 文档里的字段。
  function pageItem(item) {
    const { kind, x, y, width, height, source } = item;
    const base = { kind, x, y, width, height, source };
    switch (kind) {
      case "text":
        return {
          ...base,
          blockType: item.blockType,
          text: item.text,
          marker: item.marker,
          fontSize: item.fontSize,
          runs: item.pieces.map((piece) => ({ text: piece.text, ...piece.marks })),
        };
      case "table":
        return {
          ...base,
          columns: item.columns,
          cellWidth: item.cellWidth,
          // 跨页时每页第一行都是重复的表头
          rows: item.rows.map((row) => ({ header: row.header, height: row.height, cells: row.cells.map((cell) => cell.text) })),
        };
      case "image":
        return { ...base, imageId: item.imageId, live: item.live };
      case "imagePair":
        return { ...base, imageIds: [...item.imageIds] };
      default:
        return base;
    }
  }

  function pageSummary(canvas, index) {
    const page = root.MediaCraftRender.pageOf(canvas);
    const { left, top, right, bottom } = page.bounds;
    return {
      index,
      width: root.MediaCraftEngine.CARD_WIDTH,
      height: root.MediaCraftEngine.CARD_HEIGHT,
      pixelRatio: root.MediaCraftRender.PIXEL_RATIO,
      structure: page.structure,
      role: page.role,
      header: page.first || Boolean(page.signature),
      contentBounds: { left, top, right, bottom },
      fill: page.fill === null ? null : Math.round(page.fill * 100) / 100,
      chars: page.chars,
      overflow: Boolean(page.overflow),
      items: page.items.map(pageItem),
      imageHits: page.imageHits.map(({ imageId, live, x, y, width, height, baseWidth, maxWidth, resizeMaxWidth, source, cover }) => ({
        imageId, live, x, y, width, height, baseWidth, maxWidth, resizeMaxWidth, source, cover: Boolean(cover),
      })),
      dropTargets: page.dropTargets.map(({ kind, imageId, y, height, source }) => ({ kind, imageId, y, height, source })),
    };
  }

  // ===== 各组接口。app：正在编辑的这篇与各模块，由 src/app.js 接好传进来（字段见那里的 app 对象）；
  // current()：这篇现在的样子（API 的 Draft） =====

  // drafts.update：主题先换（会重置配色），再套用同一次传进来的颜色：只给了 bg、text、accent 三色时辅助与衬底按三色规则推，
  // 否则给了的换掉、给了的辅助与衬底记为单独调过，没单独调过的跟着背景与文字走；给了 tunedColors 就按它记（src/themes/palettes.js 的 complete）。
  // undoable 时正文与改了的字段合成撤销历史里的一步（⌘Z 一起撤回）：
  // 字段先照常落到界面上，再连同正文作为一步记进编辑器（套用同样的值不会再变）。
  async function updateDraft(app, patch, { undoable = false } = {}) {
    assertDraftPatch(patch, app.draft.images);
    app.assertEditable();
    const before = undoable ? app.fields() : null;
    const pending = [];
    if ("theme" in patch) pending.push(app.chooseTheme(patch.theme));
    if ("title" in patch) app.setTitle(patch.title);
    if ("caption" in patch) app.setCaption(patch.caption);
    if ("markdown" in patch && !undoable) {
      app.editor.setText(patch.markdown);
      app.media.refresh();
    }
    if ("mode" in patch) app.setMode(patch.mode);
    if ("cover" in patch) app.setCover({ ...app.draft.cover, ...patch.cover });
    if ("cardCss" in patch) app.setCardCss(patch.cardCss);
    const style = Object.fromEntries(Object.entries(patch).filter(([key]) => NUMBER_FIELDS.includes(key)));
    if (patch.colors || patch.tunedColors) Object.assign(style, root.MediaCraftPalettes.complete(patch.colors ?? {}, app.styleForm.read(), patch.tunedColors));
    if (patch.fonts) style.fonts = Object.fromEntries(Object.entries(patch.fonts).map(([script, key]) => [script, String(key)]));
    app.styleForm.write(style);
    if (undoable) {
      const after = app.fields();
      const fields = HISTORY_FIELDS
        .filter((field) => JSON.stringify(before[field]) !== JSON.stringify(after[field]))
        .map((field) => ({ field, before: before[field], after: after[field] }));
      app.editor.edit({ text: patch.markdown, fields });
      if ("markdown" in patch) app.media.refresh();
    }
    pending.push(app.pipeline.now());
    await Promise.all(pending);
    await root.MediaCraftDrafts.flush();
  }

  // 别的稿子（不切换过去）出图用的设置：它存下的字段与图片（画面从本机媒体库里取），署名用界面上现在的。
  async function storedRenderSettings(app, id) {
    const drafts = root.MediaCraftDrafts;
    const record = drafts.get(id);
    if (!record) throw new Error(`没有这篇稿子：${id}`);
    const stored = await drafts.store.readMedia(id);
    const images = Object.fromEntries(Object.entries(record.images || {}).map(([imageId, info]) => [
      imageId,
      { ...info, src: stored.images[imageId] ?? info.src ?? "" },
    ]));
    return { ...apiDraft(id, record), images, profile: app.byline.read() };
  }

  // 稿子由稿件模块（src/drafts/）管；正在编辑的这篇从界面读。
  function draftsApi(app, current) {
    const { editor } = app;
    const drafts = root.MediaCraftDrafts;
    const update = async (patch, options = {}) => {
      assertFields(options, ["undoable"], "drafts.update 的选项：");
      await updateDraft(app, patch, { undoable: Boolean(options.undoable) });
      return current();
    };
    // 出图、存盘都跟上之后返回这篇现在的样子
    const settled = async () => {
      await app.pipeline.now();
      await drafts.flush();
      return current();
    };

    return {
      limit: drafts.limit,
      list: async () => drafts.list(),
      async get(id) {
        if (id === app.draft.id) return current();
        const record = drafts.get(id);
        return record ? apiDraft(id, record) : null;
      },
      current: async () => current(),
      async create(init = {}) {
        assertDraftPatch(init, {});
        await drafts.create();
        return Object.keys(init).length ? update(init) : current();
      },
      // options.focus：那篇在别的窗口里开着时要不要把那个窗口调到前面（默认要；外部 Agent 开的不抢焦点）
      async open(id, options = {}) {
        await drafts.open(id, { focus: options.focus !== false });
        return current();
      },
      // 直接删除，不弹确认框（界面上的删除按钮仍会先确认）。
      async remove(id) {
        await drafts.remove(id);
      },
      // 存盘状态：{ status: "saved" | "pending" | "saving" | "error" | "none", savedAt, error, draftId }
      saveState: async () => drafts.saveState(),
      // 马上存（保存按钮、⌘S、壳在退出 / 关窗 / 重新载入前）：等写进本机后返回状态，没存上时 reject
      saveNow: async () => drafts.saveNow(),
      update,
      // 页内专用：这篇（不切换过去）的第一张卡片，按它自己的正文、主题、配色、字体与图片出图，不管模式；
      // 正在编辑的这篇按界面上的样子。只画第一页；不改稿子、不等预览出图。
      async firstPage(id) {
        const settings = id === app.draft.id ? app.renderSettings({ preview: false }) : await storedRenderSettings(app, id);
        const { pageCount, canvases } = await root.MediaCraftRender.cards(settings, { paint: 1 });
        return { pageCount, canvas: canvases[0] ?? null };
      },
      async undo() {
        editor.undo();
        return settled();
      },
      async redo() {
        editor.redo();
        return settled();
      },
    };
  }

  function renderApi(app) {
    const { editor, pipeline } = app;
    const engine = root.MediaCraftEngine;
    // 每页带上排版自检的问题（src/stage/layout-check.js）
    const cards = () => {
      if (app.draft.mode === "article") return [];
      const pages = pipeline.cards().map(pageSummary);
      const issues = root.MediaCraftLayoutCheck.issues(pages);
      return pages.map((page, index) => ({ ...page, issues: issues[index] }));
    };
    return {
      // 等预览画到最新并返回每页摘要；长文模式没有分页，返回 []。
      async pages() {
        await pipeline.settle();
        return cards();
      },
      // 重新排版出一次图（比如字体加载完之后），返回每页摘要。
      async refresh() {
        await pipeline.now();
        return cards();
      },
      // 页内专用：最近一次画完的预览画布（2 倍图），不触发出图。
      async canvases() {
        await pipeline.latest().catch(() => undefined);
        // HTML 卡片的画布要出图后才有像素
        return [...await pipeline.pixels().catch(() => pipeline.cards())];
      },
      // 页内专用：按当前稿子另出一套图文卡片（预览先画到最新，免得两次出图交错），structure 可指定卡片结构（如 editorial）。
      async offscreen(options = {}) {
        assertFields(options, ["structure"], "render.offscreen：");
        if (options.structure !== undefined && !Object.hasOwn(engine.cardStructures, options.structure)) {
          throw new Error(`没有这个卡片结构：${options.structure}`);
        }
        await pipeline.settle();
        const { canvases, views } = await root.MediaCraftRender.cards(app.renderSettings({ preview: false }), { structure: options.structure });
        return { pages: canvases.map(pageSummary), canvases, views };
      },
      plainText: async (markdown) => engine.plainText(markdown ?? editor.getText()),
      articleHtml: async (markdown) => root.MediaCraftArticle.html(engine.parseMarkdown(markdown ?? editor.getText()), app.draft.images),
    };
  }

  function themesApi(app, current) {
    const themes = root.MediaCraftThemes;
    return {
      async list() {
        return themes.list().map(({ id, name, label, structure, colors, fonts }) => ({
          id, name, label, structure, colors: { ...colors }, fonts: { ...fonts },
        }));
      },
      // 与主题面板里点选相同：换皮肤、结构与配色，颜色微调重置，记为新稿子沿用的主题。
      async apply(id) {
        if (!themes.has(id)) throw new Error(`没有这个主题：${id}`);
        app.assertEditable();
        await app.chooseTheme(id);
        return current();
      },
      // 页内专用：当前正文换成这个主题会排成几页、第一页什么样（主题面板的缩略图）。只画第一页；不改稿子、不等预览出图。
      // 卡片结构、主题配色与「跟随主题」的字体都用它的；就是当前主题时保留颜色微调。
      async preview(id) {
        if (!themes.has(id)) throw new Error(`没有这个主题：${id}`);
        const settings = app.renderSettings({ preview: false });
        const themed = id === settings.theme ? settings : { ...settings, theme: id, colors: { ...themes.get(id).colors }, tunedColors: [] };
        const { pageCount, canvases } = await root.MediaCraftRender.cards(themed, { paint: 1 });
        return { pageCount, canvas: canvases[0] ?? null };
      },
      // 浮动条颜色菜单里的字色与高亮底色：由当前稿子的配色推出来（src/themes/palettes.js 的 inlineSwatches）。
      async swatches() {
        const { text, highlight } = root.MediaCraftPalettes.inlineSwatches(app.fields().colors);
        const hex = (list) => list.map(({ color }) => color);
        return { text: hex(text), highlight: hex(highlight) };
      },
    };
  }

  // 三个字体选单的选项（第一项是「跟随主题」）；family 是出图用的 CSS 字体栈，license 是许可（「跟随主题」为 null）。
  async function fontList() {
    const fonts = root.MediaCraftFonts;
    await fonts.ready;
    const options = (script) => fonts.choices(script).map((choice) => ({
      id: choice.key,
      label: choice.label,
      bundled: Boolean(choice.bundled),
      available: !fonts.isMissing(choice),
      family: fonts.stack(script, choice.key),
      license: fonts.license(choice)?.id ?? null,
    }));
    return { zh: options("zh"), en: options("en"), code: options("code") };
  }

  // 署名（名字、账号、头像）是全局的，不属于某一篇稿子。
  function profileApi(app) {
    const { byline } = app;
    return {
      get: async () => byline.read(),
      async update(patch) {
        assertFields(patch, ["name", "handle", "avatar", "avatarCrop"], "profile.update：");
        app.assertEditable();
        if ("avatar" in patch && (typeof patch.avatar !== "string" || !patch.avatar)) throw new TypeError("avatar 需要是图片地址或 data URL");
        const next = {};
        if ("name" in patch) next.name = String(patch.name);
        if ("handle" in patch) next.handle = String(patch.handle);
        // 换头像时裁剪清空
        if ("avatar" in patch) Object.assign(next, { avatar: patch.avatar, avatarCrop: null });
        if ("avatarCrop" in patch) {
          const crop = patch.avatarCrop;
          next.avatarCrop = crop
            ? { x: Number(crop.x) || 0, y: Number(crop.y) || 0, width: Number(crop.width) || 0, height: Number(crop.height) || 0 }
            : null;
        }
        await byline.write(next);
        await app.pipeline.now();
        return byline.read();
      },
    };
  }

  // 导出的选项：{ save }〔页内〕代替存进「下载」，save(blob, filename) → 实际存下的文件名（外部 Agent 用它写进指定的目录）
  function outputOptions(options = {}) {
    assertFields(options, ["save"], "导出的选项：");
    if ("save" in options && typeof options.save !== "function") throw new TypeError("save 需要是函数 (blob, filename) → 文件名");
    return options;
  }

  // 返回 { api, emit }：api 挂成 window.mediacraft，emit(type, detail) 发 change / rendered 事件。
  function create(app) {
    const events = new EventTarget();
    const { editor, exporter } = app;
    const current = () => apiDraft(app.draft.id, app.fields());
    const check = { fields: assertFields, colors: assertColors, editable: app.assertEditable, current };

    const api = {
      version: "5",
      // 订阅事件：change（当前稿子存盘后有变化，含切换稿子）/ rendered（一次出图画完）/ ai（AI 会话，见 src/ai/session.js）/
      // save-state（存盘状态变了：已保存、等着存、正在写、没存上）。
      // 返回取消订阅的函数。
      on(type, handler) {
        if (!EVENTS.includes(type)) throw new TypeError(`没有这个事件：${type}`);
        if (typeof handler !== "function") throw new TypeError("handler 需要是函数");
        if (type === "ai") return root.MediaCraftAI.on(handler);
        const listener = (event) => handler(event.detail);
        events.addEventListener(type, listener);
        return () => events.removeEventListener(type, listener);
      },
      drafts: draftsApi(app, current),
      editor: {
        selection: async () => editor.selection(),
        select: async (start, end = start) => editor.select(start, end),
        async focus() {
          editor.focus();
        },
      },
      render: renderApi(app),
      // 新解析器（src/engine/markdown.js）：稿子 → 块与行内语法树，带源码范围；语法见 docs/markdown-syntax.md。
      engine: {
        async parse(markdown) {
          if (markdown !== undefined && typeof markdown !== "string") throw new TypeError("engine.parse 需要 Markdown 字符串");
          return root.MediaCraftEngine.parseMarkdown(markdown ?? editor.getText());
        },
      },
      themes: themesApi(app, current),
      // 配色：配色库（内置 48 组）与我的配色（全局，存在本机），套用到当前稿子；色轮的配色规则。
      palettes: root.MediaCraftApi.palettes(app, check),
      fonts: { list: fontList },
      profile: profileApi(app),
      media: root.MediaCraftApi.media(app, check),
      // AI 会话（本机 Claude Code）：每篇稿子一个会话，实现在 src/ai/session.js。
      ai: root.MediaCraftAI.api,
      // 导出与发送（src/output/）：存进「下载」（同名自动加序号），文件名以标题开头；含实况的页打包成 .pvt 放进 ZIP。
      output: {
        exportPng: async (index, options) => exporter.exportPng(index, outputOptions(options)),
        exportZip: async (options) => exporter.exportZip(outputOptions(options)),
        // 长文长图；不在长文模式时会先切到长文。
        exportLongImage: async (options) => exporter.exportLongImage(outputOptions(options)),
        // 整组按页序交给隔空投送，正文纯文本进剪贴板（只在 MediaCraft.app 里可用）。
        sendToIPhone: () => exporter.sendToIPhone(),
        // 长文带格式（行内样式的 HTML）与纯文本一起进剪贴板，可直接粘进公众号编辑器。
        copyArticle: () => exporter.copyArticle(),
      },
      // 外部 Agent（MCP）：连接的开关、接入命令与它做过的操作（可以逐个撤销），实现在 src/mcp/server.js。
      mcp: root.MediaCraftMCP.api,
    };

    return {
      api: deepFreeze(afterDraftsReady(api, app)),
      emit: (type, detail) => events.dispatchEvent(new CustomEvent(type, { detail })),
    };
  }

  (root.MediaCraftApi ||= {}).create = create;
})(window);
