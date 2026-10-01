// App API 的 media 一组：当前稿子里的图片与实况（导入、改版式与裁剪、挪位置、实况设置）。挂在 window.mediacraft.media。
(function (root) {
  "use strict";

  // 实况设置里 App API 能给的几项；时长、倍速只能取界面上有的值，其余收进有效范围（没给的不出现）
  const LIVE_FIELDS = ["duration", "speed", "start", "coverOffset", "sound", "crop"];
  const LAYOUT_FIELDS = ["widthPercent", "fixedWidth", "fixedHeight", "align"];
  const CROP_FIELDS = ["x", "y", "width", "height"];

  function liveSettings(options) {
    const { DURATIONS, SPEEDS, normalizeCrop } = root.MediaCraftMedia.live;
    if ("duration" in options && !DURATIONS.includes(Number(options.duration))) {
      throw new TypeError(`时长只能是 ${DURATIONS.join(" / ")} 秒`);
    }
    if ("speed" in options && !SPEEDS.includes(Number(options.speed))) {
      throw new TypeError(`倍速只能是 ${SPEEDS.join(" / ")}`);
    }
    const settings = {};
    for (const key of ["duration", "speed", "start", "coverOffset"]) {
      if (key in options) settings[key] = Math.max(0, Number(options[key]) || 0);
    }
    if ("sound" in options) settings.sound = Boolean(options.sound);
    if ("crop" in options) {
      settings.crop = normalizeCrop(options.crop);
      settings.aspect = options.crop ? "free" : "original";
    }
    return settings;
  }

  // crop：原图像素里的 { x, y, width, height }，x、y ≥ 0，宽高 > 0
  function assertCrop(crop, check) {
    check.fields(crop, CROP_FIELDS, "crop：");
    const valid = Object.values(crop).every((value) => Number.isFinite(value) && value >= 0) && crop.width > 0 && crop.height > 0;
    if (!valid) throw new TypeError("crop 需要 x、y ≥ 0，width、height > 0 的像素值");
  }

  // app：见 src/app.js；check：src/api/api.js 里共用的校验（fields、editable）
  function media(app, check) {
    const { editor, livePhotos, pipeline } = app;
    const images = () => app.draft.images;

    function info(id) {
      const image = images()[id];
      if (!image) return null;
      const result = {
        id,
        kind: image.kind === "live" ? "live" : "image",
        name: image.name || "",
        layout: image.layout ? { ...image.layout } : null,
        crop: image.crop ? { ...image.crop } : null,
      };
      if (image.kind === "live") result.live = livePhotos.info(id);
      return result;
    }

    // 插入位置：给了 at 用它（收进正文长度内），没给用光标处
    function insertionPoint(at) {
      const length = editor.getText().length;
      return Math.min(length, Math.max(0, Number(at ?? editor.selection().start) || 0));
    }

    return {
      async list() {
        return Object.keys(images()).map(info);
      },
      async get(id) {
        return info(id);
      },
      // 画面本体：data URL 或随网页打包的相对路径。
      async src(id) {
        return images()[id]?.src || null;
      },
      // 页内专用：插入图片 / PDF（PDF 每页一张图），按文件名排序，插在 at（Markdown 偏移，默认光标处）。返回新图片 id。
      async import(files, options = {}) {
        check.fields(options, ["at"], "media.import：");
        check.editable();
        const list = Array.from(files || []);
        if (!list.length || !list.every((file) => file instanceof Blob)) throw new TypeError("media.import 需要 File 数组");
        const before = app.statusText();
        const ids = await app.media.importFiles(list, insertionPoint(options.at));
        if (!ids) {
          const message = app.statusText();
          throw new Error(message !== before ? message : "没有可导入的图片或 PDF");
        }
        await pipeline.now();
        return ids;
      },
      // layout 整个替换：{ widthPercent, fixedWidth, fixedHeight, align }，null 回到默认；live 只改给出的几项实况设置
      // （duration、speed、start、coverOffset、sound、crop，封面跟着重截）；crop：原图像素里的 { x, y, width, height }，null 不裁。
      // 与界面上改一样可以撤销。
      async update(id, patch) {
        check.fields(patch, ["name", "layout", "live", "crop"], "media.update：");
        check.editable();
        const image = images()[id];
        if (!image) throw new Error(`没有这张图：${id}`);
        if ("layout" in patch && patch.layout !== null) check.fields(patch.layout, LAYOUT_FIELDS, "layout：");
        if ("live" in patch) {
          if (image.kind !== "live") throw new Error(`这张不是实况：${id}`);
          check.fields(patch.live, LIVE_FIELDS, "live：");
          await livePhotos.update(id, liveSettings(patch.live));
        }
        if ("crop" in patch && patch.crop !== null) assertCrop(patch.crop, check);
        app.media.updateImage(id, patch);
        await pipeline.now();
        return info(id);
      },
      // 与在预览里拖动图片相同：移到第 page 页第 target 个落点（render.pages() 的 dropTargets）之前或之后。
      async move(id, { page, target, after = false } = {}) {
        check.editable();
        await pipeline.settle();
        const canvases = pipeline.cards();
        // 封面的底图不在正文里，挪的是正文里的那一张
        const hit = canvases.flatMap((canvas) => root.MediaCraftRender.pageOf(canvas).imageHits).find((item) => item.imageId === id && !item.cover);
        if (!hit) throw new Error(`预览里没有这张图：${id}`);
        const dropTarget = canvases[page] && root.MediaCraftRender.pageOf(canvases[page]).dropTargets[target];
        if (!dropTarget) throw new RangeError(`第 ${page} 页没有第 ${target} 个落点`);
        const moved = app.media.move({ ids: [id], source: hit.source }, { target: dropTarget, after: Boolean(after) });
        await pipeline.now();
        return moved;
      },
      // 页内专用：视频做成实况插入，不弹编辑器。options：at、duration（3/5/8）、speed（1/1.5/2/3）、start、coverOffset、sound、crop；
      // 没给的用默认值：3 秒、原速、从头、整幅画面、带声音、封面在这一段正中间。返回 id。
      async insertLivePhoto(file, options = {}) {
        check.fields(options, ["at", ...LIVE_FIELDS], "media.insertLivePhoto：");
        check.editable();
        if (!(file instanceof Blob)) throw new TypeError("media.insertLivePhoto 需要视频文件");
        const id = await livePhotos.insert(file, liveSettings(options), insertionPoint(options.at));
        await pipeline.now();
        return id;
      },
      // 实况视频本体的保存情况：内存里与本机存储（IndexedDB）里各有多少字节，没有为 null。
      video: (key) => livePhotos.videoBytes(key),
    };
  }

  (root.MediaCraftApi ||= {}).media = media;
})(window);
