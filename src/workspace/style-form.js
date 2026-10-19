// 检查器「样式」里跟着稿子走的几项：字体、字号、行距、段距、图片最大高、配色的五个色块
// （主题区在 src/theme-panel.js，配色库与色轮在 src/workspace/palette-panel.js）。
// 这里只管界面与取值范围；改了什么由 onInput() 告诉应用，应用再 read() 出图、存盘。
(function (root) {
  "use strict";

  // 数值的默认值与上下限（与 index.html 里滑杆的 min / max / step 一致）；超出时截断，按 step 取整。
  const NUMBERS = Object.freeze({
    cardHeight: { input: "#cardHeightInput", fallback: 1152, min: 1152, max: 1728, step: 1 },
    fontSize: { input: "#fontSizeInput", fallback: 34, min: 18, max: 40, step: 1 },
    lineHeight: { input: "#lineHeightInput", fallback: 1.85, min: 1, max: 2.4, step: 0.01 },
    imageMaxHeight: { input: "#imageHeightInput", fallback: 1048, min: 220, max: 1048, step: 1 },
    // 段距：块与块之间的距离，按「一行有多高」的几倍（0.55 行是一直以来的默认）
    blockGap: { input: "#blockGapInput", fallback: 0.55, min: 0.1, max: 1.5, step: 0.05 },
  });
  // 五个色块：角色 → 色块的 <input id>；名字与说明取自 src/engine/colors.js 的 ROLE_INFO
  const { ROLES, ROLE_INFO } = root.MediaCraftEngine.colors;
  const COLORS = Object.freeze(Object.fromEntries(ROLES.map((role) => [role, `#${role}ColorInput`])));
  const SCRIPTS = ["zh", "en", "code"];

  function normalizeNumber(field, value) {
    const { fallback, min, max, step } = NUMBERS[field];
    const number = Number(value);
    if (field === "cardHeight") return [1152, 1222, 1536, 1728].includes(number) ? number : 1152;
    if (value === null || value === "" || !Number.isFinite(number)) return fallback;
    const stepped = Math.round(Math.min(max, Math.max(min, number)) / step) * step;
    return Number(stepped.toFixed(2));
  }

  const DEFAULTS = Object.freeze(Object.fromEntries(Object.entries(NUMBERS).map(([field, spec]) => [field, spec.fallback])));

  // onInput()：用户改了其中任何一项
  function create(onInput) {
    const $ = (selector) => document.querySelector(selector);
    const numbers = Object.fromEntries(Object.entries(NUMBERS).map(([field, spec]) => [field, $(spec.input)]));
    const colors = Object.fromEntries(Object.entries(COLORS).map(([key, selector]) => [key, $(selector)]));
    const pickers = root.MediaCraftFonts.createPickers(
      Object.fromEntries(SCRIPTS.map((script) => [script, $(`#${script}FontInput`)])),
      () => onInput(),
    );

    const densities = { card: [34, 1.85], reading: [28, 1.65], document: [22, 1.55] };
    const buttons = [...document.querySelectorAll('[data-density]')];
    const syncDensity = () => buttons.forEach(button => {
      const [size, leading] = densities[button.dataset.density];
      button.setAttribute('aria-pressed', String(Number(numbers.fontSize.value) === size && Number(numbers.lineHeight.value) === leading));
    });
    for (const input of Object.values(numbers)) input.addEventListener("input", () => { syncDensity(); onInput(); });
    buttons.forEach(button => button.addEventListener('click', async () => {
      const [fontSize, lineHeight] = densities[button.dataset.density];
      try { await root.mediacraft.drafts.update({fontSize, lineHeight}, {undoable: true}); }
      catch (error) { root.alert(error.message || String(error)); }
      syncDensity();
    }));

    // 色块的名字与说明（悬停提示）
    for (const role of ROLES) {
      const tile = colors[role].closest("label");
      tile.title = ROLE_INFO[role].use;
      tile.querySelector(".swatch-name").textContent = ROLE_INFO[role].name;
    }

    // 改一个色块时按 MediaCraftPalettes.complete 落到五色上：改的是辅助、衬底就记为单独调过；
    // 没单独调过的辅助、衬底跟着背景、文字色走
    const readColors = () => Object.fromEntries(ROLES.map((role) => [role, colors[role].value]));
    let shown = readColors();
    let tuned = [];
    for (const role of ROLES) {
      colors[role].addEventListener("input", () => {
        const next = root.MediaCraftPalettes.complete({ [role]: colors[role].value }, { colors: shown, tunedColors: tuned });
        for (const other of ROLES) if (other !== role) colors[other].value = next.colors[other];
        shown = readColors();
        tuned = next.tunedColors;
        onInput();
      });
    }

    return {
      read() {
        return {
          colors: readColors(),
          tunedColors: [...tuned],
          fonts: Object.fromEntries(SCRIPTS.map((script) => [script, pickers.get(script)])),
          ...Object.fromEntries(Object.entries(numbers).map(([field, input]) => [field, normalizeNumber(field, input.value)])),
        };
      },
      // 给了哪几项就改哪几项；colors、fonts 也可以只给其中几个。tunedColors 是单独调过的辅助、衬底，原样记下
      // （颜色怎么落、标记怎么变由调用方用 MediaCraftPalettes.complete 算好）
      write(fields) {
        for (const role of ROLES) if (fields.colors?.[role]) colors[role].value = fields.colors[role];
        shown = readColors();
        if (fields.tunedColors) tuned = [...fields.tunedColors];
        for (const [script, key] of Object.entries(fields.fonts || {})) pickers.set(script, root.MediaCraftFonts.normalize(script, key));
        for (const field of Object.keys(NUMBERS)) {
          if (field in fields) numbers[field].value = String(normalizeNumber(field, fields[field]));
        }
        syncDensity();
      },
    };
  }

  root.MediaCraftStyleForm = { create, DEFAULTS, normalizeNumber };
})(globalThis);
