// 编辑区的两条工具：
// - 精简格式条：段落样式、B / I / U / S、列表、引用、插入、源码开关；按钮状态跟着光标所在的格式走。
// - 选中文字时的浮动条：B / I / U、字色、高亮、链接、改写；字色、高亮的色块由应用按这篇的配色给出。
(() => {
  const { syntax } = window.MediaCraftEditor;

  const SHOW_DELAY = 120;
  const KIND_NAMES = { color: "字色", bg: "高亮" };

  function closeMenu(control) {
    const menu = control.closest("details");
    if (menu) menu.open = false;
  }

  // 格式条只管写字：加粗等行内格式、插入、源码。段落的样式（标题、列表、引用、组件）在预览里点选那一块改（src/stage/blocks.js），
  // 不在这里另开一个入口
  function bindFormatBar(editor, bar) {
    const sourceToggle = bar.querySelector("[data-source-toggle]");
    const run = (control, action) => control.addEventListener("click", () => {
      action();
      closeMenu(control);
      editor.focus();
    });
    bar.querySelectorAll("[data-mark]").forEach((button) => run(button, () => editor.command("toggleInline", button.dataset.mark)));
    bar.querySelectorAll("[data-insert]").forEach((button) => run(button, () => editor.insert(button.dataset.insert)));
    run(sourceToggle, () => editor.setSourceMode(!editor.sourceMode()));

    return function sync() {
      const { state } = editor.view;
      const { from, to } = state.selection.main;
      const formats = syntax.formatsAt(state, from, to);
      bar.querySelectorAll("[data-mark]").forEach((button) => button.setAttribute("aria-pressed", String(Boolean(formats[button.dataset.mark]))));
      sourceToggle.setAttribute("aria-pressed", String(editor.sourceMode()));
    };
  }

  // 一行色块：点哪个就把它的颜色交给 pick；色块随配色重画（fillSwatches），点击交给这一行统一接
  function swatchGrid(pick) {
    const grid = document.createElement("div");
    grid.className = "selection-tools-swatches";
    grid.addEventListener("click", (event) => {
      const swatch = event.target.closest(".selection-tools-swatch");
      if (swatch) pick(swatch.dataset.color);
    });
    return grid;
  }

  // 色块的提示是名字加色值（「强调 #0043ce」）
  function fillSwatches(grid, kind, swatches) {
    grid.replaceChildren(...swatches.map(({ name, color }) => {
      const swatch = document.createElement("button");
      swatch.type = "button";
      swatch.className = "selection-tools-swatch";
      swatch.dataset.color = color;
      swatch.style.background = color;
      swatch.title = `${name} ${color}`;
      swatch.setAttribute("aria-label", `${KIND_NAMES[kind]} ${name} ${color}`);
      return swatch;
    }));
  }

  function bindSelectionToolbar(editor, toolbar, swatches) {
    const { view } = editor;
    const palettes = {
      color: toolbar.querySelector('[data-color-menu="color"]'),
      bg: toolbar.querySelector('[data-color-menu="bg"]'),
    };
    let timer = 0;
    let pointerDown = false;

    const setPalette = (kind) => {
      for (const [name, palette] of Object.entries(palettes)) {
        palette.hidden = name !== kind;
        toolbar.querySelector(`[data-color-menu-toggle="${name}"]`).setAttribute("aria-expanded", String(name === kind));
      }
      if (!toolbar.hidden) place();
    };
    const hide = () => {
      clearTimeout(timer);
      toolbar.hidden = true;
      setPalette(null);
    };

    // 贴在选区上方，居中对齐选区；上面放不下就放到选区下方。
    function place() {
      const { from, to, empty } = view.state.selection.main;
      const start = empty ? null : view.coordsAtPos(from, 1);
      const end = empty ? null : view.coordsAtPos(to, -1);
      if (!start || !end) {
        hide();
        return;
      }
      toolbar.hidden = false;
      const pane = view.dom.getBoundingClientRect();
      const { width, height } = toolbar.getBoundingClientRect();
      const margin = 8;
      const center = start.top === end.top ? (start.left + end.right) / 2 : pane.left + pane.width / 2;
      const left = Math.min(Math.max(pane.left + margin, center - width / 2), Math.max(pane.left + margin, pane.right - width - margin));
      const above = start.top - height - margin;
      const top = above >= pane.top ? above : end.bottom + margin;
      toolbar.style.left = `${Math.round(left)}px`;
      toolbar.style.top = `${Math.round(top)}px`;
    }

    function schedule() {
      clearTimeout(timer);
      const { empty } = view.state.selection.main;
      const focused = editor.hasFocus() || toolbar.contains(document.activeElement);
      if (empty || !focused || view.state.readOnly) {
        hide();
        return;
      }
      timer = setTimeout(() => {
        if (!pointerDown) place();
      }, SHOW_DELAY);
    }

    const apply = (action) => {
      action();
      setPalette(null);
      editor.focus();
      schedule();
    };

    const grids = {};
    for (const [kind, palette] of Object.entries(palettes)) {
      grids[kind] = swatchGrid((color) => apply(() => editor.command("setInlineColor", kind, color)));
      palette.prepend(grids[kind]);
      const custom = palette.querySelector("input[type=color]");
      custom.addEventListener("change", () => apply(() => editor.command("setInlineColor", kind, custom.value)));
      palette.querySelector("[data-clear-color]").addEventListener("click", () => apply(() => editor.command("setInlineColor", kind, null)));
      toolbar.querySelector(`[data-color-menu-toggle="${kind}"]`).addEventListener("click", () => setPalette(palette.hidden ? kind : null));
    }
    for (const button of toolbar.querySelectorAll("[data-mark]")) {
      button.addEventListener("click", () => apply(() => editor.command("toggleInline", button.dataset.mark)));
    }
    toolbar.querySelector("[data-link]").addEventListener("click", () => apply(() => editor.command("toggleLink")));
    // 改写：把选中的文字交给 AI 会话。AI 会话（ticket 14/15）监听这个事件；现在没人监听，点了不改稿子。
    toolbar.querySelector("[data-rewrite]").addEventListener("click", () => {
      view.dom.dispatchEvent(new CustomEvent("mediacraft:rewrite", { bubbles: true, detail: editor.selection() }));
      hide();
    });
    // 点浮动条上的按钮不抢走编辑器的焦点与选区（取色器除外，它要自己的焦点）
    toolbar.addEventListener("mousedown", (event) => {
      if (!event.target.closest("input")) event.preventDefault();
    });

    view.dom.addEventListener("pointerdown", () => {
      pointerDown = true;
    });
    document.addEventListener("pointerup", () => {
      if (!pointerDown) return;
      pointerDown = false;
      schedule();
    });
    document.addEventListener("pointerdown", (event) => {
      if (!toolbar.contains(event.target) && !view.dom.contains(event.target)) hide();
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && !toolbar.hidden) hide();
    });
    view.scrollDOM.addEventListener("scroll", () => {
      if (!toolbar.hidden) place();
    });
    view.dom.addEventListener("focusin", schedule);
    // 焦点离开编辑器（不是去了浮动条上）：等焦点落定再判断要不要收起
    view.dom.addEventListener("focusout", (event) => {
      if (!toolbar.contains(event.relatedTarget)) setTimeout(schedule);
    });

    // 配色变了才重画两行色块；已经写进正文的颜色不跟着变
    let shownSwatches = "";
    function refreshSwatches() {
      const { text, highlight } = swatches();
      const signature = JSON.stringify([text, highlight]);
      if (signature === shownSwatches) return;
      shownSwatches = signature;
      fillSwatches(grids.color, "color", text);
      fillSwatches(grids.bg, "bg", highlight);
    }
    refreshSwatches();

    function sync(update) {
      const typed = update.transactions.some((transaction) => transaction.isUserEvent("input.type") || transaction.isUserEvent("delete"));
      if (typed) hide();
      else if (update.selectionSet || update.docChanged || update.focusChanged) schedule();
    }
    return { sync, refreshSwatches };
  }

  // formatBar / selectionTools：页面里现成的两条工具的元素；
  // swatches()：现在该有的字色、高亮色块 { text, highlight }，每项 { name, color }。
  // 返回 refreshSwatches()：配色可能变了时调，色块有变化才重画。
  function bindToolbars(editor, { formatBar, selectionTools, swatches }) {
    const syncBar = bindFormatBar(editor, formatBar);
    const toolbar = bindSelectionToolbar(editor, selectionTools, swatches);
    syncBar();
    editor.onUpdate((update) => {
      syncBar();
      toolbar.sync(update);
    });
    return { refreshSwatches: toolbar.refreshSwatches };
  }

  window.MediaCraftEditor.bindToolbars = bindToolbars;
})();
