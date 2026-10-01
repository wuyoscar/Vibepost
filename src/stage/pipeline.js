// 出图流水线：这篇稿子的设置 → 图文卡片或长文（src/stage/render.js）→ 放上舞台（src/stage/preview.js）。
// 界面上连续的改动（打字、拖滑杆）先停一下再出图；切换稿子、连续改动时旧的出图可能晚于新的画完，只有最新一次能放上舞台，
// 被取代的调用不直接返回，而是等最新一次画完：await 之后看到的一定是最新卡片。
(function (root) {
  "use strict";

  const RENDER_DELAY = 120; // 连续改动停下这么久再出图

  // 停下 wait 毫秒后才执行；cancel() 取消还没到点的那次，pending() 表示还有一次在等
  function debounce(task, wait) {
    let timer = null;
    const debounced = () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        timer = null;
        task();
      }, wait);
    };
    debounced.cancel = () => {
      clearTimeout(timer);
      timer = null;
    };
    debounced.pending = () => timer !== null;
    return debounced;
  }

  // host：
  //   settings()        这一次出图用的设置（稿子字段的快照加署名，形状见 src/stage/render.js）
  //   preview           舞台：showCards(canvases, views) / showArticle(view)（views：每页的卡片元素，舞台放它）
  //   drawn({ mode, pageCount })  最新的一次放上舞台之后（存盘、发 rendered 事件）
  //   failed(error)     界面改动触发的出图出错
  function create(host) {
    let cardCanvases = []; // 最近一次画完的卡片画布（长文模式为空）
    let drawCards = () => Promise.resolve(); // 让这些画布有像素（HTML 卡片要出图时才出）
    let ticket = 0; // 出图的序号：只有最新一次能放上舞台
    let latest = Promise.resolve();

    async function draw(own) {
      const settings = host.settings();
      const article = settings.mode === "article";
      const result = article ? await root.MediaCraftRender.articleView(settings) : await root.MediaCraftRender.cards(settings, { lazy: true });
      if (own !== ticket) return latest;
      if (article) {
        cardCanvases = [];
        drawCards = () => Promise.resolve();
        host.preview.showArticle(result);
      } else {
        cardCanvases = result.canvases;
        drawCards = result.draw;
        host.preview.showCards(cardCanvases, result.views);
      }
      host.drawn({ mode: settings.mode, pageCount: cardCanvases.length });
    }

    function render() {
      const run = draw(++ticket);
      latest = run;
      return run;
    }

    const request = debounce(() => {
      render().catch(host.failed);
    }, RENDER_DELAY);

    // 马上出图：先取消还没到点的防抖出图，免得它稍后插进来，和接下来的操作交错。
    function now() {
      request.cancel();
      return render();
    }

    return {
      render,
      request,
      now,
      // 等预览画到最新：还有没到点的防抖出图就马上画，否则只等正在画的那次，不重复出图。
      settle: () => (request.pending() ? now() : latest),
      latest: () => latest,
      // 最近一次的画布，页面结果用 MediaCraftRender.pageOf 取；HTML 卡片这时可能还没有像素
      cards: () => cardCanvases,
      // 画到最新、画布都有像素之后的画布（导出、发送、缩略图、看一页用）
      async pixels() {
        await latest;
        const canvases = cardCanvases;
        await drawCards();
        return canvases;
      },
    };
  }

  root.MediaCraftPipeline = { create };
})(globalThis);
