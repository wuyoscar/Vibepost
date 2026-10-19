// 格式条上的「表情」：像 PPT 的「插入 › 符号」，点开一个小面板（最近用过、常用、表情、手势、生活、自然、符号），
// 点一个就插到光标所在处：最后在正文、标题框还是小红书正文里打字，就插到那里（默认正文）。
// 正文里插入和打字一样记进撤销历史、出图、存稿（editor.insertText）；标题框与小红书正文用系统的插入文字，⌘Z 照常。
// 按住 ⇧ 点可以连着插几个、面板不收起。最近用过的记在本机（最多 16 个）。
(function (root) {
  "use strict";

  const RECENT_KEY = "mediacraft.emoji.recent.v1";
  const RECENT_LIMIT = 16;
  const split = (text) => [...new Intl.Segmenter("zh", { granularity: "grapheme" }).segment(text)].map((part) => part.segment).filter((part) => part.trim());

  // 小红书上用得多的几类；每类一行字符串，按字形（grapheme）切开
  const CATEGORIES = Object.freeze([
    { id: "common", name: "常用", glyph: "✨", emoji: split("✨🔥💡📌✅❌⭐️💯👍👏🙏💪❤️🫶👀👉📝📚📷🎉💰⏰📍🌟⚠️❗️❓🆕💬🔗") },
    { id: "faces", name: "表情", glyph: "😊", emoji: split("😀😃😄😁😆😂🤣😊😇🙂😉😍🥰😘😋😛😜🤪😎🤓🧐🤔🤨😐😑😶🙄😏😮😯😲😳🥺🥹😢😭😤😠😡🤯😱😨😰😅😓🤗🤭🫢🤫😴🥱😪🤤😵‍💫🥳🤩😌🙃🫠") },
    { id: "hands", name: "手势", glyph: "👍", emoji: split("👍👎👏🙌🫶🙏🤝✌️🤞🫰🤟🤘👌🤌🤏👈👉👆👇☝️✋🤚🖐️👋💪✍️🫡") },
    { id: "life", name: "生活", glyph: "☕️", emoji: split("☕️🍵🧋🍰🍓🍑🍋🍎🍜🍣🍲🥗🍳🥐🍺🍷🏠🛋️🛏️🧳✈️🚄🚗🚲🏖️⛰️🗺️📱💻⌨️🎧🎬🎨🎮📖✏️🖊️📅🗓️⏳🛒🎁🎀👗👟💄🧴💊🏃‍♀️🧘‍♀️🐱🐶🐰🐼") },
    { id: "nature", name: "自然", glyph: "🌸", emoji: split("🌸🌷🌹🌻🌼💐🍀🌿🍃🍂🍁🌱🌳🌵☀️🌤️⛅️🌧️☔️❄️🌈🌙⭐️🌟💫⚡️🌊🔥💧🌍") },
    { id: "symbols", name: "符号", glyph: "①", emoji: split("①②③④⑤⑥⑦⑧⑨⑩1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟➡️⬅️⬆️⬇️↗️🔺🔻▶️◀️🔴🟠🟡🟢🔵🟣⚫️⚪️🟥🟩🟦✔️☑️✖️➕➖‼️⁉️〰️💠🔸🔹♥️⭕️🚫🔝🆗🆙") },
  ]);

  function readRecent() {
    try {
      const value = JSON.parse(root.localStorage.getItem(RECENT_KEY) || "[]");
      return Array.isArray(value) ? value.filter((item) => typeof item === "string").slice(0, RECENT_LIMIT) : [];
    } catch {
      return [];
    }
  }

  function remember(emoji) {
    const next = [emoji, ...readRecent().filter((item) => item !== emoji)].slice(0, RECENT_LIMIT);
    try {
      root.localStorage.setItem(RECENT_KEY, JSON.stringify(next));
    } catch {
      // 记不住只是下次「最近」少一个
    }
  }

  // editor：MediaCraftEditor.create() 返回的接口；menu：<details id="emojiMenu">；fields：标题框、小红书正文这些也能插的输入框
  function bind(editor, menu, { fields = [], readOnly = () => false } = {}) {
    const tabs = menu.querySelector("[data-emoji-tabs]");
    const grid = menu.querySelector("[data-emoji-grid]");
    let target = null; // 最后打字的输入框；null 是正文
    let category = readRecent().length ? "recent" : "common";

    document.addEventListener("focusin", (event) => {
      if (fields.includes(event.target)) target = event.target;
      else if (editor.view.dom.contains(event.target)) target = null;
    });

    const groups = () => [
      { id: "recent", name: "最近", glyph: "🕘", emoji: readRecent() },
      ...CATEGORIES,
    ];

    function renderTabs() {
      tabs.replaceChildren(...groups().map((group) => {
        const tab = document.createElement("button");
        tab.type = "button";
        tab.className = "emoji-tab";
        tab.setAttribute("role", "tab");
        tab.setAttribute("aria-label", group.name);
        tab.setAttribute("aria-selected", String(group.id === category));
        tab.title = group.name;
        tab.textContent = group.glyph;
        tab.addEventListener("click", () => {
          category = group.id;
          render();
        });
        return tab;
      }));
    }

    function renderGrid() {
      const group = groups().find((item) => item.id === category) ?? CATEGORIES[0];
      grid.setAttribute("aria-label", group.name);
      if (!group.emoji.length) {
        grid.replaceChildren(Object.assign(document.createElement("p"), { className: "emoji-empty", textContent: "还没有用过的表情" }));
        return;
      }
      grid.replaceChildren(...group.emoji.map((emoji) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "emoji-item";
        button.textContent = emoji;
        button.setAttribute("aria-label", `插入 ${emoji}`);
        button.addEventListener("click", (event) => insert(emoji, event.shiftKey));
        return button;
      }));
    }

    function render() {
      renderTabs();
      renderGrid();
    }

    function insert(emoji, keepOpen) {
      if (readOnly()) return;
      if (target && target.isConnected && !target.disabled) {
        target.focus();
        // 系统的插入文字：触发 input、进输入框自己的撤销历史
        if (!document.execCommand("insertText", false, emoji)) {
          const { selectionStart = target.value.length, selectionEnd = target.value.length } = target;
          target.setRangeText(emoji, selectionStart, selectionEnd, "end");
          target.dispatchEvent(new Event("input", { bubbles: true }));
        }
      } else {
        editor.insertText(emoji);
      }
      remember(emoji);
      if (keepOpen) {
        if (category === "recent") renderGrid();
        return;
      }
      menu.open = false;
      if (!target) editor.focus();
    }

    menu.addEventListener("toggle", () => {
      if (menu.open) render();
    });
    render();
  }

  root.MediaCraftEmoji = Object.freeze({ CATEGORIES, bind });
})(window);
