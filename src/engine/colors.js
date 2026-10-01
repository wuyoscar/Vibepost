// 颜色：配色的五个角色（名字、界面上的叫法、用在哪里、对比度门槛、三色规则）与颜色计算
// （sRGB 与 OKLCH 互转、WCAG 对比度、按对比度调明度）。只此一处：出图（paint.js、长文）、配色（src/themes/palettes.js）、
// 检查器的色块、主题面板、配色面板与 AI 工具的说明都从这里取。挂在 MediaCraftEngine.colors。
(function (root) {
  "use strict";

  const engine = root.MediaCraftEngine || (root.MediaCraftEngine = {});
  const freeze = engine.deepFreeze;

  // ===== 五个角色 =====

  // 对比度门槛（WCAG）：正文 4.5:1，大字（标题）3:1
  const CONTRAST = freeze({ body: 4.5, large: 3 });

  const ROLES = freeze(["bg", "text", "accent", "secondary", "surface"]);
  // name：界面上的叫法；use：用在哪里；minimum：配色本身要做到的对比度（文字、强调、辅助对背景，衬底是衬底上的正文）
  const ROLE_INFO = freeze({
    bg: { name: "背景", use: "卡片与长文的底色", minimum: null },
    text: { name: "文字", use: "正文", minimum: CONTRAST.body },
    accent: { name: "强调", use: "列表编号与圆点、链接、引用竖线、页眉页脚的标签、装饰线", minimum: CONTRAST.body },
    secondary: { name: "辅助", use: "标题", minimum: CONTRAST.large },
    surface: { name: "衬底", use: "引用块、表头、代码块与行内代码的底", minimum: CONTRAST.body },
  });
  // 三色规则推得出来的两个角色：没单独调过时跟着背景与文字走
  const DERIVABLE = freeze(["secondary", "surface"]);

  // ===== sRGB =====

  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

  function parseHex(hex) {
    const value = String(hex).replace("#", "");
    const full = value.length === 3 ? [...value].map((char) => char + char).join("") : value.slice(0, 6);
    const number = Number.parseInt(full, 16);
    return { r: (number >> 16) & 255, g: (number >> 8) & 255, b: number & 255 };
  }

  function toHex({ r, g, b }) {
    return `#${[r, g, b].map((value) => Math.round(clamp(value, 0, 255)).toString(16).padStart(2, "0")).join("")}`;
  }

  // from 向 to 走 amount（0–1）
  function mix(from, to, amount) {
    const a = parseHex(from);
    const b = parseHex(to);
    return toHex({ r: a.r + (b.r - a.r) * amount, g: a.g + (b.g - a.g) * amount, b: a.b + (b.b - a.b) * amount });
  }

  const toLinear = (value) => (value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
  const toGamma = (value) => (value <= 0.0031308 ? 12.92 * value : 1.055 * value ** (1 / 2.4) - 0.055);

  function luminance(hex) {
    const { r, g, b } = parseHex(hex);
    return 0.2126 * toLinear(r / 255) + 0.7152 * toLinear(g / 255) + 0.0722 * toLinear(b / 255);
  }

  function contrast(first, second) {
    const [high, low] = [luminance(first), luminance(second)].sort((a, b) => b - a);
    return (high + 0.05) / (low + 0.05);
  }

  // ===== OKLCH：同样的明度看起来一样亮，调明度、转色相时颜色轻重一致 =====

  function hexToOklch(hex) {
    const { r, g, b } = parseHex(hex);
    const [red, green, blue] = [r, g, b].map((value) => toLinear(value / 255));
    const l = Math.cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue);
    const m = Math.cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue);
    const s = Math.cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue);
    const lightness = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s;
    const a = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
    const bb = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
    return { l: lightness, c: Math.hypot(a, bb), h: ((Math.atan2(bb, a) * 180) / Math.PI + 360) % 360 };
  }

  function oklchToLinear({ l, c, h }) {
    const angle = (h * Math.PI) / 180;
    const a = c * Math.cos(angle);
    const b = c * Math.sin(angle);
    const long = (l + 0.3963377774 * a + 0.2158037573 * b) ** 3;
    const medium = (l - 0.1055613458 * a - 0.0638541728 * b) ** 3;
    const short = (l - 0.0894841775 * a - 1.291485548 * b) ** 3;
    return [
      4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short,
      -1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short,
      -0.0041960863 * long - 0.7034186147 * medium + 1.707614701 * short,
    ];
  }

  const inGamut = (rgb) => rgb.every((value) => value >= -0.0001 && value <= 1.0001);

  // 这个明度、色相下 sRGB 放得下的最大彩度（最多 0.4）
  function maxChroma(l, h) {
    let low = 0;
    let high = 0.4;
    for (let step = 0; step < 18; step += 1) {
      const middle = (low + high) / 2;
      if (inGamut(oklchToLinear({ l, c: middle, h }))) low = middle;
      else high = middle;
    }
    return low;
  }

  // OKLCH → sRGB 的 0–255 三个数。放不进 sRGB 的颜色：明度、色相不变，彩度降到刚好放得下。
  function oklchToRgb(color) {
    const target = { ...color, l: clamp(color.l, 0, 1), c: Math.max(0, color.c) };
    let rgb = oklchToLinear(target);
    if (!inGamut(rgb)) rgb = oklchToLinear({ ...target, c: maxChroma(target.l, target.h) });
    return rgb.map((value) => Math.round(clamp(toGamma(clamp(value, 0, 1)), 0, 1) * 255));
  }

  function oklchToHex(color) {
    const [r, g, b] = oklchToRgb(color);
    return toHex({ r, g, b });
  }

  // ===== 对比度保护（出图的自动对比、配色的对比度保护、字色与高亮色块都用这一个）=====

  // 对 against 的对比度不到 minimum 时，色相、彩度不变，把明度往远离 against 的方向调，直到够为止。
  function withContrast(hex, against, minimum) {
    if (contrast(hex, against) >= minimum) return hex;
    const color = hexToOklch(hex);
    const direction = contrast("#000000", against) > contrast("#ffffff", against) ? -1 : 1;
    for (let step = 1; step <= 50; step += 1) {
      const candidate = oklchToHex({ ...color, l: color.l + direction * step * 0.02 });
      if (contrast(candidate, against) >= minimum) return candidate;
    }
    return direction < 0 ? "#000000" : "#ffffff";
  }

  // ===== 三色规则 =====
  // 只有背景、文字、强调三色的配色（这版之前存的稿子、只给三色的改动、主题），辅助与衬底按这条推出来：
  // 辅助 = 文字色，衬底 = 文字色 10% 叠在背景上。
  function derive({ bg, text }) {
    return { secondary: text, surface: mix(text, bg, 0.9) };
  }

  // ===== 卡片上的角色色 =====
  // 五个角色落到卡片上：正文所在的底（paper，知识卡是底板的颜色）与相对它保证反差的一组颜色（HTML 卡片与长文都用）。

  // 从 from 往底色 to 退 amount，但对底色的反差不低于 minimum。
  function fade(from, to, amount, minimum) {
    for (let step = amount; step > 0; step -= 0.05) {
      const candidate = mix(from, to, step);
      if (contrast(candidate, to) >= minimum) return candidate;
    }
    return from;
  }

  // 衬底是相对底色配的。正文写在另一种底上（知识卡的底板、公众号的白底）时：没单独调过的衬底（tuned 里没有它）
  // 对着这个底按三色规则重新推；调过的把它与底色的差照样放到这个底上，衬底与底的关系和配色里一样。
  function surfaceOn(paper, colors, tuned = []) {
    if (paper === colors.bg) return colors.surface;
    if (!tuned.includes("surface")) return derive({ bg: paper, text: colors.text }).surface;
    const [value, base, target] = [colors.surface, colors.bg, paper].map(parseHex);
    const channel = (key) => Math.min(255, Math.max(0, target[key] + value[key] - base[key]));
    return toHex({ r: channel("r"), g: channel("g"), b: channel("b") });
  }

  // 正文、衬底上的字按正文 4.5:1；标题与用作文字的强调色按大字 3:1 保底。
  // structure：卡片结构（有 board 的正文写在底板上）；tuned：单独调过的辅助、衬底（见 docs/app-api.md 的五个颜色角色）。
  function roles(colors, structure, tuned = []) {
    const background = colors.bg;
    const light = luminance(background) > 0.4;
    const paper = structure.board ? (light ? "#ffffff" : mix(background, colors.text, 0.07)) : background;
    const text = withContrast(colors.text, paper, CONTRAST.body);
    const surface = surfaceOn(paper, { ...colors, text }, tuned);
    const surfaceText = withContrast(text, surface, CONTRAST.body);
    return {
      background,
      paper,
      text,
      muted: fade(text, paper, 0.46, 3), // 署名、页码等次要文字
      rule: fade(text, paper, 0.65, 2.2), // 分割线、发丝线、表格线
      accent: colors.accent,
      accentText: withContrast(colors.accent, paper, CONTRAST.large), // 用作文字的强调色（编号、标签、链接）
      tint: mix(colors.accent, paper, 0.86), // 标签的浅强调底、没有头像时的圆
      heading: withContrast(colors.secondary, paper, CONTRAST.large), // 标题是大字
      surface, // 引用块、表头、代码块的底
      surfaceText, // 衬底上的字
      chip: surface, // 行内代码的底
      onAccent: readableOn(colors.accent, text, { paper, text }), // 满版强调色（撞色的封面、备忘的小签）上的字
    };
  }

  // 高亮底上的字：本来的颜色不够清楚时，换成正文底色或黑白里最先够 4.5:1 的那个。
  function readableOn(background, preferred, colorRoles) {
    for (const color of [preferred, colorRoles.paper, colorRoles.text, "#161616", "#ffffff"]) {
      if (contrast(color, background) >= CONTRAST.body) return color;
    }
    return contrast("#000000", background) > contrast("#ffffff", background) ? "#000000" : "#ffffff";
  }

  engine.colors = {
    roles,
    surfaceOn,
    readableOn,
    CONTRAST,
    ROLES,
    ROLE_INFO,
    DERIVABLE,
    parseHex,
    toHex,
    mix,
    luminance,
    contrast,
    hexToOklch,
    oklchToRgb,
    oklchToHex,
    maxChroma,
    withContrast,
    derive,
  };
})(globalThis);
