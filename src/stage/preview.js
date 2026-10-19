// 预览舞台上的内容：图文卡片一页一个框（卡片画布或 HTML 卡片 + 图片与实况的操作层 + 右侧「下载这张」），长文是一整篇页面。
// HTML 卡片（ADR 0006）放的是活的卡片元素（864 × 1152，按框宽等比缩放），不等出图。
// 翻页、胶片、跟着光标走在 src/shell.js；这里只负责把出好的图放上去，页脚写几张图。
(function (root) {
  "use strict";

  const ARTICLE_GUTTER = 48; // 长文页面两侧至少留的空
  const CARD_WIDTH = 864;

  // 框里的 HTML 卡片跟着框宽缩放
  const cardScale = new ResizeObserver((entries) => {
    for (const { target, contentRect } of entries) target.style.setProperty("--card-scale", String(contentRect.width / CARD_WIDTH));
  });

  // host：
  //   pages        放卡片的容器（#stageCards）
  //   pageCount    页脚「N 张图片」
  //   attach(frame, page, index)  给一页挂上图片、实况的操作层（src/media/）
  //   exportPage(index)           「下载这张」
  function create(host) {
    const { pages, pageCount } = host;

    function downloadIcon() {
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      svg.setAttribute("class", "icon");
      svg.setAttribute("aria-hidden", "true");
      const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
      use.setAttribute("href", "#i-download");
      svg.append(use);
      return svg;
    }

    // view：这一页的 HTML 卡片元素。有的话看到的是它，画布垫在后面看不见（出图后才有像素）：
    // 画布仍在舞台上，render.canvases() 里的每张都能在舞台上找到
    function stageCard(canvas, index, view) {
      const card = document.createElement("article");
      card.className = "stage-card";
      const frame = document.createElement("div");
      frame.className = "card-frame";
      const height = canvas.height / 2;
      frame.style.setProperty('--card-height', String(height));
      frame.style.setProperty('--card-height-px', `${height}px`);
      frame.style.setProperty('--card-ratio', String(CARD_WIDTH / height));
      const sizeLabel = {1152: '3:4', 1222: 'A4 比例', 1536: '9:16', 1728: '1:2'}[height];
      document.querySelector('.stage-spec').textContent = `${canvas.width} × ${canvas.height} · ${sizeLabel ?? ''} · PNG`;
      if (view) {
        canvas.classList.add("is-raster");
        frame.append(view, canvas);
      } else {
        frame.append(canvas);
      }
      if (view) cardScale.observe(frame);
      host.attach(frame, root.MediaCraftRender.pageOf(canvas), index);

      const footer = document.createElement("div");
      footer.className = "card-footer";
      const label = document.createElement("span");
      label.textContent = `第 ${index + 1} 张`;
      const download = document.createElement("button");
      download.type = "button";
      download.dataset.pageExport = "true";
      download.setAttribute("aria-label", `下载第 ${index + 1} 张`);
      download.title = "下载这张（PNG）";
      download.append(downloadIcon());
      download.addEventListener("click", () => host.exportPage(index));
      footer.append(label, download);

      card.append(frame, footer);
      return card;
    }

    // 舞台比版心窄时整页等比缩小（zoom 连布局一起缩），排版仍和长图一致。
    function fitArticle() {
      const page = pages.querySelector(".article-page");
      if (!page) return;
      const room = pages.parentElement.clientWidth - ARTICLE_GUTTER;
      page.style.zoom = String(Math.min(1, room / root.MediaCraftArticle.PAGE_WIDTH));
    }
    new ResizeObserver(fitArticle).observe(pages.parentElement);

    return {
      showCards(canvases, views = null) {
        pages.className = "stage-cards";
        for (const frame of pages.querySelectorAll(".card-frame")) cardScale.unobserve(frame);
        pages.replaceChildren(...canvases.map((canvas, index) => stageCard(canvas, index, views?.[index])));
        const live = canvases.filter((canvas) => root.MediaCraftRender.pageOf(canvas).imageHits.some((hit) => hit.live)).length;
        pageCount.textContent = `${canvases.length} 张图片${live ? ` · ${live} 张实况` : ""}`;
      },
      showArticle(view) {
        pages.className = "stage-cards is-article";
        pages.replaceChildren(view);
        fitArticle();
        pageCount.textContent = "长文 · 1 张长图";
      },
    };
  }

  root.MediaCraftPreview = { create };
})(globalThis);
