// 检查器里滑杆旁边的读数换成小的数值框，像 PPT 的字号框：能直接输入精确的值（回车或离开时生效，超出范围收进来），
// ↑ ↓ 按一档（⇧ 十档），左右两个小按钮 − ＋ 也是一档。一档是滑杆的 data-nudge（没写就是它的 step）。
// 数值框只是另一种拨滑杆的方式：改了就给滑杆设值、发 input 与 change，原来听滑杆的代码都不用动。
// 读数由原来的 <output for> 显示的地方（src/shell.js 的 syncReadouts）一起更新：它调 sync()。
(function (root) {
  "use strict";

  const steppers = [];

  // 显示几位小数：跟滑杆的 step 走（行距 0.01 → 两位，字号 1 → 整数）
  function format(range) {
    const step = String(range.step || "1");
    const places = step.includes(".") ? step.split(".")[1].length : 0;
    return Number(range.value).toFixed(places);
  }

  function setValue(range, value) {
    const min = Number(range.min);
    const max = Number(range.max);
    const step = Number(range.step) || 1;
    const clamped = Math.min(max, Math.max(min, value));
    const stepped = Number((Math.round((clamped - min) / step) * step + min).toFixed(4));
    if (stepped === Number(range.value)) return false;
    range.value = String(stepped);
    range.dispatchEvent(new Event("input", { bubbles: true }));
    range.dispatchEvent(new Event("change", { bubbles: true }));
    return true;
  }

  // range：<input type="range">；label：读屏时的名字（字号、行距……）；replace：原来的读数元素（换成数值框）
  function attach(range, label, replace) {
    const nudge = () => Number(range.dataset.nudge || range.step || 1);
    const wrap = document.createElement("span");
    wrap.className = "stepper";
    const button = (sign, text) => {
      const element = document.createElement("button");
      element.type = "button";
      element.className = "stepper-button";
      element.textContent = text;
      element.tabIndex = -1;
      element.setAttribute("aria-label", `${label}${sign < 0 ? "调小" : "调大"}一档`);
      element.addEventListener("click", () => {
        setValue(range, Number(range.value) + sign * nudge());
        sync();
      });
      return element;
    };
    const field = document.createElement("input");
    field.type = "text";
    field.inputMode = "decimal";
    field.className = "stepper-field";
    field.setAttribute("aria-label", `${label}（输入数值）`);
    field.autocomplete = "off";
    field.spellcheck = false;
    const commit = () => {
      const typed = Number(field.value.replace(/[^\d.\-]/g, ""));
      if (field.value.trim() !== "" && Number.isFinite(typed)) setValue(range, typed);
      field.value = format(range);
    };
    field.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        commit();
        field.select();
      } else if (event.key === "Escape") {
        field.value = format(range);
        field.blur();
      } else if (event.key === "ArrowUp" || event.key === "ArrowDown") {
        event.preventDefault();
        setValue(range, Number(range.value) + (event.key === "ArrowUp" ? 1 : -1) * nudge() * (event.shiftKey ? 10 : 1));
        field.value = format(range);
      }
    });
    field.addEventListener("blur", commit);
    field.addEventListener("focus", () => field.select());
    wrap.append(button(-1, "−"), field, button(1, "＋"));
    if (replace) {
      replace.classList.add("visually-hidden");
      replace.after(wrap);
    } else range.after(wrap);
    const entry = { range, field, wrap };
    steppers.push(entry);
    range.addEventListener("input", () => {
      if (document.activeElement !== field) field.value = format(range);
    });
    field.value = format(range);
    return entry;
  }

  function sync() {
    for (const { range, field } of steppers) {
      if (document.activeElement !== field) field.value = format(range);
      field.disabled = range.disabled;
      for (const button of field.parentElement.querySelectorAll("button")) button.disabled = range.disabled;
    }
  }

  // 检查器里每个 .slider-row：名字取 .option-label（或滑杆的 aria-label），读数是同一行的 .slider-value
  function enhance(container) {
    for (const row of container.querySelectorAll(".slider-row")) {
      const range = row.querySelector('input[type="range"]');
      if (!range || row.querySelector(".stepper")) continue;
      const label = row.querySelector(".option-label")?.textContent.trim() || range.getAttribute("aria-label") || "数值";
      attach(range, label, row.querySelector(".slider-value"));
    }
  }

  root.MediaCraftSteppers = Object.freeze({ enhance, attach, sync, setValue });
})(window);
