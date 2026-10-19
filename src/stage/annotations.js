// 在卡片上批注几处，一次交给 AI（借鉴 EditHere：在成品上指着说，再把结构化的意图交给 AI）。
// 点选一块后工具条上「批注」写一句（「这里太挤」「换成提示框」）；卡片上那一块右上角出编号的小圆点，点它改或删；
// 舞台右上角一条「N 处批注 · 交给 AI · 清空」。交给 AI 时每处带上第几页与它在原文里的开头，发进这篇的 AI 会话，
// 改动照常进修改对比。批注只在这次打开的这篇稿子里，不存盘、不进原文；出图后按原文找回它批注的那一块。
// host：{ viewport（提示条放这里）, pagesRoot（放卡片的容器）, text(), readOnly(), send(prompt, label), openAI() }
(() => {
  const CARD_WIDTH = 864;
  const vertical = (value) => `calc(${value} / var(--card-height, 1152) * 100%)`;
  const NOTE_LIMIT = 200;
  const EXCERPT = 24;
  const percent = (value, total) => `${(value / total) * 100}%`;

  function create(host) {
    let notes = []; // { id, chunk, note }
    let pages = []; // { frame, page, index, layer }
    let nextId = 1;

    // 一块占的整行原文（与 src/cards/blocks.js 的 span 一致）
    const chunkOf = (block, text = host.text()) => {
      const { from, to } = window.MediaCraftCardBlocks.span(text, block.source);
      return text.slice(from, to);
    };

    // ===== 舞台底部的一条 =====
    const tray = document.createElement("div");
    tray.className = "stage-note-tray";
    tray.setAttribute("role", "toolbar");
    tray.setAttribute("aria-label", "批注");
    tray.hidden = true;
    const count = document.createElement("span");
    count.className = "stage-note-count";
    const sendButton = document.createElement("button");
    sendButton.type = "button";
    sendButton.className = "primary-button";
    sendButton.textContent = "交给 AI";
    const clearButton = document.createElement("button");
    clearButton.type = "button";
    clearButton.className = "text-button";
    clearButton.textContent = "清空";
    tray.append(count, sendButton, clearButton);
    host.viewport.append(tray);
    sendButton.addEventListener("click", () => void send());
    clearButton.addEventListener("click", () => {
      notes = [];
      paint();
    });

    // ===== 每页的小圆点 =====
    function attach(frame, page, index) {
      if (!page?.blocks?.length) return;
      const layer = document.createElement("div");
      layer.className = "stage-note-layer";
      frame.append(layer);
      // 出图时逐页挂上、之后才整组放上舞台：这里只换掉同一页，旧页等舞台换页时再丢（见下面的 MutationObserver）
      pages = [...pages.filter((entry) => entry.index !== index), { frame, page, index, layer }].sort((a, b) => a.index - b.index);
      paint();
    }

    new MutationObserver(() => {
      pages = pages.filter((entry) => entry.frame.isConnected);
      paint();
    }).observe(host.pagesRoot, { childList: true });

    // 批注落在哪一页的哪一块：按原文找（挪动、换样式后原文不变的那块还认得）
    function locate(note) {
      const text = host.text();
      for (const entry of pages) {
        const block = entry.page.blocks.find((item) => chunkOf(item, text).trim() === note.chunk.trim());
        if (block) return { entry, block };
      }
      return null;
    }

    function paint() {
      for (const entry of pages) entry.layer.replaceChildren();
      notes.forEach((note, order) => {
        const spot = locate(note);
        if (!spot) return;
        const pin = document.createElement("button");
        pin.type = "button";
        pin.className = "stage-note-pin";
        pin.textContent = String(order + 1);
        pin.title = note.note;
        pin.setAttribute("aria-label", `批注 ${order + 1}：${note.note}`);
        pin.style.left = percent(spot.block.x + spot.block.width, CARD_WIDTH);
        pin.style.top = vertical(spot.block.y);
        pin.addEventListener("click", (event) => {
          event.stopPropagation();
          editor(spot.entry, spot.block, note);
        });
        spot.entry.layer.append(pin);
      });
      tray.hidden = notes.length === 0;
      count.textContent = `${notes.length} 处批注`;
    }

    // ===== 写批注的小框 =====
    function editor(entry, block, note = null) {
      entry.frame.querySelector(".stage-note-editor")?.remove();
      const box = document.createElement("form");
      box.className = "stage-note-editor";
      box.setAttribute("aria-label", note ? "改批注" : "写批注");
      box.style.left = percent(block.x, CARD_WIDTH);
      box.style.top = vertical(block.y + block.height);
      const input = document.createElement("textarea");
      input.rows = 2;
      input.maxLength = NOTE_LIMIT;
      input.placeholder = "想怎么改这一块？比如：太挤了、换成提示框、这句更口语";
      input.setAttribute("aria-label", "批注");
      input.value = note?.note ?? "";
      const actions = document.createElement("div");
      actions.className = "stage-note-actions";
      const save = Object.assign(document.createElement("button"), { type: "submit", className: "primary-button", textContent: note ? "改好了" : "添加" });
      const cancel = Object.assign(document.createElement("button"), { type: "button", className: "text-button", textContent: note ? "删除" : "取消" });
      actions.append(cancel, save);
      box.append(input, actions);
      box.addEventListener("pointerdown", (event) => event.stopPropagation());
      box.addEventListener("submit", (event) => {
        event.preventDefault();
        const text = input.value.trim();
        if (text && note) note.note = text;
        else if (text) notes = [...notes, { id: nextId++, chunk: chunkOf(block), note: text }];
        box.remove();
        paint();
      });
      cancel.addEventListener("click", () => {
        if (note) notes = notes.filter((item) => item !== note);
        box.remove();
        paint();
      });
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) box.requestSubmit();
        if (event.key === "Escape") {
          event.stopPropagation();
          box.remove();
        }
      });
      entry.frame.append(box);
      input.focus();
    }

    // 工具条上的「批注」：在这一块下面打开写批注的小框
    function add(block) {
      if (host.readOnly()) return;
      const entry = pages.find((item) => item.page.blocks.includes(block));
      if (entry) editor(entry, block);
    }

    // ===== 交给 AI =====
    function prompt() {
      const lines = notes.map((note, order) => {
        const spot = locate(note);
        const where = spot ? `第 ${spot.entry.index + 1} 页` : "（这一块已经改没了）";
        const excerpt = note.chunk.replace(/\s+/g, " ").trim();
        const head = Array.from(excerpt).slice(0, EXCERPT).join("") + (Array.from(excerpt).length > EXCERPT ? "…" : "");
        return `${order + 1}. ${where}「${head}」：${note.note}`;
      });
      return [
        "用户在卡片上批注了几处，请逐条照着改（引号里是那一块在 draft.md 里的开头）：",
        ...lines,
        "先用 view_page 看看批注的那几页；措辞的改动直接改 draft.md，换样式用 restyle_block，调顺序用 move_section，要新的样子用 set_card_css；",
        "没批注的地方不动，所有自定义标记原样保留。改完用一两句话逐条说明怎么处理的；做不到的那条说明原因。",
      ].join("\n");
    }

    async function send() {
      if (!notes.length || host.readOnly()) return;
      const text = prompt();
      const label = `按 ${notes.length} 处批注改`;
      notes = [];
      paint();
      host.openAI();
      await host.send(text, label);
    }

    return {
      attach,
      add,
      // 换稿子：批注不跟过去
      reset() {
        notes = [];
        paint();
      },
      list: () => notes.map(({ chunk, note }) => ({ chunk, note })),
      prompt,
    };
  }

  window.MediaCraftStageNotes = { create };
})();
