// 出图：一篇稿子的设置 → 图文卡片（HTML 卡片，src/cards/）或长文（src/article/）。
// settings 是稿子的字段加上署名：
//   { title, markdown, theme, colors: { bg, text, accent, secondary, surface }, tunedColors（单独调过的辅助、衬底）,
//     fonts: { zh, en, code }, fontSize, lineHeight, imageMaxHeight,
//     cover: { enabled, subtitle, image }, images: { id: 图片记录（含 src）}, profile: { name, handle, avatar, avatarCrop } }
// 不碰界面：卡片元素与画布、长文页面交给调用方放到舞台上（src/stage/preview.js）。
(function (root) {
  "use strict";

  const engine = root.MediaCraftEngine;
  const themes = root.MediaCraftThemes;
  const fonts = root.MediaCraftFonts;

  const PIXEL_RATIO = 2; // 卡片出成 2 倍图：864 × 1152 的逻辑像素 → 1728 × 2304

  // 每张卡片画布（与舞台上的卡片元素）这一页的排版结果：内容项、图片点选框、拖放落点、块、正文区、所用的卡片结构；用 pageOf 取
  const layouts = new WeakMap();

  // 这篇的字体（「跟随主题」换成主题的）与卡片结构（长文也按它取字体）
  async function typeSetup(settings) {
    await fonts.ready;
    const theme = themes.get(settings.theme);
    const structure = engine.cardStructures[theme.structure];
    const fontKeys = fonts.resolve(settings.fonts, theme.fonts, theme.titleFonts);
    return { structure, fontKeys, setup: fonts.cardSetup(fontKeys, structure) };
  }

  // 头像的裁剪框（署名里「裁剪头像」）：先裁成一张正方形小图再交给卡片，卡片上只管铺满圆框。按原图与裁剪框记住上一次的结果。
  const AVATAR_SIZE = 256;
  let croppedAvatar = { key: "", src: Promise.resolve("") };
  function avatarOf(profile) {
    if (!profile?.avatar || !profile.avatarCrop) return Promise.resolve(profile?.avatar ?? "");
    const key = JSON.stringify([profile.avatar, profile.avatarCrop]);
    if (croppedAvatar.key === key) return croppedAvatar.src;
    const src = new Promise((resolve) => {
      const image = new Image();
      image.onload = () => {
        const canvas = document.createElement("canvas");
        canvas.width = canvas.height = AVATAR_SIZE;
        const rect = engine.imageCropRect({ width: image.naturalWidth, height: image.naturalHeight }, profile.avatarCrop);
        engine.drawCover(canvas.getContext("2d"), image, rect, 0, 0, AVATAR_SIZE, AVATAR_SIZE);
        resolve(canvas.toDataURL("image/png"));
      };
      image.onerror = () => resolve(profile.avatar); // 读不出来时照原图放
      image.src = profile.avatar;
    });
    croppedAvatar = { key, src };
    return src;
  }

  // 一套图文卡片（HTML 卡片，ADR 0006，src/cards/）：排整篇，前 paint 页各一张 2 倍图画布，这一页的排版结果用 pageOf 取。
  // structure：指定卡片结构（主题面板的缩略图）。lazy（出图流水线用）：先不出图，画布是空的，要像素时调 draw()；
  // 舞台放 views（每页的卡片元素），不等出图。
  async function cards(settings, { structure: structureId, paint = Infinity, lazy = false } = {}) {
    const cardsModule = root.MediaCraftCards;
    const profile = settings.profile && { ...settings.profile, avatar: await avatarOf(settings.profile) };
    const result = await cardsModule.layout({ ...settings, profile, ...(structureId ? { structureId } : {}) });
    const { pageCount, canvases, pages, views, draw, thumbnails } = await cardsModule.paint(result, { paint });
    canvases.forEach((canvas, index) => layouts.set(canvas, pages[index]));
    views.forEach((view, index) => layouts.set(view, pages[index]));
    if (!lazy) await draw();
    return { pageCount, canvases, views, draw, thumbnails };
  }

  // 长文的外观跟随这篇的主题：配色（含单篇微调）、字体、字号与行距都和卡片一致。
  async function articleOptions(settings) {
    const { fontKeys, setup } = await typeSetup(settings);
    return {
      media: settings.images,
      look: {
        colors: settings.colors,
        tunedColors: settings.tunedColors,
        fonts: { body: setup.fonts.latin, display: setup.fonts.display, code: setup.fonts.code },
        displayBold: setup.displayBold,
        zhFont: fontKeys.zh,
        boldWeight: setup.boldWeight,
        fontSize: settings.fontSize,
        lineHeight: settings.lineHeight,
      },
    };
  }

  const articleDoc = (settings) => engine.parseMarkdown(settings.markdown);

  async function articleView(settings) {
    return root.MediaCraftArticle.view(articleDoc(settings), await articleOptions(settings));
  }

  async function articleImage(settings) {
    return root.MediaCraftArticle.longImage(articleDoc(settings), await articleOptions(settings));
  }

  // 公众号格式：只带行内样式的 HTML，外加「复制全文」的纯文本
  async function articleRichText(settings) {
    const html = await root.MediaCraftArticle.wechat(articleDoc(settings), await articleOptions(settings));
    return { html, text: engine.plainText(settings.markdown) };
  }

  // 这张画布上那一页的排版结果（不是 cards() 画出来的画布为 null）
  const pageOf = (canvas) => layouts.get(canvas) ?? null;

  root.MediaCraftRender = { PIXEL_RATIO, cards, pageOf, articleView, articleImage, articleRichText };
})(globalThis);
