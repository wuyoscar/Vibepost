// 审阅 AI 的修改（由 src/ai/review.js 驱动）：正文里逐处标出删掉的字（红色删除线）与加上的字（绿色），
// 每处上方一条「第几处 · 拒绝 · 接受」。只加装饰，不改文本；审阅时编辑器只读（见 editor.js 的 showReview）。
// 决定过的一处也留着标记：接受的删掉部分变淡，拒绝的加上部分变淡并划掉，一眼看出最后留下什么。
(() => {
  const { Decoration, EditorView, StateEffect, StateField, WidgetType } = window.CodeMirror;

  // 换一套审阅（null 收起）：{ hunks, decide(index, decision) }。
  // hunk：{ index, from, to, parts: [{ op, text }], decision: "pending" | "accepted" | "rejected", conflict }，
  // from / to 按正文末尾补一个换行算（src/ai/diff.js），所以最后一行后面的新增会超出正文长度一位。
  const setReview = StateEffect.define();

  const DECIDED = { accepted: "已接受", rejected: "已拒绝" };

  class HunkBar extends WidgetType {
    constructor(hunk, decide) {
      super();
      this.hunk = hunk;
      this.decide = decide;
    }
    eq(other) {
      const [a, b] = [this.hunk, other.hunk];
      return a.index === b.index && a.decision === b.decision && a.conflict === b.conflict;
    }
    toDOM() {
      const { index, decision, conflict } = this.hunk;
      const bar = document.createElement("div");
      bar.className = `cm-review-bar is-${decision}${conflict ? " is-conflict" : ""}`;
      bar.setAttribute("role", "group");
      bar.setAttribute("aria-label", `第 ${index + 1} 处修改`);
      const label = document.createElement("span");
      label.className = "cm-review-label";
      label.textContent = [`第 ${index + 1} 处`, DECIDED[decision]].filter(Boolean).join(" · ");
      bar.append(label);
      if (conflict) {
        const note = document.createElement("span");
        note.className = "cm-review-note";
        note.textContent = "你在 AI 修改时也改了这里：接受就整段换成 AI 的";
        bar.append(note);
      }
      for (const [choice, text] of [["rejected", "拒绝"], ["accepted", "接受"]]) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = `review-choice is-${choice}`;
        button.textContent = text;
        button.setAttribute("aria-pressed", String(decision === choice));
        button.addEventListener("mousedown", (event) => event.preventDefault());
        button.addEventListener("click", () => this.decide(index, choice));
        bar.append(button);
      }
      return bar;
    }
  }

  // 加上的字：插在一行开头的整行（比如新的一段）画成单独的块，其余跟在删掉的字后面
  class Inserted extends WidgetType {
    constructor(text, decision, block) {
      super();
      this.text = text;
      this.decision = decision;
      this.block = block;
    }
    eq(other) {
      return other.text === this.text && other.decision === this.decision && other.block === this.block;
    }
    toDOM() {
      const node = document.createElement(this.block ? "div" : "span");
      node.className = `cm-review-ins is-${this.decision}${this.block ? " is-block" : ""}`;
      node.textContent = this.block ? this.text.slice(0, -1) : this.text;
      return node;
    }
  }

  function build(state, review) {
    const { doc } = state;
    const ranges = [];
    const isLineStart = (pos) => pos === 0 || doc.sliceString(pos - 1, pos) === "\n";
    for (const hunk of review.hunks) {
      const { decision } = hunk;
      // 接在最后一行后面的修改：提示条与新增都画在最后一行下面
      const beyond = hunk.from > doc.length;
      ranges.push(Decoration.widget({ widget: new HunkBar(hunk, review.decide), block: true, side: beyond ? 1 : -2 })
        .range(Math.min(hunk.from, doc.length)));
      let pos = hunk.from;
      for (const { op, text } of hunk.parts) {
        const start = pos;
        if (op !== "insert") pos += text.length;
        if (op === "equal" || (op === "delete" && decision === "rejected")) continue;
        if (op === "delete") {
          const from = Math.min(start, doc.length);
          const to = Math.min(pos, doc.length);
          if (from < to) ranges.push(Decoration.mark({ class: `cm-review-del is-${decision}` }).range(from, to));
          // 整行删掉的（包括图片、分页这种画成卡片的行）整行标出来
          for (let line = doc.lineAt(from); line.from < pos; line = doc.line(line.number + 1)) {
            if (start <= line.from && pos > line.to) ranges.push(Decoration.line({ class: `cm-review-del-line is-${decision}` }).range(line.from));
            if (line.number === doc.lines) break;
          }
        } else if (start > doc.length) {
          ranges.push(Decoration.widget({ widget: new Inserted(text, decision, true), block: true, side: 2 }).range(doc.length));
        } else {
          const block = isLineStart(start) && text.endsWith("\n");
          ranges.push(Decoration.widget({ widget: new Inserted(text, decision, block), block, side: block ? -1 : 1 }).range(start));
        }
      }
    }
    return Decoration.set(ranges, true);
  }

  const field = StateField.define({
    create: () => null,
    update(value, transaction) {
      for (const effect of transaction.effects) {
        if (effect.is(setReview)) return effect.value && { ...effect.value, decorations: build(transaction.state, effect.value) };
      }
      return value && transaction.docChanged ? { ...value, decorations: value.decorations.map(transaction.changes) } : value;
    },
    provide: (self) => [
      EditorView.decorations.from(self, (value) => value?.decorations ?? Decoration.none),
      EditorView.editorAttributes.compute([self], (state) => (state.field(self) ? { class: "is-reviewing" } : {})),
    ],
  });

  window.MediaCraftEditor.review = { field, set: setReview };
})();
