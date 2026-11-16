// 第一次打开时的新手引导：四步，每步用一圈高亮指着界面上的真按钮讲一句话。
// 只在还没有自己的稿子时出现；看完或跳过（按钮或 Esc）都记在本机，以后不再弹。
// 引导不挡操作：高亮以外的地方照常能点，第一步点「新建稿件」就直接进入下一步。
(() => {
  const STORAGE_KEY = "mediacraft.onboarding.v1";
  const MARGIN = 12;
  const GAP = 14;

  // spot：依次试这些选择器，用第一组看得见的元素（一组里有几个就圈住它们合起来的范围）。
  // advanceOn：点了这个控件就进入下一步。
  // body：一句说明；给一组时和 spot 一一对应（圈住的是第几组就说第几句），说的总是眼前圈着的东西。
  const STEPS = [
    {
      // 稿件抽屉头上的两个按钮一起圈住；点哪个都进入下一步。抽屉收着时圈的是「稿件列表」，
      // 那两个按钮还看不见：先说点开它，点开以后圈和说明都换成两个按钮的
      spot: ["#templateGalleryBtn, #newDraftBtn", "#draftsToggleBtn"],
      advanceOn: "#newDraftBtn, #templateGalleryBtn",
      title: "新建，或从模板开始",
      body: [
        "稿件栏里有三本只读的说明书，随时能翻回来看。点 + 开一篇空白稿子，或点旁边的「从模板新建」挑一套写好的改。",
        "点这里打开稿件栏：里面有三本只读的说明书，随时能翻回来看；栏头的 + 开一篇空白稿子，旁边的「从模板新建」挑一套写好的改。",
      ],
    },
    {
      spot: ["#markdownEditor"],
      title: "像写文档一样写",
      body: "看到的就是排好的样子，光标所在的行才露出标记。行首输入 / 插图片、实况、分页，⌘/ 看源码。",
    },
    {
      spot: ["#themeButton", "#themeOptions"],
      title: "挑一个主题",
      body: "主题面板里一键换，卡片结构和配色一起换。缩略图画的是你自己的第一页，还标着会排成几页。",
    },
    // 没有隔空投送的壳（Windows）：手机扫码接收
    window.MediaCraftNative?.capabilities?.phoneTransfer
      ? {
          spot: ["#aiButton, #exportActions"],
          title: "发到手机，或让 AI 帮忙",
          body: "「发送到手机」弹出二维码，手机扫码接收卡片和正文。AI 用这台电脑上的 Claude Code 或 Codex 润色，改动逐处确认。",
        }
      : {
          spot: ["#aiButton, #exportActions"],
          title: "发到 iPhone，或让 AI 帮忙",
          body: "「发送到 iPhone」按页序隔空投送，正文同时进剪贴板。AI 用你 Mac 上的 Codex 或 Claude Code 润色，改动逐处确认。",
        },
  ];

  let tour = null;

  function remembered() {
    try {
      return localStorage.getItem(STORAGE_KEY) === "done";
    } catch {
      return false;
    }
  }

  function remember() {
    try {
      localStorage.setItem(STORAGE_KEY, "done");
    } catch {
      // 存不进去只是下次再弹一次
    }
  }

  const visible = (element) => element.getClientRects().length > 0 && getComputedStyle(element).visibility !== "hidden";

  function spotRect(step) {
    for (const [index, selector] of step.spot.entries()) {
      const rects = [...document.querySelectorAll(selector)].filter(visible).map((element) => element.getBoundingClientRect());
      if (!rects.length) continue;
      // 几处合起来的外框
      const box = {
        left: Math.min(...rects.map((rect) => rect.left)),
        top: Math.min(...rects.map((rect) => rect.top)),
        right: Math.max(...rects.map((rect) => rect.right)),
        bottom: Math.max(...rects.map((rect) => rect.bottom)),
      };
      return { ...box, width: box.right - box.left, height: box.bottom - box.top, index };
    }
    return null;
  }

  // 这一步现在该说的那句：圈住的是 spot 里的第几组，就说 body 里的第几句
  function bodyOf(step, rect) {
    const body = Array.isArray(step.body) ? step.body[rect?.index ?? 0] ?? step.body[0] : step.body;
    return window.MediaCraftPlatform.keys(body);
  }

  function build() {
    const layer = document.createElement("div");
    layer.className = "onboarding";
    layer.innerHTML = `
      <div class="onboarding-dim" aria-hidden="true"></div>
      <div class="onboarding-spot" aria-hidden="true"></div>
      <section class="onboarding-card" role="dialog" aria-modal="false" aria-labelledby="onboardingTitle" aria-describedby="onboardingBody">
        <span class="onboarding-tail" aria-hidden="true"></span>
        <p class="onboarding-kicker"><span>新手引导</span><span data-onboarding-count></span></p>
        <div aria-live="polite">
          <h2 id="onboardingTitle" class="onboarding-title"></h2>
          <p id="onboardingBody" class="onboarding-body"></p>
        </div>
        <div class="onboarding-dots" aria-hidden="true">${STEPS.map(() => "<span></span>").join("")}</div>
        <div class="onboarding-buttons">
          <button class="text-button" type="button" data-onboarding="skip">跳过</button>
          <span class="onboarding-spacer"></span>
          <button class="pill-button" type="button" data-onboarding="back">上一步</button>
          <button class="primary-button" type="button" data-onboarding="next">下一步</button>
        </div>
      </section>`;
    document.body.append(layer);
    return {
      layer,
      dim: layer.querySelector(".onboarding-dim"),
      spot: layer.querySelector(".onboarding-spot"),
      card: layer.querySelector(".onboarding-card"),
      arrow: layer.querySelector(".onboarding-tail"),
      count: layer.querySelector("[data-onboarding-count]"),
      title: layer.querySelector(".onboarding-title"),
      body: layer.querySelector(".onboarding-body"),
      dots: [...layer.querySelectorAll(".onboarding-dots span")],
      back: layer.querySelector('[data-onboarding="back"]'),
      next: layer.querySelector('[data-onboarding="next"]'),
      skip: layer.querySelector('[data-onboarding="skip"]'),
    };
  }

  // 卡片放在高亮的下方、上方、右边或左边，哪边放得下用哪边；都放不下就放在窗口正中。
  function placeCard(ui, rect) {
    const card = ui.card.getBoundingClientRect();
    const room = {
      bottom: innerHeight - rect.bottom - GAP - MARGIN >= card.height,
      top: rect.top - GAP - MARGIN >= card.height,
      right: innerWidth - rect.right - GAP - MARGIN >= card.width,
      left: rect.left - GAP - MARGIN >= card.width,
    };
    const side = ["bottom", "top", "right", "left"].find((name) => room[name]) ?? "center";
    const clamp = (value, max) => Math.min(Math.max(value, MARGIN), max - MARGIN);
    const centerX = rect.left + rect.width / 2;
    const centerY = rect.top + Math.min(rect.height, innerHeight) / 2;
    let left;
    let top;
    if (side === "bottom" || side === "top") {
      left = clamp(centerX - card.width / 2, innerWidth - card.width);
      top = side === "bottom" ? rect.bottom + GAP : rect.top - GAP - card.height;
      ui.arrow.style.left = `${Math.min(Math.max(centerX - left, 20), card.width - 20)}px`;
      ui.arrow.style.top = "";
    } else if (side === "right" || side === "left") {
      left = side === "right" ? rect.right + GAP : rect.left - GAP - card.width;
      top = clamp(centerY - card.height / 2, innerHeight - card.height);
      ui.arrow.style.top = `${Math.min(Math.max(centerY - top, 20), card.height - 20)}px`;
      ui.arrow.style.left = "";
    } else {
      left = (innerWidth - card.width) / 2;
      top = (innerHeight - card.height) / 2;
    }
    ui.card.dataset.side = side;
    ui.card.style.left = `${Math.round(left)}px`;
    ui.card.style.top = `${Math.round(top)}px`;
  }

  function layout() {
    if (!tour) return;
    const rect = spotRect(STEPS[tour.index]);
    // 圈住的东西换了（第一步里点开了稿件栏）：说明跟着换
    const body = bodyOf(STEPS[tour.index], rect);
    if (tour.ui.body.textContent !== body) tour.ui.body.textContent = body;
    tour.ui.spot.hidden = !rect;
    tour.ui.dim.style.clipPath = "";
    if (rect) {
      const [left, top, right, bottom] = [rect.left - 4, rect.top - 4, rect.right + 4, rect.bottom + 4];
      Object.assign(tour.ui.spot.style, { left: `${left}px`, top: `${top}px`, width: `${right - left}px`, height: `${bottom - top}px` });
      // 整屏减去高亮的那一块（奇偶规则挖洞）
      tour.ui.dim.style.clipPath =
        `polygon(evenodd, 0 0, 100% 0, 100% 100%, 0 100%, 0 0, ${left}px ${top}px, ${right}px ${top}px, ${right}px ${bottom}px, ${left}px ${bottom}px, ${left}px ${top}px)`;
    }
    placeCard(tour.ui, rect ?? { left: innerWidth / 2, top: innerHeight / 2, right: innerWidth / 2, bottom: innerHeight / 2, width: 0, height: 0 });
  }

  // 界面动了（窗口缩放、抽屉开合、滚动）就重新对准；同一帧里只算一次。
  // 窗口看不见时不跑 requestAnimationFrame：垫一个定时器，谁先到谁算。
  function scheduleLayout() {
    if (!tour || tour.frame) return;
    const run = () => {
      if (!tour || !tour.frame) return;
      cancelAnimationFrame(tour.frame);
      clearTimeout(tour.timer);
      tour.frame = 0;
      layout();
    };
    tour.frame = requestAnimationFrame(run);
    tour.timer = setTimeout(run, 120);
  }

  function show(index) {
    const { ui } = tour;
    const step = STEPS[index];
    const last = index === STEPS.length - 1;
    tour.index = index;
    ui.count.textContent = `${index + 1} / ${STEPS.length}`;
    ui.title.textContent = step.title;
    ui.body.textContent = bodyOf(step, spotRect(step));
    ui.dots.forEach((dot, dotIndex) => dot.classList.toggle("is-current", dotIndex === index));
    // 回到第一步时「上一步」藏起来，焦点在它上面就挪到「下一步」
    const backFocused = document.activeElement === ui.back;
    ui.back.hidden = index === 0;
    if (ui.back.hidden && backFocused) ui.next.focus({ preventScroll: true });
    ui.next.textContent = last ? "开始使用" : "下一步";
    layout();
  }

  // 换一步：卡片从上一处滑到这一处，压暗层的洞跟着挪（onboarding.css），高亮圈到位后淡入
  function go(offset) {
    const index = tour.index + offset;
    if (index >= STEPS.length) close();
    else if (index >= 0) {
      MediaCraftMotion.flip([tour.ui.card], () => show(index));
      MediaCraftMotion.play(tour.ui.spot, [{ opacity: 0 }, { opacity: 1 }], { delay: 120 });
    }
  }

  // 看完、跳过都算看过。焦点在引导里时还给打开前的控件；你已经点到别处了就不抢。
  function close() {
    if (!tour) return;
    remember();
    const { ui, frame, timer, listeners, observer, returnFocus } = tour;
    const focusInside = ui.card.contains(document.activeElement);
    cancelAnimationFrame(frame);
    clearTimeout(timer);
    for (const [target, type, listener] of listeners) target.removeEventListener(type, listener, true);
    observer.disconnect();
    ui.layer.remove();
    tour = null;
    if (focusInside && returnFocus?.isConnected) returnFocus.focus({ preventScroll: true });
  }

  function onKeydown(event) {
    const action = { Escape: close, ArrowRight: () => go(1), ArrowLeft: () => go(-1) }[event.key];
    if (!action) return;
    event.preventDefault();
    action();
  }

  function onClick(event) {
    const step = STEPS[tour.index];
    // 等这次点击自己的处理（比如新建稿子）先做完，再翻到下一步
    if (step.advanceOn && event.target.closest?.(step.advanceOn)) setTimeout(() => tour && go(1));
    scheduleLayout();
  }

  function open() {
    const ui = build();
    const listeners = [
      [window, "resize", scheduleLayout],
      [window, "scroll", scheduleLayout],
      [document, "transitionend", scheduleLayout],
      [document, "click", onClick],
    ];
    for (const [target, type, listener] of listeners) target.addEventListener(type, listener, true);
    const observer = new ResizeObserver(scheduleLayout);
    observer.observe(document.documentElement);
    tour = { ui, index: 0, frame: 0, timer: 0, listeners, observer, returnFocus: document.activeElement };
    ui.card.addEventListener("keydown", onKeydown);
    ui.skip.addEventListener("click", close);
    ui.back.addEventListener("click", () => go(-1));
    ui.next.addEventListener("click", () => go(1));
    show(0);
    ui.next.focus({ preventScroll: true });
  }

  // 应用打开、稿子就绪之后调用：firstRun 是这台 Mac 上还没有自己的稿子。
  function start({ firstRun }) {
    if (firstRun && !tour && !remembered()) open();
  }

  window.MediaCraftOnboarding = { start };
})();
