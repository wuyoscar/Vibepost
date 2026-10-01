// 下拉菜单（<details class="pop-menu">：段落样式、插入、AI 设置……）的共同行为：
// 同时只开一个；点菜单以外的地方或按 Esc 收起；弹出层不超出窗口左右边缘（放不下时往里挪）。
(function (root) {
  "use strict";

  const EDGE = 8; // 弹出层离窗口边缘至少这么远

  const menus = () => [...document.querySelectorAll("details.pop-menu")];
  const openMenus = () => menus().filter((menu) => menu.open);

  // 弹出层放不下时往窗口里挪：先回到默认位置，再按布局量（offset*，不受弹出时的缩放影响）
  function keepInsideWindow(menu) {
    const panel = menu.querySelector(".pop-menu-panel");
    if (!panel) return;
    panel.style.left = "";
    // offsetLeft 相对的是 offsetParent，不一定是菜单本身（配色库、色轮的弹出层相对那一行，撑满检查器宽）
    const left = (panel.offsetParent ?? menu).getBoundingClientRect().left + panel.offsetLeft;
    const overflowRight = left + panel.offsetWidth - (root.innerWidth - EDGE);
    const overflowLeft = EDGE - left;
    const shift = overflowRight > 0 ? -Math.min(overflowRight, Math.max(0, left - EDGE)) : Math.max(0, overflowLeft);
    if (shift) panel.style.left = `${panel.offsetLeft + shift}px`;
  }

  for (const menu of menus()) {
    menu.addEventListener("toggle", () => {
      if (!menu.open) return;
      for (const other of openMenus()) if (other !== menu) other.open = false;
      keepInsideWindow(menu);
    });
  }

  document.addEventListener("pointerdown", (event) => {
    for (const menu of openMenus()) if (!menu.contains(event.target)) menu.open = false;
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    const open = openMenus();
    if (!open.length) return;
    event.preventDefault();
    for (const menu of open) {
      const hadFocus = menu.contains(document.activeElement);
      menu.open = false;
      if (hadFocus) menu.querySelector("summary").focus();
    }
  });

  root.addEventListener("resize", () => openMenus().forEach(keepInsideWindow));
})(globalThis);
