// AI 设置里的两节：
// - 「内置技能」：App 自带的两份（使用 Vibepost、写作，src/skills/skills.js），只读，每份「查看」展开全文；浏览器里也有。
// - 「写作手册」：用户自己的写作手册（名字与说明），每份「打开」（默认的 App）、「在 Finder 中显示」，下面「打开文件夹」。
//   写作手册补充题材的口味，文件在 App 支持目录的「写作手册」文件夹（壳 WritingManuals.swift，经 MediaCraftNative.manuals，
//   第一次用时壳建好空文件夹，App 不自带、也从不删）；AI 每轮在工作副本里拿到一份拷贝与目录，新建、修改经工具 save_writing_manual
//   （src/ai/tools.js，用户确认才存）。每次打开 AI 设置时重新列一遍（用户可能刚用编辑器改过）。浏览器里没有原生壳，这一节不显示。
(function (root) {
  "use strict";

  const native = root.MediaCraftNative?.manuals ?? null;
  const $ = (selector) => document.querySelector(selector);
  const section = $("#writingManuals");
  const list = $("#writingManualList");
  const error = $("#writingManualError");
  const settings = $("#aiSettings");

  function showError(problem) {
    error.hidden = !problem;
    error.textContent = problem ? problem.message || String(problem) : "";
  }

  function run(task) {
    showError(null);
    Promise.resolve().then(task).catch(showError);
  }

  function button(label, title, action) {
    const node = document.createElement("button");
    node.type = "button";
    node.className = "pill-button";
    node.textContent = label;
    node.title = title;
    node.addEventListener("click", () => run(action));
    return node;
  }

  // 一份一行：名字、说明，下面两个按钮（整行是一个以手册名命名的组）
  function row({ name, description }) {
    const item = document.createElement("li");
    item.className = "ai-manual";
    item.setAttribute("role", "group");
    item.setAttribute("aria-label", name);
    const title = document.createElement("span");
    title.className = "ai-manual-name";
    title.textContent = name;
    const note = document.createElement("span");
    note.className = "ai-manual-description";
    note.textContent = description || "（没有说明）";
    const actions = document.createElement("span");
    actions.className = "ai-manual-actions";
    actions.append(
      button("打开", `用默认的 App 打开「${name}」`, () => native.open(name)),
      button("在 Finder 中显示", `在 Finder 中显示「${name}」`, () => native.reveal(name)),
    );
    item.append(title, note, actions);
    return item;
  }

  // 内置技能一份一行：名字、说明，「查看」展开 / 收起全文（只读）
  function builtInRow({ name, description }) {
    const item = document.createElement("li");
    item.className = "ai-manual";
    item.setAttribute("role", "group");
    item.setAttribute("aria-label", name);
    const title = document.createElement("span");
    title.className = "ai-manual-name";
    title.textContent = name;
    const note = document.createElement("span");
    note.className = "ai-manual-description";
    note.textContent = description;
    const text = document.createElement("pre");
    text.className = "ai-skill-text";
    text.tabIndex = 0;
    text.setAttribute("aria-label", `「${name}」全文`);
    text.hidden = true;
    const view = document.createElement("button");
    view.type = "button";
    view.className = "pill-button";
    view.textContent = "查看";
    view.title = `查看「${name}」全文（只读）`;
    view.setAttribute("aria-expanded", "false");
    view.addEventListener("click", () => {
      const open = text.hidden;
      // 第一次展开时才写出全文
      if (open && !text.textContent) text.textContent = root.MediaCraftSkills.document(name);
      text.hidden = !open;
      view.textContent = open ? "收起" : "查看";
      view.setAttribute("aria-expanded", String(open));
    });
    const actions = document.createElement("span");
    actions.className = "ai-manual-actions";
    actions.append(view);
    item.append(title, note, actions, text);
    return item;
  }

  $("#builtInSkillList").replaceChildren(...root.MediaCraftSkills.list().map(builtInRow));

  async function refresh() {
    if (!native) return;
    try {
      const { manuals } = await native.list();
      const empty = document.createElement("li");
      empty.className = "ai-manual-empty";
      empty.textContent = "还没有写作手册：打开文件夹放进 .md 文件，或让 AI 新建一份。";
      list.replaceChildren(...(manuals.length ? manuals.map(row) : [empty]));
      showError(null);
    } catch (problem) {
      showError(problem);
    }
  }

  if (native) {
    section.hidden = false;
    $("#writingManualFolderBtn").addEventListener("click", () => run(() => native.reveal()));
    settings.addEventListener("toggle", () => {
      if (settings.open) void refresh();
    });
  }

  // 工具 save_writing_manual 存好之后刷新（设置开着时看得到新的那份）
  root.MediaCraftWritingManuals = { refresh };
})(window);
