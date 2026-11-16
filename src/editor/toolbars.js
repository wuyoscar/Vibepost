// 编辑区的两条工具：
// - 格式条：「样式」（光标所在那块是什么、换成别的）、B / I / U / S、插入、源码开关；按钮状态跟着光标走。
//   「样式」与「插入」的条目照操作手册（src/engine/manual.js）生成；换样式和卡片上点选一块后的「换样式」是同一个操作
//   （src/cards/blocks.js 的 setStyle），只是这里作用于光标所在的那几块。
// - 选中文字时的浮动条：B / I / U、字色、高亮、链接、改写；字色、高亮的色块由应用按这篇的配色给出。
(() => {
  const { syntax } = window.MediaCraftEditor;

  const SHOW_DELAY = 120;
  const KIND_NAMES = { color: "字色", bg: "高亮" };

  function closeMenu(control) {
    const menu = control.closest("details");
    if (menu) menu.open = false;
  }

  const manual = () => window.MediaCraftManual;
  const cardBlocks = () => window.MediaCraftCardBlocks;
  // 「插入」里非组件的几项用图标（组件用操作手册里的字形）
  const INSERT_ICONS = { divider: "i-divider", pageBreak: "i-page-break", endPage: "i-end-page", code: "i-code" };
  const ALIGN_ICONS = { left: "i-align-left", center: "i-align-center", right: "i-align-right" };

  function glyphOf({ glyph, icon }) {
    const span = document.createElement("span");
    span.className = "menu-glyph";
    span.setAttribute("aria-hidden", "true");
    if (icon) span.innerHTML = `<svg class="icon icon-small"><use href="#${icon}" /></svg>`;
    else span.textContent = glyph ?? "";
    return span;
  }

  // 菜单里的一项：字形、名字（hint 给了就在名字下面写一句说明）、快捷键
  function menuItem({ name, hint, glyph, icon, shortcut, title, role = "menuitem" }) {
    const item = document.createElement("button");
    item.type = "button";
    item.className = "menu-item";
    item.setAttribute("role", role);
    item.setAttribute("aria-label", name);
    if (title) item.title = title;
    const label = document.createElement("span");
    label.className = "menu-item-label";
    label.append(name);
    if (hint) label.append(Object.assign(document.createElement("small"), { className: "menu-hint", textContent: hint }));
    item.append(glyphOf({ glyph, icon }), label);
    if (shortcut) item.append(Object.assign(document.createElement("kbd"), { textContent: shortcut }));
    return item;
  }

  // 「插入」：分割线、分页、结尾页、代码块，一条线下面是全部组件，再一条线下面是「片段」一组（写好的示范段落，
  // src/engine/snippets.js，名字下面一句说明）；图片、实况两项连着文件选择框，写在页面里
  function fillInsertMenu(container) {
    const { inserts, styles } = manual();
    const rule = () => Object.assign(document.createElement("hr"), { className: "menu-rule" });
    const others = inserts.filter((item) => INSERT_ICONS[item.id]).map((item) => {
      const button = menuItem({ name: item.name, icon: INSERT_ICONS[item.id], shortcut: item.shortcut, title: item.summary });
      button.dataset.insert = item.id;
      return button;
    });
    const components = styles.filter((style) => style.component).map((style) => {
      const button = menuItem({ name: style.name, glyph: style.glyph, title: `${style.summary}（${style.when}）` });
      button.dataset.insert = `component-${style.id}`;
      return button;
    });
    const snippets = window.MediaCraftSnippets.list.map((snippet) => {
      const button = menuItem({ name: snippet.name, glyph: snippet.glyph, hint: snippet.summary, title: `${snippet.summary}（用在${snippet.when}）` });
      button.dataset.insert = `snippet-${snippet.id}`;
      return button;
    });
    const heading = Object.assign(document.createElement("p"), { className: "menu-heading", textContent: "片段" });
    // 两栏：左边是图片、实况（页面里写好的两项挪进来）、分割线这几项与组件，右边是片段，菜单不会长过窗口
    const column = (className, children) => {
      const element = document.createElement("div");
      element.className = `insert-menu-column ${className}`;
      element.append(...children);
      return element;
    };
    const files = [...(container.closest(".insert-menu-panel")?.querySelectorAll(":scope > label.menu-item") ?? [])];
    container.replaceChildren(
      column("insert-menu-basics", [...files, rule(), ...others, rule(), ...components]),
      column("insert-menu-snippets", [heading, ...snippets]),
    );
  }

  // 「样式」：段落类、列表类两组，每项带一句说明；最后是组件的对齐
  function fillStyleMenu(panel) {
    const { styles, aligns } = manual();
    const heading = (text) => Object.assign(document.createElement("p"), { className: "menu-heading", textContent: text });
    const group = (family) => styles.filter((style) => style.family === family).map((style) => {
      const title = [style.summary, style.when && `用在${style.when}`, style.avoid].filter(Boolean).join("；");
      const item = menuItem({ name: style.name, hint: style.summary, glyph: style.glyph, title, role: "menuitemradio" });
      item.dataset.style = style.id;
      return item;
    });
    const alignRow = document.createElement("div");
    alignRow.className = "style-menu-aligns";
    alignRow.setAttribute("role", "group");
    alignRow.setAttribute("aria-label", "组件的对齐");
    alignRow.append(...aligns.map((align) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "format-button";
      button.dataset.align = align.id;
      button.setAttribute("aria-label", align.name);
      button.title = `组件${align.name}`;
      button.innerHTML = `<svg class="icon icon-small" aria-hidden="true"><use href="#${ALIGN_ICONS[align.id]}" /></svg>`;
      return button;
    }));
    panel.replaceChildren(heading("段落"), ...group("text"), heading("列表"), ...group("list"), heading("对齐（组件）"), alignRow);
  }

  function bindStyleMenu(editor, menu) {
    const panel = menu.querySelector("[data-style-items]");
    const current = menu.querySelector("[data-style-current]");
    fillStyleMenu(panel);
    const range = () => {
      const { start, end } = editor.selection();
      return [start, end];
    };
    panel.addEventListener("click", (event) => {
      const control = event.target.closest("[data-style], [data-align]");
      if (!control || control.disabled) return;
      const text = editor.getText();
      const next = control.dataset.style
        ? cardBlocks().restyleRange(text, range(), control.dataset.style)
        : cardBlocks().alignRange(text, range(), control.dataset.align);
      menu.open = false;
      if (next !== null) editor.apply(next);
      editor.focus();
    });
    // 光标所在的那几块：正文没变时不重新解析
    let parsedDoc = null;
    let text = "";
    let blocks = [];
    return function sync() {
      const { state } = editor.view;
      if (state.doc !== parsedDoc) {
        parsedDoc = state.doc;
        text = state.doc.toString();
        blocks = cardBlocks().list(text);
      }
      const { from, to } = state.selection.main;
      const found = cardBlocks().blocksIn(text, [from, to], blocks);
      const style = cardBlocks().styleOf(found[0]);
      current.textContent = style ? manual().style(style).name : "样式";
      for (const item of panel.querySelectorAll("[data-style]")) {
        item.disabled = !found.length;
        item.setAttribute("aria-checked", String(item.dataset.style === style));
      }
      const component = found.find((block) => block.type === "container" && manual().component(block.name));
      const align = component ? manual().alignOf(component.attrs) ?? "left" : null;
      for (const button of panel.querySelectorAll("[data-align]")) {
        button.disabled = !component;
        button.setAttribute("aria-pressed", String(button.dataset.align === align));
      }
    };
  }

  // 格式条：「样式」、加粗等行内格式、插入、源码
  function bindFormatBar(editor, bar) {
    const sourceToggle = bar.querySelector("[data-source-toggle]");
    const run = (control, action) => control.addEventListener("click", () => {
      action();
      closeMenu(control);
      editor.focus();
    });
    fillInsertMenu(bar.querySelector("[data-insert-items]"));
    const syncStyle = bindStyleMenu(editor, bar.querySelector("#styleMenu"));
    bar.querySelectorAll("[data-mark]").forEach((button) => run(button, () => editor.command("toggleInline", button.dataset.mark)));
    bar.querySelectorAll("[data-insert]").forEach((button) => run(button, () => editor.insert(button.dataset.insert)));
    run(sourceToggle, () => editor.setSourceMode(!editor.sourceMode()));

    return function sync() {
      const { state } = editor.view;
      const { from, to } = state.selection.main;
      const formats = syntax.formatsAt(state, from, to);
      bar.querySelectorAll("[data-mark]").forEach((button) => button.setAttribute("aria-pressed", String(Boolean(formats[button.dataset.mark]))));
      sourceToggle.setAttribute("aria-pressed", String(editor.sourceMode()));
      syncStyle();
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
