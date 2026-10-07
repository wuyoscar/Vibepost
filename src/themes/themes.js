// 主题注册表：主题只管卡片（ADR 0007，界面皮肤跟随系统）：一次选择决定
// 卡片结构（src/engine/structures.js 的 cardStructures）、卡片配色，以及字体选「跟随主题」时用的中文、英文、代码字体
// （src/themes/fonts.js 的字体 key）与可选的标题字体 titleFonts: { zh, en }（没有就同正文）。
// 每篇稿子记住自己的主题；配色（五个色块、配色库、色轮）是在主题配色上的单篇调整。
// 主题配色里的辅助色与衬底就是三色规则推出来的值（src/engine/colors.js 的 derive）：主题原来的样子不变，
// 只存了三色的旧稿子打开后也和主题配色一致。配色的方向：干净的浅底、利落的近黑正文、每个主题一个清楚的强调色。
// 加主题 = 这里登记一项（+ 需要时一份卡片结构）。登记顺序就是主题面板里的顺序。
(function (root) {
  "use strict";

  const freeze = root.MediaCraftEngine.deepFreeze;

  const REGISTRY = freeze([
    {
      id: "notes",
      name: "备忘",
      label: "干净的随手记 · 黄色小签",
      structure: "notes",
      colors: { bg: "#ffffff", text: "#1c1c1e", accent: "#ffbd2e", secondary: "#1c1c1e", surface: "#e8e8e9" },
      fonts: { zh: "noto-sans-sc", en: "inter", code: "jetbrains-mono" },
    },
    {
      id: "plain",
      name: "纯白",
      label: "白底黑线 · 极简",
      structure: "plain",
      colors: { bg: "#ffffff", text: "#111111", accent: "#111111", secondary: "#111111", surface: "#e7e7e7" },
      fonts: { zh: "noto-sans-sc", en: "inter", code: "jetbrains-mono" },
    },
    {
      id: "journal",
      name: "手帐",
      label: "文楷 · 薄荷胶带 · 照片白边",
      structure: "journal",
      colors: { bg: "#fbf9f3", text: "#2a2825", accent: "#4ca585", secondary: "#2a2825", surface: "#e6e4de" },
      fonts: { zh: "lxgw-wenkai", en: "source-serif-4", code: "ibm-plex-mono" },
      titleFonts: { zh: "lxgw-wenkai", en: "lxgw-wenkai" },
    },
    {
      id: "glow",
      name: "柔光",
      label: "淡紫的柔和渐变",
      structure: "glow",
      colors: { bg: "#f5f3ff", text: "#25223d", accent: "#7a68ee", secondary: "#25223d", surface: "#e0deec" },
      fonts: { zh: "noto-sans-sc", en: "inter", code: "jetbrains-mono" },
    },
    {
      id: "clay",
      name: "陶土",
      label: "淡蜜桃纸 · 衬线标题 · 珊瑚点缀",
      structure: "clay",
      colors: { bg: "#fff6f0", text: "#1d1b18", accent: "#e5704f", secondary: "#1d1b18", surface: "#e8e0da" },
      fonts: { zh: "noto-sans-sc", en: "inter", code: "ibm-plex-mono" },
      titleFonts: { zh: "noto-serif-sc", en: "source-serif-4" },
    },
    {
      id: "editorial",
      name: "杂志",
      label: "淡天蓝纸 · 全衬线 · 居中刊头",
      structure: "editorial",
      colors: { bg: "#f2f6fa", text: "#1b2430", accent: "#2f67b1", secondary: "#1b2430", surface: "#dde1e6" },
      fonts: { zh: "noto-serif-sc", en: "source-serif-4", code: "ibm-plex-mono" },
    },
    {
      id: "poster",
      name: "撞色",
      label: "柠檬黄封面 · 黑色页眉条",
      structure: "poster",
      colors: { bg: "#fffdf5", text: "#111111", accent: "#ffe047", secondary: "#111111", surface: "#e7e5de" },
      fonts: { zh: "noto-sans-sc", en: "inter", code: "jetbrains-mono" },
      titleFonts: { zh: "smiley-sans", en: "smiley-sans" },
    },
    {
      id: "ink",
      name: "纯黑",
      label: "黑底白线 · 极简",
      structure: "ink",
      colors: { bg: "#0c0c0c", text: "#e8e8e5", accent: "#e8e8e5", secondary: "#e8e8e5", surface: "#222222" },
      fonts: { zh: "noto-sans-sc", en: "inter", code: "jetbrains-mono" },
    },
    {
      id: "fresh",
      name: "清新",
      label: "奶油白底 · 圆角白卡片 · 粉与薄荷的小点缀",
      structure: "fresh",
      colors: { bg: "#fffaf3", text: "#3a3330", accent: "#f08a8a", secondary: "#3a3330", surface: "#ebe6e0" },
      fonts: { zh: "noto-sans-sc", en: "inter", code: "jetbrains-mono" },
      titleFonts: { zh: "lxgw-wenkai", en: "lxgw-wenkai" },
    },
    {
      id: "neon",
      name: "电光",
      label: "深蓝底 · 一抹电蓝 · 等宽标签",
      structure: "neon",
      colors: { bg: "#0f172a", text: "#e6edf7", accent: "#4cc9ff", secondary: "#e6edf7", surface: "#252c3f" },
      fonts: { zh: "noto-sans-sc", en: "inter", code: "jetbrains-mono" },
    },
  ]);

  // 没选过主题时新稿子用它；认不出的主题也按它
  const DEFAULT = "notes";

  // 定稿（v5 第 03 张票）之前的八个主题：换成最接近的新主题。colors 是那个主题当时的配色（背景、文字、强调；
  // 辅助与衬底是三色规则推的），稿子的配色和它一样（没调过）就换成新主题的配色，调过的保留。见 docs/storage.md。
  const RETIRED = freeze({
    white: { to: "plain", colors: { bg: "#ffffff", text: "#161616", accent: "#0043ce" } },
    gray: { to: "plain", colors: { bg: "#f4f4f4", text: "#161616", accent: "#007d79" } },
    paper: { to: "clay", colors: { bg: "#fbf7ef", text: "#3a3226", accent: "#b5562e" } },
    mist: { to: "glow", colors: { bg: "#e4ecf5", text: "#1e2a3a", accent: "#3b6ea8" } },
    sage: { to: "notes", colors: { bg: "#eef5f0", text: "#1f3329", accent: "#3e7d5a" } },
    night: { to: "ink", colors: { bg: "#161616", text: "#f4f4f4", accent: "#78a9ff" } },
    cyber: { to: "ink", colors: { bg: "#10141b", text: "#e8ecf1", accent: "#ff4d5a" } },
    waste: { to: "journal", colors: { bg: "#efe6d6", text: "#3b2f24", accent: "#a8522a" } },
  });

  const byId = new Map(REGISTRY.map((theme) => [theme.id, theme]));

  const has = (id) => byId.has(id);
  // 旧主题换成接替它的新主题，认不出的按默认主题
  const normalize = (id) => (has(id) ? id : RETIRED[id]?.to ?? DEFAULT);

  const same = (a, b) => String(a ?? "").toLowerCase() === String(b ?? "").toLowerCase();

  // 稿子（或每轮 AI 之前存的版本）的 { theme, colors, tunedColors } 用的是旧主题时，换成接替它的新主题：
  // 配色没调过（三色与旧主题的一样、没有单独调过的辅助或衬底，或者根本没存配色）就换成新主题的配色。
  // 返回要改的字段；不是旧主题时返回 null。
  function migrate(fields) {
    const retired = RETIRED[fields?.theme];
    if (!retired) return null;
    const colors = fields.colors ?? {};
    const untouched = ["bg", "text", "accent"].every((role) => colors[role] === undefined || same(colors[role], retired.colors[role]))
      && !(Array.isArray(fields.tunedColors) && fields.tunedColors.length);
    if (!untouched) return { theme: retired.to };
    return { theme: retired.to, colors: { ...byId.get(retired.to).colors }, tunedColors: [] };
  }

  root.MediaCraftThemes = {
    DEFAULT,
    list: () => REGISTRY,
    has,
    normalize,
    migrate,
    // 认不出的 id 按默认主题
    get: (id) => byId.get(normalize(id)),
  };
})(globalThis);
