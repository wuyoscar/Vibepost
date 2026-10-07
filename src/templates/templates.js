// 模板库：仓库自带的模板（src/templates/*.md，登记表 src/templates/index.js 由 scripts/build-templates.mjs 生成）与用户自己存的
// （支持目录「模板/<名字>/模板.md」+ 同目录的图片，壳 TemplateLibrary.swift，经原生桥 MediaCraftNative.templates）。
// 这里把它们登记成稿子记录的形状（docs/storage.md）：自带模板的图片留相对路径（和内置说明书一样能直接出图），用户模板的图片
// 由壳读成 data URL；记录多一个 template 字段 { name, description, tags, builtIn }，复制成稿子时去掉（src/drafts/drafts.js 的 createFrom）。
// 模板不是稿子：不在稿件列表里，不能打开、不能改；稿件模块经 host.template(id) 认得它们（drafts.get、firstPage 能用）。
// id：自带的 "template_<登记表里的 id>"，用户的 "user_template_<名字>"。
(function (root) {
  "use strict";

  const BUILT_IN_PREFIX = "template_";
  const USER_PREFIX = "user_template_";
  const format = root.MediaCraftTemplateFormat;
  const registry = root.MediaCraftTemplateRegistry ?? [];
  const native = () => root.MediaCraftNative?.templates ?? null;

  // 用户模板：id → { entry（解析过的 模板.md）, content（原文，变了就重读图片）, record（图片读进来之后才有）}
  const users = new Map();
  let refreshing = null;

  const builtInId = (entry) => `${BUILT_IN_PREFIX}${entry.id}`;
  const userId = (name) => `${USER_PREFIX}${name}`;
  const isTemplate = (id) => String(id ?? "").startsWith(BUILT_IN_PREFIX) || String(id ?? "").startsWith(USER_PREFIX);
  const isBuiltIn = (id) => String(id ?? "").startsWith(BUILT_IN_PREFIX);

  function summaryOf(id, entry, builtIn) {
    return { id, name: entry.name, description: entry.description, tags: [...entry.tags], theme: root.MediaCraftThemes.normalize(entry.theme), builtIn };
  }

  // 登记表（或用户模板）的一项 → 稿子记录。sources：用户模板里图片路径 → data URL（自带模板不用，路径本身就能载入）
  function recordOf(id, entry, builtIn, sources = {}) {
    const themes = root.MediaCraftThemes;
    const theme = themes.get(entry.theme);
    const follow = root.MediaCraftFonts.FOLLOW_THEME;
    const { colors, tunedColors } = root.MediaCraftPalettes.complete(entry.colors, { colors: theme.colors });
    const images = {};
    for (const [imageId, path] of Object.entries(entry.images)) {
      const src = builtIn ? path : sources[path] ?? "";
      if (!src) continue; // 用户模板里缺了的图：正文里的记号照旧，图片面板里没有它
      images[imageId] = { name: path.split("/").pop(), src, layout: null, crop: null };
    }
    const cover = entry.cover ?? {};
    return {
      id,
      title: entry.title,
      caption: entry.caption,
      markdown: entry.markdown.join("\n"),
      mode: "cards",
      theme: theme.id,
      colors,
      tunedColors,
      fonts: Object.fromEntries(format.FONT_SCRIPTS.map((script) => [script, root.MediaCraftFonts.normalize(script, entry.fonts[script] ?? follow)])),
      cover: { enabled: Boolean(cover.enabled), subtitle: cover.subtitle || "", image: cover.image && images[cover.image] ? cover.image : null },
      cardCss: "",
      article: {},
      images,
      createdAt: 0,
      updatedAt: 0,
      template: { name: entry.name, description: entry.description, tags: [...entry.tags], builtIn },
    };
  }

  const builtIns = registry.map((entry) => ({ id: builtInId(entry), entry }));
  const builtIn = (id) => builtIns.find((item) => item.id === id) ?? null;

  // 全部模板的摘要：自带的按登记表顺序在前，用户的（上次 refresh 读到的）按壳给的顺序在后
  function list() {
    return [
      ...builtIns.map(({ id, entry }) => summaryOf(id, entry, true)),
      ...[...users].map(([id, { entry }]) => summaryOf(id, entry, false)),
    ];
  }

  // id 或名字（自带的优先，再用户的）→ 摘要；没有为 null
  function find(key) {
    const text = String(key ?? "");
    const all = list();
    return all.find((item) => item.id === text) ?? all.find((item) => item.name === text) ?? null;
  }

  // 稿子记录（新的拷贝；用户模板要先 load 过，图片才在）；没有为 null
  function record(id) {
    const item = builtIn(id);
    if (item) return recordOf(item.id, item.entry, true);
    const user = users.get(String(id ?? ""));
    return user?.record ? structuredClone(user.record) : null;
  }

  // 重新读用户模板的目录（名字 + 模板.md 全文）：没变的那些图片不重读；浏览器里没有用户模板。返回全部摘要
  async function refresh() {
    if (!native()) return list();
    if (!refreshing) {
      refreshing = (async () => {
        const { templates } = await native().list();
        const seen = new Set();
        for (const { name, content } of templates) {
          const id = userId(name);
          seen.add(id);
          const previous = users.get(id);
          if (previous?.content === content) continue;
          users.set(id, { entry: format.entry(`${name}/模板.md`, content), content, record: null });
        }
        for (const id of [...users.keys()]) if (!seen.has(id)) users.delete(id);
      })().finally(() => {
        refreshing = null;
      });
    }
    await refreshing;
    return list();
  }

  // 把这份模板读成稿子记录（用户模板的图片这时才经壳读成 data URL；没见过的 id 先重读目录）；id 或名字都认，没有为 null
  async function load(key) {
    let summary = find(key);
    if (!summary && native()) {
      await refresh();
      summary = find(key);
    }
    if (!summary) return null;
    if (summary.builtIn) return record(summary.id);
    const user = users.get(summary.id);
    if (!user.record) {
      const { content, images } = await native().read(summary.name);
      const entry = user.content === content ? user.entry : format.entry(`${summary.name}/模板.md`, content);
      Object.assign(user, { entry, content, record: recordOf(summary.id, entry, false, images ?? {}) });
    }
    return structuredClone(user.record);
  }

  // 把当前稿子的字段存成用户模板：{ name, description, tags } 加稿子的字段（docs/storage.md 的形状，图片带着画面 src）。
  // 图片存成文件「<图片 id>.<扩展名>」（随网页打包的相对路径先取回来；实况只存封面那张图）；
  // 配色只写背景、文字、强调与单独调过的辅助、衬底（没单独调过的读回来照旧跟着底色走）。同名的整套换掉。返回摘要
  async function save({ name, description, tags }, fields) {
    if (!native()) throw new Error("模板只在 Vibepost App 里能存（浏览器里没有模板文件夹）");
    const files = [];
    const images = {};
    for (const [imageId, image] of Object.entries(fields.images ?? {})) {
      const { mime, data } = await imageBytes(image.src);
      if (!data) throw new Error(`图片「${image.name || imageId}」读不出来，这套模板没有存`);
      const file = `${imageId}.${EXTENSIONS[mime] ?? "png"}`;
      files.push({ name: file, data });
      images[imageId] = file;
    }
    const tuned = Array.isArray(fields.tunedColors) ? fields.tunedColors : [];
    const colors = Object.fromEntries(format.COLOR_ROLES
      .filter((role) => ["bg", "text", "accent"].includes(role) || tuned.includes(role))
      .filter((role) => fields.colors?.[role])
      .map((role) => [role, fields.colors[role]]));
    const follow = root.MediaCraftFonts.FOLLOW_THEME;
    const fonts = Object.fromEntries(format.FONT_SCRIPTS.filter((script) => fields.fonts?.[script] && fields.fonts[script] !== follow).map((script) => [script, fields.fonts[script]]));
    const cover = fields.cover ?? {};
    const content = format.compose({
      name,
      description,
      tags,
      title: fields.title ?? "",
      theme: root.MediaCraftThemes.normalize(fields.theme),
      colors,
      fonts,
      cover: { enabled: Boolean(cover.enabled), subtitle: cover.subtitle || "", image: cover.image && images[cover.image] ? cover.image : null },
      caption: fields.caption ?? "",
      images,
      markdown: fields.markdown ?? "",
    });
    const saved = await native().save({ name, content, images: files });
    users.delete(userId(saved.name));
    await refresh();
    return find(userId(saved.name));
  }

  const EXTENSIONS = { "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp" };

  // 图片的画面 → { mime, data（base64）}：data URL 直接拆，相对路径（随网页打包的）取回来；读不到时 data 为 null
  async function imageBytes(src) {
    const text = String(src ?? "");
    const match = /^data:([a-z0-9.+-]+\/[a-z0-9.+-]+);base64,(.*)$/is.exec(text);
    if (match) return { mime: match[1].toLowerCase(), data: match[2] };
    if (!text || text.startsWith("blob:")) return { mime: "", data: null };
    try {
      const blob = await fetch(text).then((response) => (response.ok ? response.blob() : null));
      if (!blob) return { mime: "", data: null };
      const url = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(blob);
      });
      return imageBytes(url);
    } catch {
      return { mime: "", data: null };
    }
  }

  // 删一份用户模板（自带的不能删）
  async function remove(id) {
    const summary = find(id);
    if (!summary) throw new Error(`没有这个模板：${id}`);
    if (summary.builtIn) throw new Error(`「${summary.name}」是自带的模板，不能删除`);
    await native().remove(summary.name);
    users.delete(summary.id);
    await refresh();
  }

  // 在 Finder 中显示一份用户模板的文件夹；没给 id 时打开模板文件夹
  async function reveal(id) {
    if (!native()) throw new Error("模板文件夹只在 Vibepost App 里有");
    if (id === undefined || id === null || id === "") return native().reveal();
    const summary = find(id);
    if (!summary) throw new Error(`没有这个模板：${id}`);
    if (summary.builtIn) throw new Error(`「${summary.name}」是自带的模板，在 App 里，没有文件夹可显示`);
    return native().reveal(summary.name);
  }

  root.MediaCraftTemplates = Object.freeze({ isTemplate, isBuiltIn, list, find, record, refresh, load, save, remove, reveal });
})(window);
