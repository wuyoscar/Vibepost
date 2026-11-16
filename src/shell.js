// 界面骨架的交互：检查器标签、舞台翻页与胶片、滑杆与色块读数、顶栏主题按钮、窗口外框（稿件抽屉在 src/drafts/drawer.js）。
// 只通过 App API（window.mediacraft）和界面元素工作，不碰 src/app.js 的内部名字。
(() => {
  const mc = window.mediacraft;
  const motion = window.MediaCraftMotion;
  const $ = (selector) => document.querySelector(selector);
  const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
  const visible = (element) => element.getClientRects().length > 0;

  // ===== 检查器：样式 / AI 助手 =====
  const tabs = [...document.querySelectorAll('.inspector [role="tab"]')];
  const styleTab = $("#styleTab");
  const aiTab = $("#aiTab");
  const aiButton = $("#aiButton");

  function selectTab(tab, { focus = false } = {}) {
    for (const item of tabs) {
      const selected = item === tab;
      item.setAttribute("aria-selected", String(selected));
      item.tabIndex = selected ? 0 : -1;
      document.getElementById(item.getAttribute("aria-controls")).hidden = !selected;
    }
    aiButton.setAttribute("aria-pressed", String(tab === aiTab));
    if (focus) tab.focus();
  }

  for (const tab of tabs) tab.addEventListener("click", () => selectTab(tab));
  styleTab.parentElement.addEventListener("keydown", (event) => {
    const index = tabs.indexOf(document.activeElement);
    const moves = { ArrowLeft: index - 1, ArrowRight: index + 1, Home: 0, End: tabs.length - 1 };
    if (index === -1 || !Object.hasOwn(moves, event.key)) return;
    event.preventDefault();
    selectTab(tabs[(moves[event.key] + tabs.length) % tabs.length], { focus: true });
  });
  aiButton.addEventListener("click", () => selectTab(aiButton.getAttribute("aria-pressed") === "true" ? styleTab : aiTab));
  // AI 助手顶上的「+」开的新窗口（地址带 panel=ai）：一开就是 AI 助手
  if (new URLSearchParams(location.search).get("panel") === "ai") selectTab(aiTab);

  // ===== 顶栏：稿件名、主题按钮 =====
  const themeButton = $("#themeButton");
  const themeList = mc.themes.list();

  themeButton.addEventListener("click", () => {
    selectTab(styleTab);
    const current = $('#themeOptions [aria-pressed="true"]');
    current?.scrollIntoView({ block: "nearest" });
    current?.focus();
  });

  // 稿件名下面那行状态（「已插入 2 张图片」「已打开：……」）说完就退场：新的一句出现几秒后淡出、让出那一行，
  // 稿件名滑回正中。只是看不见了，文字还留在元素里（谁写的、写了什么都不用管）；再有新的一句就重新显出来。
  const statusLine = $("#statusText");
  const draftHeading = $("#draftHeading");
  const STATUS_LINGER = 6000;
  let statusTimer = 0;
  new MutationObserver(() => {
    clearTimeout(statusTimer);
    if (statusLine.classList.contains("is-settled")) motion.flip([draftHeading], () => statusLine.classList.remove("is-settled"));
    if (!statusLine.textContent) return;
    statusTimer = setTimeout(() => motion.flip([draftHeading], () => statusLine.classList.add("is-settled")), STATUS_LINGER);
  }).observe(statusLine, { childList: true, characterData: true, subtree: true });

  async function syncDraftChrome() {
    const [draft, drafts, themes] = await Promise.all([mc.drafts.current(), mc.drafts.list(), themeList]);
    $("#draftHeading").textContent = drafts.find((item) => item.current)?.title || "未命名稿件";
    const theme = themes.find((item) => item.id === draft.theme);
    $("#themeButtonName").textContent = theme?.name ?? "";
    themeButton.setAttribute("aria-label", `主题：${theme?.name ?? ""}`);
    themeButton.style.setProperty("--dot-bg", draft.colors.bg);
    themeButton.style.setProperty("--dot-accent", draft.colors.accent);
    const themed = theme && Object.keys(theme.colors).every((key) => theme.colors[key] === draft.colors[key]);
    $("#resetColorsBtn").disabled = draft.readOnly || Boolean(themed);
  }

  // 恢复主题配色：和套用一组配色一样，是撤销历史里的一步。只给主题的三色，辅助、衬底按三色规则推回主题的值，
  // 也回到「没单独调过」（跟着背景与文字走）
  $("#resetColorsBtn").addEventListener("click", async () => {
    const draft = await mc.drafts.current();
    const theme = (await themeList).find((item) => item.id === draft.theme);
    if (theme) await mc.palettes.apply({ bg: theme.colors.bg, text: theme.colors.text, accent: theme.colors.accent });
  });

  // ===== 滑杆与色块的读数 =====
  const readouts = [...document.querySelectorAll("output[for]")].map((output) => ({
    output,
    input: document.getElementById(output.htmlFor.value),
  }));

  function syncReadouts() {
    for (const { output, input } of readouts) {
      if (input.type === "range") {
        const fill = ((Number(input.value) - Number(input.min)) / (Number(input.max) - Number(input.min))) * 100;
        input.style.setProperty("--fill", `${fill}%`);
        output.value = input.step.includes(".") ? Number(input.value).toFixed(2) : input.value;
      } else {
        output.value = input.value;
      }
    }
    window.MediaCraftSteppers?.sync();
  }
  for (const { input } of readouts) input.addEventListener("input", syncReadouts);
  // 滑杆旁的读数换成能输入的数值框（src/workspace/steppers.js），各节能收起（src/workspace/sections.js）
  const stylePanel = $("#stylePanel");
  window.MediaCraftSteppers.enhance(stylePanel);
  window.MediaCraftSections.create(stylePanel);


  // ===== 舞台：一次看一张大卡片，上一张 / 下一张、胶片、跟着光标走 =====
  const viewport = $("#stageScroller");
  const pagesRoot = $("#stageCards");
  const filmstrip = $("#filmstrip");
  const pageLabel = $("#stagePageLabel");
  const prevButton = $("#prevPageBtn");
  const nextButton = $("#nextPageBtn");
  const editor = $("#markdownEditor");
  const shells = () => pagesRoot.querySelectorAll(".stage-card");
  let current = 0;
  // 每页正文在 Markdown 里的起点，用来找光标所在的那一页
  let pageStarts = [];

  function syncStageNav() {
    const total = shells().length;
    pageLabel.textContent = total ? `第 ${current + 1} 张 · 共 ${total} 张` : "还没有卡片";
    prevButton.disabled = current <= 0;
    nextButton.disabled = current >= total - 1;
    [...filmstrip.children].forEach((thumb, index) => thumb.setAttribute("aria-current", String(index === current)));
    filmstrip.children[current]?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  // 翻页直接跳到那一张（像幻灯片的缩略图导航），不做长距离滚动动画；
  // 跳过去的这一张从翻页的方向横着滑进来（往后翻从右边来），胶片上的框跟着滑过去（motion.track）。
  function showPage(index) {
    const list = shells();
    if (!list.length) return;
    const previous = current;
    current = clamp(index, 0, list.length - 1);
    viewport.scrollTop = list[current].offsetTop;
    syncStageNav();
    const direction = Math.sign(current - previous);
    if (direction) {
      motion.play(list[current].querySelector(".card-frame"), [
        { transform: `translateX(${direction * 32}px)`, opacity: 0.4 },
        { transform: "none", opacity: 1 },
      ], { easing: "decelerate" });
    }
  }

  prevButton.addEventListener("click", () => showPage(current - 1));
  nextButton.addEventListener("click", () => showPage(current + 1));
  $("#previewPanel").addEventListener("keydown", (event) => {
    if (document.body.dataset.layoutMode === "article") return;
    if (event.target.closest("input, textarea, select, .stage-media")) return;
    const step = { ArrowLeft: -1, ArrowRight: 1 }[event.key];
    if (!step) return;
    event.preventDefault();
    showPage(current + step);
  });

  let scrollFrame = 0;
  viewport.addEventListener("scroll", () => {
    if (document.body.dataset.layoutMode === "article") return;
    cancelAnimationFrame(scrollFrame);
    scrollFrame = requestAnimationFrame(() => {
      const list = [...shells()];
      if (!list.length) return;
      const middle = viewport.scrollTop + viewport.clientHeight / 2;
      const nearest = list.findIndex((shell) => shell.offsetTop + shell.offsetHeight > middle);
      const next = nearest === -1 ? list.length - 1 : nearest;
      if (next === current) return;
      current = next;
      syncStageNav();
    });
  });

  function pageAtCaret(caret) {
    let page = 0;
    pageStarts.forEach((start, index) => {
      if (start <= caret) page = index;
    });
    return page;
  }

  async function followCaret() {
    if (!editor.contains(document.activeElement) || !pageStarts.length) return;
    const page = pageAtCaret((await mc.editor.selection()).start);
    if (page !== current) showPage(page);
  }

  let caretTimer = 0;
  document.addEventListener("selectionchange", () => {
    if (!editor.contains(document.activeElement)) return;
    clearTimeout(caretTimer);
    caretTimer = setTimeout(followCaret, 150);
  });

  motion.track(filmstrip, '[aria-current="true"]');

  // 先按舞台上的页数摆好缩略图的按钮，再等画布有像素了画上去（HTML 卡片要出图后才有）
  async function renderFilmstrip() {
    placeThumbs(document.querySelectorAll("#stageCards .stage-card").length);
    // 小图直接从 PNG 缩，不要整页画布（十几页就是几百 MB）
    const thumbs = await mc.render.thumbnails({ width: 120, height: 160 });
    placeThumbs(thumbs.length);
    thumbs.forEach((source, index) => {
      const context = filmstrip.children[index].firstElementChild.getContext("2d");
      context.drawImage(source, 0, 0, 120, 160);
    });
  }

  function placeThumbs(count) {
    while (filmstrip.children.length > count) filmstrip.lastElementChild.remove();
    for (let index = 0; index < count; index += 1) {
      let thumb = filmstrip.children[index];
      if (!thumb) {
        thumb = document.createElement("button");
        thumb.type = "button";
        thumb.className = "film-thumb";
        const canvas = document.createElement("canvas");
        canvas.width = 120;
        canvas.height = 160;
        thumb.append(canvas);
        thumb.addEventListener("click", () => showPage([...filmstrip.children].indexOf(thumb)));
        filmstrip.append(thumb);
      }
      thumb.setAttribute("aria-label", `第 ${index + 1} 张`);
    }
  }

  // 胶片上每张正文卡的字数与填满多少：缩略图底边一条细条（长短是填满多少）、右下角字数，偏空、偏挤时换色；悬停时说明。
  // 一张 180–280 字读起来最舒服；末张太短时排版会从前一张回填（src/cards/paginate.js 的末页回填）。
  const { SPARSE_FILL, DENSE_CHARS } = window.MediaCraftLayoutCheck;

  function fillNote(page, index, bodyPages) {
    const label = `第 ${index + 1} 张`;
    if (page.role === "cover") return { density: "cover", count: "封面", note: `${label} · 封面：标题取自标题框，版式随主题` };
    if (page.role === "end") return { density: "end", count: "结尾", note: `${label} · 结尾页：[[结尾]] 之后的内容与署名` };
    const stats = `${label} · ${page.chars} 字 · 填满 ${Math.round(page.fill * 100)}%`;
    if (bodyPages > 1 && page.fill < SPARSE_FILL) {
      return { density: "sparse", count: String(page.chars), note: `${stats}\n偏空：不到四分之一张。末张太短会自动从前一张挪几段下来；挪不动时多半是 [[分页]]、大图或实况换页留下的` };
    }
    if (page.chars > DENSE_CHARS) {
      return { density: "dense", count: String(page.chars), note: `${stats}\n偏挤：一张 180–280 字读起来最舒服，可以加一个 [[分页]] 或删几句` };
    }
    return { density: "ok", count: String(page.chars), note: stats };
  }

  function showFill(pages) {
    const bodyPages = pages.filter((page) => page.role === "body").length;
    pages.forEach((page, index) => {
      const thumb = filmstrip.children[index];
      if (!thumb) return;
      let meter = thumb.querySelector(".film-meter");
      if (!meter) {
        meter = document.createElement("span");
        meter.className = "film-meter";
        meter.setAttribute("aria-hidden", "true");
        meter.append(Object.assign(document.createElement("span"), { className: "film-meter-bar" }), Object.assign(document.createElement("span"), { className: "film-meter-count" }));
        thumb.append(meter);
      }
      const { density, count, note } = fillNote(page, index, bodyPages);
      meter.dataset.density = density;
      meter.style.setProperty("--fill", String(page.fill ?? 0));
      meter.lastElementChild.textContent = count;
      thumb.title = note;
    });
  }

  // 停笔片刻再读分页（读分页会把还没到点的出图提前）：连续打字时一直往后推。
  const PAGE_MAP_DELAY = 250;
  let renderCount = 0;
  let pageMapTimer = 0;

  async function refreshPageStarts() {
    const seen = renderCount;
    const pages = await mc.render.pages();
    if (seen !== renderCount) return;
    pageStarts = pages.map((page) => Math.min(...page.items.map((item) => item.source?.[0] ?? Infinity)));
    showFill(pages);
    void followCaret();
  }

  function schedulePageMap() {
    clearTimeout(pageMapTimer);
    pageMapTimer = setTimeout(refreshPageStarts, PAGE_MAP_DELAY);
  }
  editor.addEventListener("input", schedulePageMap);

  // 每次出图都会整组换掉页面：先回到刚才看的那张，停笔后再跟到光标所在页。
  // 图文卡片 ↔ 长文换了排版：新的舞台内容淡入。
  let shownMode = null;
  mc.on("rendered", async ({ mode }) => {
    renderCount += 1;
    if (shownMode && mode !== shownMode) motion.play(pagesRoot, [{ opacity: 0 }, { opacity: 1 }]);
    shownMode = mode;
    syncReadouts();
    void syncDraftChrome();
    if (mode !== "cards") {
      clearTimeout(pageMapTimer);
      if (filmstrip.children.length) viewport.scrollTop = 0;
      filmstrip.replaceChildren();
      pageStarts = [];
      return;
    }
    showPage(current);
    try {
      await renderFilmstrip();
    } catch (error) {
      console.warn("胶片没画出来", error); // 出图出错时舞台照常，缩略图下次出图再补
    }
    syncStageNav();
    schedulePageMap();
  });
  mc.on("change", () => void syncDraftChrome());

  // ===== 窗口外框（只在 App 里开了毛玻璃时）：可拖区域 =====
  const windowChrome = window.MediaCraftNative?.windowChrome;
  if (windowChrome) {
    const titlebar = $("[data-window-drag]");
    const rect = (element) => {
      const box = element.getBoundingClientRect();
      return [box.left, box.top, box.width, box.height];
    };
    // 布局变化往往一连串，合并成一次报告
    let chromeTimer = 0;
    const reportDragRegions = () => {
      clearTimeout(chromeTimer);
      chromeTimer = setTimeout(() => {
        const covered = document.querySelector(".modal:not(.hidden)") !== null;
        const controls = titlebar.querySelectorAll("button, input, summary, a[href], [role='button']");
        windowChrome({ drag: covered ? [] : [rect(titlebar)], noDrag: [...controls].filter(visible).map(rect) });
      }, 30);
    };
    new ResizeObserver(reportDragRegions).observe(titlebar);
    new MutationObserver(reportDragRegions).observe(titlebar, { subtree: true, childList: true, attributes: true, attributeFilter: ["hidden", "disabled"] });
    for (const modal of document.querySelectorAll(".modal")) {
      new MutationObserver(reportDragRegions).observe(modal, { attributes: true, attributeFilter: ["class"] });
    }
    // 进出全屏时红绿灯让出的位置变了，按钮跟着挪（窗口的深浅外观跟随系统，页面不管）
    new MutationObserver(reportDragRegions).observe(document.documentElement, { attributes: true, attributeFilter: ["data-fullscreen"] });
    void document.fonts.ready.then(reportDragRegions);
    reportDragRegions();
  }

  syncReadouts();
  void syncDraftChrome();
})();
