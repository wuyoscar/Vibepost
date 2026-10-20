// 内置技能：App 自带、只读、每轮都用的两份。
// - 「使用 Vibepost」就是操作手册（src/engine/manual.js）：块样式、组件、记号的写法与排版经验；
// - 「写作」（src/skills/写作.md，登记表 src/skills/index.js）：怎么写才像一个真人在讲自己的事。
// App 里的 AI 每轮的说明书带两份的短版，工作副本的 AGENTS.md 是两份的全文（src/ai/session.js）；
// 外部 Agent 用 get_manual / get_writing_skill 读（src/mcp/tools.js）；AI 设置里列出、可以查看（src/ai/manuals.js）。
// 用户自己的写作手册（支持目录「写作手册」文件夹）是题材口味的补充，不在这里。
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
