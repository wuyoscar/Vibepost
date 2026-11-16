// 这台机器是不是 Mac，以及由此不同的两件事：快捷键的主修饰键（Mac 是 ⌘，别处是 Ctrl）、界面上写出来的快捷键。
// 界面的文字一律照 Mac 的写法写（⌘B、⇧⌘X），不在 Mac 上时这里换成 Ctrl+B、Ctrl+Shift+X：
//   - 页面刚载入时 index.html 里现成的界面（这时还没有稿子的内容）：文字、title、placeholder、aria-keyshortcuts；
//   - 之后只管 title / placeholder / aria-keyshortcuts 这几个属性和 <kbd>（菜单里的快捷键）；
//   - 脚本里现拼的句子（状态、提示）在拼的地方自己过一遍 keys()，只包住界面的那半句。
// 之后出现的普通文字不动：标题栏、稿件列表、修改对比里显示的是用户写的字，里面的 ⌘ 不是界面的。
//   MediaCraftPlatform.mac          这台是不是 Mac
//   MediaCraftPlatform.mod(event)   按下的是不是主修饰键（Mac 上只认 ⌘：⌃F 之类是文字框里移动光标）
//   MediaCraftPlatform.keys(text)   把一段照 Mac 写的文字换成这台机器的写法（Mac 上原样返回）
(function (root) {
  "use strict";

  const mac = /Mac|iPhone|iPad|iPod/.test(root.navigator?.platform || root.navigator?.userAgent || "");
  const NAMES = { "⌃": "Ctrl", "⌘": "Ctrl", "⌥": "Alt", "⇧": "Shift" };
  const ORDER = ["Ctrl", "Alt", "Shift"];
  const GLYPHS = /[⌃⌥⇧⌘]+/g;
  // 稿子的内容：不是界面，里面的 ⌘ 是用户或 AI 写的
  const CONTENT = ".cm-editor, .mc-card-host, .ai-thread, [contenteditable]:not([contenteditable='false'])";

  const mod = (event) => (mac ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey);

  function keys(text) {
    if (mac || typeof text !== "string" || !/[⌃⌥⇧⌘]/.test(text)) return text;
    return text.replace(GLYPHS, (run, offset, whole) => {
      const names = ORDER.filter((name) => [...run].some((glyph) => NAMES[glyph] === name));
      const next = whole[offset + run.length] ?? "";
      // 后面跟着键名（⌘B）才接加号；单独一个修饰键（「⌘ 点按」）就只写名字
      return names.join("+") + (next && !/\s/.test(next) ? "+" : "");
    });
  }

  function attribute(element, name, convert) {
    const value = element.getAttribute(name);
    if (!value) return;
    const next = convert(value);
    if (next !== value) element.setAttribute(name, next);
  }

  const shortcuts = (value) => value.replace(/\bMeta\+/g, "Control+");

  function attributes(element) {
    attribute(element, "title", keys);
    attribute(element, "placeholder", keys);
    attribute(element, "aria-keyshortcuts", shortcuts);
  }

  function texts(node) {
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
    for (let text = walker.nextNode(); text; text = walker.nextNode()) {
      const next = keys(text.nodeValue);
      if (next !== text.nodeValue) text.nodeValue = next;
    }
  }

  // 后来加进页面的一块：它和它里面的属性、<kbd>
  function added(node) {
    if (node.nodeType !== Node.ELEMENT_NODE || node.closest(CONTENT)) return;
    for (const element of [node, ...node.querySelectorAll("[title], [placeholder], [aria-keyshortcuts]")]) attributes(element);
    for (const key of node.matches("kbd") ? [node] : node.querySelectorAll("kbd")) texts(key);
  }

  function watch() {
    for (const element of document.querySelectorAll("[title], [placeholder], [aria-keyshortcuts]")) attributes(element);
    texts(document.body);
    new MutationObserver((records) => {
      for (const record of records) {
        if (record.type === "childList") for (const node of record.addedNodes) added(node);
        else if (!record.target.closest(CONTENT)) attributes(record.target);
      }
    }).observe(document.documentElement, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["title", "placeholder", "aria-keyshortcuts"],
    });
  }

  if (!mac && root.document) {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", watch, { once: true });
    else watch();
  }

  root.MediaCraftPlatform = Object.freeze({ mac, mod, keys });
})(globalThis);
