// HTML 卡片的页面框架（页眉、页脚、页面上的装饰）：每种卡片结构一套，照搬 src/engine/structures.js 的样子。
// 只拼 HTML；位置、字号在 src/cards/structures.css（[data-structure]）里。page：{ kind, index, total }，context：{ profile }。
(function (root) {
  "use strict";

  const escape = (text) => root.MediaCraftCardHtml.escape(text);
  const pad2 = (value) => String(value).padStart(2, "0");
  const pageOf = (page) => `${page.index + 1}/${page.total}`;
  const counter = (page) => `${pad2(page.index + 1)} / ${pad2(page.total)}`;
  // 电光的页码挤在胶囊里：01/08
  const slashed = (page) => `${pad2(page.index + 1)}/${pad2(page.total)}`;
  // 第一页（署名页）：没开封面时是第一张正文，开了封面是封面
  const first = (page) => page.index === 0 && page.kind !== "end";

  const avatar = (context, className = "mc-avatar") => (context.profile.avatar
    ? `<img class="${className}" alt="" data-media="__avatar">`
    : `<span class="${className} is-empty"></span>`);
  const name = (context) => escape(context.profile.name);
  // 还没填署名（名字空着）
  const unnamed = (context) => !String(context.profile.name ?? "").trim();
  // 纯白、纯黑：页眉一行署名与页码，下面一条线
  const minimalHead = (page, context) => `<div class="mc-plain-head">${first(page) ? avatar(context) : ""}<span class="mc-sign">${upper(context)}</span>`
    + `<span class="mc-count">${counter(page)}</span></div>`;
  const upper = (context) => escape(String(context.profile.name).toUpperCase());
  // 清新：左上的软胶囊（第一页带头像）；名字空着时第一页的胶囊里只放头像，之后的页不画胶囊
  const freshTag = (page, context) => (unnamed(context)
    ? (first(page) ? `<span class="mc-fresh-tag is-avatar-only">${avatar(context)}</span>` : "")
    : `<span class="mc-fresh-tag">${first(page) ? avatar(context) : ""}${name(context)}</span>`);

  // 每种结构：head / foot 返回 HTML（空串表示没有），deco 是压在正文下面的装饰层
  const CHROME = {
    clay: {
      head: (page, context) => `<div class="mc-clay-head">${first(page) ? avatar(context) : `<span class="mc-clay-dot"></span>`}`
        + `<span class="mc-sign">${name(context)}</span><span class="mc-count">${counter(page)}</span></div>`,
      foot: () => "",
    },
    plain: {
      head: (page, context) => minimalHead(page, context),
      foot: () => "",
    },
    ink: {
      head: (page, context) => minimalHead(page, context),
      foot: () => "",
    },
    editorial: {
      head: (page, context) => `<div class="mc-ed-head"><span class="mc-ed-rule"></span><span class="mc-sign">${upper(context)}</span><span class="mc-ed-rule"></span></div>`,
      foot: (page) => (page.kind === "cover" ? "" : `<span class="mc-folio">${pad2(page.index + 1)}</span>`),
    },
    notes: {
      // 名字空着时：第一页的小签只放头像，之后的页不画小签
      head: (page, context) => {
        const tag = unnamed(context)
          ? (first(page) ? `<span class="mc-notes-tag is-avatar-only">${avatar(context)}</span>` : "")
          : `<span class="mc-notes-tag">${first(page) ? avatar(context) : ""}${name(context)}</span>`;
        return `<div class="mc-notes-head">${tag}<span class="mc-count">${pageOf(page)}</span></div>`;
      },
      foot: () => "",
    },
    journal: {
      head: (page, context) => {
        const label = first(page) ? name(context) : [name(context), pad2(page.index + 1)].filter(Boolean).join(" · ");
        return `<span class="mc-tape">${first(page) ? avatar(context) : ""}${label}</span>`;
      },
      foot: () => "",
    },
    poster: {
      head: (page, context) => `<div class="mc-poster-band">${first(page) ? avatar(context) : ""}<span class="mc-sign">${upper(context)}</span>`
        + `<span class="mc-count">${counter(page)}</span></div>`,
      foot: () => "",
    },
    glow: {
      head: (page, context) => `<div class="mc-glow-head">${first(page) ? avatar(context) : ""}<span class="mc-sign">${name(context)}</span>`
        + `<span class="mc-count">${counter(page)}</span></div>`,
      foot: () => "",
    },
    fresh: {
      // 胶囊在左，右边是「1 / 8」式的页码；封面只有胶囊，不标页码
      head: (page, context) => `<div class="mc-fresh-head">${freshTag(page, context)}<span class="mc-count">${page.index + 1} / ${page.total}</span></div>`,
      foot: () => "",
      cover: {
        head: (page, context) => `<div class="mc-fresh-head">${freshTag(page, context)}</div>`,
        foot: () => "",
      },
    },
    // 电光：终端似的一条——第一页是头像、内页是一个强调色的光标块，大写等宽的名字，右边胶囊里的页码
    neon: {
      head: (page, context) => `<div class="mc-neon-head">${first(page) ? avatar(context) : `<span class="mc-neon-cursor"></span>`}`
        + `<span class="mc-sign">${upper(context)}</span><span class="mc-count">${slashed(page)}</span></div>`,
      foot: () => "",
    },
    scroll: {
      // 报头：名字居中（第一页带头像），下面一条双线；页码在页脚正中「第 2 页 / 共 8 页」（封面不标）
      head: (page, context) => `<div class="mc-scroll-head"><span class="mc-scroll-sign">${first(page) ? avatar(context) : ""}`
        + `<span class="mc-sign">${name(context)}</span></span><span class="mc-scroll-rule"></span></div>`,
      foot: (page) => (page.kind === "cover" ? "" : `<span class="mc-folio">第 ${page.index + 1} 页 / 共 ${page.total} 页</span>`),
    },
  };

  // 封面这一页用结构另写的 cover（有的话），否则和第一页一样
  function chromeOf(structure) {
    const chrome = CHROME[structure] ?? CHROME.notes;
    return {
      head: (page, context) => (page.kind === "cover" && chrome.cover ? chrome.cover.head : chrome.head)(page, context),
      foot: (page, context) => (page.kind === "cover" && chrome.cover ? chrome.cover.foot : chrome.foot)(page, context),
    };
  }

  // 结尾页最后的署名：一段强调色短线、大头像、名字与账号（样子按卡片结构的 end.signature，变量在 cards.js）。
  // 放在正文区里、排在内容后面（CSS order），带 data-chrome：分页量高度时算进去，不算内容
  const signature = (context) => `<div class="mc-signature" data-chrome aria-label="署名"><span class="mc-sig-rule"></span>`
    + `${avatar(context, "mc-avatar mc-sig-avatar")}${unnamed(context) ? "" : `<span class="mc-sig-name">${name(context)}</span>`}`
    + `${context.profile.handle ? `<span class="mc-sig-handle">${escape(context.profile.handle)}</span>` : ""}</div>`;

  root.MediaCraftCardChrome = { of: chromeOf, signature, structures: Object.keys(CHROME) };
})(globalThis);
