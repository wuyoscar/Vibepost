// HTML 卡片出图的宿主页脚本（见 raster-host.html）。原生壳经 callAsyncJavaScript 调：
//   mcRaster.setup(style, media, mediaIds, width, height)  换上这一套卡片的样式，收下新图片（编号 → data URL），回 { generation, missing }
//   mcRaster.show(html)                                    换上一页，等字体、图片都就绪后返回，壳随即截图
//   mcRaster.chrome(head, foot)                            把页眉页脚换成真实页码的那份，回要重截的区域
// 图片在这里按编号留着（同一张图只过一次桥）：客户端记着哪些发过、宿主页回 generation（重建后换一个）与缺的编号。
(function () {
  "use strict";

  const MEDIA_BYTES = 400 * 1024 * 1024; // 留着的图片总量上限：超了丢最久没用的
  const generation = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
  let card = null;
  let styleNode = null;
  let pageRoot = null;
  const media = new Map(); // 编号 → data URL；用过的挪到末尾（Map 保序，最前面的最久没用）
  let mediaBytes = 0;

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

  function keep(id, src) {
    if (media.has(id)) {
      mediaBytes -= media.get(id).length;
      media.delete(id);
    }
    media.set(id, src);
    mediaBytes += src.length;
    while (mediaBytes > MEDIA_BYTES && media.size > 1) {
      const oldest = media.keys().next().value;
      mediaBytes -= media.get(oldest).length;
      media.delete(oldest);
    }
  }

  function touch(id) {
    const src = media.get(id);
    if (src === undefined) return;
    media.delete(id);
    media.set(id, src);
  }

  // 图片写成 data-media="编号"，这里换成 data URL；等每张都解码完
  async function settleImages() {
    const images = [...pageRoot.querySelectorAll("img")];
    for (const image of images) {
      const id = image.dataset.media;
      if (id && media.has(id)) {
        touch(id);
        image.src = media.get(id);
      }
    }
    await Promise.all(images.map((image) => image.decode().catch(() => undefined)));
  }

  async function setup(style, mediaMap, mediaIds, width, height) {
    ensureCard();
    for (const [id, src] of Object.entries(mediaMap || {})) if (typeof src === "string") keep(id, src);
    styleNode.textContent = style;
    card.style.width = `${width}px`;
    card.style.height = `${height}px`;
    const missing = (Array.isArray(mediaIds) ? mediaIds : []).filter((id) => !media.has(id));
    return { generation, missing };
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

  // 正文 PNG 是按占位页码截的（这样页数变了正文页的图还能复用）；页眉页脚换成真实页码之后，回要重截的区域：
  // 元素连同全部后代的框（页眉常是个 0 高的绝对定位容器，字都在它的子元素里）换之前与换之后的并集（页码变宽变窄都盖得住），
  // 四周再放宽一些（字形的上伸下伸、贴纸的阴影、发光都画在框外面），按卡片坐标向外取整。head / foot 为空字符串的不换
  const STRIP_PAD = 16;
  const boxes = (element) => [element, ...element.querySelectorAll("*")]
    .map((node) => node.getBoundingClientRect())
    .filter((box) => box.width > 0 && box.height > 0);
  async function chrome(head, foot) {
    ensureCard();
    const rects = [];
    const base = card.getBoundingClientRect();
    for (const [selector, html] of [[".mc-head", head], [".mc-foot", foot]]) {
      const element = pageRoot.querySelector(selector);
      if (!element || typeof html !== "string" || !html) continue;
      const before = boxes(element);
      element.innerHTML = html;
      await settleImages();
      void pageRoot.offsetHeight;
      await settleFonts();
      const all = [...before, ...boxes(element)];
      if (!all.length) continue;
      const left = Math.max(0, Math.floor(Math.min(...all.map((box) => box.left)) - base.left) - STRIP_PAD);
      const top = Math.max(0, Math.floor(Math.min(...all.map((box) => box.top)) - base.top) - STRIP_PAD);
      const right = Math.min(card.offsetWidth, Math.ceil(Math.max(...all.map((box) => box.right)) - base.left) + STRIP_PAD);
      const bottom = Math.min(card.offsetHeight, Math.ceil(Math.max(...all.map((box) => box.bottom)) - base.top) + STRIP_PAD);
      if (right > left && bottom > top) rects.push({ x: left, y: top, width: right - left, height: bottom - top });
    }
    return rects;
  }

  window.mcRaster = { setup, show, chrome };
})();
