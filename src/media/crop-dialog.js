// 裁剪对话框（稿子里的图片与署名头像共用）：拖动选框移动、拖四角或四边改大小、滑杆 / 触控板缩放，
// 比例可选自由、3:4、1:1、4:3、16:9（头像固定 1:1）；自由比例下拖四角，拖到接近这几种比例时吸住（触控板轻轻一震）。
// open() 返回 Promise：点「完成」得到裁剪框 { x, y, width, height }（原图像素，整张图为 null），取消得到 undefined。
(() => {
  const ASPECTS = { free: null, "3:4": 3 / 4, "1:1": 1, "4:3": 4 / 3, "16:9": 16 / 9 };
  const MAX_ZOOM = 8;
  const MIN_SIDE = 16; // 选框最小边长（原图像素）
  const CORNERS = ["nw", "ne", "sw", "se"];
  const SNAP = 0.015; // 自由比例下离预设比例这么近（比例的对数差）就吸住

  const $ = (id) => document.getElementById(id);
  const modal = $("cropDialog");
  const title = $("cropTitle");
  const well = $("cropWell");
  const box = $("cropBox");
  const picture = $("cropImage");
  const frame = $("cropFrame");
  const aspectGroup = $("cropAspects");
  const zoom = $("cropZoom");
  const sizeLabel = $("cropSize");
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

  let session = null; // { width, height, rect, aspect, locked, resolve, returnFocus }
  let gesture = null;

  // ===== 选框的几何（原图像素）=====

  const aspectOf = (rect) => rect.width / rect.height;

  // 这个比例下能放进整张图的最大选框，居中在 (cx, cy)
  function largest(aspect, cx = session.width / 2, cy = session.height / 2) {
    const { width, height } = session;
    const w = width / height > aspect ? height * aspect : width;
    return place({ x: cx - w / 2, y: cy - w / aspect / 2, width: w, height: w / aspect });
  }

  // 大小不超过整张图、不小于最小边长，位置挪回图里
  function place(rect) {
    const width = clamp(rect.width, Math.min(MIN_SIDE, session.width), session.width);
    const height = clamp(rect.height, Math.min(MIN_SIDE, session.height), session.height);
    return {
      x: clamp(rect.x, 0, session.width - width),
      y: clamp(rect.y, 0, session.height - height),
      width,
      height,
    };
  }

  const currentAspect = () => session.aspect ?? aspectOf(session.rect);

  function zoomLevel() {
    return largest(currentAspect()).width / session.rect.width;
  }

  function setZoom(level) {
    const { rect } = session;
    const base = largest(currentAspect());
    const factor = clamp(level, 1, MAX_ZOOM);
    const width = base.width / factor;
    const height = base.height / factor;
    session.rect = place({ x: rect.x + rect.width / 2 - width / 2, y: rect.y + rect.height / 2 - height / 2, width, height });
    draw();
  }

  function setAspect(key) {
    session.aspect = ASPECTS[key];
    if (session.aspect) {
      const { rect } = session;
      session.rect = largest(session.aspect, rect.x + rect.width / 2, rect.y + rect.height / 2);
    }
    draw();
  }

  // 拖一个角或一条边：对面的角 / 边不动；有比例时（锁定的，或自由拖角时吸住的）按变化大的那一边等比缩放。
  function resize(start, handle, dx, dy, aspect = session.aspect) {
    const { width: imageWidth, height: imageHeight } = session;
    const west = handle.includes("w");
    const east = handle.includes("e");
    const north = handle.includes("n");
    const south = handle.includes("s");
    const right = start.x + start.width;
    const bottom = start.y + start.height;
    const room = {
      width: west ? right : east ? imageWidth - start.x : start.width,
      height: north ? bottom : south ? imageHeight - start.y : start.height,
    };
    let width = west ? start.width - dx : east ? start.width + dx : start.width;
    let height = north ? start.height - dy : south ? start.height + dy : start.height;
    if (aspect) {
      const horizontal = west || east;
      const vertical = north || south;
      const byWidth = horizontal && (!vertical || Math.abs(width / start.width - 1) >= Math.abs(height / start.height - 1));
      if (byWidth) height = width / aspect;
      else width = height * aspect;
      const fit = Math.min(1, room.width / width, room.height / height);
      width *= fit;
      height *= fit;
      const floor = Math.max(MIN_SIDE / width, MIN_SIDE / height, 1);
      if (floor > 1 && width * floor <= room.width && height * floor <= room.height) {
        width *= floor;
        height *= floor;
      }
    } else {
      width = clamp(width, Math.min(MIN_SIDE, room.width), room.width);
      height = clamp(height, Math.min(MIN_SIDE, room.height), room.height);
    }
    // 只拖一条边而锁定比例时，另一方向以中线为准
    const x = west ? right - width : east ? start.x : start.x + (start.width - width) / 2;
    const y = north ? bottom - height : south ? start.y : start.y + (start.height - height) / 2;
    return place({ x, y, width, height });
  }

  // ===== 画面 =====

  // 图片按原比例放进取景区
  function layoutBox() {
    if (!session) return;
    const style = getComputedStyle(well);
    const availableWidth = well.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    const availableHeight = well.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
    const scale = Math.min(availableWidth / session.width, availableHeight / session.height);
    box.style.width = `${Math.max(1, Math.floor(session.width * scale))}px`;
    box.style.height = `${Math.max(1, Math.floor(session.height * scale))}px`;
  }

  function draw() {
    const { rect, width, height } = session;
    const percent = (value, total) => `${(value / total) * 100}%`;
    frame.style.left = percent(rect.x, width);
    frame.style.top = percent(rect.y, height);
    frame.style.width = percent(rect.width, width);
    frame.style.height = percent(rect.height, height);
    sizeLabel.textContent = `${Math.round(rect.width)} × ${Math.round(rect.height)}`;
    zoom.value = String(zoomLevel());
    zoom.style.setProperty("--fill", `${((zoomLevel() - 1) / (MAX_ZOOM - 1)) * 100}%`);
    // 定了比例只能拖四角
    frame.classList.toggle("has-aspect", session.aspect !== null);
    const key = Object.keys(ASPECTS).find((name) => ASPECTS[name] === session.aspect) ?? "free";
    aspectGroup.querySelectorAll("[data-crop-aspect]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.cropAspect === key));
    });
  }

  // 原图像素 / 屏幕像素
  const sourcePerPixel = () => session.width / box.getBoundingClientRect().width;

  // ===== 打开与关闭 =====

  function presetFor(crop) {
    if (!crop) return "free";
    const ratio = crop.width / crop.height;
    return Object.keys(ASPECTS).find((key) => ASPECTS[key] && Math.abs(ASPECTS[key] / ratio - 1) < 0.01) ?? "free";
  }

  function finish(result) {
    if (!session) return;
    const { resolve, returnFocus } = session;
    session = null;
    gesture = null;
    modal.classList.add("hidden");
    picture.removeAttribute("src");
    window.MediaCraftMotion.returnFocus(modal, returnFocus);
    resolve(result);
  }

  function result() {
    const { rect, width, height } = session;
    // 取整到像素，取整后仍不超出原图
    const x = Math.round(rect.x);
    const y = Math.round(rect.y);
    const crop = { x, y, width: Math.min(Math.round(rect.width), width - x), height: Math.min(Math.round(rect.height), height - y) };
    const whole = x === 0 && y === 0 && crop.width === width && crop.height === height;
    return whole ? null : crop;
  }

  // options：{ name, src, crop, lockAspect }；name 为空时标题是「裁剪头像」
  async function open({ name = "", src, crop = null, lockAspect = null }) {
    finish(undefined);
    picture.src = src;
    await picture.decode();
    const width = picture.naturalWidth;
    const height = picture.naturalHeight;
    const returnFocus = document.activeElement;
    return new Promise((resolve) => {
      session = { width, height, rect: null, aspect: null, locked: Boolean(lockAspect), resolve, returnFocus };
      session.rect = crop ? place({ ...crop }) : { x: 0, y: 0, width, height };
      if (lockAspect) {
        session.aspect = lockAspect;
        session.rect = crop && Math.abs(aspectOf(session.rect) / lockAspect - 1) < 0.01
          ? session.rect
          : largest(lockAspect, session.rect.x + session.rect.width / 2, session.rect.y + session.rect.height / 2);
      } else {
        session.aspect = ASPECTS[presetFor(crop)];
      }
      if (name) {
        const label = document.createElement("span");
        label.className = "media-dialog-name";
        label.textContent = name;
        title.replaceChildren("裁剪 ", label);
      } else {
        title.textContent = "裁剪头像";
      }
      aspectGroup.hidden = session.locked;
      modal.classList.remove("hidden");
      layoutBox();
      draw();
      frame.focus({ preventScroll: true });
    });
  }

  // ===== 交互 =====

  function startGesture(event) {
    if (!session || event.button !== 0) return;
    const handle = event.target.closest("[data-crop-handle]")?.dataset.cropHandle ?? "move";
    if (!CORNERS.includes(handle) && handle !== "move" && session.aspect) return;
    event.preventDefault();
    frame.focus({ preventScroll: true });
    gesture = { handle, x: event.clientX, y: event.clientY, start: { ...session.rect }, scale: sourcePerPixel() };
    frame.setPointerCapture(event.pointerId);
    modal.classList.add("is-adjusting");
  }

  // 自由比例下拖角：比例接近某个预设时换成正好那个比例
  function snapped(start, handle, dx, dy) {
    const rect = resize(start, handle, dx, dy);
    if (session.aspect || !CORNERS.includes(handle)) return { rect, aspect: null };
    const aspect = Object.values(ASPECTS).find((value) => value && Math.abs(Math.log(aspectOf(rect) / value)) < SNAP) ?? null;
    return { rect: aspect ? resize(start, handle, dx, dy, aspect) : rect, aspect };
  }

  function moveGesture(event) {
    if (!gesture) return;
    const dx = (event.clientX - gesture.x) * gesture.scale;
    const dy = (event.clientY - gesture.y) * gesture.scale;
    const { start } = gesture;
    if (gesture.handle === "move") {
      session.rect = place({ ...start, x: start.x + dx, y: start.y + dy });
    } else {
      const { rect, aspect } = snapped(start, gesture.handle, dx, dy);
      if (aspect && aspect !== gesture.snapped) window.MediaCraftNative?.haptic("alignment");
      gesture.snapped = aspect;
      session.rect = rect;
    }
    draw();
  }

  function endGesture() {
    gesture = null;
    modal.classList.remove("is-adjusting");
  }

  frame.addEventListener("pointerdown", startGesture);
  frame.addEventListener("pointermove", moveGesture);
  frame.addEventListener("pointerup", endGesture);
  frame.addEventListener("pointercancel", endGesture);
  frame.addEventListener("keydown", (event) => {
    const step = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[event.key];
    if (!step || !session) return;
    event.preventDefault();
    const distance = Math.max(1, Math.round(Math.min(session.width, session.height) * (event.shiftKey ? 0.1 : 0.01)));
    const { rect } = session;
    session.rect = place({ ...rect, x: rect.x + step[0] * distance, y: rect.y + step[1] * distance });
    draw();
  });

  // 触控板双指缩放（WebKit 给的是带 ctrlKey 的滚轮）与滚轮都用来缩放
  well.addEventListener("wheel", (event) => {
    if (!session) return;
    event.preventDefault();
    setZoom(zoomLevel() * Math.exp(-event.deltaY * (event.ctrlKey ? 0.01 : 0.002)));
  }, { passive: false });

  zoom.addEventListener("input", () => setZoom(Number(zoom.value)));
  aspectGroup.addEventListener("click", (event) => {
    const key = event.target.closest("[data-crop-aspect]")?.dataset.cropAspect;
    if (key && session) setAspect(key);
  });
  $("cropReset").addEventListener("click", () => {
    if (!session) return;
    if (!session.locked) session.aspect = null;
    session.rect = session.locked ? largest(session.aspect) : { x: 0, y: 0, width: session.width, height: session.height };
    draw();
  });
  $("cropDone").addEventListener("click", () => finish(result()));
  $("cropCancel").addEventListener("click", () => finish(undefined));
  $("cropClose").addEventListener("click", () => finish(undefined));
  modal.addEventListener("pointerdown", (event) => {
    if (event.target === modal) finish(undefined);
  });
  modal.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      finish(undefined);
    } else if (event.key === "Enter" && !event.target.closest("button, input")) {
      event.preventDefault();
      finish(result());
    }
  });
  new ResizeObserver(() => layoutBox()).observe(well);

  window.MediaCraftMedia = window.MediaCraftMedia || {};
  window.MediaCraftMedia.cropDialog = { open };
})();
