// 实时预览：只加装饰，不改文本（ADR 0002）。标题、引用、列表、加粗等直接显示成排好的样子；
// 光标所在行与审阅中 AI 改动的行（src/editor/review.js）露出 Markdown 标记；图片、拼图显示为缩略图卡片，[[分页]] 显示为一条细虚线。
// 只装饰看得见的那一段，两万字的稿子打字也不卡。
(() => {
  const { Decoration, EditorView, StateEffect, ViewPlugin, WidgetType } = window.CodeMirror;
  const { syntax, review } = window.MediaCraftEditor;

  // 要求整体重算装饰：图片素材有变化（换图、裁剪、读回画面）、输入法组字结束
  const refresh = StateEffect.define();

  const hidden = Decoration.replace({});
  const shownMarker = Decoration.mark({ class: "cm-md-marker" });
  const lineDecorations = new Map();
  const markDecorations = new Map();

  function lineDecoration(className) {
    if (!lineDecorations.has(className)) lineDecorations.set(className, Decoration.line({ class: className }));
    return lineDecorations.get(className);
  }

  // 高亮底色上用深字还是白字：按底色亮度挑（卡片上也会自动保证对比度）
  function readableOn(hex) {
    const digits = hex.slice(1);
    const channel = (index) => (digits.length <= 4
      ? parseInt(digits[index].repeat(2), 16)
      : parseInt(digits.slice(index * 2, index * 2 + 2), 16));
    const luminance = (0.299 * channel(0) + 0.587 * channel(1) + 0.114 * channel(2)) / 255;
    return luminance > 0.55 ? "#161616" : "#ffffff";
  }

  // 一段行内文字的格式 → 样式（同样的格式共用一个装饰）
  function runDecoration(run) {
    const classes = [];
    if (run.bold) classes.push("cm-md-bold");
    if (run.italic) classes.push("cm-md-italic");
    if (run.strike) classes.push("cm-md-strike");
    if (run.code) classes.push("cm-md-code");
    if (run.underline) classes.push(run.underline === "dashed" ? "cm-md-underline-dashed" : "cm-md-underline");
    if (run.link) classes.push("cm-md-link");
    const styles = [];
    if (run.color) styles.push(`color: ${run.color}`);
    if (run.bg) {
      classes.push("cm-md-highlight");
      styles.push(`background-color: ${run.bg}`);
      if (!run.color) styles.push(`color: ${readableOn(run.bg)}`);
    }
    if (!classes.length && !styles.length) return null;
    const key = `${classes.join(" ")}|${styles.join(";")}|${run.link || ""}`;
    if (!markDecorations.has(key)) {
      const attributes = {};
      if (styles.length) attributes.style = styles.join("; ");
      if (run.link) attributes.title = run.link;
      markDecorations.set(key, Decoration.mark({ class: classes.join(" "), attributes }));
    }
    return markDecorations.get(key);
  }

  // ===== 小部件 =====

  class ListMarkerWidget extends WidgetType {
    constructor(text) {
      super();
      this.text = text;
    }
    eq(other) {
      return other.text === this.text;
    }
    toDOM() {
      const marker = document.createElement("span");
      marker.className = "cm-md-list-marker";
      marker.textContent = this.text;
      return marker;
    }
  }

  class SeparatorWidget extends WidgetType {
    constructor(kind) {
      super();
      this.kind = kind;
    }
    eq(other) {
      return other.kind === this.kind;
    }
    toDOM() {
      const separator = document.createElement("span");
      separator.setAttribute("role", "separator");
      if (this.kind === "pageBreak" || this.kind === "endPage") {
        const text = this.kind === "pageBreak" ? "分页" : "以下是结尾页";
        separator.className = this.kind === "pageBreak" ? "cm-md-page-break" : "cm-md-page-break cm-md-end-page";
        separator.setAttribute("aria-label", text);
        const label = document.createElement("span");
        label.textContent = text;
        separator.append(label);
      } else {
        separator.className = "cm-md-rule";
        separator.setAttribute("aria-label", "分割线");
      }
      return separator;
    }
  }

  // 图片 / 拼图的缩略图卡片：点一下交给应用去裁剪或调整拼图。
  class MediaWidget extends WidgetType {
    constructor(items, ratio, length, onEdit) {
      super();
      this.items = items; // [{ id, name, src, kind, missing }]
      this.ratio = ratio;
      this.length = length;
      this.onEdit = onEdit;
    }
    eq(other) {
      const same = (a, b) => a.id === b.id && a.name === b.name && a.src === b.src && a.kind === b.kind && a.missing === b.missing;
      return other.length === this.length && other.ratio === this.ratio
        && other.items.length === this.items.length && other.items.every((item, index) => same(item, this.items[index]));
    }
    get pair() {
      return this.items.length === 2;
    }
    toDOM(view) {
      const missing = this.items.every((item) => item.missing);
      const card = document.createElement("span");
      card.className = `cm-md-media${this.pair ? " is-pair" : ""}${missing ? " is-missing" : ""}`;
      const thumbs = document.createElement("span");
      thumbs.className = "cm-md-thumbs";
      for (const item of this.items) {
        const thumb = document.createElement("span");
        thumb.className = `cm-md-thumb${item.kind === "live" ? " is-live" : ""}`;
        if (item.src) {
          const image = document.createElement("img");
          image.alt = "";
          image.draggable = false;
          image.src = item.src;
          thumb.append(image);
        }
        thumbs.append(thumb);
      }
      const text = document.createElement("span");
      text.className = "cm-md-media-text";
      const name = document.createElement("span");
      name.className = "cm-md-media-name";
      name.textContent = missing ? "找不到这张图片" : this.items.map((item) => item.name).join(" + ");
      const meta = document.createElement("span");
      meta.className = "cm-md-media-meta";
      meta.textContent = this.describe();
      text.append(name, meta);
      card.append(thumbs, text);
      if (missing) return card;

      card.setAttribute("role", "button");
      card.setAttribute("aria-label", `${this.pair ? "调整拼图" : "编辑图片"} ${name.textContent}`);
      if (!this.pair && this.items[0].kind !== "live") {
        const image = thumbs.querySelector("img");
        image?.addEventListener("load", () => {
          meta.textContent = `${image.naturalWidth} × ${image.naturalHeight} · ${this.describe()}`;
        });
      }
      card.addEventListener("mousedown", (event) => event.preventDefault());
      card.addEventListener("click", (event) => {
        event.preventDefault();
        const from = view.posAtDOM(card);
        this.onEdit?.({ imageIds: this.items.map((item) => item.id), ratio: this.ratio, source: [from, from + this.length] });
      });
      return card;
    }
    describe() {
      if (this.items.every((item) => item.missing)) return "图片可能已被删掉";
      if (this.pair) return `拼图${this.ratio ? ` · ${this.ratio.replace("x", ":")}` : ""} · 点一下调整`;
      return this.items[0].kind === "live" ? "实况 · 点一下编辑" : "点一下裁剪";
    }
  }

  // ===== 装饰 =====

  function activeLines(state) {
    const { from, to } = state.selection.main;
    return { first: state.doc.lineAt(from).number, last: state.doc.lineAt(to).number };
  }

  // 这一次重算装饰的收集器：装饰先收进 ranges（缩略图卡片、分页线这类整块替换的另记进 atomic，光标跳过它们），
  // 以及几个按行、按片段加装饰的小工具。
  function collector(state, options) {
    const active = activeLines(state);
    // 审阅 AI 的修改时，改动的行也露出标记：删掉的与加上的标记（字色、高亮……）才对得上
    const hunks = state.field(review.field, false)?.hunks ?? [];
    const ranges = [];
    const atomic = [];
    const into = {
      state,
      options,
      ranges,
      atomic,
      isActive(pos) {
        const number = state.doc.lineAt(pos).number;
        return (number >= active.first && number <= active.last) || hunks.some((hunk) => pos >= hunk.from && pos < hunk.to);
      },
      marker(from, to, shown) {
        if (from < to) ranges.push((shown ? shownMarker : hidden).range(from, to));
      },
      line: (pos, className) => ranges.push(lineDecoration(className).range(state.doc.lineAt(pos).from)),
      // 一行里的行内格式：标记按光标所在行露出或藏起，片段按格式上样式
      inline(entry) {
        const shown = into.isActive(entry.source[0]);
        let pos = entry.contentSource[0];
        for (const run of entry.runs) {
          into.marker(pos, run.source[0], shown);
          const decoration = runDecoration(run);
          if (decoration) ranges.push(decoration.range(run.source[0], run.source[1]));
          pos = run.source[1];
        }
        into.marker(pos, entry.contentSource[1], shown);
      },
      replace: (from, to, widget) => ranges.push(Decoration.replace({ widget }).range(from, to)),
      widget(from, to, instance) {
        const range = Decoration.replace({ widget: instance }).range(from, to);
        ranges.push(range);
        atomic.push(range);
      },
    };
    return into;
  }

  // 代码块、表格：每一行一个行装饰，className(number, first, last) 给出这一行的类名
  function decorateLines(into, block, className) {
    const { doc } = into.state;
    const first = doc.lineAt(block.source[0]).number;
    const last = doc.lineAt(block.source[1]).number;
    for (let number = first; number <= last; number += 1) into.line(doc.line(number).from, className(number, first, last));
  }

  function decorateQuote(into, block) {
    block.lines.forEach((entry, index) => {
      const edges = `${index === 0 ? " is-first" : ""}${index === block.lines.length - 1 ? " is-last" : ""}`;
      into.line(entry.source[0], `cm-md-quote${edges}`);
      into.marker(entry.source[0], entry.contentSource[0], into.isActive(entry.source[0]));
      into.inline(entry);
    });
  }

  function decorateList(into, block) {
    for (const item of block.items) {
      into.line(item.source[0], "cm-md-li");
      if (into.isActive(item.source[0])) into.marker(item.source[0], item.contentSource[0], true);
      else into.replace(item.source[0], item.contentSource[0], new ListMarkerWidget(item.ordered ? item.marker : "•"));
      into.inline(item);
    }
  }

  // 图片 / 拼图：整块换成缩略图卡片
  function decorateMedia(into, block, refs, ratio) {
    const items = refs.map((ref) => into.options.media(ref));
    const [from, to] = block.source;
    into.widget(from, to, new MediaWidget(items, ratio, to - from, into.options.onEditImage));
  }

  function decorateBlock(into, block) {
    switch (block.type) {
      case "heading":
        into.line(block.source[0], `cm-md-h${Math.min(block.level, 3)}`);
        into.marker(block.source[0], block.contentSource[0], into.isActive(block.source[0]));
        into.inline(block);
        break;
      case "paragraph":
        block.lines.forEach(into.inline);
        break;
      case "quote":
        decorateQuote(into, block);
        break;
      case "list":
        decorateList(into, block);
        break;
      case "code":
        decorateLines(into, block, (number, first, last) => `cm-md-codeblock${number === first || number === last ? " is-fence" : ""}`);
        break;
      case "table":
        decorateLines(into, block, (number, first) => `cm-md-table${number === first ? " is-head" : number === first + 1 ? " is-rule" : ""}`);
        break;
      case "image":
        decorateMedia(into, block, [block.imageId ? { id: block.imageId } : { path: block.path }], null);
        break;
      case "imagePair":
        decorateMedia(into, block, block.imageIds.map((id) => ({ id })), block.ratio);
        break;
      case "rule":
        if (into.isActive(block.source[0])) into.marker(block.source[0], block.source[1], true);
        else into.replace(block.source[0], block.source[1], new SeparatorWidget("rule"));
        break;
      case "pageBreak":
      case "endPage":
        into.widget(block.source[0], block.source[1], new SeparatorWidget(block.type));
        break;
      default:
        break;
    }
  }

  function build(view, options) {
    const { state } = view;
    const into = collector(state, options);
    const visibleFrom = view.visibleRanges[0]?.from ?? 0;
    const visibleTo = view.visibleRanges.at(-1)?.to ?? 0;
    for (const block of syntax.of(state).tree.blocks) {
      if (block.source[1] < visibleFrom) continue;
      if (block.source[0] > visibleTo) break;
      decorateBlock(into, block);
    }
    return { decorations: Decoration.set(into.ranges, true), atomic: Decoration.set(into.atomic, true) };
  }

  // options.media(ref) → { id, name, src, kind, missing }；options.onEditImage({ imageIds, ratio, source: [起, 止] })
  function livePreview(options) {
    const plugin = ViewPlugin.fromClass(class {
      constructor(view) {
        Object.assign(this, build(view, options));
        this.stale = false;
      }
      update(update) {
        // 输入法组字时不动这一行的装饰，免得打断组字；组完再整体重算
        if (update.view.composing) {
          this.decorations = this.decorations.map(update.changes);
          this.atomic = this.atomic.map(update.changes);
          this.stale = true;
          return;
        }
        const refreshed = update.transactions.some((transaction) => transaction.effects.some((effect) => effect.is(refresh)))
          || update.startState.field(review.field, false) !== update.state.field(review.field, false);
        if (this.stale || refreshed || update.docChanged || update.viewportChanged || update.selectionSet) {
          Object.assign(this, build(update.view, options));
          this.stale = false;
        }
      }
    }, {
      decorations: (instance) => instance.decorations,
      eventHandlers: {
        compositionend(event, view) {
          setTimeout(() => {
            if (!view.composing) view.dispatch({ effects: refresh.of(null) });
          });
        },
      },
    });
    return [
      plugin,
      EditorView.atomicRanges.of((view) => view.plugin(plugin)?.atomic ?? Decoration.none),
    ];
  }

  window.MediaCraftEditor.livePreview = livePreview;
  window.MediaCraftEditor.refreshPreview = refresh;
})();
