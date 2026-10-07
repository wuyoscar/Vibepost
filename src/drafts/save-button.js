// 顶栏的保存按钮：这篇存好了没有（已保存 / 保存中 / 没存上），点它或按 ⌘S 马上存。
// 状态来自稿件模块（src/drafts/drafts.js 的 save-state）：改动后它自己过一会儿就存，这里只是让人看得见、也能催一下。
// App 里还把「有没有没存进本机的」告诉壳，窗口关闭按钮上显示小圆点（isDocumentEdited）。内置说明书不存，按钮藏起来。
(function (root) {
  "use strict";

  const drafts = root.MediaCraftDrafts;
  const native = root.MediaCraftNative?.windows ?? null;
  const button = document.querySelector("#saveButton");
  const label = button.querySelector(".save-label");
  const glyph = button.querySelector("use");
  const LABELS = { saved: "已保存", pending: "保存中", saving: "保存中", error: "没存上" };
  const ICONS = { saved: "#i-check", pending: "#i-save", saving: "#i-save", error: "#i-alert" };
  // 按了保存（或 ⌘S）之后对勾跳一下的时长，与 CSS 的 save-confirm 一致
  const CONFIRM_TIME = 600;
  let reportedEdited = null;
  let confirmTimer = 0;

  // 「已保存」的时间：今天的只写几点几分，更早的带上日期
  function when(at) {
    const date = new Date(at);
    const clock = date.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false });
    return date.toDateString() === new Date().toDateString() ? clock : `${date.getMonth() + 1}月${date.getDate()}日 ${clock}`;
  }

  function tooltip(state) {
    if (state.status === "error") return `没存上：${state.error}。点一下再存一次（⌘S）`;
    if (state.status === "saved") return `${state.savedAt ? `已保存（${when(state.savedAt)}）` : "已保存"} · ⌘S 马上保存`;
    return "正在存进本机 · ⌘S 马上保存";
  }

  // 窗口关闭按钮上的小圆点：等着存、正在写、没存上都算有没存的
  function reportEdited(edited) {
    if (!native?.edited || edited === reportedEdited) return;
    reportedEdited = edited;
    native.edited(edited).catch(() => {
      reportedEdited = null;
    });
  }

  function confirmSaved() {
    clearTimeout(confirmTimer);
    button.classList.remove("is-confirmed");
    void button.offsetWidth; // 连按几次也重新跳
    button.classList.add("is-confirmed");
    confirmTimer = setTimeout(() => button.classList.remove("is-confirmed"), CONFIRM_TIME);
  }

  function show(state) {
    button.hidden = state.status === "none";
    button.dataset.state = state.status;
    label.textContent = LABELS[state.status] ?? LABELS.saved;
    glyph.setAttribute("href", ICONS[state.status] ?? ICONS.saved);
    button.title = tooltip(state);
    reportEdited(state.status === "pending" || state.status === "saving" || state.status === "error");
    if (state.explicit && state.status === "saved") confirmSaved();
  }

  async function press() {
    if (drafts.saveState().status === "none") return;
    try {
      await drafts.saveNow();
    } catch {
      // 原因已经在按钮上（没存上），过一会儿也会自动再试
    }
  }

  button.addEventListener("click", () => void press());
  // ⌘S：先于编辑器接住（捕获阶段），不让浏览器弹「存储网页」；内置说明书没什么可存，也不弹
  document.addEventListener(
    "keydown",
    (event) => {
      if (!(event.metaKey || event.ctrlKey) || event.shiftKey || event.altKey || event.key.toLowerCase() !== "s") return;
      event.preventDefault();
      void press();
    },
    true,
  );
  drafts.on("save-state", show);
  show(drafts.saveState());
})(window);
