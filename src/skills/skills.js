// 内置技能：App 自带、只读、每轮都用的两份；以及写作手册的库（内置的几份题材手册 + 用户自己的）。
// - 「使用 Vibepost」就是操作手册（src/engine/manual.js）：块样式、组件、记号的写法与排版经验；
// - 「写作」（src/skills/写作.md，登记表 src/skills/index.js）：怎么写才像一个真人在讲自己的事。
// App 里的 AI 每轮的说明书带两份的短版，工作副本的 AGENTS.md 是两份的全文（src/ai/session.js）；
// 外部 Agent 用 get_manual / get_writing_skill 读（src/mcp/tools.js）；AI 设置里列出、可以查看（src/ai/manuals.js）。
// 写作手册是题材口味的补充（经验分享、教程、测评、论文解读……），AI 按题材挑一份、用户也能点名：
// - 内置的几份（src/skills/手册/*.md，登记表同上）：App 自带、只读，随 App 更新；
// - 用户自己的（支持目录「写作手册」文件夹，壳经 MediaCraftNative.manuals 读写）：想怎么改就怎么改。
//   用户的手册和内置的同名时用用户那份（「复制一份来改」就是把内置的存成同名的用户手册），删掉那个文件就回到内置的。
// MediaCraftManualLibrary 把两处合在一起，页面上凡是列手册、读手册的地方都经它（设置、输入框的「写作手册」、
// save_writing_manual、外部 Agent 的 list / read）。浏览器里没有壳，只有内置的几份。
(function (root) {
  "use strict";

  const manual = root.MediaCraftManual;
  const writing = root.MediaCraftSkillRegistry.find((entry) => entry.name === "写作");

  const SKILLS = [
    {
      name: "使用 Vibepost",
      description: "Vibepost 的操作手册：块样式、组件、记号的写法与排版经验。每轮都带着。",
      document: () => manual.document(),
      brief: () => manual.brief(),
    },
    {
      name: writing.name,
      description: writing.description,
      document: () => writing.markdown,
      brief: () => writing.brief,
    },
  ];

  function find(name) {
    const skill = SKILLS.find((item) => item.name === name);
    if (!skill) throw new RangeError(`没有这个内置技能：${name}（有：${SKILLS.map((item) => item.name).join("、")}）`);
    return skill;
  }

  // ===== 写作手册：内置的 + 用户自己的 =====
  const BUILT_IN_MANUALS = ["经验分享", "教程攻略", "测评种草", "论文与技术解读"].map((name) => {
    const entry = root.MediaCraftManualRegistry.find((item) => item.name === name);
    if (!entry) throw new Error(`登记表里没有内置写作手册「${name}」（运行 node scripts/build-skills.mjs）`);
    return entry;
  });
  const builtInManual = (name) => BUILT_IN_MANUALS.find((item) => item.name === name) ?? null;
  const nativeManuals = () => root.MediaCraftNative?.manuals ?? null;
  function requireNative() {
    const native = nativeManuals();
    if (!native) throw new Error("自己的写作手册只在 Vibepost App 里有（浏览器里只有内置的几份）");
    return native;
  }

  // { manuals: [{ name, description, builtIn, customized }], folder }：用户自己的在前（和内置同名的标 customized），
  // 后面是没被同名手册盖住的内置手册（builtIn）
  async function listManuals() {
    const native = nativeManuals();
    const { manuals: own, folder } = native ? await native.list() : { manuals: [], folder: "" };
    const mine = new Set(own.map((manual) => manual.name));
    return {
      folder,
      manuals: [
        ...own.map(({ name, description }) => ({ name, description, builtIn: false, customized: Boolean(builtInManual(name)) })),
        ...BUILT_IN_MANUALS.filter((manual) => !mine.has(manual.name))
          .map(({ name, description }) => ({ name, description, builtIn: true, customized: false })),
      ],
    };
  }

  // 一份的全文：{ name, description, content, builtIn }。用户有同名的读用户那份
  async function readManual(name) {
    const builtIn = builtInManual(name);
    const native = nativeManuals();
    if (!builtIn) return { ...(await requireNative().read(name)), builtIn: false };
    if (native && (await native.list()).manuals.some((manual) => manual.name === name)) return { ...(await native.read(name)), builtIn: false };
    return { name: builtIn.name, description: builtIn.description, content: builtIn.markdown, builtIn: true };
  }

  // 「复制一份来改」：把一份内置手册存成同名的用户手册（已经有同名的就不动它），之后用的是用户这份
  async function customizeManual(name) {
    const builtIn = builtInManual(name);
    if (!builtIn) throw new RangeError(`没有这份内置写作手册：${name}`);
    const native = requireNative();
    if ((await native.list()).manuals.some((manual) => manual.name === name)) return native.read(name);
    return native.save({ name: builtIn.name, description: builtIn.description, content: builtIn.markdown });
  }

  // 工作副本的 AGENTS.md 里接在两份技能后面的一节：没被用户同名手册盖住的内置手册全文
  // （用户自己的手册由壳拷进工作副本的「写作手册/」，目录接在更后面）
  async function manualsSection() {
    const { manuals } = await listManuals();
    const builtIn = manuals.filter((manual) => manual.builtIn).map((manual) => builtInManual(manual.name));
    if (!builtIn.length) return "";
    return [
      "# 内置写作手册",
      "App 自带的题材手册，和用户自己的写作手册一样用：按这篇的题材挑一份，都不合适就只照写作技能写；用户本条点名的优先。"
        + "它们只补充题材的取材与结构，和写作技能冲突时照写作技能。用户的写作手册里有同名的，以用户那份为准（下面已经不列）。",
      ...builtIn.map((manual) => `${manual.markdown.trimEnd().replace(/^# /, "## ").replace(/\n## /g, "\n### ")}`),
    ].join("\n\n") + "\n";
  }

  root.MediaCraftManualLibrary = Object.freeze({
    list: listManuals,
    read: readManual,
    customize: customizeManual,
    // 新建或整份换掉一份用户手册（名字和内置的一样时，就是定制那一份）
    save: (manual) => requireNative().save(manual),
    reveal: (name) => requireNative().reveal(name),
    open: (name) => requireNative().open(name),
    // 有没有壳（能不能存、能不能在 Finder 中显示）
    canEdit: () => Boolean(nativeManuals()),
    agentsSection: manualsSection,
  });

  root.MediaCraftSkills = Object.freeze({
    // [{ name, description }]，按上面的顺序
    list: () => SKILLS.map(({ name, description }) => ({ name, description, builtIn: true })),
    // 一份的全文（Markdown）
    document: (name) => find(name).document(),
    // 一份的短版
    brief: (name) => find(name).brief(),
    // 工作副本的 AGENTS.md：两份全文，操作手册在前（壳在后面再接用户写作手册的目录）
    agentsFile: () => SKILLS.map((skill) => skill.document().trimEnd()).join("\n\n") + "\n",
  });
})(window);
