// HTML 卡片分页（ADR 0006）：在屏幕外一张和卡片一模一样的「量尺卡」里一块一块放，放不下就拆，由 WebKit 自己排版、自己量。
// 拆开的后半截留着原来那一块的 data-src（原文位置），标上 data-continued。
// 段落与等宽、代码按行拆（Range 找出最后一行放得下的位置，extractContents 把切到一半的标签补成两截），
// 列表按项、表格按行拆（下一页接着编号、重复表头）；标题不留在页底；图片放得下就缩小，不然挪到下一页。
(function (root) {
  "use strict";

  const EPSILON = 0.5;
  const SLICE_MS = 24; // 连着排这么久就让出主线程一次（打字、别的动画不卡）

  // 让出主线程：MessageChannel 比 setTimeout(0) 快，也不受后台窗口的定时器节流
  const yieldToPage = () => new Promise((resolve) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = () => resolve();
    channel.port2.postMessage(null);
  });
  const MIN_IMAGE_SHARE = 0.35; // 剩下的高度不到正文区的这么多，图片就挪到下一页，不硬塞
  const MIN_IMAGE_HEIGHT = 160;

  const overflows = (body) => body.scrollHeight > body.clientHeight + EPSILON;
  const bottomOf = (body) => body.getBoundingClientRect().top + body.clientHeight;

  function fromHtml(html) {
    const template = document.createElement("template");
    template.innerHTML = html;
    return template.content.firstElementChild;
  }

  // 第 index 个字（跨文字节点数）的位置：[文字节点, 节点里的下标]
  function textPoints(element) {
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    const nodes = [];
    let total = 0;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      nodes.push({ node, start: total });
      total += node.data.length;
    }
    const at = (index) => {
      let lo = 0;
      let hi = nodes.length - 1;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (nodes[mid].start <= index) lo = mid;
        else hi = mid - 1;
      }
      const entry = nodes[lo];
      return [entry.node, Math.min(index - entry.start, entry.node.data.length)];
    };
    return { total, at };
  }

  // 第 index 个字所在那一行的底边：字形的框再往下补半个行距（CSS 的半行距），就是行框的底边
  function charBottom(points, index) {
    const [node, offset] = points.at(index);
    if (offset >= node.data.length) return -Infinity;
    const range = document.createRange();
    range.setStart(node, offset);
    range.setEnd(node, offset + 1);
    const rects = range.getClientRects();
    if (!rects.length) return -Infinity;
    const rect = rects[rects.length - 1];
    const leading = parseFloat(getComputedStyle(node.parentElement).lineHeight);
    return rect.bottom + (Number.isFinite(leading) ? Math.max(0, (leading - rect.height) / 2) : 0);
  }

  // 把一块文字从能放下的最后一整行之后切开：切下来的后半截返回，前半截留在原处；一行都放不下时返回 null
  function splitText(element, limit) {
    const points = textPoints(element);
    if (points.total < 2) return null;
    // 二分找第一个底边越过 limit 的字
    let lo = 0;
    let hi = points.total - 1;
    if (charBottom(points, hi) <= limit + EPSILON) return null;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (charBottom(points, mid) > limit + EPSILON) hi = mid;
      else lo = mid + 1;
    }
    let cut = lo;
    if (cut === 0) return null;
    // 退到这一行的行首：和第一个越界的字同一行（底边相同）的都挪下去
    const lineBottom = charBottom(points, cut);
    while (cut > 0 && Math.abs(charBottom(points, cut - 1) - lineBottom) < 1) cut -= 1;
    if (cut === 0) return null;
    const [node, offset] = points.at(cut);
    const range = document.createRange();
    // 切在一个标签的开头时从这个标签之前切：不在前半截留下空标签（比如代码块的一行、加粗的一段）
    let start = node;
    while (offset === 0 && start.parentNode !== element && start.parentNode.firstChild === start) start = start.parentNode;
    if (offset === 0) range.setStartBefore(start);
    else range.setStart(node, offset);
    range.setEndAfter(element.lastChild);
    const rest = element.cloneNode(false);
    rest.append(range.extractContents());
    trimLeadingBreaks(rest);
    rest.dataset.continued = "true";
    // 从一行中间断开的（不是原文一行的开头）：合回去时不在中间加换行
    if (offset !== 0) rest.dataset.midLine = "true";
    return rest;
  }

  function trimLeadingBreaks(element) {
    while (element.firstChild && (element.firstChild.nodeName === "BR" || (element.firstChild.nodeType === 3 && !element.firstChild.data.trim()))) {
      element.firstChild.remove();
    }
  }

  // 列表、表格：把放不下的项（行）挪到一个同样的空壳里。minEach：拆开时两边各至少留几项（列表 2，免得页底或下一页开头孤零零一条）
  function splitChildren(element, body, rowsOf, shellOf, minEach = 1) {
    const rows = rowsOf(element);
    const limit = bottomOf(body);
    const firstOut = rows.findIndex((row) => row.getBoundingClientRect().bottom > limit + EPSILON);
    if (firstOut <= 0) return null;
    if (firstOut < minEach || rows.length - firstOut < minEach) return null;
    const rest = shellOf(element, firstOut);
    for (const row of rows.slice(firstOut)) rest.target.append(row);
    return rest.element;
  }

  function splitList(element, body) {
    return splitChildren(element, body, (list) => [...list.children], (list, firstOut) => {
      const shell = list.cloneNode(false);
      shell.dataset.continued = "true";
      if (list.tagName === "OL") shell.setAttribute("start", String(Number(list.getAttribute("start") || 1) + firstOut));
      return { element: shell, target: shell };
    }, 2);
  }

  function splitTable(element, body) {
    return splitChildren(element, body, (table) => [...table.tBodies[0].rows], (table) => {
      const shell = table.cloneNode(false);
      shell.dataset.continued = "true";
      shell.append(table.tHead.cloneNode(true));
      const tbody = document.createElement("tbody");
      shell.append(tbody);
      return { element: shell, target: tbody };
    });
  }

  // 容器（等宽、提示框……）：先按里面的段落拆，最后一段再按行拆
  function splitContainer(element, body) {
    const limit = bottomOf(body);
    const parts = [...element.children];
    const firstOut = parts.findIndex((part) => part.getBoundingClientRect().bottom > limit + EPSILON);
    if (firstOut < 0) return null;
    const shell = element.cloneNode(false);
    shell.dataset.continued = "true";
    const partial = splitAny(parts[firstOut], body);
    if (partial) shell.append(partial);
    else if (firstOut === 0) return null;
    for (const part of parts.slice(firstOut + (partial ? 1 : 0))) shell.append(part);
    return shell.childElementCount ? shell : null;
  }

  function splitAny(element, body) {
    const tag = element.tagName;
    if (tag === "P" || tag === "PRE" || tag === "BLOCKQUOTE" || /^H[1-3]$/.test(tag)) return splitText(element, bottomOf(body));
    if (tag === "UL" || tag === "OL") return splitList(element, body);
    if (tag === "TABLE") return splitTable(element, body);
    if (tag === "FIGURE") return null;
    if (element.children.length) return splitContainer(element, body);
    return splitText(element, bottomOf(body));
  }

  // 图片放不下：剩下的高度还够就按比例缩小，否则交给下一页
  function shrinkImage(element, body) {
    if (element.tagName !== "FIGURE") return false;
    const room = bottomOf(body) - element.getBoundingClientRect().top;
    if (room < Math.max(MIN_IMAGE_HEIGHT, body.clientHeight * MIN_IMAGE_SHARE)) return false;
    const images = [...element.querySelectorAll(".mc-img")];
    const tallest = Math.max(...images.map((image) => image.getBoundingClientRect().height));
    const scale = Math.max(0.2, (room - (element.getBoundingClientRect().height - tallest) - 2) / tallest);
    element.style.setProperty("--mc-fig-scale", String(Math.min(1, scale)));
    element.dataset.shrunk = "true";
    return !overflows(body);
  }

  // measurer：{ page(kind, index) → { body }（换上第 index 页、那种页的页眉页脚，清空正文区） }。blocks：MediaCraftCardHtml.blocks 的结果。
  // 正文区里带 data-chrome 的是页面框架放进去的（结尾页的署名）：量高度时算进去，不算内容、不进结果。
  // 得到 [{ kind: "body" | "end", html: 正文区的 HTML, sources: [[开头, 结尾]…] }]
  // offset：前面已经有几页（封面），正文从第 offset 页起（页眉页脚、版心按那一页排）
  async function paginate(blocks, measurer, { offset = 0 } = {}) {
    const pages = [];
    let kind = "body";
    let body = null;
    let forced = false; // 刚遇到分页符：下一块另起一页，哪怕这一页还空着

    const blocksIn = () => [...body.children].filter((child) => !child.hasAttribute("data-chrome"));
    const openPage = () => {
      if (body) {
        const own = blocksIn();
        pages.push({
          kind: body.dataset.kind, html: own.map((child) => child.outerHTML).join(""), sources: own.map((child) => child.dataset.src).filter(Boolean),
          forced: body.dataset.forced === "true",
        });
      }
      body = measurer.page(kind, pages.length + offset).body;
      body.dataset.kind = kind;
      forced = false;
    };
    openPage();

    const hasLive = (element) => Boolean(element.querySelector?.(".mc-img.is-live"));

    // 页底连着的标题不留在这一页：换页时一起带过去（这一页至少留下一块别的）
    const nextPageWithHeadings = () => {
      const carried = [];
      while (blocksIn().length > 1 && /^H[1-3]$/.test(blocksIn().at(-1).tagName)) {
        const heading = blocksIn().at(-1);
        carried.unshift(heading);
        heading.remove();
      }
      openPage();
      body.append(...carried);
    };

    const place = (element) => {
      // 分割线落在卡片顶上（自然换页、[[分页]] 之后）时不画
      if (element.tagName === "HR" && !blocksIn().length) return;
      // 一页最多一段实况（导出时一页合成一段）：这页已经有了就换页，紧挨着的标题一起走
      if (hasLive(element) && [...body.children].some(hasLive)) nextPageWithHeadings();
      body.append(element);
      if (!overflows(body)) return;
      if (shrinkImage(element, body)) return;
      const rest = splitAny(element, body);
      if (rest) {
        openPage();
        place(rest);
        return;
      }
      if (blocksIn().length === 1) return; // 一整页都放不下：只好留在这一页（被裁掉），免得死循环
      element.remove();
      nextPageWithHeadings();
      place(element);
    };

    let sliceStart = performance.now();
    for (const block of blocks) {
      if (performance.now() - sliceStart > SLICE_MS) {
        await yieldToPage();
        sliceStart = performance.now();
      }
      if (block.type === "pageBreak") {
        if (blocksIn().length) openPage();
        forced = true;
        body.dataset.forced = "true";
        continue;
      }
      if (block.type === "endPage") {
        if (kind === "end") continue; // 只认第一个 [[结尾]]
        kind = "end";
        if (blocksIn().length || forced) openPage();
        else {
          body = measurer.page(kind, pages.length + offset).body;
          body.dataset.kind = kind;
        }
        continue;
      }
      const element = fromHtml(block.html);
      if (element) place(element);
    }
    if (blocksIn().length || !pages.length || body.dataset.kind === "end") openPage();
    backfill(pages, measurer, offset);
    return pages.map(({ forced: _, ...page }) => page);
  }

  // ===== 末页回填 =====
  // 最后一张正文卡太空（不到 BACKFILL_RATIO）时从前一张往后挪：先整块挪（标题跟着后面那块走），挪不动再把最后一段按原文行挪；
  // 两张都要至少 BACKFILL_RATIO、末页不溢出才算数。[[分页]] 换出来的末页不动（作者要它单独一张）。
  const BACKFILL_RATIO = 0.25;

  function fillOf(body) {
    const own = [...body.children].filter((child) => !child.hasAttribute("data-chrome"));
    if (!own.length) return 0;
    const top = body.getBoundingClientRect().top;
    const bottom = Math.max(...own.map((child) => child.getBoundingClientRect().bottom));
    return (bottom - top) / (body.clientHeight || 1);
  }

  const elementsOf = (html) => {
    const template = document.createElement("template");
    template.innerHTML = html;
    return [...template.content.children];
  };

  // 把一页的块放进量尺卡，量填满多少、溢出没有
  function trial(measurer, kind, index, elements) {
    // index 是整套卡片里的页序（含封面）
    const body = measurer.page(kind, index).body;
    body.append(...elements.map((element) => element.cloneNode(true)));
    return { fill: fillOf(body), overflow: overflows(body) };
  }

  // 前一页最后一块拆开时，末页开头是它的后半截（data-continued）：挪下来的前半截与它合回一块
  function joined(moved, rest) {
    const [first, ...others] = rest;
    const tail = moved.at(-1);
    if (!first?.dataset.continued || !tail || tail.tagName !== first.tagName) return [...moved, ...rest];
    const merged = tail.cloneNode(true);
    if (merged.tagName === "P" || merged.tagName === "BLOCKQUOTE") {
      // 在原文一行的开头断开的，两半之间补上换行（断开时行末的换行留在了前半截的就不用补）
      if (!first.dataset.midLine && merged.lastChild?.nodeName !== "BR") merged.append(document.createElement("br"));
      merged.append(...first.cloneNode(true).childNodes);
    } else if (merged.tagName === "PRE") {
      merged.append(...first.cloneNode(true).childNodes);
    } else {
      merged.append(...first.cloneNode(true).children);
    }
    delete merged.dataset.midLine;
    delete merged.dataset.continued;
    if (tail.dataset.continued) merged.dataset.continued = "true";
    return [...moved.slice(0, -1), merged, ...others];
  }

  function backfill(pages, measurer, offset) {
    if (pages.length < 2) return;
    const lastIndex = pages.length - 1;
    const at = (index) => index + offset; // 量尺卡按整套里的页序排
    const [previous, last] = pages.slice(-2);
    if (last.forced || previous.kind !== "body" || last.kind !== "body") return;
    const kept = elementsOf(previous.html);
    const tail = elementsOf(last.html);
    if (trial(measurer, "body", at(lastIndex), tail).fill >= BACKFILL_RATIO) return;
    const accept = (keep, move) => {
      const before = trial(measurer, "body", at(lastIndex - 1), keep);
      if (before.fill < BACKFILL_RATIO || /^H[1-3]$/.test(keep.at(-1)?.tagName ?? "")) return false;
      const after = trial(measurer, "body", at(lastIndex), move);
      if (after.overflow || after.fill < BACKFILL_RATIO) return false;
      pages[lastIndex - 1] = { ...previous, html: keep.map((element) => element.outerHTML).join(""), sources: sourcesOf(keep) };
      pages[lastIndex] = { ...last, html: move.map((element) => element.outerHTML).join(""), sources: sourcesOf(move) };
      return true;
    };
    // 整块
    for (let count = 1; count < kept.length; count += 1) {
      if (accept(kept.slice(0, -count), joined(kept.slice(-count), tail))) return;
    }
    // 最后一段按原文行（每行一个 span.mc-line）
    const paragraph = kept.at(-1);
    const lines = paragraph?.tagName === "P" ? [...paragraph.querySelectorAll(":scope > .mc-line")] : [];
    for (let count = 1; count < lines.length; count += 1) {
      const head = paragraph.cloneNode(false);
      const rest = paragraph.cloneNode(false);
      const cut = lines.length - count;
      head.innerHTML = lines.slice(0, cut).map((line) => line.outerHTML).join("<br>");
      rest.innerHTML = lines.slice(cut).map((line) => line.outerHTML).join("<br>");
      rest.dataset.continued = "true";
      if (accept([...kept.slice(0, -1), head], joined([rest], tail))) return;
    }
  }

  const sourcesOf = (elements) => elements.map((element) => element.dataset.src).filter(Boolean);

  root.MediaCraftCardPaginate = { paginate, yieldToPage };
})(globalThis);
