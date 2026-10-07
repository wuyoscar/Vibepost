// 排版自检：出图之后每一页有什么问题，给 Agent 的 get_pages（App API 的 render.pages() 每页带 issues）和发布检查用，跟模型无关。
// - headingOnly：这一页只有标题（没有正文、图片、列表……）
// - sparse：正文只占正文区不到四分之一（封面、结尾页与最后一页不算；只有一页正文时也不算）
// - dense：字太多（一张 180–280 字最好读，超过 300 字偏挤）
// - overflow：有一块放不下又拆不开，超出了正文区
// 判断的门槛与胶片上「偏空 / 偏挤」的提示一样（src/shell.js）。
(function (root) {
  "use strict";

  const SPARSE_FILL = 0.25;
  const DENSE_CHARS = 300;
  const HEADINGS = new Set(["h1", "h2", "h3"]);

  // pages：App API 的页面摘要（role、fill、chars、overflow、items）。返回每页的问题：[[{ id, text }]]
  function issues(pages) {
    const bodyPages = pages.filter((page) => page.role === "body").length;
    const lastBody = pages.map((page) => page.role).lastIndexOf("body");
    return pages.map((page, index) => {
      if (page.role === "cover") return [];
      const found = [];
      const items = page.items ?? [];
      if (page.role === "body" && items.length && items.every((item) => item.kind === "text" && HEADINGS.has(item.blockType))) {
        found.push({ id: "headingOnly", text: "只有标题：标题会带着后面第一段一起换页，这一页只剩标题多半是后面紧跟着 [[分页]] 或一块放不下的大内容" });
      } else if (page.role === "body" && bodyPages > 1 && index !== lastBody && (page.fill ?? 1) < SPARSE_FILL) {
        found.push({ id: "sparse", text: `太空：正文只占正文区的 ${Math.round((page.fill ?? 0) * 100)}%（不到四分之一），可以和上一页或下一页并成一页` });
      }
      if (page.role === "body" && (page.chars ?? 0) > DENSE_CHARS) {
        found.push({ id: "dense", text: `偏挤：${page.chars} 字（一张 180–280 字最好读），可以删几句或拆成两页` });
      }
      if (page.overflow) found.push({ id: "overflow", text: "溢出：有一块放不下又拆不开，超出了正文区，收紧文字、缩小图片或拆开它" });
      return found;
    });
  }

  root.MediaCraftLayoutCheck = { issues, SPARSE_FILL, DENSE_CHARS };
})(globalThis);
