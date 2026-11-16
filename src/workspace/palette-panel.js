// 检查器「配色」的两个弹出面板（下拉菜单的共同行为见 src/workspace/menus.js：同时只开一个、点外面或按 Esc 收起）：
// - 配色库：分类、「适合当前主题」、每组一张迷你卡片（点一下套用到这篇，⌘Z 撤回），「我的配色」的存与删；
// - 色轮：取基准色、选配色规则，拖把手时舞台实时预览（节流），显示对比度；也可以粘贴一串色值分给五个角色；「应用」「取消」。
// 只通过 App API（window.mediacraft）、配色的纯计算（MediaCraftPalettes）与界面元素工作，不碰 src/app.js 的内部名字。
(() => {
  const mc = window.mediacraft;
  const palettes = window.MediaCraftPalettes;
  // 五个角色的名字与对比度门槛（src/engine/colors.js）
  const { ROLE_INFO, CONTRAST, oklchToRgb } = window.MediaCraftEngine.colors;
  const status = document.getElementById("statusText");
  const ALL = "all";

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function button(className, text, label) {
    const node = element("button", className, text);
    node.type = "button";
    if (label) node.setAttribute("aria-label", label);
    return node;
  }

  function icon(id) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "icon icon-small");
    svg.setAttribute("aria-hidden", "true");
    const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
    use.setAttribute("href", `#${id}`);
    svg.append(use);
    return svg;
  }

  const report = (error) => {
    status.textContent = error.message || String(error);
  };

  // 当前稿子与它的主题：主题卡片底色的深浅决定「适合当前主题」
  async function currentLook() {
    const [draft, themes] = await Promise.all([mc.drafts.current(), mc.themes.list()]);
    const theme = themes.find((item) => item.id === draft.theme);
    return { draft, tone: palettes.toneOf(theme.colors) };
  }

  // ===== 配色库 =====
  (() => {
    const menu = document.getElementById("paletteLibrary");
    const popover = menu.querySelector(".pop-menu-panel");
    let category = ALL;
    let suitableOnly = false;
    let list = [];
    let look = null;

    const head = element("div", "palette-head");
    const title = element("h3", "palette-title", "配色库");
    const suitable = button("chip chip-small", "适合当前主题");
    suitable.setAttribute("aria-pressed", "false");
    suitable.title = "只看和当前主题深浅一致的配色";
    head.append(title, suitable);

    const categories = element("div", "palette-categories");
    categories.setAttribute("role", "group");
    categories.setAttribute("aria-label", "配色分类");
    const categoryButtons = [{ id: ALL, name: "全部" }, ...palettes.CATEGORIES, palettes.MINE].map(({ id, name }) => {
      const chip = button("chip chip-small", name);
      chip.dataset.category = id;
      chip.setAttribute("aria-pressed", String(id === category));
      chip.addEventListener("click", () => {
        category = id;
        render();
      });
      categories.append(chip);
      return chip;
    });

    const scroller = element("div", "palette-list");
    const save = element("form", "palette-save");
    const nameInput = element("input", "palette-input");
    nameInput.type = "text";
    nameInput.maxLength = 24;
    nameInput.placeholder = "给当前配色起个名字";
    nameInput.setAttribute("aria-label", "配色名字");
    const saveButton = element("button", "pill-button", "存到我的配色");
    saveButton.type = "submit";
    save.append(nameInput, saveButton);
    popover.append(head, categories, scroller, save);

    // 迷你卡片：底色上一条辅助色的标题、两行文字、一块衬底，衬底里一点强调色
    function miniCard(colors) {
      const card = element("span", "mini-card");
      for (const role of palettes.ROLES) card.style.setProperty(`--mini-${role}`, colors[role]);
      const block = element("span", "mini-block");
      block.append(element("span", "mini-accent"));
      card.append(element("span", "mini-heading"), element("span", "mini-line"), element("span", "mini-line mini-short"), block);
      card.setAttribute("aria-hidden", "true");
      return card;
    }

    // 一格：迷你卡片，下面是名字与「深 / 浅」。现在用的这一组标 aria-current（套用不是开关，不用 aria-pressed）
    function tile(palette) {
      const item = element("div", "palette-item");
      const dark = palette.tone === "dark";
      const tileButton = button("palette-tile", undefined, palette.name);
      tileButton.dataset.paletteId = palette.id;
      tileButton.title = `${palette.name} · ${dark ? "深色" : "浅色"}`;
      if (palettes.same(palette.colors, look.draft.colors)) tileButton.setAttribute("aria-current", "true");
      const tone = element("span", "palette-tone", dark ? "深" : "浅");
      tone.id = `palette-tone-${palette.id}`;
      tone.dataset.tone = palette.tone;
      tileButton.setAttribute("aria-describedby", tone.id);
      const caption = element("span", "palette-caption");
      caption.append(element("span", "palette-name", palette.name), tone);
      tileButton.append(miniCard(palette.colors), caption);
      tileButton.addEventListener("click", () => {
        // 套用后稿子存盘会发 change，下面跟着标出现在用的这一组
        mc.palettes.apply(palette.id)
          .then(() => {
            status.textContent = `已套用配色「${palette.name}」，${window.MediaCraftPlatform.keys("⌘Z")} 可以撤回`;
          })
          .catch(report);
      });
      item.append(tileButton);
      if (!palette.builtIn) {
        const remove = button("icon-button palette-remove", undefined, `删除「${palette.name}」`);
        remove.title = "从我的配色里删掉";
        remove.append(icon("i-close"));
        remove.addEventListener("click", () => {
          mc.palettes.remove(palette.id)
            .then(() => {
              status.textContent = `已从我的配色里删掉「${palette.name}」`;
              return refresh();
            })
            .catch(report);
        });
        item.append(remove);
      }
      return item;
    }

    // 深浅和当前主题一致的排在前面；「适合当前主题」打开时只留这些
    function arrange(items) {
      const fitting = items.filter((palette) => palette.tone === look.tone);
      return suitableOnly ? fitting : [...fitting, ...items.filter((palette) => palette.tone !== look.tone)];
    }

    function group(name, items, empty) {
      const section = element("section", "palette-group");
      const label = element("h4", "palette-group-label", name);
      section.append(label);
      const shown = arrange(items);
      if (!shown.length) {
        section.append(element("p", "section-note", empty));
        return section;
      }
      const grid = element("div", "palette-grid");
      grid.append(...shown.map(tile));
      section.append(grid);
      return section;
    }

    function render() {
      suitable.setAttribute("aria-pressed", String(suitableOnly));
      for (const chip of categoryButtons) chip.setAttribute("aria-pressed", String(chip.dataset.category === category));
      const groups = [...palettes.CATEGORIES, palettes.MINE].filter(({ id }) => category === ALL || id === category);
      const scrollTop = scroller.scrollTop;
      scroller.replaceChildren(...groups.map(({ id, name }) => group(
        name,
        list.filter((palette) => palette.category === id),
        id === palettes.MINE.id ? "还没有存过配色：调好颜色后在下面起个名字，点「存到我的配色」。" : "这一类里没有和当前主题深浅一致的配色。",
      )));
      scroller.scrollTop = scrollTop;
    }

    async function refresh() {
      [list, look] = await Promise.all([mc.palettes.list(), currentLook()]);
      render();
    }

    suitable.addEventListener("click", () => {
      suitableOnly = !suitableOnly;
      render();
    });

    save.addEventListener("submit", (event) => {
      event.preventDefault();
      mc.palettes.save(nameInput.value)
        .then((palette) => {
          nameInput.value = "";
          if (category !== ALL) category = palettes.MINE.id;
          status.textContent = `已存到我的配色：「${palette.name}」`;
          return refresh();
        })
        .catch(report);
    });

    menu.addEventListener("toggle", () => {
      if (!menu.open) return;
      refresh()
        .then(() => popover.scrollIntoView({ block: "nearest" }))
        .catch(report);
    });

    // 稿子换了、颜色改了（⌘Z、色块、换主题）：开着时标出现在用的是哪一组
    mc.on("change", () => {
      if (menu.open) refresh().catch(report);
    });
  })();

  // ===== 色轮 =====
  (() => {
    const menu = document.getElementById("colorWheel");
    const popover = menu.querySelector(".pop-menu-panel");
    const SIZE = 200; // 色轮直径（CSS 像素）
    const RADIUS = SIZE / 2;
    const WHEEL_LIGHTNESS = 0.75; // 色轮画在 OKLCH 的这个明度上，边缘是每个色相在 sRGB 里最浓的颜色
    const HUE_BINS = 720;
    const WHEEL_ROWS = 16; // 色轮底图一次画这么多行，行与行之间让出主线程
    const PREVIEW_INTERVAL = 120; // 拖动时最多这么久刷新一次舞台
    const HUE_STEP = 3;
    const STRENGTH_STEP = 0.05;

    // 面板状态：hue、strength 是基准色在色轮上的位置（色相 0–360；浓淡 0–1，1 是这个色相最浓的颜色，在圆边上）；
    // result 是现在推出来的配色（还没动过时为 null）；pasted 为 true 时 result 来自粘贴的色值，不是规则推的。
    const state = { hue: 0, strength: 0.6, rule: "analogous", tone: "light", result: null, pasted: false, applied: false };
    // 浓淡按强调色那个明度上最浓的颜色算：拖到圆边，强调色就是这个色相最鲜艳的样子
    const accentLightness = () => palettes.TONES[state.tone].accent.l;
    const chromaAt = (hue, strength, lightness) => strength * palettes.maxChroma(lightness, hue);
    const strengthOf = ({ c, h }) => Math.min(1, c / Math.max(0.001, palettes.maxChroma(accentLightness(), h)));

    const head = element("div", "palette-head");
    const tones = element("div", "segmented segmented-small wheel-tones");
    tones.setAttribute("role", "group");
    tones.setAttribute("aria-label", "明暗");
    const toneButtons = [["light", "浅色"], ["dark", "深色"]].map(([id, name]) => {
      const toneButton = button("", name);
      toneButton.dataset.tone = id;
      toneButton.addEventListener("click", () => {
        state.tone = id;
        derive();
      });
      tones.append(toneButton);
      return toneButton;
    });
    head.append(element("h3", "palette-title", "色轮"), tones);

    const rules = element("div", "wheel-rules");
    rules.setAttribute("role", "group");
    rules.setAttribute("aria-label", "配色规则");
    const ruleButtons = Object.entries(palettes.RULES).map(([id, rule]) => {
      const ruleButton = button("chip chip-small", rule.name);
      ruleButton.dataset.rule = id;
      ruleButton.addEventListener("click", () => {
        state.rule = id;
        derive();
      });
      rules.append(ruleButton);
      return ruleButton;
    });

    const stage = element("div", "wheel-stage");
    const canvas = element("canvas", "wheel-canvas");
    canvas.width = SIZE * 2;
    canvas.height = SIZE * 2;
    canvas.setAttribute("aria-hidden", "true");
    stage.append(canvas);
    // 把手：滑杆语义（色相 0–359，读出色相与浓淡）；方向键左右转色相、上下调浓淡。位置用 translate 摆，不动 left / top
    const handles = [0, 1, 2, 3].map((index) => {
      const handle = element("span", "wheel-handle");
      handle.dataset.index = String(index);
      handle.tabIndex = 0;
      handle.setAttribute("role", "slider");
      handle.setAttribute("aria-label", index ? `配色点 ${index + 1}` : "基准色");
      handle.setAttribute("aria-valuemin", "0");
      handle.setAttribute("aria-valuemax", "359");
      handle.title = index ? "拖动：整组一起转" : "拖动：改色相与浓淡；方向键微调";
      stage.append(handle);
      return handle;
    });

    const roles = element("ul", "wheel-roles");
    roles.setAttribute("aria-label", "五个角色");
    const rows = Object.fromEntries(palettes.ROLES.map((role) => {
      const row = element("li", "wheel-role");
      const chip = element("span", "wheel-chip");
      const name = element("span", "wheel-role-name", ROLE_INFO[role].name);
      const hex = element("code", "wheel-hex");
      const ratio = element("span", "wheel-ratio");
      row.append(chip, name, hex, ratio);
      roles.append(row);
      return [role, { row, chip, hex, ratio }];
    }));
    // 说明哪些角色调过明暗；读屏在松手、点规则、粘贴时读一次，拖动途中不读
    const note = element("p", "section-note wheel-note");
    note.setAttribute("aria-live", "polite");

    const paste = element("form", "wheel-paste");
    const pasteInput = element("input", "palette-input");
    pasteInput.type = "text";
    pasteInput.spellcheck = false;
    pasteInput.placeholder = "粘贴色值：#264653 #2a9d8f …";
    pasteInput.setAttribute("aria-label", "粘贴色值");
    const pasteButton = element("button", "pill-button", "分配");
    pasteButton.type = "submit";
    paste.append(pasteInput, pasteButton);

    const actions = element("div", "button-pair");
    const cancelButton = button("pill-button", "取消");
    const applyButton = button("primary-button", "应用");
    actions.append(cancelButton, applyButton);
    popover.append(head, rules, stage, roles, note, paste, actions);

    // ----- 色轮底图：OKLCH 同一明度下色相绕一圈，从圆心的灰往外到这个色相最浓的颜色 -----
    // 第一次打开时分块画（每块几行，块与块之间让出主线程，边画边显示），画好的画布一直留着，之后打开不再算。
    let wheelPainting = null;
    // 让出主线程到下一个任务：用消息通道而不是 setTimeout——窗口在后台时 setTimeout 会被节流到一秒一次
    const nextTask = () => new Promise((resolve) => {
      const channel = new MessageChannel();
      channel.port1.onmessage = () => resolve();
      channel.port2.postMessage(null);
    });

    function paintWheelRows(context, limits, from, to) {
      const size = canvas.width;
      const center = size / 2;
      const image = context.createImageData(size, to - from);
      for (let y = from; y < to; y += 1) {
        for (let x = 0; x < size; x += 1) {
          const dx = x + 0.5 - center;
          const dy = center - (y + 0.5);
          const distance = Math.hypot(dx, dy) / center;
          if (distance > 1) continue;
          const hue = ((Math.atan2(dy, dx) * 180) / Math.PI + 360) % 360;
          const limit = limits[Math.round((hue * HUE_BINS) / 360) % HUE_BINS];
          const [r, g, b] = oklchToRgb({ l: WHEEL_LIGHTNESS, c: distance * limit, h: hue });
          const offset = ((y - from) * size + x) * 4;
          image.data.set([r, g, b, Math.round(Math.min(1, (1 - distance) * center) * 255)], offset); // 边缘一像素渐隐
        }
      }
      context.putImageData(image, 0, from);
    }

    function paintWheel() {
      wheelPainting ||= (async () => {
        const context = canvas.getContext("2d");
        const limits = Array.from({ length: HUE_BINS }, (_, bin) => palettes.maxChroma(WHEEL_LIGHTNESS, (bin * 360) / HUE_BINS));
        for (let from = 0; from < canvas.height; from += WHEEL_ROWS) {
          await nextTask();
          paintWheelRows(context, limits, from, Math.min(canvas.height, from + WHEEL_ROWS));
        }
        canvas.classList.add("is-ready");
      })();
      return wheelPainting;
    }

    const position = (hue, strength) => {
      const distance = strength * RADIUS;
      const angle = (hue * Math.PI) / 180;
      return { x: RADIUS + Math.cos(angle) * distance, y: RADIUS - Math.sin(angle) * distance };
    };

    const offsets = () => palettes.RULES[state.rule].offsets;

    function placeHandles() {
      const shown = state.pasted ? [0] : offsets();
      const strength = Math.round(state.strength * 100);
      handles.forEach((handle, index) => {
        handle.hidden = index >= shown.length;
        if (handle.hidden) return;
        const hue = (state.hue + shown[index] + 360) % 360;
        const { x, y } = position(hue, state.strength);
        handle.style.translate = `${x}px ${y}px`;
        handle.style.setProperty("--handle-color", palettes.oklchToHex({ l: WHEEL_LIGHTNESS, c: chromaAt(hue, state.strength, WHEEL_LIGHTNESS), h: hue }));
        handle.setAttribute("aria-valuenow", String(Math.round(hue) % 360));
        handle.setAttribute("aria-valuetext", `色相 ${Math.round(hue) % 360}°，浓淡 ${strength}%`);
      });
    }

    // 调过明暗的角色（拖动途中只记下，松手时再写进读屏会读的说明）
    function noteText(adjusted) {
      const changed = adjusted.map((role) => ROLE_INFO[role].name);
      return changed.length
        ? `已自动调整${changed.join("、")}的明暗，让文字对背景至少 ${CONTRAST.body}:1、标题至少 ${CONTRAST.large}:1。`
        : `文字与强调对背景至少 ${CONTRAST.body}:1，辅助色用在标题上（大字）至少 ${CONTRAST.large}:1。`;
    }

    // 说明写进读屏会读的地方：平时有变化才写；松手时（released）照样写一次，拖出来的结果读一遍
    let pendingNote = "";
    function announce({ released = false } = {}) {
      if (released || note.textContent !== pendingNote) note.textContent = pendingNote;
    }

    // 五个角色的色块、色值与对比度；调过的角色标「已调」
    function showColors(colors, contrast, adjusted = []) {
      for (const role of palettes.ROLES) {
        const { chip, hex, ratio, row } = rows[role];
        chip.style.background = colors[role];
        hex.textContent = colors[role];
        const entry = contrast[role];
        ratio.textContent = entry ? `${entry.ratio.toFixed(1)}:1${adjusted.includes(role) ? " · 已调" : ""}` : "";
        ratio.title = entry ? (role === "surface" ? `衬底上的正文，至少 ${entry.minimum}:1` : `对背景，至少 ${entry.minimum}:1`) : "";
        row.dataset.adjusted = String(adjusted.includes(role));
        row.dataset.fail = String(Boolean(entry && !entry.pass));
      }
      pendingNote = noteText(adjusted);
      if (!drag) announce();
    }

    function syncControls() {
      for (const toneButton of toneButtons) toneButton.setAttribute("aria-pressed", String(toneButton.dataset.tone === state.tone));
      for (const ruleButton of ruleButtons) ruleButton.setAttribute("aria-pressed", String(!state.pasted && ruleButton.dataset.rule === state.rule));
      applyButton.disabled = !state.result;
      placeHandles();
    }

    // ----- 预览：拖动时节流刷新舞台，同时只有一次在画 -----
    let previewTimer = 0;
    let previewRunning = null;
    let previewNext = null;
    let previewShown = false;

    async function flushPreview() {
      previewTimer = 0;
      const colors = previewNext;
      previewNext = null;
      if (!colors) return;
      previewShown = true;
      previewRunning = mc.palettes.preview(colors).catch(report);
      await previewRunning;
      previewRunning = null;
      if (previewNext && !previewTimer) previewTimer = setTimeout(flushPreview, PREVIEW_INTERVAL);
    }

    function schedulePreview(colors) {
      previewNext = colors;
      if (!previewTimer && !previewRunning) previewTimer = setTimeout(flushPreview, PREVIEW_INTERVAL);
    }

    async function stopPreview() {
      clearTimeout(previewTimer);
      previewTimer = 0;
      previewNext = null;
      await previewRunning;
    }

    // 粘贴的配色里按三色规则推出来的辅助、衬底不交出去：预览与套用时它们记为没单独调过
    const chosenColors = () => (state.pasted ? palettes.explicitColors(state.result) : state.result.colors);

    function setResult(result, { pasted = false } = {}) {
      state.result = result;
      state.pasted = pasted;
      showColors(result.colors, result.contrast, result.adjusted);
      syncControls();
      schedulePreview(chosenColors());
    }

    // 按现在的基准色、规则与明暗推一组
    function derive() {
      const chroma = chromaAt(state.hue, state.strength, accentLightness());
      setResult(palettes.fromWheel({ hue: state.hue, chroma, rule: state.rule, tone: state.tone }));
    }

    // ----- 拖把手、点色轮 -----
    let drag = null;

    function pointAt(event) {
      const box = stage.getBoundingClientRect();
      const dx = event.clientX - box.left - RADIUS;
      const dy = RADIUS - (event.clientY - box.top);
      return {
        hue: ((Math.atan2(dy, dx) * 180) / Math.PI + 360) % 360,
        strength: Math.min(Math.hypot(dx, dy), RADIUS) / RADIUS,
      };
    }

    function moveTo(event) {
      const { hue, strength } = pointAt(event);
      const offset = state.pasted ? 0 : offsets()[drag.index] ?? 0;
      state.hue = (hue - offset + 360) % 360;
      state.strength = strength;
      derive();
    }

    stage.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      const handle = event.target.closest(".wheel-handle");
      drag = { index: handle ? Number(handle.dataset.index) : 0, pointer: event.pointerId };
      stage.setPointerCapture(event.pointerId);
      stage.classList.add("is-dragging");
      (handle ?? handles[0]).focus();
      event.preventDefault();
      moveTo(event);
    });
    stage.addEventListener("pointermove", (event) => {
      if (drag?.pointer === event.pointerId) moveTo(event);
    });
    const endDrag = (event) => {
      if (drag?.pointer !== event.pointerId) return;
      drag = null;
      stage.classList.remove("is-dragging");
      announce({ released: true });
    };
    stage.addEventListener("pointerup", endDrag);
    stage.addEventListener("pointercancel", endDrag);

    // 方向键：左右转色相，上下调浓淡
    stage.addEventListener("keydown", (event) => {
      if (!event.target.closest(".wheel-handle")) return;
      const moves = {
        ArrowLeft: [-HUE_STEP, 0], ArrowRight: [HUE_STEP, 0], ArrowUp: [0, STRENGTH_STEP], ArrowDown: [0, -STRENGTH_STEP],
      };
      const move = moves[event.key];
      if (!move) return;
      event.preventDefault();
      state.hue = (state.hue + move[0] + 360) % 360;
      state.strength = Math.min(1, Math.max(0, state.strength + move[1]));
      derive();
    });

    paste.addEventListener("submit", (event) => {
      event.preventDefault();
      try {
        const result = palettes.fromHexList(palettes.parseHexList(pasteInput.value));
        const accent = palettes.hexToOklch(result.colors.accent);
        state.tone = palettes.toneOf(result.colors);
        Object.assign(state, { hue: accent.h, strength: strengthOf(accent) });
        setResult(result, { pasted: true });
      } catch (error) {
        note.textContent = error.message;
      }
    });

    applyButton.addEventListener("click", async () => {
      if (!state.result) return;
      await stopPreview();
      try {
        await mc.palettes.apply(chosenColors());
        state.applied = true;
        status.textContent = window.MediaCraftPlatform.keys("已应用色轮配出的配色，⌘Z 可以撤回");
      } catch (error) {
        report(error);
      }
      menu.open = false;
    });

    cancelButton.addEventListener("click", () => {
      menu.open = false;
    });

    // 打开：从这篇现在的强调色出发，色块先显示现在的配色，动了才预览。色轮底图第一次打开时分块画，不卡住面板。
    async function opened() {
      void paintWheel();
      const { colors } = await mc.drafts.current();
      const accent = palettes.hexToOklch(colors.accent);
      state.tone = palettes.toneOf(colors);
      Object.assign(state, {
        hue: accent.h,
        strength: strengthOf(accent),
        result: null,
        pasted: false,
        applied: false,
      });
      pasteInput.value = "";
      showColors(colors, palettes.contrastReport(colors));
      syncControls();
      popover.scrollIntoView({ block: "nearest" });
    }

    // 收起（取消、点外面、Esc）时没点「应用」就回到稿子自己的配色。
    async function closed() {
      drag = null;
      stage.classList.remove("is-dragging");
      await stopPreview();
      if (previewShown && !state.applied) await mc.palettes.preview(null);
      previewShown = false;
    }

    menu.addEventListener("toggle", () => {
      (menu.open ? opened() : closed()).catch(report);
    });
  })();
})();
