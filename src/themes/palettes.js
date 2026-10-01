// 配色：配色库（自己配的 48 组）、我的配色（存在本机）、色轮的配色规则、粘贴色值的分配、配色落到稿子上的规则。
// 一组配色是卡片的五个颜色角色 { bg, text, accent, secondary, surface }；角色的名字、用处、对比度门槛、三色规则与颜色计算
// （OKLCH、对比度保护）都在 src/engine/colors.js，这里只用它们。
// 除了「我的配色」的存取，这里都是纯计算，不碰界面与稿子；套用到稿子上由 App API（src/api/palettes.js）做。
(function (root) {
  "use strict";

  const {
    ROLES, ROLE_INFO, DERIVABLE, contrast, luminance, derive, hexToOklch, oklchToHex, maxChroma, withContrast,
  } = root.MediaCraftEngine.colors;
  const freeze = root.MediaCraftEngine.deepFreeze;

  const HEX = /^#[0-9a-f]{6}$/i;
  // 卡片底色的相对亮度低于这个就算深色（与卡片绘制判断深浅的界线一致）
  const DARK_BELOW = 0.4;
  const STORE_KEY = "palettes";

  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  const ratio = (value) => Math.round(value * 100) / 100;

  // ===== 对比度保护 =====

  // 每个角色的对比度：文字、强调、辅助对背景，衬底是衬底上的正文；门槛见 ROLE_INFO 的 minimum。
  function contrastReport(colors) {
    const measured = {
      text: contrast(colors.text, colors.bg),
      accent: contrast(colors.accent, colors.bg),
      secondary: contrast(colors.secondary, colors.bg),
      surface: contrast(colors.text, colors.surface),
    };
    return Object.fromEntries(Object.entries(measured).map(([role, value]) => {
      const { minimum } = ROLE_INFO[role];
      return [role, { ratio: ratio(value), minimum, pass: value >= minimum }];
    }));
  }

  // 把一组配色调到都够对比度：先文字、强调、辅助（对背景），再衬底（让衬底上的正文够清楚）。adjusted 是调过的角色。
  function guard(colors) {
    const next = { ...colors };
    for (const role of ["text", "accent", "secondary"]) next[role] = withContrast(colors[role], colors.bg, ROLE_INFO[role].minimum);
    next.surface = withContrast(colors.surface, next.text, ROLE_INFO.surface.minimum);
    const adjusted = ROLES.filter((role) => next[role] !== colors[role]);
    return { colors: next, contrast: contrastReport(next), adjusted };
  }

  // ===== 色轮的配色规则 =====

  // offsets：色轮上每个把手相对基准色（强调色）转多少度；secondary、surface、bg：这几个角色取哪个把手的色相。
  const RULES = freeze({
    analogous: { name: "类比", offsets: [0, 30, -30], secondary: 30, surface: -30, bg: -30 },
    complementary: { name: "互补", offsets: [0, 180], secondary: 180, surface: 180, bg: 0 },
    split: { name: "分裂互补", offsets: [0, 150, 210], secondary: 150, surface: 210, bg: 0 },
    triadic: { name: "三角", offsets: [0, 120, 240], secondary: 120, surface: 240, bg: 240 },
    square: { name: "方形", offsets: [0, 90, 180, 270], secondary: 90, surface: 180, bg: 270 },
    monochrome: { name: "单色", offsets: [0], secondary: 0, surface: 0, bg: 0 },
  });

  // 浅色、深色配色里每个角色的明度；底色、衬底、正文只带一点基准色的彩度（最多 limit），强调色用基准色的彩度，辅助色七成。
  const TONES = freeze({
    light: {
      bg: { l: 0.975, share: 0.15, limit: 0.02 },
      surface: { l: 0.925, share: 0.3, limit: 0.04 },
      text: { l: 0.25, share: 0.2, limit: 0.03 },
      accent: { l: 0.55, share: 1, limit: 0.4 },
      secondary: { l: 0.42, share: 0.7, limit: 0.4 },
    },
    dark: {
      bg: { l: 0.2, share: 0.15, limit: 0.02 },
      surface: { l: 0.27, share: 0.3, limit: 0.04 },
      text: { l: 0.94, share: 0.1, limit: 0.015 },
      accent: { l: 0.76, share: 1, limit: 0.4 },
      secondary: { l: 0.84, share: 0.6, limit: 0.4 },
    },
  });

  const turn = (hue, offset) => (((hue + offset) % 360) + 360) % 360;

  // 色轮上的一点（色相 0–360、彩度 0–0.4）按规则推出五个角色，再做对比度保护。hues 是色轮上各把手的色相。
  function fromWheel({ hue, chroma, rule, tone }) {
    const spec = RULES[rule];
    const levels = TONES[tone];
    const base = clamp(chroma, 0, 0.4);
    const role = (name, offset) => oklchToHex({
      l: levels[name].l,
      c: Math.min(levels[name].limit, base * levels[name].share),
      h: turn(hue, offset),
    });
    const colors = {
      bg: role("bg", spec.bg),
      text: role("text", 0),
      accent: role("accent", 0),
      secondary: role("secondary", spec.secondary),
      surface: role("surface", spec.surface),
    };
    return { ...guard(colors), rule, tone, hues: spec.offsets.map((offset) => turn(hue, offset)) };
  }

  // App API palettes.harmony：基准色（#rrggbb，取它的色相与彩度）+ 规则 → 五个角色与对比度报告。纯函数。
  function harmony({ base, rule = "analogous", tone = "light" } = {}) {
    if (!HEX.test(String(base))) throw new TypeError(`基准色需要是 #rrggbb：${base}`);
    if (!Object.hasOwn(RULES, rule)) throw new TypeError(`没有这个配色规则：${rule}（可选 ${Object.keys(RULES).join(" / ")}）`);
    if (!Object.hasOwn(TONES, tone)) throw new TypeError("tone 只能是 light 或 dark");
    const { c, h } = hexToOklch(base.toLowerCase());
    return fromWheel({ hue: h, chroma: c, rule, tone });
  }

  // ===== 粘贴的色值 =====

  // 从一段文字里找出色值：只认 # 开头的 6 位或 3 位写法（#264653、#abc），逗号空格换行分隔都行；
  // 没有 # 的一串数字（电话、年份、编号）不算。重复的只留一个。
  function parseHexList(text) {
    const found = [...String(text).matchAll(/#([0-9a-f]{6}|[0-9a-f]{3})(?![0-9a-z])/gi)].map((match) => {
      const value = match[1].toLowerCase();
      return `#${value.length === 3 ? [...value].map((char) => char + char).join("") : value}`;
    });
    return [...new Set(found)];
  }

  // 一串颜色分给五个角色：
  // - 明度的中位数偏亮（≥ 0.5）就是浅色配色：最亮的当背景、最暗的当文字；偏暗反过来；
  // - 剩下不止一个时，和背景明度差不到 0.12 的那个当衬底；
  // - 再剩下的按彩度从高到低：强调、辅助；
  // - 缺的（只有三色时的辅助与衬底……）按三色规则推，最后做对比度保护。
  // 结果另有 derived：按三色规则推出来、保护也没调过的角色（套用时它们算「没单独调过」，之后跟着背景与文字走）。
  function fromHexList(list) {
    const colors = [...new Set(list.map((value) => String(value).toLowerCase()))].filter((value) => HEX.test(value));
    if (colors.length < 3) throw new TypeError("至少要三个颜色（#rrggbb）");
    const measured = new Map(colors.map((value) => [value, hexToOklch(value)]));
    const light = (value) => measured.get(value).l;
    const byLight = [...colors].sort((a, b) => light(b) - light(a));
    const middle = byLight.length / 2;
    const median = byLight.length % 2 ? light(byLight[Math.floor(middle)]) : (light(byLight[middle - 1]) + light(byLight[middle])) / 2;
    const dark = median < 0.5;
    const bg = dark ? byLight.at(-1) : byLight[0];
    const text = dark ? byLight[0] : byLight.at(-1);
    let rest = colors.filter((value) => value !== bg && value !== text);
    const surface = rest.length > 1
      ? rest.filter((value) => Math.abs(light(value) - light(bg)) <= 0.12)
        .sort((a, b) => Math.abs(light(a) - light(bg)) - Math.abs(light(b) - light(bg)))[0]
      : undefined;
    rest = rest.filter((value) => value !== surface).sort((a, b) => measured.get(b).c - measured.get(a).c);
    const three = { bg, text, accent: rest[0] };
    const filled = { ...three, ...derive(three), ...(rest[1] ? { secondary: rest[1] } : {}), ...(surface ? { surface } : {}) };
    const result = guard(filled);
    const derived = DERIVABLE.filter((role) => filled[role] === derive(result.colors)[role] && !result.adjusted.includes(role)
      && !(role === "secondary" ? rest[1] : surface));
    return { ...result, derived };
  }

  // 套用时交出去的颜色：按三色规则推出来的角色不给，让它们记为「没单独调过」
  const explicitColors = ({ colors, derived = [] }) => Object.fromEntries(Object.entries(colors).filter(([role]) => !derived.includes(role)));

  // ===== 落到稿子上 =====
  // 辅助、衬底有没有单独调过用显式标记 tunedColors（单独调过的角色，只会是 secondary、surface）记着，不看值是否相等：
  // 没单独调过的总是按三色规则从背景、文字推出来，改背景或文字时跟着变；单独调过的不动。

  const validColors = (colors) => Object.fromEntries(ROLES
    .filter((role) => typeof colors?.[role] === "string" && HEX.test(colors[role]))
    .map((role) => [role, colors[role].toLowerCase()]));
  const validTuned = (list) => DERIVABLE.filter((role) => Array.isArray(list) && list.includes(role));

  // 一组颜色（可以只有其中几个角色）落到 base（{ colors: 完整的五色, tunedColors }）上，返回新的 { colors, tunedColors }：
  // - 正好是 bg、text、accent 三色（没有辅助、衬底）时算三色配色，辅助与衬底按三色规则推，都记为没单独调过；
  // - 否则给了的换掉，给了的辅助、衬底记为单独调过；没单独调过的跟着新的背景、文字色重新推（比如只改了文字色，标题跟着变）；
  // - 给了 tunedColors 就按它记（撤回到某个样子、App API 一并给了标记时），没列出的辅助、衬底按三色规则推。
  function complete(colors, base = {}, tunedColors = undefined) {
    const given = validColors(colors);
    const three = ["bg", "text", "accent"].every((role) => given[role]) && !given.secondary && !given.surface;
    const before = validTuned(base.tunedColors);
    const tuned = tunedColors !== undefined
      ? validTuned(tunedColors)
      : three ? [] : DERIVABLE.filter((role) => before.includes(role) || given[role]);
    const next = { ...validColors(base.colors), ...given };
    const derived = derive(next);
    for (const role of DERIVABLE) if (!tuned.includes(role) || !next[role]) next[role] = derived[role];
    return { colors: next, tunedColors: tuned };
  }

  // 这版之前存的稿子与版本没有 tunedColors：只在打开它们时按值推断一次（和三色规则推出来的不一样就算调过），之后照标记走。
  function inferTuned(colors) {
    const given = validColors(colors);
    if (!given.bg || !given.text) return [];
    const derived = derive(given);
    return DERIVABLE.filter((role) => given[role] && given[role] !== derived[role]);
  }

  const toneOf = (colors) => (luminance(colors.bg) < DARK_BELOW ? "dark" : "light");
  const same = (a, b) => ROLES.every((role) => a[role]?.toLowerCase() === b[role]?.toLowerCase());

  // ===== 选中文字的字色与高亮 =====
  // 浮动条颜色菜单里的色块从这篇的配色推出来（App API themes.swatches 也是它）：
  // - 字色：强调、辅助（和正文色、强调色分得开时才有）、警示红（强调色本来就偏红时不要），再从强调色的色相
  //   按 30° 一格转出一个暖色、一个冷色，不够五个时补离已有色相最远的一格；最后是正文色退淡的「次要」；
  // - 高亮：同样几种颜色的浅底（浅色卡片）或深底（深色卡片），最后是配色的衬底；
  // - 字色对卡片底色、高亮底对正文色都至少 4.5:1，不够时色相、彩度不变，调明度；看不出差别的只留一个。

  const INLINE_MINIMUM = ROLE_INFO.text.minimum;
  const INLINE_PICKS = 5; // 「次要」之前几个
  // 按卡片深浅：转出来的字色都用同一个明度；高亮底的明度是卡片底色的明度加 shift（限在 min–max），彩度最多 chroma
  const INLINE_TONES = freeze({
    light: { text: 0.55, tint: { shift: -0.06, min: 0.84, max: 0.94, chroma: 0.1 } },
    dark: { text: 0.76, tint: { shift: 0.13, min: 0.3, max: 0.42, chroma: 0.08 } },
  });
  const HUE_STEP = 30;
  const HUE_APART = 40; // 两种有彩色的色相至少差这么多度
  const NEUTRAL_BELOW = 0.04; // 彩度低于这个算黑白灰，没有色相
  const FALLBACK_HUE = 250; // 强调、辅助都是黑白灰时从这个色相转
  const WARM_HUE = 70;
  const COOL_HUE = 230;
  const ALERT = freeze({ h: 27, c: 0.2 });
  const DISTINCT = 0.08; // OKLab 距离：辅助和正文色、强调色差这么多才单独列出
  const SAME_BELOW = 0.02; // OKLab 距离：看不出差别

  // OKLCH 色相的叫法：每项是这一段的上界
  const HUE_NAMES = [[15, "玫红"], [45, "红"], [75, "橙"], [120, "黄"], [165, "绿"], [215, "青"], [280, "蓝"], [320, "紫"], [360, "玫红"]];
  const hueName = (hue) => HUE_NAMES.find(([limit]) => hue < limit)[1];

  const hueGap = (a, b) => {
    const gap = Math.abs(a - b) % 360;
    return Math.min(gap, 360 - gap);
  };

  function distance(first, second) {
    const [a, b] = [first, second].map((hex) => {
      const { l, c, h } = hexToOklch(hex);
      const angle = (h * Math.PI) / 180;
      return [l, c * Math.cos(angle), c * Math.sin(angle)];
    });
    return Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
  }

  const distinct = (list) => list.reduce((kept, swatch) => (
    kept.some((other) => distance(other.color, swatch.color) < SAME_BELOW) ? kept : [...kept, swatch]
  ), []);

  // 字色的几种颜色（「次要」除外）：{ name, hex, hue }，hue 是 OKLCH 色相（黑白灰为 null）
  function inlinePicks(colors, tone) {
    const [accent, secondary] = [colors.accent, colors.secondary].map(hexToOklch);
    const hueOf = (color) => (color.c >= NEUTRAL_BELOW ? color.h : null);
    const base = hueOf(accent) ?? hueOf(secondary) ?? FALLBACK_HUE;
    const chroma = clamp(Math.max(accent.c, secondary.c), 0.08, ALERT.c);
    const picks = [{ name: ROLE_INFO.accent.name, hex: colors.accent, hue: hueOf(accent) }];
    const used = () => picks.map((pick) => pick.hue).filter((hue) => hue !== null);
    const spread = (hue) => Math.min(180, ...used().map((other) => hueGap(other, hue)));
    const add = (hue, c = chroma) => picks.push({ name: hueName(hue), hex: oklchToHex({ l: tone.text, c, h: hue }), hue });

    if (distance(colors.secondary, colors.text) >= DISTINCT && distance(colors.secondary, colors.accent) >= DISTINCT) {
      picks.push({ name: ROLE_INFO.secondary.name, hex: colors.secondary, hue: hueOf(secondary) });
    }
    if (spread(ALERT.h) >= HUE_APART) add(ALERT.h, ALERT.c);
    const turns = Array.from({ length: 360 / HUE_STEP - 1 }, (_, index) => turn(base, (index + 1) * HUE_STEP));
    for (const target of [WARM_HUE, COOL_HUE]) {
      const [hue] = turns.filter((candidate) => spread(candidate) >= HUE_APART)
        .sort((a, b) => hueGap(a, target) - hueGap(b, target));
      if (hue !== undefined) add(hue);
    }
    while (picks.length < INLINE_PICKS) add(turns.reduce((best, hue) => (spread(hue) > spread(best) ? hue : best)));
    return picks;
  }

  // 一组配色 → { text, highlight }，每项 { name, color }：字色对底色、高亮底对正文色都够 4.5:1。纯函数。
  function inlineSwatches(colors) {
    const tone = INLINE_TONES[toneOf(colors)];
    const picks = inlinePicks(colors, tone);
    const bg = hexToOklch(colors.bg);
    const text = hexToOklch(colors.text);
    const muted = oklchToHex({ ...text, l: (text.l + bg.l) / 2 });
    const tintLightness = clamp(bg.l + tone.tint.shift, tone.tint.min, tone.tint.max);
    // 高亮底：色相不变，彩度取原色的六成（黑白灰照旧）
    const tint = ({ hex, hue }) => {
      const { c, h } = hexToOklch(hex);
      return oklchToHex({ l: tintLightness, c: hue === null ? c : clamp(c * 0.6, NEUTRAL_BELOW, tone.tint.chroma), h });
    };
    const readable = (list, against) => distinct(list.map(({ name, hex }) => ({ name, color: withContrast(hex, against, INLINE_MINIMUM) })));
    return {
      text: readable([...picks, { name: "次要", hex: muted }], colors.bg),
      highlight: readable([...picks.map((pick) => ({ name: pick.name, hex: tint(pick) })), { name: ROLE_INFO.surface.name, hex: colors.surface }], colors.text),
    };
  }

  // ===== 配色库 =====

  const CATEGORIES = freeze([
    { id: "morandi", name: "莫兰迪" },
    { id: "japanese", name: "日系" },
    { id: "film", name: "复古胶片" },
    { id: "nature", name: "自然" },
    { id: "neon", name: "霓虹赛博" },
    { id: "mono", name: "黑白极简" },
  ]);
  const MINE = freeze({ id: "mine", name: "我的配色" });

  // [名字, 浅 / 深, 底色, 正文, 强调, 辅助, 衬底]。都是自己配的：底色与正文 ≥ 7:1，强调 ≥ 4.5:1，辅助 ≥ 3:1，衬底贴着底色。
  const LIBRARY_DATA = {
    morandi: [
      ["雾霾蓝", "light", "#eef0f2", "#2f3a44", "#4f6a85", "#3f5366", "#dfe4e9"],
      ["燕麦奶", "light", "#f3efe8", "#3d362f", "#80624b", "#5c4b3e", "#e6dfd3"],
      ["豆沙", "light", "#f5eeec", "#3e2f2e", "#955660", "#6e4a4d", "#ebdcd9"],
      ["灰绿", "light", "#eef1ec", "#2e3830", "#56705b", "#45594a", "#dfe5dc"],
      ["藕荷", "light", "#f2eef3", "#352f3a", "#765e82", "#574a60", "#e5dde8"],
      ["陶土", "light", "#f4ede6", "#3b2e26", "#98563f", "#6f4d3d", "#e9ddd1"],
      ["暮色灰", "dark", "#2b2d30", "#e6e3de", "#c2ae93", "#d0c8bb", "#373a3e"],
      ["墨青", "dark", "#263033", "#e2e6e3", "#a3bdb5", "#c8d3ce", "#313d41"],
    ],
    japanese: [
      ["生成", "light", "#f7f3ea", "#2b2b28", "#a8392a", "#3b4a5a", "#ece5d5"],
      ["藍染", "light", "#f4f5f7", "#1d2733", "#2b4c7e", "#566779", "#e4e8ef"],
      ["桜", "light", "#fbf3f3", "#3a2c2f", "#b24a5e", "#7a5560", "#f2e2e4"],
      ["抹茶", "light", "#f3f4ec", "#2c3326", "#4f7133", "#5e6b3d", "#e5e8d6"],
      ["柿渋", "light", "#faf4ec", "#3a2d22", "#a65226", "#6b4a33", "#efe3d1"],
      ["若竹", "light", "#f1f6f3", "#20332a", "#2a7159", "#3d5a4c", "#dfebe5"],
      ["墨", "dark", "#1f1f1d", "#ecebe6", "#e0685b", "#cfc8b2", "#2c2b28"],
      ["夜之藍", "dark", "#1b2230", "#e8ebf0", "#e5ab62", "#b2bfd3", "#262f3f"],
    ],
    film: [
      ["波特拉", "light", "#f6efe4", "#3a2f28", "#a0532c", "#4e6b77", "#ebdfcd"],
      ["富士绿", "light", "#eff2ea", "#2c332c", "#3a7255", "#6b563c", "#e0e6d8"],
      ["褪色明信片", "light", "#f4ece0", "#3b3530", "#a8412f", "#3f6b78", "#e8dcc9"],
      ["柯达金", "light", "#faf1dc", "#3a2e1c", "#8f5a12", "#8b3a2e", "#efe0bf"],
      ["宝丽来", "light", "#f5f3ef", "#2e2c2a", "#2c6887", "#a04f38", "#e8e4dc"],
      ["暗房", "dark", "#1c1614", "#efe4d8", "#e8744d", "#d9ba92", "#2a211d"],
      ["夜景胶片", "dark", "#14202a", "#e6edf0", "#f2a654", "#86c6ce", "#1f2d38"],
      ["银盐", "dark", "#1d1d1b", "#e9e6df", "#cfae70", "#c2bdb2", "#2a2927"],
    ],
    nature: [
      ["森林", "light", "#eef3ec", "#1f3024", "#2d673c", "#5a4630", "#dde7da"],
      ["海岸", "light", "#eef5f7", "#173039", "#1c6882", "#3d5d66", "#d9e8ed"],
      ["沙丘", "light", "#f7f0e3", "#3a2e1f", "#9c5427", "#7a5a35", "#ecdec5"],
      ["晴空", "light", "#f1f6fb", "#1b2a3a", "#2562a8", "#3f5c7a", "#dee9f5"],
      ["秋叶", "light", "#faf2e8", "#3a261a", "#a8421d", "#7b5b1e", "#efdfca"],
      ["深海", "dark", "#0f2230", "#e3eef2", "#56c5ca", "#a2cbde", "#183244"],
      ["夜林", "dark", "#16231b", "#e4ece4", "#95c772", "#cbbd8f", "#20322a"],
      ["火山岩", "dark", "#211c1b", "#eee6e1", "#e97a45", "#bdb0a6", "#2e2725"],
    ],
    neon: [
      ["霓虹夜", "dark", "#0d0f1a", "#e8e9f3", "#ff4f95", "#46e3ff", "#1a1d2e"],
      ["赛博黄", "dark", "#0f1014", "#f0f0ea", "#f5e663", "#4fd1ff", "#1c1d24"],
      ["电光紫", "dark", "#120d1f", "#ece6f7", "#bd78ff", "#5ef2c7", "#1f1832"],
      ["酸性绿", "dark", "#0c1210", "#e6f0ea", "#7dff6b", "#ff6ab8", "#17201c"],
      ["合成器", "dark", "#1a1027", "#f3e9f5", "#ff8466", "#f8c65a", "#281a3a"],
      ["终端", "dark", "#0a0f0a", "#d6f5d6", "#39ff88", "#9ad9a8", "#142014"],
      ["蒸汽波", "light", "#fbf0f7", "#2a2140", "#b0157f", "#1d7394", "#f1dfed"],
      ["全息", "light", "#f2f4fb", "#1c1f3a", "#5536e8", "#0b7d82", "#e1e5f6"],
    ],
    mono: [
      ["纯白", "light", "#ffffff", "#1a1a1a", "#000000", "#1a1a1a", "#efefef"],
      ["纸灰", "light", "#f5f5f3", "#222222", "#545454", "#111111", "#e6e6e3"],
      ["红点", "light", "#fafafa", "#1c1c1c", "#c62d29", "#1c1c1c", "#ececec"],
      ["蓝点", "light", "#ffffff", "#202124", "#1a56db", "#202124", "#f0f2f4"],
      ["暖灰", "light", "#f4f1ed", "#2b2826", "#625b55", "#2b2826", "#e7e2dc"],
      ["纯黑", "dark", "#000000", "#f5f5f5", "#ffffff", "#d4d4d4", "#1a1a1a"],
      ["石墨", "dark", "#1e1e1e", "#e8e8e8", "#bdbdbd", "#ffffff", "#2c2c2c"],
      ["夜读黄", "dark", "#171717", "#ededed", "#f2c14e", "#ededed", "#262626"],
    ],
  };

  const LIBRARY = freeze(CATEGORIES.flatMap(({ id: category }) => LIBRARY_DATA[category].map(
    ([name, tone, bg, text, accent, secondary, surface], index) => ({
      id: `${category}-${String(index + 1).padStart(2, "0")}`,
      name,
      category,
      tone,
      colors: { bg, text, accent, secondary, surface },
      builtIn: true,
    }),
  )));

  // ===== 我的配色 =====
  // 全局，存在本机存储的 meta「palettes」里：{ key: "palettes", items: [{ id, name, colors, createdAt }] }（docs/storage.md）。

  const NAME_LIMIT = 24;

  function createCollection(store) {
    let items = null;
    // 别的窗口存了我的配色：下次用时重新读
    store.onExternalChange?.(({ meta }) => {
      if (meta.includes(STORE_KEY)) items = null;
    });

    async function load() {
      if (!items) {
        const record = await store.readMeta(STORE_KEY);
        items = (record?.items ?? []).filter((item) => item?.id && ROLES.every((role) => HEX.test(item.colors?.[role])));
      }
      return items;
    }

    async function persist(next) {
      await store.write({ meta: [{ key: STORE_KEY, items: next }] });
      items = next;
    }

    const toPalette = ({ id, name, colors }) => ({ id, name, category: MINE.id, tone: toneOf(colors), colors: { ...colors }, builtIn: false });

    return {
      async list() {
        return (await load()).map(toPalette);
      },
      // 名字空着时叫「我的配色 N」
      async save(name, colors) {
        const current = await load();
        const clean = String(name ?? "").trim().slice(0, NAME_LIMIT) || `${MINE.name} ${current.length + 1}`;
        const item = {
          id: `mine-${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`,
          name: clean,
          colors: validColors(colors),
          createdAt: Date.now(),
        };
        await persist([...current, item]);
        return toPalette(item);
      },
      async remove(id) {
        const current = await load();
        if (!current.some((item) => item.id === id)) throw new Error(`我的配色里没有这一组：${id}`);
        await persist(current.filter((item) => item.id !== id));
      },
    };
  }

  root.MediaCraftPalettes = {
    ROLES,
    ROLE_INFO,
    RULES,
    TONES,
    CATEGORIES,
    MINE,
    LIBRARY,
    harmony,
    fromWheel,
    parseHexList,
    fromHexList,
    explicitColors,
    contrastReport,
    complete,
    inferTuned,
    toneOf,
    inlineSwatches,
    same,
    hexToOklch,
    oklchToHex,
    maxChroma,
    createCollection,
  };
})(globalThis);
