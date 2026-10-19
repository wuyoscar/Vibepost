// 舞台上 HTML 卡片的「块」（ADR 0006 的直接编排）：点选一块（段落、标题、列表、组件、表格……）出小工具条——上移、下移、
// 换样式、让 AI 改、删除；拖到两块之间换位置；双击或回车跳到编辑器里的原文。图片、实况另有图片层（src/media/stage-images.js），
// 压在这一层上面。自己不改稿子：每个动作交给 actions，由它算出新的原文（src/cards/blocks.js）一次写进编辑器，可以 ⌘Z。
// actions：{ readOnly(), text(), apply(nextText), reveal(source), ask(source), annotate(block) }
(() => {
  const CARD_WIDTH = 864;
  const vertical = (value) => `calc(${value} / var(--card-height, 1152) * 100%)`;
  const DRAG_THRESHOLD = 4;
  const ops = () => window.MediaCraftCardBlocks;
  const percent = (value, total) => `${(value / total) * 100}%`;

  const KIND_LABEL = { heading: "标题", paragraph: "段落", list: "列表", quote: "引用", code: "代码块", table: "表格", rule: "分割线", component: "组件" };
  // 样式的名字、说明与分组都在操作手册（src/engine/manual.js），和编辑器左上角的「样式」是同一份
  const manual = () => window.MediaCraftManual;

  const labelOf = (block) => (block.kind === "component" ? manual().component(block.name)?.name ?? block.name : KIND_LABEL[block.kind] ?? "内容");

  // 这一块现在是哪种样式（操作手册里的 id，与 src/cards/blocks.js 的 setStyle 同一套）
  function styleOf(block) {
    if (block.kind === "heading") return `h${block.level}`;
    if (block.kind === "paragraph") return "p";
    if (block.kind === "quote") return "quote";
    if (block.kind === "list") return block.ordered ? "ol" : "ul";
    if (block.kind === "component") return manual().component(block.name)?.id ?? null;
    return null;
  }

  // 换样式菜单：段落类的块在段落类里互换，列表类的在列表类里（也能拆回正文）
  function familyOf(current) {
    const { styles } = manual();
    const family = manual().style(current)?.family ?? "text";
    return family === "list" ? [...styles.filter((style) => style.family === "list"), manual().style("p")] : styles.filter((style) => style.family === "text");
  }

  // 这一块能换成的样式：[{ label, title, run(text) → 新原文 | null, current, group? }]；代码块、表格、分割线、认不出的组件没有
  function stylesOf(block) {
    const { setStyle, setAttr } = ops();
    const current = styleOf(block);
    if (!current) return [];
    const styles = familyOf(current).map((style) => ({
      label: style.name, title: style.summary, current: style.id === current, run: (text) => setStyle(text, block.source, style.id),
    }));
    if (block.kind !== "component") return styles;
    const aligns = manual().aligns.map((align) => ({
      label: align.name, group: "align", current: (block.align ?? "left") === align.id,
      run: (text) => setAttr(text, block.source, "align", align.id === "left" ? null : align.id),
    }));
    return [...styles, ...aligns];
  }

  function iconButton(label, icon, run) {
    const control = document.createElement("button");
    control.type = "button";
    control.title = label;
    control.setAttribute("aria-label", label);
    control.innerHTML = `<svg class="icon icon-small" aria-hidden="true"><use href="#${icon}" /></svg>`;
    control.addEventListener("click", (event) => {
      event.stopPropagation();
      run(control);
    });
    return control;
  }

  function create({ viewport, pagesRoot, actions }) {
    let pages = []; // { frame, page, index, layer, entries: [{ block, box }] }
    let selected = null; // { start, chunk }：选中那一块的原文开头与原文（出图后按原文找回来）
    let pending = null; // 下一次出图后选中哪一块：{ chunk }（挪动后按原文找）或 { start }（换样式、改级别后起点不变）

    const sameBlock = (entry, key) => entry.block.source[0] === key.start;

    function attach(frame, page, index) {
      if (!page?.blocks?.length) return;
      const layer = document.createElement("div");
      layer.className = "stage-block-layer";
      const entry = { frame, page, index, layer, entries: [] };
      for (const block of page.blocks) {
        const box = document.createElement("div");
        box.className = "stage-block";
        box.tabIndex = 0;
        box.setAttribute("role", "button");
        box.setAttribute("aria-label", `选择${labelOf(block)}`);
        Object.assign(box.style, {
          left: percent(block.x, CARD_WIDTH), top: vertical(block.y),
          width: percent(block.width, CARD_WIDTH), height: vertical(block.height),
        });
        box.addEventListener("pointerdown", (event) => startDrag(event, entry, block, box));
        box.addEventListener("dblclick", () => actions.reveal(block.source));
        box.addEventListener("keydown", (event) => handleKey(event, block));
        box.addEventListener("focus", () => {
          if (!isSelected(block)) select(block);
        });
        layer.append(box);
        entry.entries.push({ block, box });
      }
      // 放在图片层下面：图片的点选、拖动优先
      frame.querySelector(".stage-media-layer")?.before(layer) ?? frame.append(layer);
      pages = [...pages.filter((item) => item.index !== index), entry].sort((a, b) => a.index - b.index);
      paint();
    }

    const isSelected = (block) => selected?.start === block.source[0];

    // 出图换掉了页面：丢掉旧页；刚挪过、换过样式的块按原文找回来选中
    function sync() {
      pages = pages.filter((entry) => entry.frame.isConnected);
      if (pending) {
        const text = actions.text();
        const all = pages.flatMap((entry) => entry.entries);
        const found = pending.chunk !== undefined
          ? all.find(({ block }) => chunkOf(block, text).trim() === pending.chunk.trim())
          : all.find(({ block }) => ops().span(text, block.source).from === pending.start);
        selected = found ? { start: found.block.source[0] } : null;
        pending = null;
        paint();
        found?.box.focus({ preventScroll: true });
        return;
      }
      if (selected && !pages.some((entry) => entry.entries.some((item) => sameBlock(item, selected)))) selected = null;
      paint();
    }

    function select(block) {
      selected = block ? { start: block.source[0] } : null;
      paint({ appear: true });
    }

    function clear() {
      if (!selected) return;
      selected = null;
      paint();
    }

    // 选中的块：描边（跨页的一块两页都描）与第一处上方的小工具条
    function paint({ appear = false } = {}) {
      let barShown = false;
      for (const entry of pages) {
        entry.layer.querySelector(".stage-block-bar")?.remove();
        for (const { block, box } of entry.entries) {
          const on = Boolean(selected) && sameBlock({ block }, selected);
          box.classList.toggle("is-selected", on);
          box.setAttribute("aria-pressed", String(on));
          if (on && !barShown && !actions.readOnly()) {
            entry.layer.append(toolbar(block, appear));
            barShown = true;
          }
        }
      }
    }

    // 算出新的原文交给 actions；next 为 null（没变化、挪不动）时什么也不做。then：出图后选中哪一块（见 pending）
    function commit(next, then = null) {
      if (next === null || next === undefined || actions.readOnly()) return false;
      pending = then;
      actions.apply(next);
      return true;
    }

    // 一块占的整行原文
    function chunkOf(block, text = actions.text()) {
      const { from, to } = ops().span(text, block.source);
      return text.slice(from, to);
    }

    function shiftBlock(block, direction) {
      commit(ops().shift(actions.text(), block.source, direction), { chunk: chunkOf(block) });
    }

    function removeBlock(block) {
      selected = null;
      commit(ops().remove(actions.text(), block.source));
    }

    function toolbar(block, appear) {
      const bar = document.createElement("div");
      bar.className = `stage-media-bar stage-block-bar${appear ? " is-appearing" : ""}`;
      bar.setAttribute("role", "toolbar");
      bar.setAttribute("aria-label", `${labelOf(block)}操作`);
      bar.addEventListener("pointerdown", (event) => event.stopPropagation());
      const styles = stylesOf(block);
      bar.append(
        iconButton("上移", "i-chevron-up", () => shiftBlock(block, -1)),
        iconButton("下移", "i-chevron-down", () => shiftBlock(block, 1)),
        ...(styles.length ? [iconButton("换样式", "i-palette", (control) => toggleMenu(bar, control, block, styles))] : []),
        iconButton("批注", "i-comment", () => actions.annotate(block)),
        iconButton("让 AI 改这一块", "i-sparkle", () => actions.ask(block.source)),
        iconButton(`删除这${block.kind === "component" ? "个组件" : "一块"}`, "i-trash", () => removeBlock(block)),
      );
      const { x, y, width, height } = block;
      bar.classList.toggle("is-below", y < 64);
      bar.style.left = percent(x + width / 2, CARD_WIDTH);
      bar.style.top = vertical(y < 64 ? y + height : y);
      return bar;
    }

    // 换样式的小菜单：挂在工具条下面
    function toggleMenu(bar, control, block, styles) {
      const open = bar.querySelector(".stage-block-menu");
      if (open) {
        open.remove();
        control.setAttribute("aria-expanded", "false");
        return;
      }
      const menu = document.createElement("div");
      menu.className = "stage-block-menu";
      menu.setAttribute("role", "menu");
      for (const [index, style] of styles.entries()) {
        // 对齐那几项与样式隔开
        if (style.group === "align" && styles[index - 1]?.group !== "align") menu.append(Object.assign(document.createElement("hr"), { className: "stage-block-menu-rule" }));
        const item = document.createElement("button");
        item.type = "button";
        item.className = "stage-block-menu-item";
        item.setAttribute("role", "menuitemradio");
        item.setAttribute("aria-checked", String(Boolean(style.current)));
        item.textContent = style.label;
        if (style.title) item.title = style.title;
        item.addEventListener("click", (event) => {
          event.stopPropagation();
          const text = actions.text();
          const next = style.run(text);
          if (next === null) {
            menu.remove();
            return;
          }
          // 换样式、改级别、对齐都不挪位置：出图后选中从同一行开头的那一块
          commit(next, { start: ops().span(text, block.source).from });
        });
        menu.append(item);
      }
      bar.append(menu);
      control.setAttribute("aria-expanded", "true");
      menu.querySelector("[aria-checked='true']")?.focus() ?? menu.firstElementChild?.focus();
    }

    function handleKey(event, block) {
      if (event.target !== event.currentTarget) return;
      if (event.key === "Enter") {
        event.preventDefault();
        actions.reveal(block.source);
      } else if (event.key === "Escape") {
        event.preventDefault();
        clear();
        event.currentTarget.blur();
      } else if (event.altKey && (event.key === "ArrowUp" || event.key === "ArrowDown")) {
        event.preventDefault();
        shiftBlock(block, event.key === "ArrowUp" ? -1 : 1);
      } else if ((event.key === "Delete" || event.key === "Backspace") && !actions.readOnly()) {
        event.preventDefault();
        event.stopPropagation();
        removeBlock(block);
      }
    }

    // ===== 拖动换位置 =====

    // 指针下的那一页（不在任何一页上时取上下最近的一页）与卡片上的 y
    function locate(clientX, clientY) {
      let best = null;
      for (const entry of pages) {
        const rect = entry.frame.getBoundingClientRect();
        const distance = Math.max(rect.top - clientY, clientY - rect.bottom, 0);
        if (!best || distance < best.distance) best = { entry, rect, distance };
      }
      if (!best) return null;
      const height = best.entry.page.height ?? 1152;
      return { entry: best.entry, y: Math.min(height, Math.max(0, ((clientY - best.rect.top) / best.rect.height) * height)) };
    }

    // 落在哪两块之间：离指针最近的一块的上半截算它之前，下半截算它之后
    function dropAt(spot, dragged) {
      const candidates = spot?.entry.page.blocks.filter((block) => block.source[0] !== dragged.source[0]) ?? [];
      let best = null;
      for (const block of candidates) {
        const middle = block.y + block.height / 2;
        const distance = Math.abs(spot.y - middle);
        if (!best || distance < best.distance) best = { block, after: spot.y > middle, distance, entry: spot.entry };
      }
      return best;
    }

    let line = null;
    function showLine(drop) {
      line?.remove();
      line = null;
      if (!drop) return;
      const { block, after, entry } = drop;
      line = document.createElement("div");
      line.className = "stage-drop-line";
      line.setAttribute("aria-hidden", "true");
      const { bounds } = entry.page;
      line.style.left = percent(bounds.left, CARD_WIDTH);
      line.style.width = percent(bounds.right - bounds.left, CARD_WIDTH);
      line.style.top = vertical(after ? block.y + block.height : block.y);
      entry.layer.append(line);
    }

    function startDrag(event, entry, block, box) {
      if (event.button !== 0) return;
      const start = { x: event.clientX, y: event.clientY };
      let dragging = false;
      let drop = null;
      try {
        box.setPointerCapture(event.pointerId);
      } catch {
        // 合成的指针事件（测试、辅助功能）没有真的指针可以捕获
      }
      const move = (moveEvent) => {
        if (!dragging && Math.hypot(moveEvent.clientX - start.x, moveEvent.clientY - start.y) < DRAG_THRESHOLD) return;
        if (!dragging) {
          if (actions.readOnly()) return;
          dragging = true;
          box.classList.add("is-dragging");
        }
        // 这一块跟着指针上下走（像拿起来了），落点线标出放下后插在哪
        box.style.transform = `translateY(${moveEvent.clientY - start.y}px)`;
        drop = dropAt(locate(moveEvent.clientX, moveEvent.clientY), block);
        showLine(drop);
      };
      const end = () => {
        box.removeEventListener("pointermove", move);
        box.removeEventListener("pointerup", end);
        box.removeEventListener("pointercancel", end);
        box.classList.remove("is-dragging");
        box.style.removeProperty("transform");
        showLine(null);
        if (!dragging) {
          select(block);
          return;
        }
        if (drop) commit(ops().move(actions.text(), block.source, drop.block.source, drop.after), { chunk: chunkOf(block) });
      };
      box.addEventListener("pointermove", move);
      box.addEventListener("pointerup", end);
      box.addEventListener("pointercancel", end);
    }

    // 点卡片外面、按 Esc 取消选中
    viewport.addEventListener("pointerdown", (event) => {
      if (!event.target.closest(".stage-block, .stage-block-bar")) clear();
    });
    new MutationObserver(sync).observe(pagesRoot, { childList: true });

    return {
      attach,
      clear,
      // 选中的块的原文范围（没有为 null）
      selection: () => {
        const found = selected && pages.flatMap((entry) => entry.entries).find((item) => sameBlock(item, selected));
        return found ? [...found.block.source] : null;
      },
    };
  }

  window.MediaCraftStageBlocks = { create };
})();
