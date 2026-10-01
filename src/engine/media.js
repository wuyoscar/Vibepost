// 图片的几样共用规则（HTML 卡片、长文、图片面板与拼图对话框都用）：拼图比例、按文件名找回标准 Markdown 图片、
// 图片的版式（宽度百分比 / 固定框 / 对齐）、裁剪框，以及长图上把一张图铺满一个框（drawCover）。
(function (root) {
  "use strict";

  const engine = root.MediaCraftEngine || (root.MediaCraftEngine = {});

  const PAIR_RATIOS = Object.freeze({ "1x1": 1, "4x3": 4 / 3, "3x2": 3 / 2, "16x9": 16 / 9 });
  const FALLBACK_PAIR_RATIO = "16x9"; // 拼图标记里没写比例或写了认不出的比例时
  const IMAGE_ALIGNS = new Set(["left", "center", "right"]);

  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

  // 拼图两格合起来的宽高比
  const pairRatio = (ratio) => PAIR_RATIOS[ratio] || PAIR_RATIOS[FALLBACK_PAIR_RATIO];

  // 图片版式：固定框 > 宽度百分比 > 预览里拖出来的缩放 > 默认（100%），对齐默认居中。
  function resolveImageLayout(layout) {
    const value = layout && typeof layout === "object" ? layout : {};
    const positive = (number) => (Number.isFinite(Number(number)) && Number(number) > 0 ? Number(number) : null);
    const percent = positive(value.widthPercent);
    const scale = positive(value.widthScale);
    return {
      widthPercent: percent === null ? null : clamp(percent, 25, 100),
      widthScale: scale === null ? null : clamp(scale, 0.25, 1),
      fixedWidth: positive(value.fixedWidth),
      fixedHeight: positive(value.fixedHeight),
      align: IMAGE_ALIGNS.has(value.align) ? value.align : "center",
    };
  }

  // 裁剪框（原图像素）；没裁剪或裁剪框无效时是整张图。
  // 宽高至少 1 像素、不超出原图（没给时取整张）；左上角收进原图里放得下这个框的范围。
  function imageCropRect(size, crop) {
    if (!crop) return { x: 0, y: 0, width: size.width, height: size.height };
    const extent = (value, full) => clamp(Number(value) || full, 1, full);
    const offset = (value, room) => clamp(Number(value) || 0, 0, room);
    const width = extent(crop.width, size.width);
    const height = extent(crop.height, size.height);
    return { x: offset(crop.x, size.width - width), y: offset(crop.y, size.height - height), width, height };
  }

  // 按文件名找回标准 Markdown 图片：只看最后一段文件名，不分大小写。
  function fileKey(path) {
    const clean = String(path || "").split(/[?#]/)[0];
    return clean.slice(clean.lastIndexOf("/") + 1).toLowerCase();
  }

  function mediaLookup(media) {
    const byName = new Map();
    for (const [id, image] of Object.entries(media)) {
      for (const key of [fileKey(image.sourcePath), fileKey(image.name)]) {
        if (key && !byName.has(key)) byName.set(key, id);
      }
    }
    return byName;
  }

  // 在 crop 里取一块与目标框同比例、居中的区域（object-fit: cover）
  function coverRect(crop, width, height) {
    const aspect = width / height;
    if (crop.width / crop.height > aspect) {
      const sw = crop.height * aspect;
      return { x: crop.x + (crop.width - sw) / 2, y: crop.y, width: sw, height: crop.height };
    }
    const sh = crop.width / aspect;
    return { x: crop.x, y: crop.y + (crop.height - sh) / 2, width: crop.width, height: sh };
  }

  // 把图片的 crop 部分铺满 (x, y, width, height)，多出来的居中裁掉。crop 省略时用整张图。
  function drawCover(ctx, image, crop, x, y, width, height) {
    const full = { x: 0, y: 0, width: image.naturalWidth || image.width, height: image.naturalHeight || image.height };
    const from = coverRect(crop || full, width, height);
    ctx.drawImage(image, from.x, from.y, from.width, from.height, x, y, width, height);
  }

  Object.assign(engine, {
    PAIR_RATIOS, // 拼图能选的比例，由方到扁
    pairRatio,
    resolveImageLayout,
    imageCropRect,
    imageFileKey: fileKey,
    mediaLookup,
    drawCover,
  });
})(globalThis);
