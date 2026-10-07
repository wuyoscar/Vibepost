// MediaCraft 卡片结构：每种结构的版心、字号比例、图片圆角、页眉页脚用什么字，
// 以及封面（cover：标题字号范围与行数、副标题、文字区与底图放在哪）与结尾页（end：两侧留白、署名的样子）的规格。
// 只是数据：HTML 卡片（src/cards/cards.js、cover.js）按它排版，页眉页脚与装饰的样子在 src/cards/chrome.js 与 structures.css。
// 坐标是卡片的逻辑像素（864 × 1152）。主题用哪种结构见 src/themes/themes.js。
(function (root) {
  "use strict";

  const CARD_WIDTH = 864;
  const CARD_HEIGHT = 1152;

  // 纯白、纯黑共用的版式（两个结构 id：线条与次要文字的深浅在 src/cards/structures.css 里分开写）
  const MINIMAL = {
    name: "纯白",
    pages: { inner: { top: 164, right: 72, bottom: 96, left: 72 }, first: { top: 164, right: 72, bottom: 96, left: 72 } },
    body: { scale: 1 },
    headings: {
      h1: { scale: 2, lineHeight: 1.18, weight: 700 },
      h2: { scale: 1.34, lineHeight: 1.36, weight: 700 },
      h3: { scale: 1.12, lineHeight: 1.5, weight: 700 },
    },
    imageRadius: 0,
    labelFont: "sans",
    board: null,
    cover: {
      title: { weight: 700, max: 132, min: 72, lineHeight: 1.08, maxLines: 4 },
      subtitle: { size: 30, weight: 400, lineHeight: 1.6, gap: 28, maxLines: 3, pin: null },
      align: "left",
      column: { left: 72, right: 72 },
      area: { top: 200, bottom: 1000, anchor: "bottom" },
      image: {
        mode: "plate",
        box: { x: 72, y: 164, width: 720, height: 520, radius: 0 },
        area: { top: 724, bottom: 1060, anchor: "top" },
        lead: 0,
        titleMax: 96,
        subtitleLines: 2,
      },
    },
    end: {
      inset: 72,
      signature: { avatar: 88, name: { size: 24, weight: 600, font: "label", upper: true, spacing: 4 }, handle: { size: 22 } },
    },
  };

  const STRUCTURES = {
    clay: {
      name: "陶土",
      pages: { inner: { top: 150, right: 80, bottom: 104, left: 80 }, first: { top: 150, right: 80, bottom: 104, left: 80 } },
      body: { scale: 1 },
      headings: {
        h1: { scale: 1.82, lineHeight: 1.26, weight: 600 },
        h2: { scale: 1.3, lineHeight: 1.38, weight: 600 },
        h3: { scale: 1.1, lineHeight: 1.5, weight: 600 },
      },
      imageRadius: 14,
      labelFont: "sans",
      board: null,
      cover: {
        title: { weight: 600, max: 132, min: 64, lineHeight: 1.16, maxLines: 4 },
        subtitle: { size: 30, weight: 400, lineHeight: 1.6, gap: 36, maxLines: 3, pin: null },
        align: "left",
        column: { left: 80, right: 80 },
        area: { top: 220, bottom: 1000, anchor: "bottom" },
        image: {
          mode: "plate",
          box: { x: 80, y: 150, width: 704, height: 480, radius: 18 },
          area: { top: 672, bottom: 1040, anchor: "top" },
          lead: 0,
          titleMax: 100,
          subtitleLines: 2,
        },
      },
      end: {
        inset: 64,
        signature: { avatar: 96, name: { size: 30, weight: 600, font: "body", upper: false, spacing: 0 }, handle: { size: 24 } },
      },
    },
    plain: MINIMAL,
    ink: { ...MINIMAL, name: "纯黑" },
    editorial: {
      name: "杂志",
      pages: { inner: { top: 150, right: 80, bottom: 150, left: 80 }, first: { top: 150, right: 80, bottom: 150, left: 80 } },
      body: { scale: 1 },
      headings: {
        h1: { scale: 1.9, lineHeight: 1.22, weight: 600 },
        h2: { scale: 1.3, lineHeight: 1.4, weight: 600 },
        h3: { scale: 1.08, lineHeight: 1.5, weight: 600 },
      },
      imageRadius: 0,
      labelFont: "sans",
      board: null,
      cover: {
        title: { weight: 600, max: 112, min: 64, lineHeight: 1.16, maxLines: 4 },
        subtitle: { size: 30, weight: 400, lineHeight: 1.7, gap: 40, maxLines: 3, pin: null },
        align: "center",
        column: { left: 80, right: 80 },
        area: { top: 220, bottom: 960, anchor: "center" },
        image: {
          mode: "plate",
          box: { x: 80, y: 150, width: 704, height: 540, radius: 0 },
          area: { top: 736, bottom: 1060, anchor: "top" },
          lead: 0,
          titleMax: 96,
          subtitleLines: 2,
        },
      },
      end: {
        inset: 72,
        signature: { avatar: 88, name: { size: 22, weight: 500, font: "label", upper: true, spacing: 6 }, handle: { size: 22 } },
      },
    },
    notes: {
      name: "备忘",
      pages: { inner: { top: 150, right: 64, bottom: 96, left: 64 }, first: { top: 150, right: 64, bottom: 96, left: 64 } },
      body: { scale: 1 },
      headings: {
        h1: { scale: 1.9, lineHeight: 1.28, weight: 700 },
        h2: { scale: 1.34, lineHeight: 1.4, weight: 700 },
        h3: { scale: 1.12, lineHeight: 1.5, weight: 600 },
      },
      imageRadius: 16,
      labelFont: "body",
      board: null,
      cover: {
        title: { weight: 700, max: 120, min: 60, lineHeight: 1.2, maxLines: 3 },
        subtitle: { size: 32, weight: 400, lineHeight: 1.65, gap: 28, maxLines: 3, pin: null },
        align: "left",
        column: { left: 64, right: 64 },
        area: { top: 180, bottom: 1000, anchor: "top" },
        image: {
          mode: "plate",
          box: { below: true, gap: 56, bottom: 96, radius: 18, minHeight: 240 },
          area: { top: 180, bottom: 1000, anchor: "top" },
          lead: 0,
          titleMax: 96,
          subtitleLines: 2,
        },
      },
      end: {
        inset: 48,
        signature: { avatar: 96, name: { size: 32, weight: 600, font: "body", upper: false, spacing: 0 }, handle: { size: 24 } },
      },
    },
    journal: {
      name: "手帐",
      pages: { inner: { top: 156, right: 76, bottom: 100, left: 76 }, first: { top: 156, right: 76, bottom: 100, left: 76 } },
      body: { scale: 1 },
      headings: {
        h1: { scale: 1.76, lineHeight: 1.36, weight: 700 },
        h2: { scale: 1.28, lineHeight: 1.45, weight: 700 },
        h3: { scale: 1.1, lineHeight: 1.5, weight: 700 },
      },
      imageRadius: 6,
      labelFont: "body",
      board: null,
      cover: {
        title: { weight: 700, max: 116, min: 60, lineHeight: 1.3, maxLines: 3 },
        subtitle: { size: 32, weight: 400, lineHeight: 1.7, gap: 40, maxLines: 3, pin: null },
        align: "center",
        column: { left: 96, right: 96 },
        area: { top: 260, bottom: 920, anchor: "center" },
        image: {
          mode: "plate",
          box: { x: 150, y: 150, width: 564, height: 470, radius: 4 },
          area: { top: 696, bottom: 1040, anchor: "top" },
          lead: 0,
          titleMax: 88,
          subtitleLines: 2,
        },
      },
      end: {
        inset: 64,
        signature: { avatar: 96, name: { size: 32, weight: 700, font: "body", upper: false, spacing: 0 }, handle: { size: 24 } },
      },
    },
    poster: {
      name: "撞色",
      pages: { inner: { top: 160, right: 64, bottom: 88, left: 64 }, first: { top: 160, right: 64, bottom: 88, left: 64 } },
      body: { scale: 1 },
      headings: {
        h1: { scale: 2.1, lineHeight: 1.14, weight: 900 },
        h2: { scale: 1.2, lineHeight: 1.4, weight: 900 },
        h3: { scale: 1.06, lineHeight: 1.5, weight: 900 },
      },
      imageRadius: 0,
      labelFont: "sans",
      board: null,
      cover: {
        title: { weight: 400, max: 150, min: 88, lineHeight: 1.02, maxLines: 4 },
        subtitle: { size: 34, weight: 700, lineHeight: 1.5, gap: 36, maxLines: 2, pin: null },
        align: "left",
        column: { left: 64, right: 64 },
        area: { top: 176, bottom: 1060, anchor: "bottom" },
        image: {
          mode: "plate",
          box: { x: 64, y: 144, width: 736, height: 540, radius: 0 },
          area: { top: 720, bottom: 1070, anchor: "bottom" },
          lead: 0,
          titleMax: 124,
          subtitleLines: 2,
        },
      },
      end: {
        inset: 64,
        signature: { avatar: 104, name: { size: 40, weight: 700, font: "body", upper: false, spacing: 0 }, handle: { size: 26 } },
      },
    },
    glow: {
      name: "柔光",
      pages: { inner: { top: 150, right: 72, bottom: 100, left: 72 }, first: { top: 150, right: 72, bottom: 100, left: 72 } },
      body: { scale: 1 },
      headings: {
        h1: { scale: 1.8, lineHeight: 1.28, weight: 700 },
        h2: { scale: 1.3, lineHeight: 1.4, weight: 700 },
        h3: { scale: 1.1, lineHeight: 1.5, weight: 600 },
      },
      imageRadius: 24,
      labelFont: "body",
      board: null,
      cover: {
        title: { weight: 700, max: 120, min: 60, lineHeight: 1.2, maxLines: 3 },
        subtitle: { size: 32, weight: 400, lineHeight: 1.65, gap: 32, maxLines: 3, pin: null },
        align: "center",
        column: { left: 96, right: 96 },
        area: { top: 200, bottom: 960, anchor: "center" },
        image: {
          mode: "plate",
          box: { x: 72, y: 150, width: 720, height: 520, radius: 28 },
          area: { top: 710, bottom: 1040, anchor: "top" },
          lead: 0,
          titleMax: 96,
          subtitleLines: 2,
        },
      },
      end: {
        inset: 64,
        signature: { avatar: 96, name: { size: 32, weight: 600, font: "body", upper: false, spacing: 0 }, handle: { size: 24 } },
      },
    },
    fresh: {
      name: "清新",
      // 正文写在页面中央的圆角白卡片上（卡片是 structures.css 画的：离页边 40px，顶上留一条页眉带）；版心是卡片再往里收一圈
      pages: { inner: { top: 180, right: 88, bottom: 92, left: 88 }, first: { top: 180, right: 88, bottom: 92, left: 88 } },
      body: { scale: 1 },
      headings: {
        h1: { scale: 1.8, lineHeight: 1.3, weight: 700 },
        h2: { scale: 1.3, lineHeight: 1.42, weight: 700 },
        h3: { scale: 1.1, lineHeight: 1.5, weight: 700 },
      },
      imageRadius: 22,
      labelFont: "body",
      // 正文在白卡片上：颜色角色按底板算（src/engine/colors.js 的 roles：浅色配色的卡片是纯白，深色配色的比底色亮一点）
      board: true,
      cover: {
        title: { weight: 700, max: 116, min: 60, lineHeight: 1.3, maxLines: 3 },
        subtitle: { size: 32, weight: 400, lineHeight: 1.7, gap: 28, maxLines: 3, pin: null },
        align: "center",
        column: { left: 96, right: 96 },
        area: { top: 220, bottom: 940, anchor: "center" },
        image: {
          mode: "plate",
          // 照片是一张带白边的圆角小卡（白边 14px 是 structures.css 的 box-shadow，框要给它留出位置）
          box: { x: 132, y: 150, width: 600, height: 450, radius: 24 },
          area: { top: 680, bottom: 1040, anchor: "top" },
          lead: 0,
          titleMax: 88,
          subtitleLines: 2,
        },
      },
      end: {
        inset: 64,
        signature: { avatar: 96, name: { size: 32, weight: 600, font: "body", upper: false, spacing: 0 }, handle: { size: 24 } },
      },
    },
    // 电光：深色底上的粗黑标题（思源黑体 Black）、等宽的页眉与标签；版心对齐 48px 的网格（structures.css 画在底下），
    // 页眉条的下线在 120、正文从 168 起。封面标题靠左压底，底图是直角（4px）细框的相框
    neon: {
      name: "电光",
      pages: { inner: { top: 168, right: 72, bottom: 100, left: 72 }, first: { top: 168, right: 72, bottom: 100, left: 72 } },
      body: { scale: 1 },
      headings: {
        h1: { scale: 2, lineHeight: 1.12, weight: 900 },
        h2: { scale: 1.3, lineHeight: 1.3, weight: 800 },
        h3: { scale: 1.1, lineHeight: 1.45, weight: 800 },
      },
      imageRadius: 4,
      labelFont: "mono",
      board: null,
      cover: {
        title: { weight: 900, max: 128, min: 68, lineHeight: 1.08, maxLines: 4 },
        subtitle: { size: 30, weight: 500, lineHeight: 1.6, gap: 28, maxLines: 3, pin: null },
        align: "left",
        column: { left: 72, right: 72 },
        area: { top: 200, bottom: 1000, anchor: "bottom" },
        image: {
          mode: "plate",
          box: { x: 72, y: 168, width: 720, height: 500, radius: 4 },
          area: { top: 716, bottom: 1040, anchor: "top" },
          lead: 0,
          titleMax: 96,
          subtitleLines: 2,
        },
      },
      end: {
        inset: 72,
        signature: { avatar: 88, name: { size: 24, weight: 700, font: "label", upper: true, spacing: 4 }, handle: { size: 22 } },
      },
    },
  };

  const { deepFreeze } = root.MediaCraftEngine;
  const cardStructures = Object.freeze(Object.fromEntries(
    Object.entries(STRUCTURES).map(([id, structure]) => [id, deepFreeze({ ...structure, id })]),
  ));

  const engine = root.MediaCraftEngine || (root.MediaCraftEngine = {});
  engine.CARD_WIDTH = CARD_WIDTH;
  engine.CARD_HEIGHT = CARD_HEIGHT;
  engine.cardStructures = cardStructures;
})(globalThis);
