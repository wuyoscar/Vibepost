// 正文编辑器：CodeMirror 6，默认实时预览（ADR 0002），⌘/ 切到源码。Markdown 文本是唯一的底层格式，
// 显示层只加装饰，存进去什么就读出来什么（一字不差，含 \r）。
// 应用只通过 create() 返回的小接口读写正文、选区、焦点与撤销历史。
(() => {
  const {
    Annotation, Compartment, EditorSelection, EditorState, EditorView, Prec, StateEffect, Transaction,
    dropCursor, history, historyKeymap, insertNewline, invertedEffects, isolateHistory, keymap, redo, standardKeymap, undo,
  } = window.CodeMirror;
  const { syntax, commands, livePreview, refreshPreview, review, slashMenu } = window.MediaCraftEditor;

  // 应用自己改的正文（换稿、App API 改稿、插图片）：照常进撤销历史，但不再回头通知应用
  const programmatic = Annotation.define();

  // 图片属性的改动（版式、裁剪……）不在正文里，但和正文一起进撤销历史：{ id, field, before, after }。
  // 撤销时换成反方向的同一种改动，应用在 onMediaEdit 里把它落到图片上。
  const mediaEdit = StateEffect.define();
  // 稿子其余字段的改动（标题、主题、配色、字体、版式、整组图片……）同样随正文进撤销历史：{ field, before, after }，
  // 应用在 onFieldEdit 里落到稿子上（AI 的修改与撤回版本用它，见 src/ai/）。
  const fieldEdit = StateEffect.define();
  const undoableEffects = invertedEffects.of((transaction) => transaction.effects
    .filter((effect) => effect.is(mediaEdit) || effect.is(fieldEdit))
    .map((effect) => (effect.is(mediaEdit) ? mediaEdit : fieldEdit).of({ ...effect.value, before: effect.value.after, after: effect.value.before }))
    .reverse());

  // 微信表情复制出来只剩 [微笑] 这样的文字，粘贴时换成 Emoji（卡片上不认微信表情代码）。
  // 名字按微信表情面板里的叫法（含旧版与新加的），Emoji 是我们自己挑的意思最近的一个。
  // 按类别分组（笑、哭与难过、生气与不屑、惊讶害怕与困惑、其他神情、手势与动作、心物品与节日），组内按拼音排序；
  // 顺序不影响替换，只为好找。
  const EMOJI_FOR_WECHAT_FACE = new Map([
    // 笑
    ["呲牙", "😁"], ["得意", "😏"], ["调皮", "😜"], ["飞吻", "😘"], ["害羞", "🙈"], ["憨笑", "😄"], ["嘿哈", "🥋"],
    ["坏笑", "😼"], ["机智", "🤓"], ["奸笑", "😈"], ["破涕为笑", "😂"], ["亲亲", "😚"], ["色", "😍"], ["社会社会", "🕶️"],
    ["偷笑", "🤭"], ["吐舌", "😛"], ["哇", "🤩"], ["旺柴", "🐶"], ["微笑", "🙂"], ["笑脸", "😃"], ["耶", "🥳"],
    ["阴险", "🐍"], ["悠闲", "😌"], ["愉快", "😊"],
    // 哭与难过
    ["大哭", "😭"], ["可怜", "🥹"], ["苦涩", "🥲"], ["快哭了", "🥺"], ["裂开", "🫠"], ["流泪", "😢"], ["难过", "😞"],
    ["失望", "😔"], ["衰", "😩"], ["叹气", "😮‍💨"], ["委屈", "😣"], ["捂脸", "🤦"],
    // 生气与不屑
    ["傲慢", "🧐"], ["白眼", "😒"], ["鄙视", "🤨"], ["差劲", "🙁"], ["打脸", "🤕"], ["发怒", "😠"], ["翻白眼", "🙄"],
    ["疯了", "🤯"], ["怄火", "😡"], ["撇嘴", "🫤"], ["右哼哼", "😤"], ["咒骂", "🤬"], ["抓狂", "😫"], ["左哼哼", "😤"],
    // 惊讶、害怕与困惑
    ["闭嘴", "🤐"], ["擦汗", "😅"], ["发呆", "😶"], ["发抖", "🫨"], ["尴尬", "😬"], ["汗", "💦"], ["惊恐", "😱"],
    ["惊讶", "😮"], ["囧", "😧"], ["恐惧", "😨"], ["冷汗", "😰"], ["流汗", "😓"], ["糗大了", "🫣"], ["让我看看", "👀"],
    ["天啊", "😲"], ["无语", "😑"], ["吓", "🙀"], ["嘘", "🤫"], ["疑问", "🤔"], ["晕", "😵‍💫"], ["皱眉", "☹️"],
    ["Emm", "😐"],
    // 其他神情
    ["吃瓜", "🍿"], ["奋斗", "🔥"], ["鬼魂", "👻"], ["哈欠", "🥱"], ["饥饿", "🤤"], ["抠鼻", "👃"], ["骷髅", "💀"],
    ["酷", "😎"], ["困", "😪"], ["脸红", "😳"], ["生病", "🤒"], ["睡", "😴"], ["吐", "🤮"], ["猪头", "🐷"],
    // 手势与动作
    ["666", "💯"], ["爱你", "🤟"], ["抱拳", "🫡"], ["勾引", "🫴"], ["鼓掌", "👏"], ["好的", "🆗"], ["合十", "🙏"],
    ["回头", "🔄"], ["加油", "🙌"], ["磕头", "🙇"], ["强", "👍"], ["强壮", "💪"], ["敲打", "🔨"], ["拳头", "👊"],
    ["弱", "👎"], ["胜利", "✌️"], ["跳绳", "🪢"], ["跳跳", "🕺"], ["投降", "🏳️"], ["握手", "🤝"], ["拥抱", "🤗"],
    ["再见", "👋"], ["转圈", "🌀"], ["NO", "🙅"], ["OK", "👌"],
    // 心、物品与节日
    ["爱情", "💑"], ["爱心", "❤️"], ["爆竹", "🧨"], ["便便", "💩"], ["菜刀", "🔪"], ["蛋糕", "🎂"], ["刀", "🗡️"],
    ["凋谢", "🥀"], ["發", "💰"], ["饭", "🍚"], ["福", "🏮"], ["红包", "🧧"], ["鸡", "🐔"], ["咖啡", "☕"], ["篮球", "🏀"],
    ["礼物", "🎁"], ["玫瑰", "🌹"], ["啤酒", "🍺"], ["瓢虫", "🐞"], ["乒乓", "🏓"], ["庆祝", "🎉"], ["闪电", "⚡"],
    ["太阳", "☀️"], ["西瓜", "🍉"], ["心碎", "💔"], ["烟花", "🎆"], ["月亮", "🌙"], ["炸弹", "💣"], ["足球", "⚽"],
    ["嘴唇", "💋"],
  ]);
  const WECHAT_FACE_CODE = new RegExp(`\\[(${[...EMOJI_FOR_WECHAT_FACE.keys()].join("|")})\\]`, "g");

  function wechatFacesToEmoji(text) {
    return text.replace(WECHAT_FACE_CODE, (code, name) => EMOJI_FOR_WECHAT_FACE.get(name) ?? code);
  }

  // 整篇换成 next 时真正变了的那一段（前后相同的部分不动，撤销后光标也落在原处）
  function difference(current, next) {
    let start = 0;
    const shorter = Math.min(current.length, next.length);
    while (start < shorter && current.charCodeAt(start) === next.charCodeAt(start)) start += 1;
    let currentEnd = current.length;
    let nextEnd = next.length;
    while (currentEnd > start && nextEnd > start && current.charCodeAt(currentEnd - 1) === next.charCodeAt(nextEnd - 1)) {
      currentEnd -= 1;
      nextEnd -= 1;
    }
    return { from: start, to: currentEnd, insert: next.slice(start, nextEnd) };
  }

  // 从 Finder 拖文件进来时插在哪：落在一行开头的上半截插在这一行前面，落在别处插在这一行后面（不把一行字拆开）；
  // 空行就插在这一行。返回 { at, edge }，edge 是提示线画在这一行的上沿 before、下沿 after 还是中间 line。
  function fileDropPosition(view, event) {
    const pos = view.posAtCoords({ x: event.clientX, y: event.clientY }) ?? view.state.selection.main.head;
    const line = view.state.doc.lineAt(pos);
    if (!line.text.trim()) return { at: line.from, edge: "line" };
    if (pos > line.from) return { at: line.to, edge: "after" };
    const block = view.lineBlockAt(line.from);
    return event.clientY < view.documentTop + block.top + block.height / 2
      ? { at: line.from, edge: "before" }
      : { at: line.to, edge: "after" };
  }

  // 拖文件时的落点提示：一条横线画在要插入的两行之间（代替只指到字符之间的拖放光标）。
  function fileDropLine(view) {
    let line = null;
    let hideTimer = 0;
    return {
      show({ at, edge }) {
        clearTimeout(hideTimer);
        if (!line) {
          line = document.createElement("div");
          line.className = "cm-file-drop-line";
          line.setAttribute("aria-hidden", "true");
          view.scrollDOM.append(line);
          view.dom.classList.add("is-file-drag");
        }
        const block = view.lineBlockAt(at);
        const y = { before: block.top, after: block.bottom, line: block.top + block.height / 2 }[edge];
        // 横线对齐正文那一栏（去掉编辑区左右的留白）
        const scroller = view.scrollDOM.getBoundingClientRect();
        const content = view.contentDOM.getBoundingClientRect();
        const style = getComputedStyle(view.contentDOM);
        const left = content.left + parseFloat(style.paddingLeft);
        // 纵向位置写在 translate 上：换落点时线滑过去（media.css）
        line.style.translate = `0 ${view.documentTop - scroller.top + view.scrollDOM.scrollTop + y}px`;
        line.style.left = `${left - scroller.left + view.scrollDOM.scrollLeft}px`;
        line.style.width = `${content.right - parseFloat(style.paddingRight) - left}px`;
      },
      // 拖着在编辑区的子元素之间移动也会触发 dragleave，稍等一下，还在拖就不收起
      hide(delay = 0) {
        clearTimeout(hideTimer);
        hideTimer = setTimeout(() => {
          line?.remove();
          line = null;
          view.dom.classList.remove("is-file-drag");
        }, delay);
      },
    };
  }

  // 「/」菜单与格式条「插入」里的命令。pickImages / pickLivePhoto 由应用打开文件选择。
  // 「/」菜单与格式条「插入」里的项：名字、字形、拼音缩写与说明都在操作手册（src/engine/manual.js），组件插入的是中文写法。
  // 标题、列表、引用这类段落样式不在这里：用格式条的「样式」，或在预览里点选那一块换（直接写 # 、- 、> 也行）
  function insertCommands(hooks) {
    const manual = window.MediaCraftManual;
    const runs = {
      image: () => hooks.pickImages(),
      live: () => hooks.pickLivePhoto(),
      divider: commands.insertDivider,
      pageBreak: commands.insertPageBreak,
      endPage: commands.insertEndPage,
      code: commands.insertCodeBlock,
    };
    return [
      ...manual.inserts.map((item) => ({
        id: item.id, glyph: item.glyph, label: item.name, keys: item.shortcut, aliases: item.keys, hint: item.summary, run: runs[item.id],
      })),
      // 组件：卡片上各有样子
      ...manual.styles.filter((style) => style.component).map((style) => ({
        id: `component-${style.id}`, glyph: style.glyph, label: style.name, aliases: [...style.aliases, ...style.keys], hint: style.summary,
        run: (view) => commands.insertComponent(view, style.name, style.body ?? ""),
      })),
    ];
  }

  // options：
  //   parent                    放编辑器的元素
  //   media(ref)                ref 为 { id } 或 { path }，返回 { id, name, src, kind, missing }
  //   onEditImage(detail)       点了缩略图卡片：{ imageIds, ratio, source }，source 是这块在正文里的范围 [起, 止]
  //   onChange({ history })     用户改了正文（打字、格式命令、粘贴、撤销 / 重做……）；应用自己改的不通知
  //   onMediaEdit(edits)        图片属性改了（edit() 记下的，或撤销 / 重做到的）：[{ id, field, after }]
  //   onFieldEdit(edits)        稿子的其他字段改了（edit() 记下的，或撤销 / 重做到的）：[{ field, after }]
  //   onPasteFiles(files, at)   粘贴进来图片文件
  //   onDropFiles(transfer, at) 从 Finder 拖进来文件，at 是松手的那一行之前或之后（整行插入的位置）
  //   pickImages() / pickLivePhoto()  「/」菜单里的插图片、插实况
  function create(options) {
    const listeners = new Set();
    const historySlot = new Compartment();
    const modeSlot = new Compartment();
    const accessSlot = new Compartment();
    const menuCommands = insertCommands(options);
    let source = false;
    // 只读有两个来源：应用（内置说明书）与审阅 AI 的修改，任一个在就只读
    let appReadOnly = false;
    let reviewing = false;

    const preview = () => livePreview({ media: options.media, onEditImage: options.onEditImage });
    const access = (readOnly) => [EditorState.readOnly.of(readOnly), EditorView.editable.of(!readOnly)];
    const toggleSource = () => {
      api.setSourceMode(!source);
      return true;
    };
    const run = (command, ...args) => (view) => command(view, ...args);

    const shortcuts = keymap.of([
      { key: "Mod-1", run: run(commands.setBlockStyle, "h1") },
      { key: "Mod-2", run: run(commands.setBlockStyle, "h2") },
      { key: "Mod-3", run: run(commands.setBlockStyle, "h3") },
      { key: "Mod-0", run: run(commands.setBlockStyle, "paragraph") },
      { key: "Mod-b", run: run(commands.toggleInline, "bold") },
      { key: "Mod-i", run: run(commands.toggleInline, "italic") },
      { key: "Mod-u", run: run(commands.toggleInline, "underline") },
      { key: "Mod-Shift-x", run: run(commands.toggleInline, "strike") },
      { key: "Mod-k", run: commands.toggleLink },
      { key: "Mod-/", run: toggleSource },
      { key: "Mod-Enter", run: commands.insertPageBreak },
      { key: "Enter", run: (view) => commands.continueMarkup(view) || insertNewline(view) },
    ]);

    const hasFiles = (transfer) => Array.from(transfer?.types || []).includes("Files");
    let dropLine = null;
    const fileEvents = EditorView.domEventHandlers({
      paste(event, view) {
        const files = Array.from(event.clipboardData?.files || []);
        if (files.length) {
          event.preventDefault();
          if (!view.state.readOnly) options.onPasteFiles(files, view.state.selection.main.head);
          return true;
        }
        const text = event.clipboardData?.getData("text/plain") ?? "";
        const converted = wechatFacesToEmoji(text);
        if (converted === text || view.state.readOnly) return false;
        event.preventDefault();
        view.dispatch(view.state.replaceSelection(converted), { userEvent: "input.paste", scrollIntoView: true });
        return true;
      },
      dragover(event, view) {
        if (!hasFiles(event.dataTransfer)) return false;
        event.preventDefault();
        if (!view.state.readOnly) {
          dropLine ??= fileDropLine(view);
          dropLine.show(fileDropPosition(view, event));
        }
        return true;
      },
      dragleave() {
        dropLine?.hide(80);
        return false;
      },
      drop(event, view) {
        if (!hasFiles(event.dataTransfer)) return false;
        event.preventDefault();
        dropLine?.hide();
        if (view.state.readOnly) return true;
        options.onDropFiles(event.dataTransfer, fileDropPosition(view, event).at);
        return true;
      },
    });

    const notify = EditorView.updateListener.of((update) => {
      const transactions = update.transactions;
      const edits = transactions.flatMap((transaction) => transaction.effects.filter((effect) => effect.is(mediaEdit)))
        .map(({ value }) => ({ id: value.id, field: value.field, after: value.after }));
      if (edits.length) options.onMediaEdit(edits);
      const fields = transactions.flatMap((transaction) => transaction.effects.filter((effect) => effect.is(fieldEdit)))
        .map(({ value }) => ({ field: value.field, after: value.after }));
      if (fields.length) options.onFieldEdit(fields);
      if (update.docChanged && !transactions.some((transaction) => transaction.annotation(programmatic))) {
        options.onChange({ history: transactions.some((transaction) => transaction.isUserEvent("undo") || transaction.isUserEvent("redo")) });
      }
      listeners.forEach((listener) => listener(update));
    });

    const view = new EditorView({
      parent: options.parent,
      state: EditorState.create({
        doc: "",
        extensions: [
          EditorState.lineSeparator.of("\n"),
          syntax.field,
          historySlot.of(history()),
          undoableEffects,
          review.field,
          modeSlot.of(preview()),
          accessSlot.of(access(false)),
          EditorView.lineWrapping,
          EditorView.contentAttributes.of({ "aria-label": "正文", spellcheck: "false", autocorrect: "off", autocapitalize: "off" }),
          dropCursor(),
          slashMenu(menuCommands),
          Prec.high(shortcuts),
          Prec.high(fileEvents),
          keymap.of([...historyKeymap, ...standardKeymap]),
          notify,
        ],
      }),
    });

    const change = (spec, userEvent) => view.dispatch({
      ...spec,
      userEvent,
      annotations: [programmatic.of(true), isolateHistory.of("full")],
    });
    let cachedDoc = null;
    let cachedText = "";

    const api = {
      view,
      getText() {
        if (view.state.doc !== cachedDoc) {
          cachedDoc = view.state.doc;
          cachedText = cachedDoc.toString();
        }
        return cachedText;
      },
      // 换一篇稿子：新的正文、光标回到开头、撤销历史从头开始，上一篇的审阅标注收起
      load(text) {
        reviewing = false;
        view.dispatch({
          changes: { from: 0, to: view.state.doc.length, insert: text },
          selection: EditorSelection.cursor(0),
          effects: [review.set.of(null), accessSlot.reconfigure(access(appReadOnly))],
          annotations: [programmatic.of(true), Transaction.addToHistory.of(false)],
        });
        api.clearHistory();
        view.scrollDOM.scrollTop = 0;
      },
      // 整篇换成 text（只改变了的那一段），是撤销历史里单独的一步
      setText(text) {
        const current = api.getText();
        if (text !== current) change({ changes: difference(current, text) }, "input.replace");
      },
      // 把 [from, to) 换成 text，光标停在换进去的字后面
      replace(from, to, text) {
        change({ changes: { from, to, insert: text }, selection: EditorSelection.cursor(from + text.length) }, "input.replace");
      },
      // 撤销历史里单独的一步：正文换成 text（只改变了的那一段，不给就不改正文），
      // 同时记下图片属性的改动 media：[{ id, field, before, after }] 与稿子其他字段的改动 fields：[{ field, before, after }]。
      // 什么都没变时返回 false。
      edit({ text, media = [], fields = [] }) {
        const current = api.getText();
        const changes = text === undefined || text === current ? [] : [difference(current, text)];
        const effects = [
          ...media.filter((item) => JSON.stringify(item.before) !== JSON.stringify(item.after)).map((item) => mediaEdit.of(item)),
          ...fields.map((item) => fieldEdit.of(item)),
        ];
        if (!changes.length && !effects.length) return false;
        change({ changes, effects }, "input.replace");
        return true;
      },
      // 插入独占整行的内容（图片标记等），返回插入后光标的位置
      insertBlock(text, at = view.state.selection.main.head) {
        const { changes, caret } = commands.blockInsertion(view.state, text, Math.min(Math.max(0, at), view.state.doc.length));
        change({ changes, selection: EditorSelection.cursor(caret), scrollIntoView: true }, "input.insert");
        return caret;
      },
      selection() {
        const { from, to } = view.state.selection.main;
        return { start: from, end: to, text: view.state.sliceDoc(from, to) };
      },
      select(start, end = start, { focus = true } = {}) {
        const { length } = view.state.doc;
        const from = Math.min(Math.max(0, Math.trunc(Number(start)) || 0), length);
        const to = Math.min(Math.max(from, Math.trunc(Number(end)) || 0), length);
        if (focus) view.focus();
        view.dispatch({ selection: EditorSelection.range(from, to), scrollIntoView: true });
        return api.selection();
      },
      focus() {
        view.focus();
      },
      hasFocus() {
        return view.dom.contains(document.activeElement);
      },
      undo: () => undo(view),
      redo: () => redo(view),
      clearHistory() {
        view.dispatch({ effects: historySlot.reconfigure([]) });
        view.dispatch({ effects: historySlot.reconfigure(history()) });
      },
      setReadOnly(readOnly) {
        appReadOnly = Boolean(readOnly);
        view.dispatch({ effects: accessSlot.reconfigure(access(appReadOnly || reviewing)) });
      },
      // 审阅 AI 的修改（src/editor/review.js）：{ hunks, decide(index, decision) }，null 收起。
      // 审阅时只读（⌘Z 也不动正文）；刚打开时滚到第一处修改。
      showReview(value) {
        const opening = !reviewing && Boolean(value);
        reviewing = Boolean(value);
        const first = value?.hunks[0];
        view.dispatch({
          effects: [
            review.set.of(value),
            accessSlot.reconfigure(access(appReadOnly || reviewing)),
            ...(opening && first ? [EditorView.scrollIntoView(Math.min(first.from, view.state.doc.length), { y: "center" })] : []),
          ],
        });
      },
      sourceMode: () => source,
      setSourceMode(on) {
        source = Boolean(on);
        view.dispatch({
          effects: modeSlot.reconfigure(source ? EditorView.editorAttributes.of({ class: "is-source" }) : preview()),
          scrollIntoView: true,
        });
      },
      // 图片素材变了（换图、裁剪、画面读回来）：重画缩略图卡片
      refreshMedia() {
        if (!source) view.dispatch({ effects: refreshPreview.of(null) });
      },
      scrollTo(pos) {
        view.dispatch({ effects: EditorView.scrollIntoView(Math.min(pos, view.state.doc.length), { y: "center" }) });
      },
      // 格式命令（src/editor/commands.js），作用于当前选区
      command(name, ...args) {
        return commands[name](view, ...args);
      },
      // 「插入」里的一项：h1、image、pageBreak……
      insert(id) {
        return menuCommands.find((command) => command.id === id).run(view);
      },
      onUpdate(listener) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    };
    return api;
  }

  // 焦点在能打字的地方（输入框、正文）时，⌘Z 留给它自己
  const isTextEntry = (target) => Boolean(target?.closest?.("input, textarea, select, [contenteditable]:not([contenteditable='false'])"));

  // 焦点不在输入框时（比如刚在预览里删了图），⌘Z / ⇧⌘Z 也撤销 / 重做正文的改动；对话框开着时不管。
  function bindUndoKeys(editor) {
    document.addEventListener("keydown", (event) => {
      if (event.defaultPrevented || !(event.metaKey || event.ctrlKey) || event.altKey) return;
      if (event.key.toLowerCase() !== "z" || isTextEntry(event.target)) return;
      const dialogOpen = Boolean(document.querySelector(".modal:not(.hidden)"));
      if (dialogOpen) return;
      event.preventDefault();
      (event.shiftKey ? editor.redo : editor.undo)();
    });
  }

  window.MediaCraftEditor.create = create;
  window.MediaCraftEditor.bindUndoKeys = bindUndoKeys;
})();
