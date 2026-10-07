// 格式条上的「A−」「A+」：像 PPT 的「减小 / 增大字号」，每按一下这篇的字号 ±1（24–40，和检查器「版式 › 字号」是同一个值，
// 走 App API 的 drafts.update({ fontSize }, { undoable: true })，所以滑块跟着动、⌘Z 能撤回、也会存进本机）。
// 快捷键 ⇧⌘> / ⇧⌘<（按键位置认，不分键盘布局），在哪都能按（捕获阶段先于编辑器）。到了上下限按钮变灰。
(function (root) {
  "use strict";

  const drafts = root.MediaCraftDrafts;
  // 范围和检查器的字号滑块一样（src/workspace/style-form.js 的 NUMBERS.fontSize）
  const [min, max] = [24, 40];
  const buttons = [...document.querySelectorAll("[data-font-step]")];
  const slider = document.querySelector("#fontSizeInput");
  const LABELS = { "-1": "字号减小", "1": "字号增大" };
  const KEYS = { "-1": "⇧⌘<", "1": "⇧⌘>" };
  let busy = false;

  const mc = () => root.mediacraft;
  const current = () => Number(slider?.value) || root.MediaCraftStyleForm.DEFAULTS.fontSize;

  // 按钮的灰与提示：到了 24 / 40 那一头按不动；提示里写着现在的字号
  function refresh() {
    const size = current();
    for (const button of buttons) {
      const step = Number(button.dataset.fontStep);
      const next = size + step;
      button.disabled = next < min || next > max;
      button.title = `${LABELS[button.dataset.fontStep]}（现在 ${size}）${KEYS[button.dataset.fontStep]}`;
    }
  }

  async function step(delta) {
    const api = mc();
    if (busy || !api) return;
    const draft = await api.drafts.current();
    if (!draft || draft.readOnly) return;
    const next = Math.min(max, Math.max(min, (Number(draft.fontSize) || root.MediaCraftStyleForm.DEFAULTS.fontSize) + delta));
    if (next === draft.fontSize) return;
    busy = true;
    try {
      await api.drafts.update({ fontSize: next }, { undoable: true });
    } catch {
      // 内置说明书等改不了的：按钮本来就该灰着，这里不再提示
    } finally {
      busy = false;
      refresh();
    }
  }

  for (const button of buttons) {
    button.addEventListener("click", () => {
      void step(Number(button.dataset.fontStep)).then(() => mc()?.editor.focus());
    });
  }
  // ⇧⌘> / ⇧⌘<：按 code 认（Period / Comma），不管布局与输入法；先于编辑器接住
  document.addEventListener(
    "keydown",
    (event) => {
      if (!(event.metaKey || event.ctrlKey) || !event.shiftKey || event.altKey) return;
      const delta = event.code === "Period" ? 1 : event.code === "Comma" ? -1 : 0;
      if (!delta) return;
      event.preventDefault();
      void step(delta);
    },
    true,
  );
  slider?.addEventListener("input", refresh);
  drafts?.on?.("change", refresh);
  refresh();
})(window);
