// 检查器「样式」的各节能收起，像 PPT 的「设置格式」窗格：点节名收起 / 展开，⌥ 点一下全部一起；
// 收起时节名后面一行摘要（版式写尺寸与字号行距，主题写名字，配色画五个小色点……），不用滚就看得到现在是什么样。
// 开合记在本机；在预览里点选一张图时「图片」那节自己展开（不改记下的开合），取消选中再收回去。
// 节是 #stylePanel 里带 data-fold 的 <section>，节名是其中的 .section-label（可能在 .section-head 里）。
(function (root) {
  "use strict";

  const STORAGE_KEY = "mediacraft.inspector.folds.v1";
  // 没记过时：版式、主题开着，其余收起（一屏放得下）
  const DEFAULT_FOLDED = Object.freeze(["font", "cover", "colors", "images", "byline"]);

  const $ = (selector, within = document) => within.querySelector(selector);

  function readStored() {
    try {
      const value = JSON.parse(root.localStorage.getItem(STORAGE_KEY) || "null");
      return value && typeof value === "object" && !Array.isArray(value) ? value : null;
    } catch {
      return null;
    }
  }

  // 摘要：读界面上现在的值（和稿子同步的那些控件），不另外记状态
  const text = (selector) => $(selector)?.textContent.trim() ?? "";
  const PEEKS = {
    layout() {
      const size = $("#cardHeightInput");
      const parts = [];
      if (size && !document.body.matches('[data-layout-mode="article"]')) parts.push(size.selectedOptions[0]?.textContent.split(" · ")[0] ?? "");
      parts.push(`字号 ${$("#fontSizeInput").value}`, `行距 ${Number($("#lineHeightInput").value).toFixed(2)}`);
      const gap = $("#blockGapInput");
      if (gap) parts.push(`段距 ${Number(gap.value).toFixed(2)}`);
      return parts.filter(Boolean).join(" · ");
    },
    theme: () => text('#themeOptions [aria-pressed="true"] .theme-option-name'),
    font() {
      const names = [...new Set(["#zhFontInput", "#enFontInput", "#codeFontInput"].map(text))];
      return names.join(" / ");
    },
    cover: () => ($("#coverToggle")?.checked ? "首页做封面" : "不做封面"),
    colors() {
      const dots = document.createElement("span");
      dots.className = "section-peek-dots";
      for (const role of ["bg", "text", "accent", "secondary", "surface"]) {
        const dot = document.createElement("span");
        dot.style.background = $(`#${role}ColorInput`)?.value ?? "transparent";
        dots.append(dot);
      }
      return dots;
    },
    images: () => [text("[data-image-scope]"), text("[data-image-width-value]")].filter(Boolean).join(" · 宽度 "),
    byline: () => $("#displayNameInput")?.value.trim() || "还没填名字",
  };

  function create(panel) {
    const stored = readStored();
    const sections = [...panel.querySelectorAll(":scope > section[data-fold]")].map((section) => {
      const id = section.dataset.fold;
      const label = $(".section-label", section);
      const name = label.textContent.trim();
      const toggle = document.createElement("button");
      toggle.type = "button";
      toggle.className = "section-fold";
      // 名字就是里面的节名（摘要对读屏隐藏）；不写 aria-label，免得和同名的组（主题格子的「主题」）混在一起
      toggle.title = `收起或展开「${name}」（⌥ 点一下：全部）`;
      toggle.innerHTML = '<svg class="icon icon-small section-fold-chevron" aria-hidden="true"><use href="#i-chevron-right" /></svg>';
      const title = document.createElement("span");
      title.className = "section-fold-name";
      title.textContent = name;
      const peek = document.createElement("span");
      peek.className = "section-peek";
      peek.setAttribute("aria-hidden", "true");
      toggle.append(title, peek);
      label.replaceChildren(toggle);
      const folded = stored && id in stored ? Boolean(stored[id]) : DEFAULT_FOLDED.includes(id);
      const entry = { id, section, toggle, peek, folded, revealed: false };
      toggle.addEventListener("click", (event) => {
        const next = !isFolded(entry);
        if (event.altKey) for (const other of sections) setFolded(other, next);
        else setFolded(entry, next);
        save();
      });
      return entry;
    });

    const isFolded = (entry) => entry.folded && !entry.revealed;

    function apply(entry) {
      const folded = isFolded(entry);
      entry.section.classList.toggle("is-folded", folded);
      entry.toggle.setAttribute("aria-expanded", String(!folded));
      if (folded) refreshPeek(entry);
    }

    function setFolded(entry, folded) {
      entry.folded = folded;
      entry.revealed = false;
      apply(entry);
    }

    function save() {
      try {
        root.localStorage.setItem(STORAGE_KEY, JSON.stringify(Object.fromEntries(sections.map((entry) => [entry.id, entry.folded]))));
      } catch {
        // 记不住只是下次回到默认的开合
      }
    }

    function refreshPeek(entry) {
      const value = PEEKS[entry.id]?.() ?? "";
      entry.peek.replaceChildren(value);
    }

    function refresh() {
      for (const entry of sections) if (isFolded(entry)) refreshPeek(entry);
    }

    // 点选了一张图：「图片」自己展开，取消选中后回到记下的样子
    const images = sections.find((entry) => entry.id === "images");
    const selected = $("[data-image-summary]", panel);
    if (images && selected) {
      const sync = () => {
        const revealed = !selected.hidden;
        if (revealed === images.revealed) return;
        images.revealed = revealed;
        apply(images);
        if (revealed && images.folded) images.section.scrollIntoView({ block: "nearest", behavior: "smooth" });
      };
      new MutationObserver(sync).observe(selected, { attributes: true, attributeFilter: ["hidden"] });
    }

    // 摘要跟着值走：检查器里改的、稿子换了的、主题换了的
    let pending = 0;
    const later = () => {
      if (pending) return;
      // 定时器而不是 requestAnimationFrame：窗口在后台时也照样更新
      pending = root.setTimeout(() => {
        pending = 0;
        refresh();
      }, 30);
    };
    panel.addEventListener("input", later);
    panel.addEventListener("change", later);
    panel.addEventListener("click", later);
    new MutationObserver(later).observe(document.documentElement, { attributes: true, attributeFilter: ["data-card-theme"] });
    root.mediacraft?.on?.("change", later);

    for (const entry of sections) apply(entry);
    return { refresh, sections: () => sections.map(({ id }) => ({ id, folded: isFolded(sections.find((entry) => entry.id === id)) })) };
  }

  root.MediaCraftSections = Object.freeze({ create, DEFAULT_FOLDED });
})(window);
