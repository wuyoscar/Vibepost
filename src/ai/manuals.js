// AI 设置里的两节：
// - 「内置技能」：App 自带的两份（使用 Vibepost、写作，src/skills/skills.js），只读，每份「查看」展开全文；浏览器里也有。
// - 「写作手册」：补充题材的口味，内置的几份和用户自己的列在一起（src/skills/skills.js 的 MediaCraftManualLibrary）：
//   · 用户自己的在前：每份「打开」（默认的 App）、「在 Finder 中显示」；和内置同名的（定制过的那份）标「已定制」。
//     文件在 App 支持目录的「写作手册」文件夹（壳 WritingManuals.swift；第一次用时壳建好空文件夹，App 从不删里面的文件）。
//   · 内置的标「内置」：「查看」展开全文（只读），「复制一份来改」把它存成同名的用户手册并打开，之后用的是用户那份；
//     删掉那个文件就回到内置的。
//   AI 每轮在工作副本里拿到内置手册的全文（AGENTS.md）与用户手册的拷贝和目录，新建、修改经工具 save_writing_manual
//   （src/ai/tools.js，用户确认才存）。每次打开 AI 设置时重新列一遍（用户可能刚用编辑器改过）。
//   浏览器里没有原生壳：只列内置的几份，不能复制。
(function (root) {
  "use strict";

  const library = root.MediaCraftManualLibrary;
  const $ = (selector) => document.querySelector(selector);
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

  // 一行的骨架：名字（后面可以带一个小标记）、说明、按钮（整行是一个以手册名命名的组）
  function frame(name, description, badge) {
    const item = document.createElement("li");
    item.className = "ai-manual";
    item.setAttribute("role", "group");
    item.setAttribute("aria-label", name);
    const title = document.createElement("span");
    title.className = "ai-manual-name";
    title.textContent = name;
    if (badge) {
      const mark = document.createElement("span");
      mark.className = "ai-manual-badge";
      mark.textContent = badge;
      title.append(mark);
    }
    const note = document.createElement("span");
    note.className = "ai-manual-description";
    note.textContent = description || "（没有说明）";
    const actions = document.createElement("span");
    actions.className = "ai-manual-actions";
    item.append(title, note, actions);
    return { item, actions };
  }

  // 「查看」：展开 / 收起全文（只读），第一次展开时才取全文
  function viewer(name, item, load) {
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
    view.addEventListener("click", () => run(async () => {
      const open = text.hidden;
      if (open && !text.textContent) text.textContent = await load();
      text.hidden = !open;
      view.textContent = open ? "收起" : "查看";
      view.setAttribute("aria-expanded", String(open));
    }));
    item.append(text);
    return view;
  }

  // 用户自己的一份：「打开」「在 Finder 中显示」；和内置同名的标「已定制」
  function row({ name, description, customized }) {
    const { item, actions } = frame(name, description, customized ? "已定制" : "");
    actions.append(
      button("打开", `用默认的 App 打开「${name}」`, () => library.open(name)),
      button("在 Finder 中显示", `在 Finder 中显示「${name}」`, () => library.reveal(name)),
    );
    return item;
  }

  // 内置的一份：「查看」全文，「复制一份来改」存成同名的用户手册并打开（浏览器里没有壳，只能查看）
  function builtInManualRow({ name, description }) {
    const { item, actions } = frame(name, description, "内置");
    actions.append(viewer(name, item, async () => (await library.read(name)).content));
    if (library.canEdit()) {
      actions.append(button("复制一份来改", `把「${name}」复制成你自己的写作手册并打开；之后 AI 用你改过的这份，删掉文件就回到内置的`, async () => {
        await library.customize(name);
        await refresh();
        await library.open(name);
      }));
    }
    return item;
  }

  // 内置技能一份一行：名字、说明，「查看」展开 / 收起全文（只读）
  function builtInRow({ name, description }) {
    const { item, actions } = frame(name, description, "");
    actions.append(viewer(name, item, () => root.MediaCraftSkills.document(name)));
    return item;
  }

  $("#builtInSkillList").replaceChildren(...root.MediaCraftSkills.list().map(builtInRow));

  async function refresh() {
    try {
      const { manuals } = await library.list();
      list.replaceChildren(...manuals.map((manual) => (manual.builtIn ? builtInManualRow(manual) : row(manual))));
      showError(null);
    } catch (problem) {
      showError(problem);
    }
  }

  const folder = $("#writingManualFolderBtn");
  folder.hidden = !library.canEdit();
  folder.addEventListener("click", () => run(() => library.reveal()));
  settings.addEventListener("toggle", () => {
    if (settings.open) void refresh();
  });

  // 工具 save_writing_manual 存好之后刷新（设置开着时看得到新的那份）
  root.MediaCraftWritingManuals = { refresh };
})(window);
