// HTML 卡片出图的宿主页脚本（见 raster-host.html）。原生壳经 callAsyncJavaScript 调：
//   mcRaster.setup(style, media, width, height)  换上这一套卡片的样式与图片（编号 → data URL）
//   mcRaster.show(html)                          换上一页，等字体、图片都就绪后返回，壳随即截图
(function () {
  "use strict";

  let card = null;
  let styleNode = null;
  let pageRoot = null;
  let media = {};

  function ensureCard() {
    if (card) return;
    card = document.createElement("div");
    card.className = "mc-raster-card";
    const shadow = card.attachShadow({ mode: "open" });
    styleNode = document.createElement("style");
    pageRoot = document.createElement("div");
    pageRoot.className = "mc-root";
    shadow.append(styleNode, pageRoot);
    document.body.append(card);
  }

  // 图片写成 data-media="编号"，这里换成 data URL；等每张都解码完
  async function settleImages() {
    const images = [...pageRoot.querySelectorAll("img")];
    for (const image of images) {
      const id = image.dataset.media;
      if (id && media[id]) image.src = media[id];
    }
    await Promise.all(images.map((image) => image.decode().catch(() => undefined)));
  }

  async function setup(style, mediaMap, width, height) {
    ensureCard();
    media = mediaMap || {};
    styleNode.textContent = style;
    card.style.width = `${width}px`;
    card.style.height = `${height}px`;
    return true;
  }

  // 这一页用到的字：按每段字实际的字体（斜体、字重、字族）分组，逐组 document.fonts.load。打包的中文字体按字切成
  // 很多小块（unicode-range），只等 fonts.ready 时还没开始下载的块会被漏掉，截出来的就是备用字
  async function settleFonts() {
    const groups = new Map();
    const walker = document.createTreeWalker(pageRoot, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.nodeValue.trim() || !node.parentElement) continue;
      const style = getComputedStyle(node.parentElement);
      const font = `${style.fontStyle} ${style.fontWeight} 16px ${style.fontFamily}`;
      groups.set(font, (groups.get(font) ?? "") + node.nodeValue);
    }
    await Promise.all([...groups].map(([font, text]) => document.fonts.load(font, text).catch(() => undefined)));
    await document.fonts.ready;
  }

  async function show(html) {
    ensureCard();
    pageRoot.innerHTML = html;
    await settleImages();
    void pageRoot.offsetHeight; // 先排一次版，字体才会开始加载
    await settleFonts();
    return { width: card.offsetWidth, height: card.offsetHeight };
  }

  window.mcRaster = { setup, show };
})();
