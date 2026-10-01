// 手机预览：舞台换成 iPhone 外框，顶上切换三种视图。「笔记」是信息流帖子——作者一行、卡片轮播（页码点与计数）、
// 标题、正文（正文栏里单独写的那段，不是卡片上的字；空着时灰色提示，点它跳到正文栏）、标签、互动栏；「发现页」「主页」是网格，看这一篇混在最近几篇稿子里的样子（src/phone-feed.js）。
// 不用任何平台的标识，也不画假的状态栏。点卡片左右两侧、触控板横扫、拖动、← → 键都能翻页；每次出图、改稿后跟着更新。
// 焦点在手机预览里时 ⌘1 / ⌘2 / ⌘3 切换视图（编辑器里的 ⌘1–3 是标题级别，焦点不在这里，互不相干）。
// 只通过 App API（window.mediacraft）和界面元素工作，不碰 src/app.js 的内部名字。
(() => {
  const mc = window.mediacraft;
  const root = document.getElementById("phonePreview");
  const $ = (selector) => root.querySelector(selector);
  const stage = document.getElementById("previewPanel");
  const toggle = document.getElementById("phoneButton");
  const fit = $(".phone-fit");
  const phone = $(".phone");
  const viewButtons = [...root.querySelectorAll("[data-phone-view]")];
  const screens = [...root.querySelectorAll("[data-phone-screen]")];
  const hint = $(".phone-hint");
  const feed = window.MediaCraftPhoneFeed.create({
    feed: $(".phone-feed-list"),
    grid: $(".phone-grid"),
    name: $(".phone-profile-name"),
    handle: $(".phone-profile-handle"),
  });
  const carousel = $(".phone-carousel");
  const track = $(".phone-track");
  const prevButton = $(".phone-flip-prev");
  const nextButton = $(".phone-flip-next");
  const counter = $(".phone-counter");
  const dots = $(".phone-dots");
  const avatar = $(".phone-avatar");
  const authorName = $(".phone-name");
  const title = $(".phone-title");
  const body = $(".phone-body");
  const tags = $(".phone-tags");

  // 外框的设计尺寸（CSS 像素）；舞台放不下时整体等比缩小
  const PHONE_WIDTH = 390;
  const PHONE_HEIGHT = 844;
  // 轮播里一张卡片的画布（外框内宽 370、3:4 的 2 倍图）
  const SLIDE_WIDTH = 740;
  const SLIDE_HEIGHT = 986;
  // 横扫、拖动超过这么多像素算翻一页
  const SWIPE_DISTANCE = 40;
  // 横扫停下这么久算一次手势结束（一次手势只翻一页）
  const WHEEL_SETTLE = 180;
  // 标签：行首或空白后面的「#文字」（# 后面紧跟空格的不算）
  const TAG = /(^|\s)#([^\s#]+)/gu;
  const TAG_TRAILING_PUNCTUATION = /[，。！？、；：,.!?;:）)」』”’]+$/u;

  // 三种视图：按钮上的字之外，顶上的提示；⌘1–3 按这个顺序
  const VIEWS = ["note", "feed", "profile"];
  // 正文栏空着时帖子里的灰字
  const EMPTY_CAPTION = "还没写正文，点这里在「正文」栏里写";
  const HINTS = {
    note: "点卡片左右两侧或按 ← → 翻页",
    feed: "这一篇混在最近几篇稿子里的样子",
    profile: "主页网格：这一篇排在第一格",
  };

  let open = false;
  let view = "note";
  let index = 0;
  let count = 0;
  let scale = 1;
  let syncSeq = 0;
  // 已经画上（或正在画）的头像，同一张不重画
  let drawnAvatar = { source: null, crop: null };

  const clamp = (value, min, max) => Math.max(min, Math.min(max, value));

  // ===== 开合 =====
  function setOpen(value) {
    open = value;
    toggle.setAttribute("aria-pressed", String(open));
    root.hidden = !open;
    stage.dataset.view = open ? "phone" : "cards";
    feed.show(open && view !== "note" ? view : null);
    if (open) {
      fitPhone();
      void sync();
    }
  }

  toggle.addEventListener("click", () => setOpen(!open));

  // ===== 三种视图 =====
  function setView(next) {
    view = next;
    for (const button of viewButtons) button.setAttribute("aria-pressed", String(button.dataset.phoneView === view));
    for (const screen of screens) screen.hidden = screen.dataset.phoneScreen !== view;
    hint.textContent = HINTS[view];
    feed.show(open && view !== "note" ? view : null);
    if (open && view === "note") void sync();
  }

  for (const button of viewButtons) button.addEventListener("click", () => setView(button.dataset.phoneView));

  // 点进手机预览（没落在能聚焦的控件上时）焦点交给整层，之后 ⌘1–3 就在这里接
  root.addEventListener("pointerdown", () => {
    if (!root.contains(document.activeElement)) root.focus({ preventScroll: true });
  });
  root.addEventListener("keydown", (event) => {
    const next = VIEWS[Number(event.key) - 1];
    if (!next || !(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return;
    event.preventDefault();
    event.stopPropagation();
    setView(next);
  });

  function fitPhone() {
    scale = Math.min(1, fit.clientWidth / PHONE_WIDTH, fit.clientHeight / PHONE_HEIGHT);
    phone.style.setProperty("--phone-scale", String(scale));
  }
  new ResizeObserver(fitPhone).observe(fit);

  // ===== 跟着稿子更新 =====
  // 正文里挑出标签，剩下的做正文摘要
  function splitTags(text) {
    const found = [];
    const rest = text.replace(TAG, (match, lead, tag) => {
      const clean = tag.replace(TAG_TRAILING_PUNCTUATION, "");
      if (clean && !found.includes(clean)) found.push(clean);
      return lead;
    });
    return { tags: found, excerpt: rest.replace(/[ \t]+$/gm, "").replace(/\n{3,}/g, "\n\n").trim() };
  }

  async function sync() {
    const seq = ++syncSeq;
    const [canvases, draft, profile] = await Promise.all([mc.render.canvases(), mc.drafts.current(), mc.profile.get()]);
    if (seq !== syncSeq || !open) return;
    authorName.textContent = profile.name.trim() || "还没填署名";
    if (view === "note") {
      drawSlides(canvases);
      const post = splitTags(draft.caption);
      const empty = !draft.caption.trim();
      title.textContent = draft.title.trim();
      title.hidden = !title.textContent;
      body.textContent = empty ? EMPTY_CAPTION : post.excerpt;
      body.classList.toggle("is-placeholder", empty);
      body.hidden = !body.textContent;
      tags.textContent = post.tags.map((tag) => `#${tag}`).join(" ");
      tags.hidden = !post.tags.length;
    }
    await drawAvatar(profile);
  }

  // 点正文（或按回车、空格）：跳到编辑区的正文栏
  const editCaption = () => window.MediaCraftCaption.focus();
  body.addEventListener("click", editCaption);
  body.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    event.preventDefault();
    editCaption();
  });

  function drawSlides(canvases) {
    while (track.children.length > canvases.length) track.lastElementChild.remove();
    canvases.forEach((source, page) => {
      let slide = track.children[page];
      if (!slide) {
        slide = document.createElement("canvas");
        slide.className = "phone-slide";
        slide.width = SLIDE_WIDTH;
        slide.height = SLIDE_HEIGHT;
        slide.setAttribute("role", "img");
        track.append(slide);
      }
      slide.setAttribute("aria-label", `第 ${page + 1} 张`);
      const context = slide.getContext("2d");
      context.imageSmoothingQuality = "high";
      context.drawImage(source, 0, 0, SLIDE_WIDTH, SLIDE_HEIGHT);
    });
    if (count !== canvases.length) {
      count = canvases.length;
      dots.replaceChildren(...canvases.map(() => document.createElement("span")));
    }
    show(index);
  }

  // 头像按署名里的裁剪框取正中的方形，和卡片上的头像一致；发现页、主页的小头像用同一张（CSS 变量 --phone-avatar）
  async function drawAvatar({ avatar: source, avatarCrop }) {
    const crop = JSON.stringify(avatarCrop);
    if (source === drawnAvatar.source && crop === drawnAvatar.crop) return;
    const drawing = { source, crop };
    drawnAvatar = drawing;
    const context = avatar.getContext("2d");
    context.clearRect(0, 0, avatar.width, avatar.height);
    phone.style.removeProperty("--phone-avatar");
    const image = new Image();
    image.src = source;
    try {
      await image.decode();
    } catch {
      // 头像读不出来时留空（卡片上同样不画头像），外框里只剩名字。
      return;
    }
    if (drawnAvatar !== drawing) return;
    const rect = window.MediaCraftEngine.imageCropRect({ width: image.naturalWidth, height: image.naturalHeight }, avatarCrop);
    const side = Math.min(rect.width, rect.height);
    const x = rect.x + (rect.width - side) / 2;
    const y = rect.y + (rect.height - side) / 2;
    context.imageSmoothingQuality = "high";
    context.drawImage(image, x, y, side, side, 0, 0, avatar.width, avatar.height);
    phone.style.setProperty("--phone-avatar", `url("${avatar.toDataURL()}")`);
  }

  // ===== 翻页 =====
  function show(page) {
    index = clamp(page, 0, Math.max(0, count - 1));
    track.style.setProperty("--index", String(index));
    counter.textContent = count ? `${index + 1}/${count}` : "";
    prevButton.disabled = index <= 0;
    nextButton.disabled = index >= count - 1;
    [...track.children].forEach((slide, page) => slide.setAttribute("aria-hidden", String(page !== index)));
    [...dots.children].forEach((dot, page) => dot.classList.toggle("is-current", page === index));
  }

  prevButton.addEventListener("click", () => show(index - 1));
  nextButton.addEventListener("click", () => show(index + 1));

  // 键盘：焦点在轮播里时 ← → 翻页（不再交给舞台去翻后面藏着的大卡片）
  carousel.addEventListener("keydown", (event) => {
    const step = { ArrowLeft: -1, ArrowRight: 1 }[event.key];
    if (!step) return;
    event.preventDefault();
    event.stopPropagation();
    show(index + step);
  });

  // 触控板横扫：一次手势翻一页
  let wheelTravel = 0;
  let wheelDone = false;
  let wheelTimer = 0;
  carousel.addEventListener("wheel", (event) => {
    if (Math.abs(event.deltaX) <= Math.abs(event.deltaY)) return;
    event.preventDefault();
    clearTimeout(wheelTimer);
    wheelTimer = setTimeout(() => {
      wheelTravel = 0;
      wheelDone = false;
    }, WHEEL_SETTLE);
    if (wheelDone) return;
    wheelTravel += event.deltaX;
    if (Math.abs(wheelTravel) < SWIPE_DISTANCE) return;
    wheelDone = true;
    show(index + Math.sign(wheelTravel));
  }, { passive: false });

  // 按住拖动：卡片跟着手走，松手超过一段距离就翻页；拖过之后那一下不算点按。
  // 拖出轮播也要跟着，所以按下后在整个窗口上听移动与松手。
  let drag = null;
  let swallowClick = false;
  function moveDrag(event) {
    if (event.pointerId !== drag.id) return;
    const distance = event.clientX - drag.x;
    if (!drag.moving && Math.abs(distance) < 4) return;
    drag.moving = true;
    carousel.classList.add("is-dragging");
    track.style.setProperty("--drag", `${distance / scale}px`);
  }
  function endDrag(event) {
    if (event.pointerId !== drag.id) return;
    window.removeEventListener("pointermove", moveDrag);
    window.removeEventListener("pointerup", endDrag);
    window.removeEventListener("pointercancel", endDrag);
    const distance = event.clientX - drag.x;
    if (drag.moving) {
      swallowClick = true;
      carousel.classList.remove("is-dragging");
      track.style.removeProperty("--drag");
      if (event.type === "pointerup" && Math.abs(distance) >= SWIPE_DISTANCE) show(index - Math.sign(distance));
    }
    drag = null;
  }
  carousel.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || drag) return;
    // 点过、拖过之后接着就能用 ← → 翻（点按钮在 macOS 上不会把焦点给它）
    carousel.focus({ preventScroll: true });
    swallowClick = false;
    drag = { id: event.pointerId, x: event.clientX, moving: false };
    window.addEventListener("pointermove", moveDrag);
    window.addEventListener("pointerup", endDrag);
    window.addEventListener("pointercancel", endDrag);
  });
  carousel.addEventListener("click", (event) => {
    if (!swallowClick) return;
    swallowClick = false;
    event.preventDefault();
    event.stopPropagation();
  }, true);

  // ===== 事件 =====
  // 长文模式没有卡片：关掉手机预览，按钮停用
  mc.on("rendered", ({ mode }) => {
    const cards = mode === "cards";
    toggle.disabled = !cards;
    if (!cards && open) setOpen(false);
    if (open) void sync();
  });
  mc.on("change", () => {
    if (open) void sync();
  });
})();
