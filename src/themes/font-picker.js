// 检查器「字体」里的三个选单（中文、英文、代码）。macOS 原生 <select> 的菜单不按各项的字体显示，
// 所以用按钮 + listbox 自己画，每项用自己的字体写名字；按钮的 value 就是选中的字体 key。
(function (root) {
  "use strict";

  const fonts = root.MediaCraftFonts;
  const MAX_LIST_HEIGHT = 340;
  const MIN_LIST_HEIGHT = 160;
  const clamp = (value, min, max) => Math.max(min, Math.min(max, value));

  // buttons：{ zh, en, code } 三个 .font-picker-button；onPick(script, key) 在用户选了一项后调用。
  function createPickers(buttons, onPick) {
    const listOf = (button) => document.getElementById(button.getAttribute("aria-controls"));

    function set(button, key) {
      const script = button.dataset.fontScript;
      const all = fonts.choices(script);
      const choice = all.find((item) => item.key === key) || all[0];
      button.value = choice.key;
      button.textContent = fonts.isMissing(choice) ? `${choice.label}（未下载）` : choice.label;
      button.style.fontFamily = fonts.stack(script, choice.key);
    }

    // reveal 时只滚动列表自身（scrollIntoView 会连带滚动外面的面板）；鼠标悬停不滚动。
    function highlight(list, option, reveal = true) {
      list.querySelector('[role="option"].active')?.classList.remove("active");
      if (!option) return;
      option.classList.add("active");
      list.setAttribute("aria-activedescendant", option.id);
      if (!reveal) return;
      if (option.offsetTop < list.scrollTop) list.scrollTop = option.offsetTop;
      else if (option.offsetTop + option.offsetHeight > list.scrollTop + list.clientHeight) {
        list.scrollTop = option.offsetTop + option.offsetHeight - list.clientHeight;
      }
    }

    function optionFor(list, script, choice, previous, selected) {
      const option = document.createElement("li");
      option.id = `${list.id}-${choice.key}`;
      option.setAttribute("role", "option");
      option.setAttribute("aria-selected", String(choice.key === selected));
      option.dataset.font = choice.key;
      // 跟随主题 / 打包字体 / 系统字体三组之间画一条分隔线
      option.classList.toggle("group-start", Boolean(previous) && Boolean(choice.bundled) !== Boolean(previous.bundled));
      option.style.fontFamily = fonts.stack(script, choice.key);
      option.textContent = choice.label;
      // 许可标注画在名字右边（::after，用界面字体），读屏跟着名字一起读
      const license = fonts.license(choice);
      if (license) {
        option.dataset.license = license.label;
        option.classList.toggle("is-personal", !license.commercial);
      }
      if (fonts.isMissing(choice)) {
        option.setAttribute("aria-disabled", "true");
        const note = document.createElement("small");
        note.textContent = "未下载";
        option.append(note);
      }
      return option;
    }

    function open(button) {
      const script = button.dataset.fontScript;
      const list = listOf(button);
      const all = fonts.choices(script);
      list.replaceChildren(...all.map((choice, index) => optionFor(list, script, choice, all[index - 1], button.value)));
      // 列表不超出窗口底部，放不下的在列表里滚动
      const room = window.innerHeight - button.getBoundingClientRect().bottom - 12;
      list.style.maxHeight = `${clamp(room, MIN_LIST_HEIGHT, MAX_LIST_HEIGHT)}px`;
      list.hidden = false;
      button.setAttribute("aria-expanded", "true");
      highlight(list, list.querySelector('[aria-selected="true"]:not([aria-disabled])') || list.querySelector('[role="option"]:not([aria-disabled])'));
      list.focus();
    }

    function close(button, { focus = false } = {}) {
      listOf(button).hidden = true;
      button.setAttribute("aria-expanded", "false");
      if (focus) button.focus();
    }

    function pick(button, key) {
      set(button, key);
      close(button, { focus: true });
      onPick(button.dataset.fontScript, button.value);
    }

    function onListKey(event, button) {
      const list = event.currentTarget;
      const options = [...list.querySelectorAll('[role="option"]:not([aria-disabled])')];
      const index = options.indexOf(list.querySelector('[role="option"].active'));
      const moves = { ArrowDown: index + 1, ArrowUp: index - 1, Home: 0, End: options.length - 1 };
      if (Object.hasOwn(moves, event.key)) {
        event.preventDefault();
        highlight(list, options[clamp(moves[event.key], 0, options.length - 1)]);
      } else if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        if (options[index]) pick(button, options[index].dataset.font);
      } else if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation(); // 只收起字体列表
        close(button, { focus: true });
      } else if (event.key === "Tab") {
        close(button);
      }
    }

    for (const button of Object.values(buttons)) {
      const list = listOf(button);
      const enabledOption = (event) => event.target.closest('[role="option"]:not([aria-disabled])');
      button.addEventListener("click", () => (list.hidden ? open(button) : close(button)));
      button.addEventListener("keydown", (event) => {
        if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
        event.preventDefault();
        open(button);
      });
      list.addEventListener("keydown", (event) => onListKey(event, button));
      list.addEventListener("click", (event) => {
        const option = enabledOption(event);
        if (option) pick(button, option.dataset.font);
      });
      list.addEventListener("pointermove", (event) => {
        const option = enabledOption(event);
        if (option) highlight(list, option, false);
      });
      document.addEventListener("pointerdown", (event) => {
        if (!list.hidden && !button.parentElement.contains(event.target)) close(button);
      });
    }

    // 打包字体读进来之后，按钮上的名字换成真正的字体（去掉「未下载」）
    void fonts.ready.then(() => {
      for (const button of Object.values(buttons)) set(button, button.value);
    });

    return {
      set: (script, key) => set(buttons[script], key),
      get: (script) => buttons[script].value,
    };
  }

  fonts.createPickers = createPickers;
})(globalThis);
