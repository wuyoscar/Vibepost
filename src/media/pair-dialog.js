// 拼图对话框：两张图并排预览，和卡片上一样按整组比例排、各自铺满半格。
// 整组比例可点选，也可拖预览的下边（吸附到 16:9 / 3:2 / 4:3 / 1:1）；可左右对调、各自裁剪、拆成两张。
// 改动先只在对话框里，点「完成」才一起生效，取消什么都不改。
// open() 返回 Promise：完成得到 { ids, ratio, crops }，拆开得到 { split: true, ids, crops }，取消得到 null。
(() => {
  // 能选的比例与卡片排版共用一份（src/engine/media.js）
  const RATIOS = window.MediaCraftEngine.PAIR_RATIOS;
  const ORDER = Object.keys(RATIOS).reverse(); // 由扁到方
  const DEFAULT_RATIO = ORDER[0];
  const LABEL = (ratio) => ratio.replace("x", ":");

  const $ = (id) => document.getElementById(id);
  const modal = $("pairDialog");
  const names = $("pairDialogNames");
  const preview = $("pairStage");
  const canvases = [$("pairLeftCanvas"), $("pairRightCanvas")];
  const handle = $("pairRatioHandle");
  const ratioGroup = $("pairRatios");

  let session = null; // { ids, ratio, original, images: { id: { name, crop, element } }, crops, cropImage, resolve, returnFocus }
  let drag = null;

  const cropOf = (id) => (Object.hasOwn(session.crops, id) ? session.crops[id] : session.images[id].crop);

  // 在裁剪框里取一块与格子同比例、居中的区域（和卡片上一样铺满）
  function cover(element, crop, aspect) {
    const area = crop ?? { x: 0, y: 0, width: element.naturalWidth, height: element.naturalHeight };
    if (area.width / area.height > aspect) {
      const width = area.height * aspect;
      return { x: area.x + (area.width - width) / 2, y: area.y, width, height: area.height };
    }
    const height = area.width / aspect;
    return { x: area.x, y: area.y + (area.height - height) / 2, width: area.width, height };
  }

  function drawCells() {
    if (!session) return;
    const scale = window.devicePixelRatio || 1;
    canvases.forEach((canvas, index) => {
      const id = session.ids[index];
      const { clientWidth: width, clientHeight: height } = canvas; // 布局尺寸：对话框弹出时的缩放不算进来
      if (!width || !height) return;
      canvas.width = Math.round(width * scale);
      canvas.height = Math.round(height * scale);
      const { element } = session.images[id];
      const source = cover(element, cropOf(id), width / height);
      const context = canvas.getContext("2d");
      context.imageSmoothingQuality = "high";
      context.drawImage(element, source.x, source.y, source.width, source.height, 0, 0, canvas.width, canvas.height);
    });
  }

  function sync() {
    const { ratio, ids } = session;
    preview.style.aspectRatio = String(RATIOS[ratio]);
    names.textContent = ids.map((id) => session.images[id].name).join(" + ");
    ratioGroup.querySelectorAll("[data-pair-ratio]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.pairRatio === ratio));
    });
    handle.setAttribute("aria-valuenow", String(ORDER.indexOf(ratio)));
    handle.setAttribute("aria-valuetext", LABEL(ratio));
    requestAnimationFrame(drawCells);
  }

  function setRatio(ratio) {
    if (!session || !RATIOS[ratio] || session.ratio === ratio) return;
    session.ratio = ratio;
    sync();
  }

  function finish(result) {
    if (!session) return;
    const { resolve, returnFocus } = session;
    session = null;
    drag = null;
    modal.classList.add("hidden");
    window.MediaCraftMotion.returnFocus(modal, returnFocus);
    resolve(result);
  }

  // images：{ [id]: { name, src, crop } }；cropImage(id, crop) 打开裁剪对话框，返回新的裁剪框（取消为 undefined）
  async function open({ ids, ratio, images, cropImage }) {
    finish(null);
    const loaded = {};
    for (const id of ids) {
      const element = new Image();
      element.src = images[id].src;
      await element.decode();
      loaded[id] = { name: images[id].name, crop: images[id].crop ?? null, element };
    }
    const returnFocus = document.activeElement;
    return new Promise((resolve) => {
      const chosen = RATIOS[ratio] ? ratio : DEFAULT_RATIO;
      session = { ids: [...ids], ratio: chosen, original: RATIOS[ratio] ? ratio : null, images: loaded, crops: {}, cropImage, resolve, returnFocus };
      modal.classList.remove("hidden");
      sync();
      $("pairDone").focus({ preventScroll: true });
    });
  }

  function done() {
    const { ids, ratio, original, crops } = session;
    // 没写比例的拼图就是 16:9：比例没改时不往正文里多写一段
    finish({ ids, ratio: ratio === DEFAULT_RATIO && original === null ? null : ratio, crops });
  }

  async function cropCell(index) {
    if (!session) return;
    const current = session;
    const id = current.ids[index];
    const crop = await current.cropImage(id, cropOf(id));
    if (session !== current || crop === undefined) return;
    current.crops[id] = crop;
    drawCells();
  }

  // 拖预览的下边改整组比例：高度跟着指针，吸附到最近的一种比例
  handle.addEventListener("pointerdown", (event) => {
    if (!session || event.button !== 0) return;
    event.preventDefault();
    handle.focus({ preventScroll: true });
    const rect = preview.getBoundingClientRect();
    drag = { y: event.clientY, width: rect.width, height: rect.height };
    handle.setPointerCapture(event.pointerId);
    modal.classList.add("is-adjusting");
  });
  handle.addEventListener("pointermove", (event) => {
    if (!drag) return;
    const height = Math.max(1, drag.height + event.clientY - drag.y);
    const target = Math.log(drag.width / height);
    const nearest = ORDER.reduce((best, key) => (Math.abs(Math.log(RATIOS[key]) - target) < Math.abs(Math.log(RATIOS[best]) - target) ? key : best));
    // 吸到下一档比例时触控板轻轻一震
    if (nearest !== session.ratio) window.MediaCraftNative?.haptic("level-change");
    setRatio(nearest);
  });
  const endDrag = () => {
    drag = null;
    modal.classList.remove("is-adjusting");
  };
  handle.addEventListener("pointerup", endDrag);
  handle.addEventListener("pointercancel", endDrag);
  handle.addEventListener("keydown", (event) => {
    const step = { ArrowUp: -1, ArrowLeft: -1, ArrowDown: 1, ArrowRight: 1 }[event.key];
    if (!step || !session) return;
    event.preventDefault();
    setRatio(ORDER[Math.min(ORDER.length - 1, Math.max(0, ORDER.indexOf(session.ratio) + step))]);
  });

  ratioGroup.addEventListener("click", (event) => {
    const ratio = event.target.closest("[data-pair-ratio]")?.dataset.pairRatio;
    if (ratio) setRatio(ratio);
  });
  $("pairSwap").addEventListener("click", () => {
    if (!session) return;
    session.ids.reverse();
    sync();
  });
  $("pairLeftCrop").addEventListener("click", () => void cropCell(0));
  $("pairRightCrop").addEventListener("click", () => void cropCell(1));
  $("pairSplit").addEventListener("click", () => {
    if (session) finish({ split: true, ids: session.ids, crops: session.crops });
  });
  $("pairDone").addEventListener("click", () => {
    if (session) done();
  });
  $("pairCancel").addEventListener("click", () => finish(null));
  $("pairClose").addEventListener("click", () => finish(null));
  modal.addEventListener("pointerdown", (event) => {
    if (event.target === modal) finish(null);
  });
  modal.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    event.preventDefault();
    event.stopPropagation();
    finish(null);
  });
  new ResizeObserver(() => drawCells()).observe(preview);

  window.MediaCraftMedia = window.MediaCraftMedia || {};
  window.MediaCraftMedia.pairDialog = { open };
})();
