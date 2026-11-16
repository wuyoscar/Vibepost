// 工作区的面板宽度：编辑区右边、检查器左边各一道分隔条，拖动（或聚焦后按 ← →）改宽度，拖到默认宽度附近会吸住，双击恢复默认；
// 宽度记在本机，下次打开还是它。宽度写成 .workspace 上的 CSS 变量 --editor-width / --inspector-width，
// 列宽的最终上下限由 styles.css 按窗口宽度再收一次。检查器的分隔条在它左边：往左拖是变宽（side: -1）。
// 另外量一次滚动条占多宽，写成 --scrollbar-width（见 measureScrollbar）。
(function (root) {
  "use strict";

  const STORAGE_KEY = "mediacraft.panels.v1";
  const PANELS = Object.freeze({
    editor: { variable: "--editor-width", fallback: 500, min: 360, max: 760, side: 1 },
    inspector: { variable: "--inspector-width", fallback: 340, min: 300, max: 560, side: -1 },
  });
  const KEY_STEP = 16;
  const KEY_STEP_LARGE = 64;
  // 拖到离默认宽度这么近时吸住默认宽度（触控板轻轻一震）
  const SNAP_DISTANCE = 8;

  const workspace = document.querySelector(".workspace");
  const clamp = (panel, value) => Math.round(Math.min(PANELS[panel].max, Math.max(PANELS[panel].min, value)));

  function readStored() {
    try {
      return JSON.parse(root.localStorage.getItem(STORAGE_KEY) || "null") ?? {};
    } catch {
      return {};
    }
  }

  function save() {
    try {
      root.localStorage.setItem(STORAGE_KEY, JSON.stringify(widths));
    } catch {
      // 存不进去只是下次回到默认宽度
    }
  }

  const stored = readStored();
  const widths = Object.fromEntries(Object.entries(PANELS).map(([panel, spec]) => {
    const value = Number(stored[panel]);
    return [panel, Number.isFinite(value) ? clamp(panel, value) : spec.fallback];
  }));

  function apply(panel) {
    workspace.style.setProperty(PANELS[panel].variable, `${widths[panel]}px`);
    for (const handle of document.querySelectorAll(`[data-panel-resize="${panel}"]`)) {
      handle.setAttribute("aria-valuenow", String(widths[panel]));
    }
  }

  function set(panel, value) {
    widths[panel] = clamp(panel, value);
    apply(panel);
  }

  function drag(handle, event) {
    const panel = handle.dataset.panelResize;
    const startX = event.clientX;
    const startWidth = widths[panel];
    const { fallback } = PANELS[panel];
    handle.classList.add("is-dragging");
    document.body.classList.add("is-resizing-editor");
    const move = (moveEvent) => {
      const wanted = startWidth + (moveEvent.clientX - startX) * PANELS[panel].side;
      const snapped = Math.abs(wanted - fallback) <= SNAP_DISTANCE;
      if (snapped && widths[panel] !== fallback) root.MediaCraftNative?.haptic("alignment");
      set(panel, snapped ? fallback : wanted);
    };
    const stop = () => {
      handle.classList.remove("is-dragging");
      document.body.classList.remove("is-resizing-editor");
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", stop);
      window.removeEventListener("pointercancel", stop);
      save();
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", stop);
    window.addEventListener("pointercancel", stop);
  }

  // 滚动条占多宽（接着鼠标的 Mac、Windows 上十几 px；叠在内容上的那种是 0）：写成 --scrollbar-width，
  // 一直给滚动条留着位置的面板（检查器「样式」，styles.css）右边就少留这么多内边距。系统设置可能中途改，回到窗口时再量一次
  function measureScrollbar() {
    const probe = document.createElement("div");
    probe.style.cssText = "position: absolute; top: -200px; width: 100px; height: 100px; overflow: scroll; visibility: hidden;";
    document.body.append(probe);
    const width = probe.offsetWidth - probe.clientWidth;
    probe.remove();
    document.documentElement.style.setProperty("--scrollbar-width", `${width}px`);
  }
  measureScrollbar();
  root.addEventListener("focus", measureScrollbar);

  for (const handle of document.querySelectorAll("[data-panel-resize]")) {
    const panel = handle.dataset.panelResize;
    handle.setAttribute("aria-valuemin", String(PANELS[panel].min));
    handle.setAttribute("aria-valuemax", String(PANELS[panel].max));
    handle.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      drag(handle, event);
    });
    handle.addEventListener("keydown", (event) => {
      const direction = { ArrowLeft: -1, ArrowRight: 1 }[event.key];
      if (!direction) return;
      event.preventDefault();
      set(panel, widths[panel] + direction * PANELS[panel].side * (event.shiftKey ? KEY_STEP_LARGE : KEY_STEP));
      save();
    });
    handle.addEventListener("dblclick", () => {
      set(panel, PANELS[panel].fallback);
      save();
    });
    apply(panel);
  }
})(globalThis);
