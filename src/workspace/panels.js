// 工作区的面板宽度：编辑区右边的分隔条拖动（或聚焦后按 ← →）改编辑区宽度，拖到默认宽度附近会吸住，双击恢复默认；宽度记在本机，下次打开还是它。
// 宽度写成 .workspace 上的 CSS 变量 --editor-width，列宽的最终上下限由 styles.css 按窗口宽度再收一次。
(function (root) {
  "use strict";

  const STORAGE_KEY = "mediacraft.panels.v1";
  const PANELS = Object.freeze({
    editor: { variable: "--editor-width", fallback: 500, min: 360, max: 760 },
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
      const wanted = startWidth + moveEvent.clientX - startX;
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
      set(panel, widths[panel] + direction * (event.shiftKey ? KEY_STEP_LARGE : KEY_STEP));
      save();
    });
    handle.addEventListener("dblclick", () => {
      set(panel, PANELS[panel].fallback);
      save();
    });
    apply(panel);
  }
})(globalThis);
