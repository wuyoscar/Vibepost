// 检查器「高级 › 卡片样式」：这一篇自己的 CSS（稿子的 cardCss），只作用在这一篇的 HTML 卡片上（关在卡片的 Shadow DOM 里，
// 碰不到 App 界面；进卡片前过滤，见 src/cards/cards.js 的 cleanCss）。改了停一下再出图（出图后顺带存盘）。
(function (root) {
  "use strict";

  const DELAY = 400;

  function create({ onChange }) {
    const field = document.querySelector("#cardCssInput");
    const count = document.querySelector("#cardCssCount");
    let timer = 0;

    function show() {
      const rules = (field.value.match(/\{/g) ?? []).length;
      count.textContent = field.value.trim() ? `${rules} 条规则` : "";
    }

    field.addEventListener("input", () => {
      show();
      clearTimeout(timer);
      timer = setTimeout(() => onChange(field.value), DELAY);
    });
    // Tab 在这里输入两个空格，不跳走
    field.addEventListener("keydown", (event) => {
      if (event.key !== "Tab" || event.shiftKey || event.metaKey) return;
      event.preventDefault();
      field.setRangeText("  ", field.selectionStart, field.selectionEnd, "end");
      field.dispatchEvent(new Event("input"));
    });

    return {
      write(value) {
        clearTimeout(timer);
        field.value = value;
        show();
      },
    };
  }

  root.MediaCraftCardCss = { create };
})(window);
