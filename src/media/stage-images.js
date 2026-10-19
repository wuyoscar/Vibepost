// 舞台卡片上的图片：点选（四角把手 + 小工具条）、拖到两块内容之间（落点线提示插在哪）、
// 拖到另一张图上拼成一组、拖把手改宽度、⌫ 删除、双击或回车裁剪；从 Finder 拖文件到卡片上，插在松手的位置。
// 自己不改稿子：每个动作都交给 actions，由它变成正文（和图片属性）的一步改动。
(() => {
  const CARD_WIDTH = 864;
  const vertical = (value) => `calc(${value} / var(--card-height, 1152) * 100%)`;
  const DRAG_THRESHOLD = 4; // 按下后挪动超过这么多像素才算拖动
  const EDGE_SCROLL = 56; // 拖到舞台上下边这么近时自动滚动
  const GHOST_SIZE = 140; // 拖动时跟着指针的小图最长边（像素）
  const KIND_LABEL = { image: "图片", live: "实况", pair: "拼图" };
  const HANDLES = ["nw", "ne", "sw", "se"];

  const percent = (value, total) => `${(value / total) * 100}%`;
  const isEditable = (element) => Boolean(element?.closest?.("input, textarea, select, [contenteditable='true'], [role='textbox']"));

  // 一页上能点选的图片：单张图（含实况）来自 imageHits，拼图来自 imagePair 内容项。
  // 封面的底图不在正文里，不能拖动、缩放（在检查器的「封面」里换）。
  function refsOf(page) {
    const singles = page.imageHits.filter((hit) => !hit.cover).map((hit) => ({
      kind: hit.live ? "live" : "image", key: hit.imageId, ids: [hit.imageId], source: hit.source, box: hit,
    }));
    const pairs = page.items.filter((item) => item.kind === "imagePair").map((item) => ({
      kind: "pair", key: `pair:${item.imageIds.join("|")}`, ids: [...item.imageIds], source: item.source, box: item,
    }));
    return [...singles, ...pairs];
  }

  // 卡片上的 y（逻辑像素）→ 插在哪个落点之前或之后：落在一个落点里按上下半截，落在空隙里取最近的那条边
  function dropAt(page, y) {
    let best = null;
    page.dropTargets.forEach((target, index) => {
      const top = target.y;
      const bottom = target.y + target.height;
      if (!best?.inside && y >= top && y <= bottom) {
        best = { index, target, after: y >= (top + bottom) / 2, inside: true };
        return;
      }
      const distance = y < top ? top - y : y - bottom;
      if (!best || (!best.inside && distance < best.distance)) best = { index, target, after: y > bottom, distance };
    });
    return best && { index: best.index, target: best.target, after: best.after };
  }

  // actions：
  //   readOnly()                       这篇不能改（内置说明书）
  //   label(id) / align(id)           图片名、对齐方式
  //   select(ref)                      选中变了（ref 为 null 是没有选中）
  //   edit(ref) / remove(ref)          裁剪（拼图、实况打开各自的编辑器）/ 删除
  //   move(ref, drop)                  挪到落点 drop：{ target, after }
  //   pair(ref, target, side)          拖到另一张图上：side 是放在它的 left / right
  //   resize(ref, widthPercent)        拖把手改宽度（相对这张图在这一页上的最大宽度）
  //   dropFiles(files, drop)           从 Finder 拖进来的文件，drop 为 null 时放到正文最后
  // viewport：舞台的滚动区；pagesRoot：放卡片的容器（出图时整组换掉它的子元素）
  function createStage({ viewport, pagesRoot, actions }) {
    let pages = []; // 当前出图的每一页：{ frame, page, index, layer, entries: [{ ref, box }] }
    let selected = null; // { key, source }
    let keepFocus = false; // 重画前焦点在选中的图上：重画后还给它
    let gesture = null;
    let scrollFrame = 0;

    // ===== 每一页的图层 =====

    function place(element, rect) {
      element.style.left = percent(rect.x, CARD_WIDTH);
      element.style.top = vertical(rect.y);
      element.style.width = percent(rect.width, CARD_WIDTH);
      element.style.height = vertical(rect.height);
    }

    function attach(frame, page, index) {
      const layer = document.createElement("div");
      layer.className = "stage-media-layer";
      const entry = { frame, page, index, layer, entries: [] };
      for (const ref of refsOf(page)) {
        const box = document.createElement("button");
        box.type = "button";
        box.className = `stage-media is-${ref.kind}`;
        box.setAttribute("aria-label", `选择${KIND_LABEL[ref.kind]} ${ref.ids.map(actions.label).join(" + ")}`);
        place(box, ref.box);
        box.addEventListener("pointerdown", (event) => startGesture(event, { type: "move", entry, ref, box }));
        box.addEventListener("dblclick", () => actions.edit(ref));
        box.addEventListener("keydown", (event) => handleKey(event, ref));
        box.addEventListener("focus", () => {
          keepFocus = true;
          if (!isSelected(ref)) select(ref);
        });
        layer.append(box);
        entry.entries.push({ ref, box });
      }
      frame.append(layer);
      // 页面还没挂进舞台（出图时逐页生成）：换掉的旧页等 sync() 再丢
      pages = [...pages.filter((item) => item.index !== index), entry].sort((a, b) => a.index - b.index);
      paintSelection();
    }

    // 出图换掉了页面（含切到长文）：丢掉旧页，把选中的图找回来（同一张图可能挪了位置）
    function sync() {
      pages = pages.filter((entry) => entry.frame.isConnected);
      const found = selected && findEntry(selected);
      selected = found ? { key: found.ref.key, source: found.ref.source } : null;
      paintSelection();
      actions.select(found?.ref ?? null);
      if (found && keepFocus && (!document.activeElement || document.activeElement === document.body)) {
        found.box.focus({ preventScroll: true });
      }
    }

    function findEntry({ key, source }) {
      const candidates = pages.flatMap((entry) => entry.entries).filter((item) => item.ref.key === key);
      if (!candidates.length) return null;
      if (!source) return candidates[0];
      return candidates.reduce((best, item) => (Math.abs(item.ref.source[0] - source[0]) < Math.abs(best.ref.source[0] - source[0]) ? item : best));
    }

    const isSelected = (ref) => selected?.key === ref.key && selected.source?.[0] === ref.source[0];

    // ===== 选中 =====

    function select(ref, { focus = false } = {}) {
      selected = ref ? { key: ref.key, source: ref.source } : null;
      paintSelection({ appear: true });
      if (focus) findEntry(selected)?.box.focus({ preventScroll: true });
      actions.select(ref);
    }

    function clearSelection() {
      if (!selected) return;
      keepFocus = false;
      select(null);
    }

    // 选中的图：描边、四角把手（单张图才能改宽度）、上方的小工具条。
    // appear：刚点选时小工具条弹出来（出图后重画时不再弹一次）
    function paintSelection({ appear = false } = {}) {
      const current = selected && findEntry(selected);
      for (const entry of pages) {
        entry.layer.querySelector(".stage-media-bar")?.remove();
        for (const { box } of entry.entries) {
          const on = box === current?.box;
          box.classList.toggle("is-selected", on);
          box.setAttribute("aria-pressed", String(on));
          box.replaceChildren();
        }
      }
      if (!current || actions.readOnly()) return;
      const { ref, box } = current;
      if (ref.kind !== "pair") addResizeHandles(ref, box);
      box.parentElement.append(selectionBar(ref, appear));
    }

    // 单张图四角改宽度的把手
    function addResizeHandles(ref, box) {
      for (const corner of HANDLES) {
        const handle = document.createElement("span");
        handle.className = `stage-media-handle is-${corner}`;
        handle.dataset.handle = corner;
        handle.addEventListener("pointerdown", (event) => {
          event.stopPropagation();
          const entry = pages.find((item) => item.entries.some((each) => each.box === box));
          startGesture(event, { type: "resize", corner, entry, ref, box });
        });
        box.append(handle);
      }
    }

    // 选中的图上方（贴着卡片上沿时在下方）的小工具条：编辑、删除
    function selectionBar(ref, appear) {
      const bar = document.createElement("div");
      bar.className = appear ? "stage-media-bar is-appearing" : "stage-media-bar";
      bar.setAttribute("role", "toolbar");
      bar.setAttribute("aria-label", `${KIND_LABEL[ref.kind]}操作`);
      const button = (label, icon, run) => {
        const control = document.createElement("button");
        control.type = "button";
        control.title = label;
        control.setAttribute("aria-label", label);
        control.innerHTML = `<svg class="icon icon-small" aria-hidden="true"><use href="#${icon}" /></svg>`;
        control.addEventListener("click", run);
        return control;
      };
      const editLabel = { image: "裁剪这张图", live: "编辑这段实况", pair: "调整这组拼图" }[ref.kind];
      bar.append(
        button(editLabel, ref.kind === "pair" ? "i-image" : ref.kind === "live" ? "i-live" : "i-crop", () => actions.edit(ref)),
        button(`删除这${ref.kind === "pair" ? "组拼图" : ref.kind === "live" ? "段实况" : "张图"}`, "i-trash", () => actions.remove(ref)),
      );
      const { y, height } = ref.box;
      bar.classList.toggle("is-below", y < 64);
      bar.style.left = percent(ref.box.x + ref.box.width / 2, CARD_WIDTH);
      bar.style.top = vertical(y < 64 ? y + height : y);
      return bar;
    }

    function handleKey(event, ref) {
      if (event.key === "Enter") {
        event.preventDefault();
        actions.edit(ref);
      } else if (event.key === "Escape") {
        event.preventDefault();
        clearSelection();
        event.currentTarget.blur();
      } else if ((event.key === "Delete" || event.key === "Backspace") && !actions.readOnly()) {
        event.preventDefault();
        event.stopPropagation();
        actions.remove(ref);
      }
    }

    // ===== 拖动与缩放 =====

    // 指针下的那一页（不在任何一页上时取上下最近的一页），以及在卡片上的逻辑坐标
    function locate(clientX, clientY) {
      let best = null;
      for (const entry of pages) {
        const rect = entry.frame.getBoundingClientRect();
        // 指针在这一页上下范围里时为 0，否则是到上沿或下沿的距离
        const distance = Math.max(rect.top - clientY, clientY - rect.bottom, 0);
        if (best && best.distance <= distance) continue;
        best = { entry, rect, distance };
      }
      if (!best) return null;
      const { entry, rect } = best;
      const x = ((clientX - rect.left) / rect.width) * CARD_WIDTH;
      const height = entry.page.height ?? 1152;
      const y = Math.min(height, Math.max(0, ((clientY - rect.top) / rect.height) * height));
      return { entry, x, y };
    }

    // 拖着单张图停在另一张单张图的中间一块：拼图，按停在左半还是右半决定放哪边
    function pairTargetAt(spot, ref) {
      if (!spot || ref.kind !== "image") return null;
      for (const { ref: other, box } of spot.entry.entries) {
        if (other.kind !== "image" || other.key === ref.key) continue;
        const { x, y, width, height } = other.box;
        const inside = spot.x > x + width * 0.2 && spot.x < x + width * 0.8 && spot.y > y + height * 0.2 && spot.y < y + height * 0.8;
        if (inside) return { ref: other, box, side: spot.x < x + width / 2 ? "left" : "right" };
      }
      return null;
    }

    // 指针处的落点：{ target, after, entry }；这一页上没有落点时为 null
    function dropFor(spot) {
      const found = spot && dropAt(spot.entry.page, spot.y);
      return found ? { target: found.target, after: found.after, entry: spot.entry } : null;
    }

    // 落点线：画在要插进去的两块之间，横跨正文区。落点没变时留着原来那条（换落点时新的一条展开出来）
    let shownDrop = null;
    const sameDrop = (a, b) => a?.target === b?.target && a?.after === b?.after && a?.entry === b?.entry;

    function showDropLine(drop) {
      if (drop && sameDrop(drop, shownDrop)) return;
      hideDropLine();
      if (!drop) return;
      shownDrop = drop;
      const { target, after, entry } = drop;
      const { bounds } = entry.page;
      const line = document.createElement("div");
      line.className = "stage-drop-line";
      line.setAttribute("aria-hidden", "true");
      line.style.left = percent(bounds.left, CARD_WIDTH);
      line.style.width = percent(bounds.right - bounds.left, CARD_WIDTH);
      line.style.top = vertical(after ? target.y + target.height : target.y);
      entry.layer.append(line);
    }

    function hideDropLine() {
      shownDrop = null;
      for (const entry of pages) entry.layer.querySelectorAll(".stage-drop-line").forEach((line) => line.remove());
    }

    function showPairTarget(target) {
      for (const entry of pages) {
        for (const { box } of entry.entries) box.classList.toggle("is-pair-target", box === target?.box);
      }
    }

    function startGesture(event, spec) {
      if (event.button !== 0) return;
      event.preventDefault();
      if (!isSelected(spec.ref)) select(spec.ref);
      spec.box.focus({ preventScroll: true });
      if (actions.readOnly()) return;
      const frame = spec.entry.frame.getBoundingClientRect();
      gesture = {
        ...spec,
        startX: event.clientX,
        startY: event.clientY,
        lastX: event.clientX,
        lastY: event.clientY,
        active: false,
        scale: CARD_WIDTH / frame.width,
        startWidth: spec.ref.box.width,
        percent: Math.round((spec.ref.box.width / (spec.ref.box.baseWidth || spec.ref.box.width)) * 100),
      };
    }

    // HTML 卡片上的一张图画成和卡片同样大小（逻辑像素）的画布：图按它在卡片上露出来的位置画
    function htmlPicture(frame, imageId) {
      const card = frame.querySelector(".mc-card-host");
      const cell = card?.shadowRoot.querySelector(`.mc-img[data-image="${CSS.escape(imageId ?? "")}"]`);
      const image = cell?.querySelector("img");
      if (!image?.naturalWidth) return null;
      const page = card.getBoundingClientRect();
      const scale = CARD_WIDTH / page.width;
      const box = image.getBoundingClientRect();
      const clip = cell.getBoundingClientRect();
      const canvas = Object.assign(document.createElement("canvas"), { width: CARD_WIDTH, height: Math.round(page.height * scale) });
      const context = canvas.getContext("2d");
      context.beginPath();
      context.rect((clip.left - page.left) * scale, (clip.top - page.top) * scale, clip.width * scale, clip.height * scale);
      context.clip();
      context.drawImage(image, (box.left - page.left) * scale, (box.top - page.top) * scale, box.width * scale, box.height * scale);
      return canvas;
    }

    // 跟着指针走的小图：从这一页的画布上剪下这张图（含裁剪），最长边 140 像素。
    // 舞台上是 HTML 卡片（没有画布）时，取卡片里这张图：图片元素按它在卡片上的框摆好了裁剪
    function ghostOf(entry, rect, imageId) {
      const source = entry.frame.querySelector("canvas") ?? htmlPicture(entry.frame, imageId);
      if (!source) return document.createElement("div");
      const pixels = source.width / CARD_WIDTH;
      const fit = Math.min(1, GHOST_SIZE / rect.width, GHOST_SIZE / rect.height);
      const shown = (length) => Math.round(length * fit);
      const backing = (length) => Math.max(1, Math.round(length * fit * 2)); // 2 倍图
      const canvas = Object.assign(document.createElement("canvas"), { width: backing(rect.width), height: backing(rect.height) });
      canvas.style.width = `${shown(rect.width)}px`;
      canvas.style.height = `${shown(rect.height)}px`;
      // 这张图在卡片画布上的像素范围
      const area = new DOMRect(rect.x * pixels, rect.y * pixels, rect.width * pixels, rect.height * pixels);
      const context = canvas.getContext("2d");
      context.drawImage(source, area.x, area.y, area.width, area.height, 0, 0, canvas.width, canvas.height);
      const ghost = document.createElement("div");
      ghost.className = "stage-drag-ghost";
      ghost.setAttribute("aria-hidden", "true");
      ghost.append(canvas);
      return ghost;
    }

    function begin() {
      gesture.active = true;
      gesture.box.classList.add(gesture.type === "move" ? "is-dragging" : "is-resizing");
      if (gesture.type === "move") {
        document.body.append(gesture.ghost = ghostOf(gesture.entry, gesture.ref.box, gesture.ref.ids[0]));
        autoScroll();
      } else {
        const badge = document.createElement("span");
        badge.className = "stage-media-size";
        gesture.box.append(badge);
        gesture.badge = badge;
      }
    }

    function moveGesture(event) {
      if (!gesture) return;
      gesture.lastX = event.clientX;
      gesture.lastY = event.clientY;
      if (!gesture.active) {
        if (Math.hypot(event.clientX - gesture.startX, event.clientY - gesture.startY) < DRAG_THRESHOLD) return;
        begin();
      }
      if (gesture.type === "move") trackMove();
      else trackResize(event);
    }

    function trackMove() {
      const { ghost, lastX, lastY, ref } = gesture;
      ghost.style.translate = `${lastX + 14}px ${lastY + 14}px`;
      const spot = locate(lastX, lastY);
      const pair = pairTargetAt(spot, ref);
      // 拖到另一张图上（松手就拼成一组）的那一下，触控板轻轻一震
      if (pair && pair.ref !== gesture.pair?.ref) window.MediaCraftNative?.haptic("alignment");
      gesture.pair = pair;
      gesture.drop = pair ? null : dropFor(spot);
      showPairTarget(pair);
      showDropLine(gesture.drop);
    }

    // 宽度按把手拖出的距离变：居中的图两边一起变，所以横向距离算两倍
    function trackResize(event) {
      const { ref, corner, box, scale, startWidth } = gesture;
      const base = ref.box.baseWidth || startWidth;
      const align = actions.align(ref.ids[0]);
      const sign = corner.endsWith("e") ? 1 : -1;
      const growth = sign * (event.clientX - gesture.startX) * scale * (align === "center" ? 2 : 1);
      const width = Math.min(base, Math.max(base * 0.25, startWidth + growth));
      gesture.percent = Math.round((width / base) * 100);
      const height = width * (ref.box.height / ref.box.width);
      const left = align === "left" ? ref.box.x : align === "right" ? ref.box.x + ref.box.width - width : ref.box.x + (ref.box.width - width) / 2;
      place(box, { x: left, y: ref.box.y, width, height });
      gesture.badge.textContent = `${gesture.percent}%`;
    }

    function endGesture(commit) {
      if (!gesture) return;
      const current = gesture;
      gesture = null;
      cancelAnimationFrame(scrollFrame);
      current.ghost?.remove();
      current.badge?.remove();
      current.box.classList.remove("is-dragging", "is-resizing");
      hideDropLine();
      showPairTarget(null);
      if (!current.active) return;
      if (current.type === "resize") {
        place(current.box, current.ref.box);
        if (commit) actions.resize(current.ref, current.percent);
        return;
      }
      if (!commit) return;
      if (current.pair) actions.pair(current.ref, current.pair.ref, current.pair.side);
      else if (current.drop) actions.move(current.ref, current.drop);
    }

    // 拖到舞台上下边附近时慢慢滚过去，好把图拖到别的卡片上
    function autoScroll() {
      scrollFrame = requestAnimationFrame(() => {
        if (!gesture?.active || gesture.type !== "move") return;
        const rect = viewport.getBoundingClientRect();
        const speed = gesture.lastY < rect.top + EDGE_SCROLL ? -1 : gesture.lastY > rect.bottom - EDGE_SCROLL ? 1 : 0;
        if (speed) {
          viewport.scrollTop += speed * 14;
          trackMove();
        }
        autoScroll();
      });
    }

    window.addEventListener("pointermove", moveGesture);
    window.addEventListener("pointerup", () => endGesture(true));
    window.addEventListener("pointercancel", () => endGesture(false));
    window.addEventListener("blur", () => endGesture(false));

    // ===== 键盘与点空白处 =====

    document.addEventListener("keydown", (event) => {
      if (gesture && event.key === "Escape") {
        event.preventDefault();
        endGesture(false);
        return;
      }
      // 焦点不在输入框里、也不在图上时（比如点完图焦点落回页面），⌫ 仍删除选中的图
      if (!selected || event.defaultPrevented || isEditable(event.target) || event.target.closest?.(".stage-media")) return;
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      if (event.target !== document.body && !viewport.contains(event.target)) return;
      const current = findEntry(selected);
      if (current) handleKey(event, current.ref);
    });

    viewport.addEventListener("pointerdown", (event) => {
      if (!event.target.closest(".stage-media, .stage-media-bar")) clearSelection();
    });
    // 焦点移到图与图上的按钮以外的地方时，不再把焦点留在图上
    viewport.addEventListener("focusout", ({ relatedTarget }) => {
      if (relatedTarget && !relatedTarget.closest?.(".stage-media, .stage-media-bar")) keepFocus = false;
    });

    // ===== 从 Finder 拖文件进来 =====

    let fileHideTimer = 0;
    viewport.addEventListener("dragover", (event) => {
      if (!window.MediaCraftMedia.importer.hasFiles(event.dataTransfer)) return;
      event.preventDefault();
      if (actions.readOnly()) {
        event.dataTransfer.dropEffect = "none";
        return;
      }
      event.dataTransfer.dropEffect = "copy";
      clearTimeout(fileHideTimer);
      showDropLine(dropFor(locate(event.clientX, event.clientY)));
    });
    viewport.addEventListener("dragleave", () => {
      clearTimeout(fileHideTimer);
      fileHideTimer = setTimeout(hideDropLine, 80);
    });
    viewport.addEventListener("drop", (event) => {
      if (!window.MediaCraftMedia.importer.hasFiles(event.dataTransfer)) return;
      event.preventDefault();
      clearTimeout(fileHideTimer);
      hideDropLine();
      if (actions.readOnly()) return;
      const files = Array.from(event.dataTransfer.files);
      const drop = dropFor(locate(event.clientX, event.clientY));
      actions.dropFiles(files, drop);
    });

    new MutationObserver(sync).observe(pagesRoot, { childList: true });

    return {
      attach,
      clearSelection,
      // 选中的图（在当前页面上）：ref 或 null
      selection: () => (selected && findEntry(selected)?.ref) ?? null,
      // 下一次出图后选中这张图（拖成拼图后选中新的那组）
      selectAfterRender(key) {
        selected = { key, source: null };
      },
    };
  }

  window.MediaCraftMedia = window.MediaCraftMedia || {};
  window.MediaCraftMedia.createStage = createStage;
})();
