// 导出 / 发送的进度条：舞台右下角一张不挡操作的小卡片，显示在做什么、做到哪、能不能取消。
// begin(title, { cancellable }) → task：
//   task.signal              取消时中止（AbortSignal）
//   task.step(detail, done)  更新说明与进度（done 为 0–1；不给时是不定进度）
//   task.note({ text, action: { label, run } })  附一条提醒（比如用了只限个人使用的字体），action 点了之后提醒收起
//   task.succeed(message)    完成：打勾，几秒后自己收起。message：{ title, detail, actions? }，
//                            actions 是 [{ label, disabled?, title?, run }]，run() 返回点完之后说明里写的话；
//                            有按钮或提醒时卡片留着等人关
//   task.fail(error)         出错或被取消：显示原因，出错时留着等人关
(function (root) {
  "use strict";

  const panel = document.querySelector("#outputActivity");
  const title = panel.querySelector(".activity-title");
  const detail = panel.querySelector(".activity-detail");
  const track = panel.querySelector(".activity-track");
  const fill = panel.querySelector(".activity-fill");
  const cancel = panel.querySelector(".activity-cancel");
  const close = panel.querySelector(".activity-close");
  const note = panel.querySelector(".activity-note");
  const noteText = panel.querySelector(".activity-note-text");
  const noteAction = panel.querySelector(".activity-note-action");
  const actions = panel.querySelector(".activity-actions");

  const SUCCESS_HIDE_MS = 3500;
  const CANCEL_HIDE_MS = 1800;
  let current = null;
  // 最近开始的一件（做完了也还是它，直到下一件开始）：晚到的提醒只给它
  let latest = null;
  let hideTimer = 0;
  let dismissNote = null;

  function show(state, heading, text) {
    clearTimeout(hideTimer);
    panel.dataset.state = state;
    title.textContent = heading;
    detail.textContent = text;
    detail.hidden = !text;
    cancel.hidden = state !== "running" || !current?.cancellable;
    close.hidden = state === "running";
    panel.hidden = false;
  }

  function setProgress(done) {
    const known = Number.isFinite(done);
    track.classList.toggle("is-indeterminate", !known);
    if (known) {
      const percent = Math.round(Math.min(1, Math.max(0, done)) * 100);
      fill.style.setProperty("--done", String(percent / 100));
      track.setAttribute("aria-valuenow", String(percent));
    } else {
      fill.style.removeProperty("--done");
      track.removeAttribute("aria-valuenow");
    }
  }

  function hideLater(ms) {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      panel.hidden = true;
    }, ms);
  }

  function setNote(value) {
    note.hidden = !value;
    noteText.textContent = value?.text ?? "";
    noteAction.textContent = value?.action.label ?? "";
    dismissNote = value?.action.run ?? null;
  }

  function actionButton({ label, disabled = false, title: hint = "", run }) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "pill-button";
    button.textContent = label;
    button.disabled = disabled;
    if (hint) button.title = hint;
    button.addEventListener("click", async () => {
      try {
        detail.textContent = await run();
      } catch (error) {
        detail.textContent = `没能完成：${error.message || error}`;
      }
      detail.hidden = false;
    });
    return button;
  }

  function setActions(list = []) {
    actions.replaceChildren(...list.map(actionButton));
    actions.hidden = !list.length;
  }

  function begin(heading, { cancellable = false } = {}) {
    const controller = new AbortController();
    const task = {
      cancellable,
      signal: controller.signal,
      abort: () => {
        const error = new Error("已取消");
        error.name = "AbortError";
        controller.abort(error);
      },
      step(text, done) {
        if (current !== task) return;
        show("running", heading, text);
        setProgress(done);
      },
      note(value) {
        if (latest !== task) return;
        setNote(value);
        // 已经做完的也留着，等人看完提醒
        if (!current) clearTimeout(hideTimer);
      },
      succeed(message) {
        if (current !== task) return;
        current = null;
        show("success", message.title, message.detail || "");
        setProgress(1);
        setActions(message.actions);
        if (!message.actions?.length && note.hidden) hideLater(SUCCESS_HIDE_MS);
      },
      fail(error) {
        if (current !== task) return;
        current = null;
        const cancelled = error?.name === "AbortError";
        // 「发送到 iPhone」这类以西文结尾的标题后面空一格
        const failed = `${heading}${/[A-Za-z0-9]$/.test(heading) ? " " : ""}没有完成`;
        show(cancelled ? "cancelled" : "error", cancelled ? "已取消" : failed, cancelled ? "" : error?.message || "");
        if (cancelled) hideLater(CANCEL_HIDE_MS);
      },
    };
    current = task;
    latest = task;
    setNote(null);
    setActions();
    task.step("", undefined);
    return task;
  }

  cancel.addEventListener("click", () => current?.abort());
  close.addEventListener("click", () => {
    panel.hidden = true;
  });
  noteAction.addEventListener("click", () => {
    dismissNote?.();
    setNote(null);
  });

  root.MediaCraftProgress = { begin };
})(globalThis);
