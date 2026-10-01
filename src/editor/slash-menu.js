// 「/」菜单：在行首输入 / 弹出插入菜单，接着打字筛选（中文名或拼音缩写都行），
// ↑↓ 挑、回车或 Tab 插入、Esc 关掉（留下打的字）。
(() => {
  const { EditorSelection, Prec, Transaction, ViewPlugin, keymap } = window.CodeMirror;

  const MAX_QUERY = 12;

  function matches(command, query) {
    const needle = query.toLowerCase();
    return !needle || command.label.toLowerCase().includes(needle) || command.aliases.some((alias) => alias.startsWith(needle));
  }

  // commands：[{ id, glyph, label, keys?, aliases, run(view) }]
  function slashMenu(commands) {
    const plugin = ViewPlugin.fromClass(class {
      constructor(view) {
        this.view = view;
        this.from = -1; // 「/」的位置；-1 表示菜单没打开
        this.items = [];
        this.active = 0;
        this.timer = 0;
        this.dom = document.createElement("div");
        this.dom.className = "slash-menu pop-menu-panel";
        this.dom.setAttribute("role", "listbox");
        this.dom.setAttribute("aria-label", "快速插入");
        this.dom.hidden = true;
        this.dom.addEventListener("mousedown", (event) => event.preventDefault());
        document.body.append(this.dom);
      }

      get open() {
        return this.from >= 0;
      }

      update(update) {
        if (!this.open && update.docChanged && update.transactions.some((transaction) => transaction.isUserEvent("input.type"))) {
          update.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
            const line = update.state.doc.lineAt(fromB);
            const typedSlash = inserted.toString() === "/" && update.state.selection.main.head === toB;
            if (typedSlash && !update.state.sliceDoc(line.from, fromB).trim()) this.from = fromB;
          });
        }
        if (this.open && (update.docChanged || update.selectionSet || update.focusChanged)) this.sync();
      }

      // 光标离开「/」所在行、选中了文字、打了空格，或「/」被删掉，都收起菜单
      sync() {
        const { state } = this.view;
        const { main } = state.selection;
        const line = state.doc.lineAt(Math.min(this.from, state.doc.length));
        const query = state.sliceDoc(this.from + 1, main.head);
        const stillSlash = this.from < state.doc.length && state.sliceDoc(this.from, this.from + 1) === "/";
        if (!stillSlash || !main.empty || main.head <= this.from || main.head > line.to || /\s/.test(query) || query.length > MAX_QUERY) {
          this.close();
          return;
        }
        this.items = commands.filter((command) => matches(command, query));
        this.active = Math.min(this.active, Math.max(0, this.items.length - 1));
        this.render();
        clearTimeout(this.timer);
        this.timer = setTimeout(() => this.place());
      }

      render() {
        const options = this.items.map((command, index) => {
          const option = document.createElement("div");
          option.className = "menu-item";
          option.setAttribute("role", "option");
          option.setAttribute("aria-label", command.label);
          option.setAttribute("aria-selected", String(index === this.active));
          const glyph = document.createElement("span");
          glyph.className = "menu-glyph";
          glyph.setAttribute("aria-hidden", "true");
          glyph.textContent = command.glyph;
          option.append(glyph, command.label);
          if (command.keys) {
            const keys = document.createElement("kbd");
            keys.textContent = command.keys;
            option.append(keys);
          }
          option.addEventListener("click", () => this.pick(index));
          return option;
        });
        const title = document.createElement("p");
        title.className = "slash-menu-title";
        title.textContent = options.length ? "插入" : "没有这个命令";
        this.dom.replaceChildren(title, ...options);
        this.dom.hidden = false;
      }

      // 贴着「/」下方；下面放不下就翻到上方
      place() {
        if (!this.open) return;
        const at = this.view.coordsAtPos(this.from);
        if (!at) return;
        const margin = 8;
        const { offsetWidth: width, offsetHeight: height } = this.dom; // 布局尺寸，不受弹出时的缩放影响
        const below = at.bottom + 6;
        const top = below + height > window.innerHeight - margin ? Math.max(margin, at.top - height - 6) : below;
        const left = Math.min(Math.max(margin, at.left - 10), window.innerWidth - width - margin);
        this.dom.style.top = `${Math.round(top)}px`;
        this.dom.style.left = `${Math.round(left)}px`;
      }

      move(step) {
        if (!this.open || !this.items.length) return false;
        this.active = (this.active + step + this.items.length) % this.items.length;
        this.render();
        return true;
      }

      // 删掉打的「/筛选词」（不进撤销历史），再执行命令
      pick(index = this.active) {
        const command = this.items[index];
        if (!this.open || !command) return false;
        const { view } = this;
        const { from } = this;
        this.close();
        view.dispatch({
          changes: { from, to: view.state.selection.main.head },
          selection: EditorSelection.cursor(from),
          annotations: Transaction.addToHistory.of(false),
        });
        command.run(view);
        view.focus();
        return true;
      }

      close() {
        if (!this.open) return false;
        this.from = -1;
        this.active = 0;
        this.dom.hidden = true;
        clearTimeout(this.timer);
        return true;
      }

      destroy() {
        clearTimeout(this.timer);
        this.dom.remove();
      }
    }, {
      eventHandlers: {
        blur() {
          this.close();
        },
      },
    });

    const withMenu = (action) => (view) => {
      const menu = view.plugin(plugin);
      return menu?.open ? action(menu) : false;
    };
    return [
      plugin,
      Prec.highest(keymap.of([
        { key: "ArrowDown", run: withMenu((menu) => menu.move(1)) },
        { key: "ArrowUp", run: withMenu((menu) => menu.move(-1)) },
        { key: "Enter", run: withMenu((menu) => menu.pick()) },
        { key: "Tab", run: withMenu((menu) => menu.pick()) },
        { key: "Escape", run: withMenu((menu) => menu.close()) },
      ])),
    ];
  }

  window.MediaCraftEditor.slashMenu = slashMenu;
})();
