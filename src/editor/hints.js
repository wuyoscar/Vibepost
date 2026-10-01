// 发布检查在正文里的标注（由 src/publish/assistant.js 驱动）：命中的字下面画一道线，警告是红色波浪线、提示是黄色虚线，
// 指针停上去显示原因。只加装饰，不改文本；正文改动时标注跟着挪，下一次检查再整批换掉。
(() => {
  const { Decoration, EditorView, StateEffect, StateField } = window.CodeMirror;

  const setHints = StateEffect.define();

  const field = StateField.define({
    create: () => Decoration.none,
    update(value, transaction) {
      for (const effect of transaction.effects) {
        if (effect.is(setHints)) return effect.value;
      }
      return transaction.docChanged ? value.map(transaction.changes) : value;
    },
    provide: (self) => EditorView.decorations.from(self),
  });

  // editor：MediaCraftEditor.create() 的接口。返回 { set(markdown, hints) }：
  // hints 是 [{ from, to, level: "warn" | "hint", title }]，按 markdown 这一版正文算的；正文已经变了就不换（下一次检查会带着新的来）。
  function bindHints(editor) {
    const { view } = editor;
    view.dispatch({ effects: StateEffect.appendConfig.of(field) });
    return {
      set(markdown, hints) {
        if (editor.getText() !== markdown) return;
        const marks = hints
          .filter(({ from, to }) => from < to)
          .map(({ from, to, level, title }) => Decoration.mark({ class: `cm-hint is-${level}`, attributes: { title } }).range(from, to));
        view.dispatch({ effects: setHints.of(Decoration.set(marks, true)) });
      },
    };
  }

  window.MediaCraftEditor.bindHints = bindHints;
})();
