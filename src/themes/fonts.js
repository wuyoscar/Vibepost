// 卡片与长文的字体：字体选单的选项、打包字体（fonts/，由 scripts/fetch-fonts.py 下载）的加载、出图用的字体栈。
// 字体 key 存进稿子（fonts.zh / en / code），"theme" 表示「跟随主题」（src/themes/themes.js 里每个主题的 fonts）。
(function (root) {
  "use strict";

  const FOLLOW_THEME = "theme";

  // 系统字体：主题没指定字体时「跟随主题」按它排，打包字体没下载时也回退到它。
  const SYSTEM_STACKS = Object.freeze({
    zh: '"PingFang SC", "Hiragino Sans GB", "Noto Sans CJK SC", "Microsoft YaHei", sans-serif',
    en: '-apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif',
    code: '"SFMono-Regular", Menlo, Consolas, monospace',
  });

  // 字体许可（字体选单里每项的标注）：打包字体按随字体下载的许可证文本（fonts/licenses/，由 scripts/fetch-fonts.py
  // 从各字体的 npm 包与发布仓库取来）核对过，全是 SIL OFL 1.1；系统字体是 macOS 自带的，只在这台 Mac 上用，商用要另外取得授权。
  const LICENSES = Object.freeze({
    ofl: { label: "OFL 可商用", commercial: true },
    system: { label: "系统字体 · 仅限个人", commercial: false },
  });

  // 可选的字体。bundled 的族名以 fonts/manifest.json 为准；系统字体只留在 WKWebView 里实测能解析、字重齐全的
  // （楷体画出来是回退字体，黑体、Rounded 只有一种字重，已去掉）。行内代码只用等宽字体。
  const CHOICES = Object.freeze({
    zh: [
      { key: "noto-sans-sc", label: "思源黑体", bundled: true, license: "ofl" },
      { key: "noto-serif-sc", label: "思源宋体", bundled: true, license: "ofl" },
      { key: "lxgw-wenkai", label: "霞鹜文楷", bundled: true, license: "ofl" },
      { key: "smiley-sans", label: "得意黑", bundled: true, license: "ofl" },
      { key: "zh-pingfang", label: "苹方", stack: SYSTEM_STACKS.zh, license: "system" },
      { key: "zh-song", label: "宋体", stack: '"Songti SC", SimSun, "Noto Serif CJK SC", serif', license: "system" },
    ],
    en: [
      { key: "inter", label: "Inter", bundled: true, license: "ofl" },
      { key: "ibm-plex-sans", label: "IBM Plex Sans", bundled: true, license: "ofl" },
      { key: "ibm-plex-serif", label: "IBM Plex Serif", bundled: true, license: "ofl" },
      { key: "source-serif-4", label: "Source Serif 4", bundled: true, license: "ofl" },
      { key: "jetbrains-mono", label: "JetBrains Mono", bundled: true, license: "ofl" },
      { key: "ibm-plex-mono", label: "IBM Plex Mono", bundled: true, license: "ofl" },
      { key: "fira-code", label: "Fira Code", bundled: true, license: "ofl" },
      { key: "en-sf", label: "SF", stack: SYSTEM_STACKS.en, license: "system" },
      { key: "en-serif", label: "Georgia", stack: 'Georgia, "Times New Roman", Times, serif', license: "system" },
      { key: "en-mono", label: "Menlo", stack: SYSTEM_STACKS.code, license: "system" },
    ],
    code: [
      { key: "jetbrains-mono", label: "JetBrains Mono", bundled: true, license: "ofl" },
      { key: "ibm-plex-mono", label: "IBM Plex Mono", bundled: true, license: "ofl" },
      { key: "fira-code", label: "Fira Code", bundled: true, license: "ofl" },
      { key: "code-menlo", label: "Menlo", stack: SYSTEM_STACKS.code, license: "system" },
    ],
  });

  // 结构的标签字体（页眉页脚）用哪个打包字体
  const LABEL_FONTS = Object.freeze({ mono: "ibm-plex-mono", sans: "ibm-plex-sans" });
  // 卡片上会画出、但稿子原文里未必有的字：页脚的间隔点与破折号、夜读的大引号、知识卡的标签、书卷的页码「第 N 页 / 共 N 页」，
  // 以及页码、大写署名一类的 ASCII。
  const CARD_EXTRA_TEXT = `·—“知识卡第页共${Array.from({ length: 95 }, (_, index) => String.fromCharCode(32 + index)).join("")}`;

  // 打包字体：key → { family, weights }。没下载字体时为空，选了也回退系统字体。
  let bundled = new Map();

  // 有 manifest 才挂上 fonts.css：字体目录不存在时不发起会报错的 <link> 请求。
  async function loadManifest() {
    try {
      const response = await fetch("fonts/manifest.json");
      if (!response.ok) return;
      const { fonts } = await response.json();
      await new Promise((resolve, reject) => {
        const link = document.createElement("link");
        link.rel = "stylesheet";
        link.href = "fonts/fonts.css";
        link.addEventListener("load", resolve);
        link.addEventListener("error", reject);
        document.head.append(link);
      });
      bundled = new Map(fonts.map((font) => [font.id, font]));
    } catch {
      // 字体目录不完整时照常用系统字体排版。
    }
  }
  const ready = loadManifest();

  const find = (script, key) => CHOICES[script].find((choice) => choice.key === key);

  // 字体选单的选项：第一项是「跟随主题」
  function choices(script) {
    return [{ key: FOLLOW_THEME, label: "跟随主题" }, ...CHOICES[script]];
  }

  // 这个选项的许可标注：{ id, label, commercial }；「跟随主题」没有（主题用的都是打包字体）
  function license(choice) {
    return choice.license ? { id: choice.license, ...LICENSES[choice.license] } : null;
  }

  // 这篇用到的字体里只限个人使用的（系统字体）的名字。fonts 是稿子的 { zh, en, code }，themeFonts 是主题的，
  // scripts 是这篇实际用到的几种（没有代码时不算代码字体）。
  function personalOnly(fonts, themeFonts, scripts) {
    const keys = resolve(fonts, themeFonts);
    return [...new Set(scripts.map((script) => find(script, keys[script])).filter((choice) => choice && !license(choice).commercial).map((choice) => choice.label))];
  }

  function isMissing(choice) {
    return Boolean(choice.bundled) && !bundled.has(choice.key);
  }

  // 显示与出图用的字体栈：所选字体在前，系统字体兜底
  function stack(script, key) {
    const choice = find(script, key);
    const font = choice?.bundled && bundled.get(key);
    if (font) return `"${font.family}", ${SYSTEM_STACKS[script]}`;
    return choice?.stack || SYSTEM_STACKS[script];
  }

  // 只取所选字体本身：打包字体就是它的族名，系统字体是它的字体栈去掉末尾的通用族
  function primary(script, key) {
    const choice = find(script, key);
    const font = choice?.bundled && bundled.get(key);
    if (font) return `"${font.family}"`;
    return (choice?.stack || SYSTEM_STACKS[script]).replace(/,\s*(?:serif|sans-serif|monospace)\s*$/, "");
  }

  // 旧稿子里已去掉的字体（楷体、黑体、Rounded）和以前的默认值都改为「跟随主题」
  function normalize(script, key) {
    return find(script, key) ? key : FOLLOW_THEME;
  }

  // 「跟随主题」换成主题的字体：fonts 是稿子的 { zh, en, code }，themeFonts 是主题的，titleFonts 是主题另带的标题字体 { zh, en }（可以没有）。
  // 标题字体：这种文字跟随主题时用主题的标题字体（主题没有就同正文），自己选了字体就连标题也用选的。
  function resolve(fonts, themeFonts, titleFonts = null) {
    const follows = (script) => fonts[script] === FOLLOW_THEME;
    const pick = (script) => (follows(script) ? themeFonts[script] : fonts[script]);
    const display = (script) => (follows(script) ? titleFonts?.[script] ?? themeFonts[script] : fonts[script]);
    return { zh: pick("zh"), en: pick("en"), code: pick("code"), display: { zh: display("zh"), en: display("en") } };
  }

  // 加粗用的字重：字体没有 700、有 600 时（如思源宋体）用 600，免得跳到 900；只有一个字重（得意黑）就不加粗，不让浏览器造假粗体
  function boldOf(key) {
    const weights = bundled.get(key)?.weights || [];
    if (weights.length === 1) return weights[0];
    return weights.length && !weights.includes(700) && weights.includes(600) ? 600 : 700;
  }

  // 标题字体的西文：打包字体直接用它的族名（得意黑、文楷的西文字形也用它们自己的），其余照英文字体取
  const displayLatin = (key) => (bundled.get(key) ? `"${bundled.get(key).family}"` : primary("en", key));

  // 出图用的字体：正文里中日韩文字用中文字体栈（wide），其余用拉丁字体栈（latin：所选英文字体在前，中文字体接在后面兜底）。
  // 标题（display）同理，用主题的标题字体（没有就同正文）。结构的标签字体（页眉页脚）可以是等宽或无衬线，中文仍用正文的中文字体。
  // keys 是 resolve() 之后的字体。
  function cardSetup(keys, structure) {
    const zh = stack("zh", keys.zh);
    const latin = `${primary("en", keys.en)}, ${zh}`;
    const display = keys.display ?? { zh: keys.zh, en: keys.en };
    const label = LABEL_FONTS[structure.labelFont];
    return {
      keys: [...new Set([keys.zh, keys.en, keys.code, label, display.zh, display.en].filter(Boolean))],
      fonts: {
        latin,
        wide: zh,
        display: `${displayLatin(display.en)}, ${stack("zh", display.zh)}`,
        code: `${primary("code", keys.code)}, ${zh}`,
        label: label ? `${primary(structure.labelFont === "mono" ? "code" : "en", label)}, ${zh}` : latin,
      },
      boldWeight: boldOf(keys.zh) === 600 ? 600 : 700,
      displayBold: boldOf(display.zh),
    };
  }

  // 每个打包字体已加载过的字：打字时只为新出现的字再等 document.fonts.load。
  const loadedText = new Map();

  // 分页按最终字形测量：先把用到的打包字体里、这些字用到的 unicode-range 分片（各字重）加载好。
  async function load(keys, text) {
    await ready;
    const wanted = new Set(`${text}${CARD_EXTRA_TEXT}`);
    await Promise.all([...new Set(keys)].map(async (key) => {
      const font = bundled.get(key);
      if (!font) return;
      const loaded = loadedText.get(key) || new Set();
      loadedText.set(key, loaded);
      const pending = [...wanted].filter((char) => !loaded.has(char)).join("");
      if (!pending) return;
      try {
        await Promise.all(font.weights.map((weight) => document.fonts.load(`${weight} 16px "${font.family}"`, pending)));
        [...pending].forEach((char) => loaded.add(char));
      } catch {
        // 个别分片读不到时，缺的字按回退字体排。
      }
    }));
  }

  root.MediaCraftFonts = { FOLLOW_THEME, ready, choices, license, personalOnly, isMissing, stack, normalize, resolve, cardSetup, load };
})(globalThis);
