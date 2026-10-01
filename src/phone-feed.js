// 手机预览的两个网格视图（src/phone-preview.js 切换）：发现页是双列瀑布流，这一篇放在最近几篇稿子中间；
// 主页是资料头加三列网格，这一篇在第一格。每格的首图是那篇稿子的第一张卡片，不用任何平台的标识。
// 这一篇的首图每次出图后直接用预览的第一页；别的稿子（内置说明书、长文不算）的首图停手后逐篇生成，
// 按（稿子、修改时间、设置与署名）缓存；一有按键、点按或输入就停下，停手后接着来，不跟打字抢时间。
// 只通过 App API（window.mediacraft）和界面元素工作，不碰 src/app.js 的内部名字。
(function (root) {
  "use strict";

  const mc = root.mediacraft;
  // 首图画布：发现页一格约 176 CSS 像素宽的 2 倍图，主页三列时缩小着用
  const THUMB_WIDTH = 360;
  const THUMB_HEIGHT = 480;
  // 最多放几篇别的稿子
  const RECENT = 9;
  // 停手多久后开始（或接着）生成
  const IDLE_DELAY = 400;
  // 最多记住多少张首图（每张约 690 KB）
  const CACHE_LIMIT = 24;

  // 32 位 FNV-1a
  function hash(text) {
    let value = 2166136261;
    for (let index = 0; index < text.length; index += 1) {
      value ^= text.charCodeAt(index);
      value = Math.imul(value, 16777619);
    }
    return (value >>> 0).toString(36);
  }

  // 头像的 data URL 可能有几 MB：只取长度与首尾，够分辨换没换
  const fingerprint = (source) => (source ? `${source.length}:${source.slice(0, 96)}:${source.slice(-96)}` : "");

  function element(tag, className, text) {
    const node = document.createElement(tag);
    node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function coverCanvas() {
    const canvas = element("canvas", "phone-cover");
    canvas.width = THUMB_WIDTH;
    canvas.height = THUMB_HEIGHT;
    canvas.setAttribute("aria-hidden", "true");
    return canvas;
  }

  function shrink(canvas) {
    const thumb = document.createElement("canvas");
    thumb.width = THUMB_WIDTH;
    thumb.height = THUMB_HEIGHT;
    const context = thumb.getContext("2d");
    context.imageSmoothingQuality = "high";
    context.drawImage(canvas, 0, 0, THUMB_WIDTH, THUMB_HEIGHT);
    return thumb;
  }

  // 发现页的一格：首图、两行标题、头像昵称与点赞位
  function feedTile() {
    const node = element("div", "phone-tile");
    node.setAttribute("role", "listitem");
    const canvas = coverCanvas();
    const title = element("p", "phone-tile-title");
    const meta = element("div", "phone-tile-meta");
    meta.setAttribute("aria-hidden", "true");
    const name = element("span", "phone-tile-name");
    const like = element("span", "phone-tile-like");
    const heart = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    heart.setAttribute("class", "icon");
    const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
    use.setAttribute("href", "#i-heart");
    heart.append(use);
    like.append(heart, "赞");
    meta.append(element("span", "phone-tile-avatar"), name, like);
    node.append(canvas, title, meta);
    return { node, canvas, title, name, shown: undefined };
  }

  // 主页网格的一格：只有首图
  function gridTile() {
    const node = element("div", "phone-grid-tile");
    node.setAttribute("role", "listitem");
    const canvas = coverCanvas();
    node.append(canvas);
    return { node, canvas, shown: undefined };
  }

  // elements：{ feed: 发现页的列表（里面两列）, grid: 主页网格, name, handle: 主页资料头里的名字与账号 }
  function create(elements) {
    const columns = [...elements.feed.children];
    const tiles = { feed: new Map(), profile: new Map() };
    const cache = new Map();
    // 现在显示的视图（"feed" / "profile"），手机预览关着或在看笔记时为 null
    let view = null;
    // 最近一次整理出来的：这一篇 { id, title, image } 与别的稿子 [{ id, title, key }]
    let current = null;
    let others = [];
    let profile = { name: "", handle: "" };
    let refreshSeq = 0;
    // 每次停下都加一；跑着的那一轮发现变了就放弃
    let job = 0;
    let idleTimer = 0;

    function store(key, image) {
      cache.delete(key);
      cache.set(key, image);
      if (cache.size > CACHE_LIMIT) cache.delete(cache.keys().next().value);
    }

    function drawCover(tile, image) {
      if (tile.shown === image) return;
      tile.shown = image;
      const context = tile.canvas.getContext("2d");
      context.clearRect(0, 0, THUMB_WIDTH, THUMB_HEIGHT);
      if (image) context.drawImage(image, 0, 0);
    }

    // 发现页：这一篇放在第二格（右列最上面），像是混在最近的稿子里；主页：这一篇在第一格
    function order() {
      if (!current) return [];
      if (view === "profile" || !others.length) return [current, ...others];
      return [others[0], current, ...others.slice(1)];
    }

    // 按整理好的顺序摆格子：已有的格子挪位置、换字，不重建；首图有变化才重画
    function paint() {
      if (!view) return;
      const items = order();
      const map = tiles[view];
      for (const [id, tile] of map) {
        if (!items.some((item) => item.id === id)) {
          tile.node.remove();
          map.delete(id);
        }
      }
      let pending = 0;
      items.forEach((item, index) => {
        let tile = map.get(item.id);
        if (!tile) {
          tile = view === "feed" ? feedTile() : gridTile();
          map.set(item.id, tile);
        }
        const mine = item === current;
        const image = mine ? item.image : cache.get(item.key);
        if (image === undefined) pending += 1;
        drawCover(tile, image ?? null);
        tile.node.setAttribute("aria-label", item.title);
        if (mine) tile.node.setAttribute("aria-current", "true");
        else tile.node.removeAttribute("aria-current");
        if (view === "feed") {
          tile.title.textContent = item.title;
          tile.name.textContent = profile.name;
          columns[index % 2].append(tile.node);
        } else {
          elements.grid.append(tile.node);
        }
      });
      (view === "feed" ? elements.feed : elements.grid).setAttribute("aria-busy", String(pending > 0));
      elements.name.textContent = profile.name;
      elements.handle.textContent = profile.handle ? `账号：${profile.handle}` : "";
      elements.handle.hidden = !profile.handle;
    }

    // ===== 别的稿子的首图：停手后逐篇生成 =====
    const nextTask = () => new Promise((resolve) => setTimeout(resolve, 0));

    function stop() {
      job += 1;
      clearTimeout(idleTimer);
    }

    function schedule() {
      stop();
      if (view && others.some((item) => !cache.has(item.key))) idleTimer = setTimeout(generate, IDLE_DELAY);
    }

    // 一次出一篇；出图期间按了键、换了稿子，这一张照样记下（它只看那篇存下的样子），下一张等停手后再来。
    // 出不来的（比如刚被删掉）记为空白，不反复重试。
    async function generate() {
      const run = ++job;
      while (run === job && view) {
        const item = others.find((entry) => !cache.has(entry.key));
        if (!item) return;
        const { canvas } = await mc.drafts.firstPage(item.id).catch(() => ({ canvas: null }));
        store(item.key, canvas ? shrink(canvas) : null);
        paint();
        await nextTask();
      }
    }

    // ===== 整理：最近的稿子、署名与这一篇的首图 =====
    async function keyOf({ id, updatedAt }, profileKey) {
      const draft = await mc.drafts.get(id);
      return `${id}|${updatedAt}|${hash(JSON.stringify(draft))}|${profileKey}`;
    }

    async function refresh() {
      if (!view) return;
      const seq = ++refreshSeq;
      const [list, me, canvases] = await Promise.all([mc.drafts.list(), mc.profile.get(), mc.render.canvases()]);
      const profileKey = hash(JSON.stringify([me.name, me.handle, fingerprint(me.avatar), me.avatarCrop]));
      const recent = list.filter((item) => !item.builtIn && !item.current && item.mode === "cards").slice(0, RECENT);
      const keys = await Promise.all(recent.map((item) => keyOf(item, profileKey)));
      const mine = list.find((item) => item.current);
      if (seq !== refreshSeq || !view || !mine) return;
      profile = { name: me.name, handle: me.handle };
      current = { id: mine.id, title: mine.title, image: canvases[0] ? shrink(canvases[0]) : null };
      others = recent.map((item, index) => ({ id: item.id, title: item.title, key: keys[index] }));
      paint();
      schedule();
    }

    // 打字、点按时停下，停手后接着生成
    for (const type of ["keydown", "pointerdown", "input"]) document.addEventListener(type, schedule, true);
    mc.on("rendered", () => void refresh());
    mc.on("change", () => void refresh());

    return {
      // 换成这个视图（"feed" / "profile"）；null 是手机预览关了或在看笔记：停下生成
      show(next) {
        view = next;
        if (!view) {
          stop();
          return;
        }
        void refresh();
      },
    };
  }

  root.MediaCraftPhoneFeed = { create };
})(window);
