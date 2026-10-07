// 内置说明书：三篇只读的稿子，正文是随网页打包的 Markdown（src/guides/cards.js、styles.js、article.js 登记进来，
// 稿件栏里按这个次序；styles.js 的「样式与写法」由操作手册登记表 src/engine/manual.js 写出），
// 演示用的图片与实况视频在 docs/guide-assets/（scripts/make-guide-assets.swift 生成）。
// 稿件模块把它们列在稿子最前（host.builtIns），不存盘；打开说明书时，界面上改稿子的控件都停用。
(function (root) {
  "use strict";

  const ID_PREFIX = "guide_";
  const guides = [];

  // 登记一篇说明书：{ id（以 guide_ 开头）, title, mode: "cards" | "article", markdown: 行的数组, images }
  // images 是稿子记录里的图片信息（docs/storage.md），画面用随网页打包的相对路径。
  function define(guide) {
    if (!String(guide.id).startsWith(ID_PREFIX)) throw new TypeError(`说明书的 id 要以 ${ID_PREFIX} 开头：${guide.id}`);
    guides.push(guide);
  }

  // 稿件模块要的内置稿子 [{ id, title, record }]：record 同稿子记录的形状，主题用默认主题、字体跟随主题，
  // 配色、字号、行距、图片最大高不写，打开时按主题与默认值补上。
  function builtIns() {
    return guides.map((guide) => ({
      id: guide.id,
      title: guide.title,
      record: {
        id: guide.id,
        title: guide.title,
        markdown: guide.markdown.join("\n"),
        mode: guide.mode,
        theme: root.MediaCraftThemes.DEFAULT,
        colors: {},
        fonts: { zh: "theme", en: "theme", code: "theme" },
        article: {},
        images: structuredClone(guide.images),
        createdAt: 0,
        updatedAt: 0,
      },
    }));
  }

  function isGuide(id) {
    return String(id ?? "").startsWith(ID_PREFIX);
  }

  // 只读时停用排版模式切换与标了 data-guide-lock 的区域（格式条、标题、查找、检查器「样式」）里的控件，
  // 菜单收起、点不开。离开说明书时只恢复自己停用的那些：别的模块因为别的原因停用的控件照旧。
  function lockControls(readOnly) {
    for (const region of document.querySelectorAll(".layout-mode-switch, [data-guide-lock]")) {
      for (const control of region.querySelectorAll("button, input, select, textarea")) {
        if (readOnly && !control.disabled) {
          control.disabled = true;
          control.dataset.guideLocked = "";
        } else if (!readOnly && "guideLocked" in control.dataset) {
          control.disabled = false;
          delete control.dataset.guideLocked;
        }
      }
      for (const menu of region.querySelectorAll("details")) {
        if (readOnly) menu.open = false;
        menu.inert = readOnly;
        menu.querySelector("summary")?.setAttribute("aria-disabled", String(readOnly));
      }
    }
  }

  root.MediaCraftGuides = { define, builtIns, isGuide, lockControls };
})(window);
