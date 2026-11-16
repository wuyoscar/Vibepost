// 查找与替换：编辑区上方的一条查找栏，按的是 Markdown 原文（不分大小写）。
//   ⌘F 打开并聚焦查找框（选中的文字在一行以内时先填进去），⌥⌘F 同时展开替换；
//   ⌘G / ⇧⌘G 下一个 / 上一个（查找栏收着时也行），查找框里 ↩ / ⇧↩ 同样；Esc 收起，回到正文。
//   全部替换是撤销历史里的一步。只读（内置说明书、审阅 AI 的修改）时能找不能换。⌃⌘F 留给系统全屏。
(() => {
  const { Decoration, EditorSelection, EditorView, StateEffect, StateField } = window.CodeMirror;

  const MAX_MATCHES = 999;
  const PREFILL_LENGTH = 100;

  const setQuery = StateEffect.define();
  const markMatch = Decoration.mark({ class: "cm-find-match" });
  const markCurrent = Decoration.mark({ class: "cm-find-match is-current" });

  const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

  // query 在 text 里的每一处 [from, to)，最多 MAX_MATCHES 处
  function findAll(text, query) {
    if (!query) return [];
    const pattern = new RegExp(escapeRegExp(query), "giu");
    const matches = [];
    for (const match of text.matchAll(pattern)) {
      matches.push({ from: match.index, to: match.index + match[0].length });
      if (matches.length === MAX_MATCHES) break;
    }
    return matches;
  }

  // 选区正好是哪一处（没有为 -1）
  function currentIndex(matches, selection) {
    const { from, to } = selection.main;
    return matches.findIndex((match) => match.from === from && match.to === to);
  }

  function searchState(query, state) {
    const matches = findAll(state.doc.toString(), query);
    const current = currentIndex(matches, state.selection);
    const marks = matches.map((match, index) => (index === current ? markCurrent : markMatch).range(match.from, match.to));
    return { query, matches, current, decorations: Decoration.set(marks) };
  }

  const searchField = StateField.define({
    create: (state) => searchState("", state),
    update(value, transaction) {
      const next = transaction.effects.find((effect) => effect.is(setQuery));
      if (next) return searchState(next.value, transaction.state);
      if (!value.query || (!transaction.docChanged && !transaction.selection)) return value;
      return searchState(value.query, transaction.state);
    },
    provide: (field) => EditorView.decorations.from(field, (value) => value.decorations),
  });

  // editor：MediaCraftEditor.create() 的接口。elements：{ bar, toggle（页脚的「查找」按钮）}。notify(message) 写状态栏。
  function bindFind(editor, { bar, toggle }, notify) {
    const { view } = editor;
    const $ = (selector) => bar.querySelector(selector);
    const findInput = $("[data-find-query]");
    const replaceInput = $("[data-find-replacement]");
    const count = $("[data-find-count]");
    const replaceRow = $("[data-find-replace-row]");
    const replaceToggle = $("[data-find-toggle-replace]");
    const replaceButtons = [$("[data-find-replace-one]"), $("[data-find-replace-all]")];

    view.dispatch({ effects: StateEffect.appendConfig.of(searchField) });
    const search = () => view.state.field(searchField);
    const isOpen = () => !bar.hidden;

    function syncBar() {
      const { query, matches, current } = search();
      count.textContent = !query ? "" : matches.length ? `${current + 1 || "–"}/${matches.length}${matches.length === MAX_MATCHES ? "+" : ""}` : "无结果";
      count.classList.toggle("is-empty", Boolean(query) && !matches.length);
      for (const button of replaceButtons) button.disabled = view.state.readOnly || !matches.length;
      bar.querySelectorAll("[data-find-step]").forEach((button) => {
        button.disabled = !matches.length;
      });
    }

    function setReplaceShown(shown) {
      replaceRow.hidden = !shown;
      replaceToggle.setAttribute("aria-expanded", String(shown));
    }

    function applyQuery() {
      view.dispatch({ effects: setQuery.of(isOpen() ? findInput.value : "") });
    }

    // 选中这一处并滚到它；focus 为 false 时焦点留在查找栏
    function selectMatch(match, focus) {
      if (focus) view.focus();
      view.dispatch({ selection: EditorSelection.range(match.from, match.to), scrollIntoView: true });
    }

    // 从选区往后（backward 时往前）找下一处，到头了从另一头接着找
    function step(backward = false, { focus = !isOpen() } = {}) {
      if (!search().query && findInput.value) view.dispatch({ effects: setQuery.of(findInput.value) });
      const { matches } = search();
      if (!matches.length) return false;
      const { from, to } = view.state.selection.main;
      const match = backward
        ? matches.findLast((item) => item.from < from) ?? matches[matches.length - 1]
        : matches.find((item) => item.from >= to) ?? matches[0];
      selectMatch(match, focus);
      return true;
    }

    // 打字时：从选区开头起的第一处（没有就回到第一处）
    function seek() {
      applyQuery();
      const { matches } = search();
      if (!matches.length) return;
      const { from } = view.state.selection.main;
      selectMatch(matches.find((match) => match.from >= from) ?? matches[0], false);
    }

    function open({ replace = false } = {}) {
      const { from, to } = view.state.selection.main;
      const selected = view.state.sliceDoc(from, to);
      if (selected && !selected.includes("\n") && selected.length <= PREFILL_LENGTH) findInput.value = selected;
      bar.hidden = false;
      toggle.setAttribute("aria-expanded", "true");
      if (replace) setReplaceShown(true);
      applyQuery();
      const field = replace && findInput.value ? replaceInput : findInput;
      field.focus();
      field.select();
    }

    function close() {
      if (!isOpen()) return;
      bar.hidden = true;
      toggle.setAttribute("aria-expanded", "false");
      applyQuery();
      view.focus();
    }

    function replaceOne() {
      if (view.state.readOnly) return;
      const { matches, current } = search();
      if (current === -1) {
        step(false, { focus: false });
        return;
      }
      const match = matches[current];
      view.dispatch({
        changes: { from: match.from, to: match.to, insert: replaceInput.value },
        selection: EditorSelection.cursor(match.from + replaceInput.value.length),
        userEvent: "input.replace",
      });
      step(false, { focus: false });
    }

    function replaceAll() {
      if (view.state.readOnly) return;
      const { matches } = search();
      if (!matches.length) return;
      view.dispatch({
        changes: matches.map((match) => ({ from: match.from, to: match.to, insert: replaceInput.value })),
        userEvent: "input.replace",
        scrollIntoView: true,
      });
      notify(`已替换 ${matches.length} 处`);
    }

    toggle.addEventListener("click", () => (isOpen() ? close() : open()));
    replaceToggle.addEventListener("click", () => setReplaceShown(replaceRow.hidden));
    findInput.addEventListener("input", seek);
    $("[data-find-step='previous']").addEventListener("click", () => step(true, { focus: false }));
    $("[data-find-step='next']").addEventListener("click", () => step(false, { focus: false }));
    $("[data-find-close]").addEventListener("click", close);
    replaceButtons[0].addEventListener("click", replaceOne);
    replaceButtons[1].addEventListener("click", replaceAll);
    findInput.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" || event.isComposing) return;
      event.preventDefault();
      step(event.shiftKey, { focus: false });
    });
    replaceInput.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" || event.isComposing) return;
      event.preventDefault();
      replaceOne();
    });
    bar.addEventListener("keydown", (event) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      close();
    });

    // ⌘F / ⌥⌘F / ⌘G / ⇧⌘G：对话框开着时不管
    window.addEventListener("keydown", (event) => {
      if (event.defaultPrevented || !window.MediaCraftPlatform.mod(event)) return;
      if (document.querySelector(".modal:not(.hidden)")) return;
      const key = event.key.toLowerCase();
      if (key === "f" && !event.shiftKey) {
        event.preventDefault();
        open({ replace: event.altKey });
      } else if (key === "g" && !event.altKey) {
        event.preventDefault();
        if (!step(event.shiftKey) && !isOpen()) open();
      }
    });

    editor.onUpdate(syncBar);
    syncBar();
    return { open, close, isOpen };
  }

  window.MediaCraftEditor.bindFind = bindFind;
})();
