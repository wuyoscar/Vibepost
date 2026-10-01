// 实况编辑器：上面是视频和取景框（拖动移动、拖四角改大小，比例可选），下面是整段视频的胶片条，
// 亮框框出要用的那一段（拖动挪起点），白线是播放头、小点是封面。时长 3 / 5 / 8 秒、倍速、声音、设为封面。
// 预览按倍速循环播放选中的这一段。改动先只在对话框里，点「插入 / 完成」才生效，取消什么都不改。
// open() 返回 Promise：完成得到设置（同 MediaCraftMedia.live.settingsOf 的形状），取消得到 undefined。
(() => {
  const live = window.MediaCraftMedia.live;
  const MIN_SIDE = 24; // 取景框最小边长（视频像素）
  const LOOP_CHECK_MS = 40;
  const DRAG_THRESHOLD = 3;

  const $ = (id) => document.getElementById(id);
  const modal = $("liveDialog");
  const nameLabel = $("liveName");
  const well = $("liveWell");
  const box = $("liveBox");
  const video = $("liveVideo");
  const frame = $("liveFrame");
  const playButton = $("livePlay");
  const track = $("liveTrack");
  const strip = $("liveStrip");
  const windowBox = $("liveWindow");
  const coverMark = $("liveCoverMark");
  const playhead = $("livePlayhead");
  const durations = $("liveDurations");
  const speeds = $("liveSpeeds");
  const aspects = $("liveAspects");
  const soundButton = $("liveSoundBtn");
  const coverButton = $("liveCoverBtn");
  const coverThumb = $("liveCoverThumb");
  const summary = $("liveSummary");
  const doneButton = $("liveDone");

  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  const seconds = (value) => {
    const rounded = Math.round(value * 10) / 10;
    return Number.isInteger(rounded) ? String(rounded) : rounded.toFixed(1);
  };

  // { src, meta, settings, rect（取景框，视频像素）, resolve, returnFocus, playing, loopTimer, audible,
  //   grabber（截帧用的视频）, grabbing, stripCells（胶片条上还没画的格子）, coverRequest（还没画的封面缩略图）}
  let session = null;
  let gesture = null;

  // ===== 时间 =====

  const clip = () => live.clipOf(session.settings, session.meta.duration);

  function setSettings(patch) {
    session.settings = live.fitted({ ...session.settings, ...patch }, session.meta.duration);
    draw();
  }

  // ===== 取景框（视频像素）=====

  const aspectValue = () => live.ASPECTS[session.settings.aspect] ?? (session.settings.aspect === "original" ? session.meta.width / session.meta.height : null);

  function place(rect) {
    const { width: W, height: H } = session.meta;
    const width = clamp(rect.width, Math.min(MIN_SIDE, W), W);
    const height = clamp(rect.height, Math.min(MIN_SIDE, H), H);
    return { x: clamp(rect.x, 0, W - width), y: clamp(rect.y, 0, H - height), width, height };
  }

  // 这个比例下能放进画面的最大框，居中在 (cx, cy)
  function largest(aspect, cx = session.meta.width / 2, cy = session.meta.height / 2) {
    const { width: W, height: H } = session.meta;
    const width = W / H > aspect ? H * aspect : W;
    return place({ x: cx - width / 2, y: cy - width / aspect / 2, width, height: width / aspect });
  }

  function rectToCrop(rect) {
    const { width: W, height: H } = session.meta;
    return live.normalizeCrop({ x: rect.x / W, y: rect.y / H, width: rect.width / W, height: rect.height / H });
  }

  function commitRect(rect) {
    session.rect = rect;
    session.settings = { ...session.settings, crop: rectToCrop(rect) };
    draw();
  }

  function setAspect(key) {
    const { rect } = session;
    session.settings = { ...session.settings, aspect: key };
    const aspect = aspectValue();
    commitRect(key === "original" ? { x: 0, y: 0, width: session.meta.width, height: session.meta.height }
      : aspect ? largest(aspect, rect.x + rect.width / 2, rect.y + rect.height / 2) : rect);
    refreshCoverThumb();
  }

  // 拖一个角：对角不动；定了比例时按变化大的一边等比缩放
  function resize(start, handle, dx, dy) {
    const { width: W, height: H } = session.meta;
    const west = handle.includes("w");
    const north = handle.includes("n");
    const right = start.x + start.width;
    const bottom = start.y + start.height;
    const room = { width: west ? right : W - start.x, height: north ? bottom : H - start.y };
    let width = clamp(west ? start.width - dx : start.width + dx, MIN_SIDE, room.width);
    let height = clamp(north ? start.height - dy : start.height + dy, MIN_SIDE, room.height);
    const aspect = aspectValue();
    if (aspect) {
      if (Math.abs(width / start.width - 1) >= Math.abs(height / start.height - 1)) height = width / aspect;
      else width = height * aspect;
      const fit = Math.min(1, room.width / width, room.height / height);
      width *= fit;
      height *= fit;
    }
    return place({ x: west ? right - width : start.x, y: north ? bottom - height : start.y, width, height });
  }

  // ===== 画面 =====

  // 视频按原比例放进取景区
  function layoutBox() {
    if (!session) return;
    const style = getComputedStyle(well);
    const availableWidth = well.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    const availableHeight = well.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
    const scale = Math.min(availableWidth / session.meta.width, availableHeight / session.meta.height);
    box.style.width = `${Math.max(1, Math.floor(session.meta.width * scale))}px`;
    box.style.height = `${Math.max(1, Math.floor(session.meta.height * scale))}px`;
  }

  const percent = (value) => `${value * 100}%`;

  function draw() {
    const { settings, meta } = session;
    const { crop } = settings;
    frame.style.left = percent(crop.x);
    frame.style.top = percent(crop.y);
    frame.style.width = percent(crop.width);
    frame.style.height = percent(crop.height);
    frame.classList.toggle("is-locked", settings.aspect === "original");
    const pressed = (group, attribute, value) => group.querySelectorAll(`[${attribute}]`).forEach((button) => {
      button.setAttribute("aria-pressed", String(button.getAttribute(attribute) === String(value)));
    });
    pressed(durations, "data-duration", settings.duration);
    pressed(speeds, "data-speed", settings.speed);
    pressed(aspects, "data-aspect", settings.aspect);
    soundButton.setAttribute("aria-pressed", String(settings.sound));
    soundButton.querySelector("use").setAttribute("href", settings.sound ? "#i-sound" : "#i-sound-off");

    const current = clip();
    windowBox.style.left = percent(current.start / meta.duration);
    windowBox.style.width = percent(current.span / meta.duration);
    coverMark.style.left = percent(current.cover / current.span);
    track.setAttribute("aria-valuemax", seconds(Math.max(0, meta.duration - current.span)));
    track.setAttribute("aria-valuenow", seconds(current.start));
    track.setAttribute("aria-valuetext", `从 ${seconds(current.start)} 秒起，用 ${seconds(current.span)} 秒`);
    const lead = current.short ? `视频只有 ${seconds(meta.duration)} 秒，成片 ${seconds(current.seconds)} 秒` : `成片 ${seconds(current.seconds)} 秒`;
    const range = `原视频 ${seconds(current.start)}–${seconds(current.start + current.span)} 秒`;
    const note = window.MediaCraftNative ? "" : " · 导出实况要在 MediaCraft App 里";
    summary.textContent = `${lead} · ${range} · 封面在第 ${seconds(current.cover / settings.speed)} 秒${note}`;
    drawPlayhead();
  }

  function drawPlayhead() {
    if (!session) return;
    playhead.style.left = percent(clamp(video.currentTime / session.meta.duration, 0, 1));
  }

  // ===== 播放：按倍速循环这一段 =====

  function setPlaying(playing) {
    session.playing = playing;
    clearInterval(session.loopTimer);
    playButton.setAttribute("aria-label", playing ? "暂停" : "播放");
    playButton.querySelector("use").setAttribute("href", playing ? "#i-pause" : "#i-play");
    if (!playing) {
      video.pause();
      return;
    }
    const { start, span } = clip();
    video.playbackRate = session.settings.speed;
    video.muted = !(session.settings.sound && session.audible);
    // 不在这一段里（或快到段尾）就从段首放起
    const time = video.currentTime;
    if (time < start || time >= start + span - 0.02) video.currentTime = start;
    // 静音才能自动播；带声音播不了时先静音播着
    video.play().catch(() => {
      video.muted = true;
      return video.play();
    }).catch(() => undefined);
    session.loopTimer = setInterval(() => {
      const { start, span } = clip();
      if (video.currentTime >= start + span - 0.02 || video.currentTime < start - 0.05) video.currentTime = start;
      drawPlayhead();
    }, LOOP_CHECK_MS);
  }

  // 停在某一刻（点胶片条、挪片段时）
  function scrub(time) {
    setPlaying(false);
    video.currentTime = clamp(time, 0, session.meta.duration);
    drawPlayhead();
  }

  // ===== 胶片条与封面缩略图 =====
  // 用另一个视频元素截帧，免得打断预览；同时只让它做一件事（几个视频一起跳着解码会互相卡住），封面优先。

  function schedule() {
    const current = session;
    if (current.grabbing) return;
    current.grabbing = true;
    (async () => {
      current.grabber ??= await live.loadVideo(current.src);
      while (session === current) {
        const cover = current.coverRequest;
        current.coverRequest = null;
        if (cover) await drawCover(current.grabber, cover);
        else if (current.stripCells.length) await drawCell(current.grabber, current.stripCells.shift());
        else break;
      }
    })().catch(() => undefined).finally(() => {
      current.grabbing = false;
    });
  }

  function buildStrip() {
    const scale = window.devicePixelRatio || 1;
    const width = Math.round(strip.clientWidth * scale);
    const height = Math.round(strip.clientHeight * scale);
    if (!width || !height) return;
    strip.width = width;
    strip.height = height;
    const context = strip.getContext("2d");
    context.fillStyle = "#2c2c2e";
    context.fillRect(0, 0, width, height);
    const { meta } = session;
    const count = Math.max(1, Math.ceil(width / (height * Math.min(meta.width / meta.height, 1.8))));
    session.stripCells = Array.from({ length: count }, (_, index) => {
      const x = Math.round((index * width) / count);
      return { x, width: Math.round(((index + 1) * width) / count) - x, height, time: ((index + 0.5) / count) * meta.duration, meta };
    });
    schedule();
  }

  async function drawCell(grabber, cell) {
    const region = live.coverRegion({ x: 0, y: 0, width: 1, height: 1 }, cell.meta, cell.width / cell.height);
    const image = await live.grab(grabber, cell.time, region, Math.max(cell.width, cell.height));
    strip.getContext("2d").drawImage(image, cell.x, 0, cell.width, cell.height);
  }

  async function drawCover(grabber, { time, crop }) {
    const image = await live.grab(grabber, time, crop, 96);
    coverThumb.width = image.width;
    coverThumb.height = image.height;
    coverThumb.getContext("2d").drawImage(image, 0, 0);
  }

  // 连着改几下时只画最后一次
  function refreshCoverThumb() {
    session.coverRequest = { time: clip().start + clip().cover, crop: session.settings.crop };
    schedule();
  }

  function setCover() {
    const current = clip();
    setSettings({ coverOffset: clamp(video.currentTime - current.start, 0, current.span) });
    refreshCoverThumb();
  }

  // ===== 打开与关闭 =====

  function finish(result) {
    if (!session) return;
    const { resolve, returnFocus, loopTimer, grabber } = session;
    clearInterval(loopTimer);
    session = null;
    gesture = null;
    modal.classList.add("hidden");
    for (const element of [video, grabber]) {
      if (!element) continue;
      element.pause();
      element.removeAttribute("src");
      element.load();
    }
    window.MediaCraftMotion.returnFocus(modal, returnFocus);
    resolve(result);
  }

  function waitForVideo() {
    return new Promise((resolve, reject) => {
      video.addEventListener("loadeddata", resolve, { once: true });
      video.addEventListener("error", () => reject(new Error("这段视频读不出来")), { once: true });
    });
  }

  // options：{ name, src（视频地址）, meta（{ duration, width, height }）, settings, confirmLabel }
  async function open({ name, src, meta, settings, confirmLabel = "完成" }) {
    finish(undefined);
    const ready = waitForVideo();
    video.src = src;
    await ready;
    const returnFocus = document.activeElement;
    return new Promise((resolve) => {
      const fitted = live.fitted(settings, meta.duration);
      const { crop } = fitted;
      session = {
        src, meta, settings: fitted, resolve, returnFocus, playing: false, loopTimer: 0, audible: false,
        grabber: null, grabbing: false, stripCells: [], coverRequest: null,
        rect: { x: crop.x * meta.width, y: crop.y * meta.height, width: crop.width * meta.width, height: crop.height * meta.height },
      };
      nameLabel.textContent = name || "";
      doneButton.textContent = confirmLabel;
      modal.classList.remove("hidden");
      layoutBox();
      draw();
      buildStrip();
      refreshCoverThumb();
      setPlaying(true);
      doneButton.focus({ preventScroll: true });
    });
  }

  const result = () => live.fitted(session.settings, session.meta.duration);

  // ===== 交互：取景框 =====

  frame.addEventListener("pointerdown", (event) => {
    if (!session || event.button !== 0 || session.settings.aspect === "original") return;
    event.preventDefault();
    frame.focus({ preventScroll: true });
    const handle = event.target.closest("[data-live-handle]")?.dataset.liveHandle ?? "move";
    const scale = session.meta.width / box.getBoundingClientRect().width;
    gesture = { kind: "crop", handle, x: event.clientX, y: event.clientY, start: { ...session.rect }, scale };
    frame.setPointerCapture(event.pointerId);
    modal.classList.add("is-adjusting");
  });
  frame.addEventListener("pointermove", (event) => {
    if (gesture?.kind !== "crop") return;
    const dx = (event.clientX - gesture.x) * gesture.scale;
    const dy = (event.clientY - gesture.y) * gesture.scale;
    const { start } = gesture;
    commitRect(gesture.handle === "move" ? place({ ...start, x: start.x + dx, y: start.y + dy }) : resize(start, gesture.handle, dx, dy));
  });
  const endCrop = () => {
    if (gesture?.kind !== "crop") return;
    gesture = null;
    modal.classList.remove("is-adjusting");
    refreshCoverThumb();
  };
  frame.addEventListener("pointerup", endCrop);
  frame.addEventListener("pointercancel", endCrop);
  frame.addEventListener("keydown", (event) => {
    const step = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[event.key];
    if (!step || !session || session.settings.aspect === "original") return;
    event.preventDefault();
    const distance = Math.max(1, Math.round(Math.min(session.meta.width, session.meta.height) * (event.shiftKey ? 0.1 : 0.01)));
    const { rect } = session;
    commitRect(place({ ...rect, x: rect.x + step[0] * distance, y: rect.y + step[1] * distance }));
    refreshCoverThumb();
  });

  // ===== 交互：胶片条（拖亮框挪起点，点一下看那一刻）=====

  const timeAt = (clientX) => {
    const rect = track.getBoundingClientRect();
    return clamp((clientX - rect.left) / rect.width, 0, 1) * session.meta.duration;
  };

  function moveWindow(start) {
    setSettings({ start });
    if (!session.playing) video.currentTime = clip().start + clip().cover;
    drawPlayhead();
  }

  track.addEventListener("pointerdown", (event) => {
    if (!session || event.button !== 0) return;
    event.preventDefault();
    track.focus({ preventScroll: true });
    const time = timeAt(event.clientX);
    const current = clip();
    const inside = time >= current.start && time <= current.start + current.span;
    // 点在亮框外：亮框挪过去，以这一点为中心
    if (!inside) moveWindow(time - current.span / 2);
    gesture = { kind: "window", x: event.clientX, moved: !inside, grab: time - clip().start, time };
    track.setPointerCapture(event.pointerId);
  });
  track.addEventListener("pointermove", (event) => {
    if (gesture?.kind !== "window") return;
    if (!gesture.moved && Math.abs(event.clientX - gesture.x) < DRAG_THRESHOLD) return;
    gesture.moved = true;
    moveWindow(timeAt(event.clientX) - gesture.grab);
  });
  const endTrack = () => {
    if (gesture?.kind !== "window") return;
    const { moved, time } = gesture;
    gesture = null;
    if (!moved) scrub(time);
    refreshCoverThumb();
  };
  track.addEventListener("pointerup", endTrack);
  track.addEventListener("pointercancel", endTrack);
  track.addEventListener("keydown", (event) => {
    const direction = { ArrowRight: 1, ArrowUp: 1, ArrowLeft: -1, ArrowDown: -1 }[event.key];
    if (!direction || !session) return;
    event.preventDefault();
    moveWindow(clip().start + direction * (event.shiftKey ? 1 : 0.1));
    refreshCoverThumb();
  });

  // ===== 交互：按钮 =====

  durations.addEventListener("click", (event) => {
    const value = Number(event.target.closest("[data-duration]")?.dataset.duration);
    if (!session || !value) return;
    setSettings({ duration: value });
    refreshCoverThumb();
  });
  speeds.addEventListener("click", (event) => {
    const value = Number(event.target.closest("[data-speed]")?.dataset.speed);
    if (!session || !value) return;
    setSettings({ speed: value });
    if (session.playing) video.playbackRate = value;
    refreshCoverThumb();
  });
  aspects.addEventListener("click", (event) => {
    const key = event.target.closest("[data-aspect]")?.dataset.aspect;
    if (session && key) setAspect(key);
  });
  soundButton.addEventListener("click", () => {
    if (!session) return;
    // 点过这里算用户允许出声，预览随之带上声音
    session.audible = true;
    setSettings({ sound: !session.settings.sound });
    video.muted = !session.settings.sound;
  });
  playButton.addEventListener("click", () => {
    if (!session) return;
    session.audible = true;
    setPlaying(!session.playing);
  });
  coverButton.addEventListener("click", () => {
    if (session) setCover();
  });
  video.addEventListener("timeupdate", drawPlayhead);
  doneButton.addEventListener("click", () => {
    if (session) finish(result());
  });
  $("liveCancel").addEventListener("click", () => finish(undefined));
  $("liveClose").addEventListener("click", () => finish(undefined));
  modal.addEventListener("pointerdown", (event) => {
    if (event.target === modal) finish(undefined);
  });
  modal.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      finish(undefined);
    } else if (event.key === " " && !event.target.closest("button, input")) {
      event.preventDefault();
      session.audible = true;
      setPlaying(!session.playing);
    }
  });
  new ResizeObserver(() => layoutBox()).observe(well);

  window.MediaCraftMedia.liveDialog = { open };
})();
