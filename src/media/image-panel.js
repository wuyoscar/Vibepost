// 检查器「图片」：舞台上选中一张图时，调它自己的宽度、对齐、固定宽高，裁剪或删除；
// 没选中时，把宽度或固定宽高一次用到这篇的全部图片。每次改动都是撤销历史里的一步。
(() => {
  const DEFAULT_PERCENT = 100;
  const KIND_NAME = { image: "图片", live: "实况", pair: "拼图" };
  const EDIT_LABEL = { image: "裁剪", live: "编辑实况", pair: "调整拼图" };

  // 版式里的宽度百分比：固定宽高或旧版拖出来的缩放都换算成百分比显示
  function widthPercentOf(layout) {
    if (layout?.widthPercent) return Math.round(layout.widthPercent);
    if (layout?.widthScale) return Math.round(layout.widthScale * 100);
    return DEFAULT_PERCENT;
  }

  const positive = (input) => {
    const value = Math.round(Number(input.value));
    return input.value.trim() && Number.isFinite(value) && value > 0 ? value : null;
  };

  // actions：
  //   image(id)                 图片记录 { name, src, layout, crop, kind }
  //   allIds()                  这篇的全部图片 id
  //   setLayouts(ids, change)   改一批图片的版式：change(旧版式) → 新版式，一步撤销
  //   editSelected()            裁剪选中的图（拼图、实况打开各自的编辑器）
  //   removeSelected()          删除选中的图
  //   deselect()                取消舞台上的选中
  function createPanel(root, actions) {
    const $ = (selector) => root.querySelector(selector);
    const summary = $("[data-image-summary]");
    const thumb = $("[data-image-thumb]");
    const name = $("[data-image-name]");
    const info = $("[data-image-info]");
    const scope = $("[data-image-scope]");
    const hint = $("[data-image-hint]");
    const width = $("[data-image-width]");
    const widthValue = $("[data-image-width-value]");
    const alignRow = $("[data-image-align-row]");
    const fixedWidth = $("[data-image-fixed-width]");
    const fixedHeight = $("[data-image-fixed-height]");
    const editButton = $("[data-image-edit]");
    const deleteButton = $("[data-image-delete]");
    const sizeControls = root.querySelectorAll("[data-image-size]");
    let current = null; // 选中的 ref（舞台给的）

    function showWidth(value) {
      width.value = String(value);
      widthValue.textContent = `${value}%`;
      width.style.setProperty("--fill", `${((value - Number(width.min)) / (Number(width.max) - Number(width.min))) * 100}%`);
    }

    function show(ref) {
      current = ref;
      const single = ref && ref.kind !== "pair";
      const image = ref ? actions.image(ref.ids[0]) : null;
      summary.hidden = !ref;
      hint.hidden = Boolean(ref);
      scope.textContent = ref ? `选中的${KIND_NAME[ref.kind]}` : "全部图片";
      editButton.hidden = !ref;
      deleteButton.hidden = !ref;
      alignRow.hidden = !single;
      sizeControls.forEach((element) => {
        element.hidden = Boolean(ref) && !single;
      });
      if (!ref) {
        fixedWidth.value = "";
        fixedHeight.value = "";
        return;
      }
      const images = ref.ids.map(actions.image).filter(Boolean);
      thumb.src = images[0]?.src || "";
      name.textContent = images.map((item) => item.name).join(" + ");
      editButton.textContent = EDIT_LABEL[ref.kind];
      if (!single) {
        info.textContent = "两张并排成一组";
        return;
      }
      const layout = image?.layout ?? null;
      info.textContent = [
        ref.kind === "live" ? "实况" : null,
        image?.crop ? `裁剪为 ${image.crop.width} × ${image.crop.height}` : null,
        layout?.fixedWidth && layout?.fixedHeight ? `固定 ${layout.fixedWidth} × ${layout.fixedHeight}` : `宽度 ${widthPercentOf(layout)}%`,
      ].filter(Boolean).join(" · ");
      showWidth(widthPercentOf(layout));
      fixedWidth.value = layout?.fixedWidth && layout?.fixedHeight ? String(layout.fixedWidth) : "";
      fixedHeight.value = layout?.fixedWidth && layout?.fixedHeight ? String(layout.fixedHeight) : "";
      alignRow.querySelectorAll("[data-image-align]").forEach((button) => {
        button.setAttribute("aria-pressed", String(button.dataset.imageAlign === (layout?.align ?? "center")));
      });
    }

    const selectedId = () => (current && current.kind !== "pair" ? current.ids[0] : null);
    const alignOf = (layout) => layout?.align ?? "center";
    const byWidth = (percent) => (layout) => ({ align: alignOf(layout), widthPercent: percent });
    const byFixed = (w, h) => (layout) => ({ align: alignOf(layout), widthPercent: widthPercentOf(layout), fixedWidth: w, fixedHeight: h });

    width.addEventListener("input", () => showWidth(Number(width.value)));
    // 松手才改：拖动途中不往撤销历史里塞一串
    width.addEventListener("change", () => {
      const id = selectedId();
      if (id) actions.setLayouts([id], byWidth(Number(width.value)));
    });
    alignRow.addEventListener("click", (event) => {
      const align = event.target.closest("[data-image-align]")?.dataset.imageAlign;
      const id = selectedId();
      if (align && id) actions.setLayouts([id], (layout) => ({ ...layout, align }));
    });
    // 选中一张图时：宽高都填了就按固定框排，两个都清空就回到按宽度排
    for (const input of [fixedWidth, fixedHeight]) {
      input.addEventListener("change", () => {
        const id = selectedId();
        if (!id) return;
        const w = positive(fixedWidth);
        const h = positive(fixedHeight);
        if (w && h) actions.setLayouts([id], byFixed(w, h));
        else if (!fixedWidth.value.trim() && !fixedHeight.value.trim()) actions.setLayouts([id], (layout) => byWidth(widthPercentOf(layout))(layout));
      });
    }
    $("[data-image-apply-width]").addEventListener("click", () => {
      actions.setLayouts(actions.allIds(), byWidth(Number(width.value)));
    });
    $("[data-image-apply-fixed]").addEventListener("click", () => {
      const w = positive(fixedWidth);
      const h = positive(fixedHeight);
      if (w && h) actions.setLayouts(actions.allIds(), byFixed(w, h));
      else (w ? fixedHeight : fixedWidth).focus();
    });
    editButton.addEventListener("click", () => actions.editSelected());
    deleteButton.addEventListener("click", () => actions.removeSelected());
    $("[data-image-deselect]").addEventListener("click", () => actions.deselect());

    showWidth(DEFAULT_PERCENT);
    return { show };
  }

  window.MediaCraftMedia = window.MediaCraftMedia || {};
  window.MediaCraftMedia.createPanel = createPanel;
})();
