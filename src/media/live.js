// 实况的设置与素材：图片记录里的 liveSettings 怎样读（docs/storage.md），用原视频的哪一段，
// 读视频的时长与画面大小，按设置截出封面（卡片上静止时显示的那一帧），以及当前稿子的实况视频放在哪。
// 成片由原生壳合成（ADR 0004），这里只管网页里要用的部分。
(() => {
  const DURATIONS = [3, 5, 8];
  const SPEEDS = [1, 1.5, 2, 3];
  const DEFAULT_DURATION = 3;
  // 取景比例（宽 / 高）：原视频是整幅画面，自由是随手拖的框
  const ASPECTS = { original: null, free: null, "3:4": 3 / 4, "1:1": 1, "4:3": 4 / 3, "16:9": 16 / 9, "9:16": 9 / 16 };
  // 旧版记下的比例写法
  const LEGACY_ASPECTS = { 1: "1:1", 1.333333: "4:3", 1.777778: "16:9", 0.75: "3:4", 0.5625: "9:16" };
  const FRAME_RATE = 30;
  const MIN_CROP = 0.05;
  const COVER_MAX_SIDE = 1600; // 封面最长边（像素），够卡片 2 倍图用
  const LOAD_TIMEOUT = 20_000;
  const SEEK_TIMEOUT = 3_000;

  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  const numberOr = (value, fallback) => (value !== null && value !== "" && Number.isFinite(Number(value)) ? Number(value) : fallback);

  // 取景框（0–1，按视频的显示方向）：挪回画面里，太小的撑到最小
  function normalizeCrop(crop) {
    if (!crop || typeof crop !== "object") return { x: 0, y: 0, width: 1, height: 1 };
    const width = clamp(numberOr(crop.width, 1), MIN_CROP, 1);
    const height = clamp(numberOr(crop.height, 1), MIN_CROP, 1);
    return { x: clamp(numberOr(crop.x, 0), 0, 1 - width), y: clamp(numberOr(crop.y, 0), 0, 1 - height), width, height };
  }

  function aspectKey(value) {
    if (Object.hasOwn(ASPECTS, value)) return value;
    return LEGACY_ASPECTS[String(value)] ?? "original";
  }

  // 图片记录 → 规范的设置（缺的、不认识的用默认值）。只读记录，不改它。
  //   duration  成片几秒（3 / 5 / 8）      speed  倍速（1 / 1.5 / 2 / 3），用原视频 duration × speed 秒
  //   start     从原视频第几秒起          coverOffset  封面在起点之后第几秒（原视频时间）
  //   sound     成片带不带声音            crop  取景框            aspect  取景比例（编辑器里选的）
  function settingsOf(record) {
    const raw = record?.liveSettings && typeof record.liveSettings === "object" ? record.liveSettings : {};
    return {
      duration: DURATIONS.includes(Number(raw.duration)) ? Number(raw.duration) : DEFAULT_DURATION,
      speed: SPEEDS.includes(Number(raw.speed)) ? Number(raw.speed) : 1,
      start: Math.max(0, numberOr(raw.start, 0)),
      coverOffset: Math.max(0, numberOr(raw.coverOffset, 0)),
      sound: raw.sound !== false,
      crop: normalizeCrop(raw.crop),
      aspect: aspectKey(raw.aspect),
    };
  }

  // 给了的设置加上默认值（3 秒、原速、从头开始、整幅画面、带声音；封面默认取这一段的正中间），按视频长度收好
  function complete(settings, meta) {
    const merged = { duration: DEFAULT_DURATION, speed: 1, start: 0, coverOffset: 0, sound: true, aspect: "original", ...settings };
    merged.crop = normalizeCrop(settings.crop);
    if (settings.coverOffset === undefined) merged.coverOffset = clipOf(merged, meta.duration).span / 2;
    return fitted(merged, meta.duration);
  }

  // 用原视频的哪一段：从 start 起 duration × speed 秒；视频不够长时成片跟着变短（short 为 true）。
  // 返回 { start, span, cover, seconds, short }：cover 是封面在起点之后第几秒，seconds 是成片长度。
  function clipOf(settings, videoDuration) {
    const wanted = settings.duration * settings.speed;
    const total = Number.isFinite(videoDuration) && videoDuration > 0 ? videoDuration : wanted + settings.start;
    const span = Math.min(wanted, total);
    const start = clamp(settings.start, 0, Math.max(0, total - span));
    const lastFrame = Math.max(0, span - settings.speed / FRAME_RATE);
    return { start, span, cover: clamp(settings.coverOffset, 0, lastFrame), seconds: span / settings.speed, short: span < wanted - 0.01 };
  }

  // 把设置里的起点、封面按视频长度挪到有效范围里（存进记录的就是这样的值）
  function fitted(settings, videoDuration) {
    const clip = clipOf(settings, videoDuration);
    return { ...settings, crop: normalizeCrop(settings.crop), start: clip.start, coverOffset: clip.cover };
  }

  // 一个载好首帧的视频元素（不挂进页面）
  function loadVideo(src) {
    return new Promise((resolve, reject) => {
      const video = document.createElement("video");
      video.muted = true;
      video.playsInline = true;
      video.preload = "auto";
      const timer = setTimeout(() => fail(), LOAD_TIMEOUT);
      function fail() {
        clearTimeout(timer);
        video.removeAttribute("src");
        reject(new Error("这段视频读不出来（支持 MP4、MOV）"));
      }
      video.addEventListener("loadeddata", () => {
        clearTimeout(timer);
        if (!video.videoWidth || !video.videoHeight || !Number.isFinite(video.duration) || video.duration <= 0) {
          fail();
          return;
        }
        // WebKit 头一回把视频画到画布上时才开始往外交画面（这一次是黑的）：先空画一次，之后跳到哪一刻都画得出来
        const warm = document.createElement("canvas");
        warm.width = 1;
        warm.height = 1;
        warm.getContext("2d").drawImage(video, 0, 0, 1, 1);
        resolve(video);
      }, { once: true });
      video.addEventListener("error", fail, { once: true });
      video.src = src;
    });
  }

  // 视频的时长与画面大小（按显示方向）
  async function probe(src) {
    const video = await loadVideo(src);
    const meta = { duration: video.duration, width: video.videoWidth, height: video.videoHeight };
    video.removeAttribute("src");
    video.load();
    return meta;
  }

  // 跳到某一刻并等画面出来。已经停在这一刻时不跳（WebKit 不一定再发 seeked）；万一一直等不到也不卡住
  function seek(video, seconds) {
    const target = clamp(seconds, 0, Math.max(0, video.duration - 0.001));
    if (Math.abs(video.currentTime - target) < 0.0005) return Promise.resolve();
    return new Promise((resolve) => {
      const timer = setTimeout(resolve, SEEK_TIMEOUT);
      video.addEventListener("seeked", () => {
        clearTimeout(timer);
        resolve();
      }, { once: true });
      video.currentTime = target;
    });
  }

  // 画出视频此刻的取景框部分；maxSide 限制最长边。这一刻的画面还没出来时画布是透明的
  function drawCrop(video, crop, maxSide) {
    // 取景框是 0–1 的比例，换成视频像素；最长边超过 maxSide 时等比缩小，至少 1 像素
    const area = new DOMRect(crop.x * video.videoWidth, crop.y * video.videoHeight, crop.width * video.videoWidth, crop.height * video.videoHeight);
    const shrink = Math.min(1, maxSide / Math.max(area.width, area.height));
    const side = (length) => Math.max(1, Math.round(length * shrink));
    const out = Object.assign(document.createElement("canvas"), { width: side(area.width), height: side(area.height) });
    const context = out.getContext("2d");
    context.imageSmoothingQuality = "high";
    context.drawImage(video, area.x, area.y, area.width, area.height, 0, 0, out.width, out.height);
    return out;
  }

  const painted = (canvas) => canvas.getContext("2d").getImageData(0, 0, 1, 1).data[3] > 0;

  // 某一刻的画面（取景框部分）。WebKit 直接跳到一组画面末尾的几帧、或跳回当前这一刻时，偶尔交不出画面：
  // 画出来是空的就先退一秒再跳过去，还不行就往后挪一点点
  async function grab(video, seconds, crop, maxSide) {
    let canvas = null;
    for (const hops of [[seconds], [Math.max(0, seconds - 1), seconds], [seconds + 0.001]]) {
      for (const time of hops) await seek(video, time);
      canvas = drawCrop(video, crop, maxSide);
      if (painted(canvas)) break;
    }
    return canvas;
  }

  // 封面：封面那一刻的画面按取景框截下来（JPEG data URL），卡片上静止时显示它，排版也按它的比例
  async function coverImage(src, settings, meta) {
    const video = await loadVideo(src);
    try {
      const clip = clipOf(settings, meta.duration);
      return (await grab(video, clip.start + clip.cover, settings.crop, COVER_MAX_SIDE)).toDataURL("image/jpeg", 0.9);
    } finally {
      video.removeAttribute("src");
      video.load();
    }
  }

  // 在取景框里取一块与目标框同比例、居中的区域（和卡片上一样铺满）；都是 0–1 的比例，aspect 是目标框宽高比
  function coverRegion(crop, meta, aspect) {
    const width = crop.width * meta.width;
    const height = crop.height * meta.height;
    if (width / height > aspect) {
      const w = (height * aspect) / meta.width;
      return { x: crop.x + (crop.width - w) / 2, y: crop.y, width: w, height: crop.height };
    }
    const h = width / aspect / meta.height;
    return { x: crop.x, y: crop.y + (crop.height - h) / 2, width: crop.width, height: h };
  }

  // 当前稿子的实况视频：内存里一份（编辑、预览、导出用），本机存储里一份（经 storage 读写，归稿件模块管）。
  // storage：{ put(key, blob), remove(key), read(key) }，都返回 Promise
  function createLibrary(storage) {
    const items = new Map(); // key → { blob, url }
    const queue = new Map(); // key → 这段视频排着队的删与写回（按先后来，前一个出错不拦后一个）

    function enqueue(key, work) {
      const next = (queue.get(key) ?? Promise.resolve()).catch(() => undefined).then(work);
      queue.set(key, next);
      return next;
    }

    function drop(key) {
      const item = items.get(key);
      if (item) URL.revokeObjectURL(item.url);
      items.delete(key);
    }

    function hold(key, blob) {
      drop(key);
      const item = { blob, url: URL.createObjectURL(blob) };
      items.set(key, item);
      return item;
    }

    return {
      // 换了一篇稿子：放掉上一篇的，放进这一篇的（videos：{ key: Blob }）
      load(videos) {
        for (const key of [...items.keys()]) drop(key);
        for (const [key, blob] of Object.entries(videos || {})) {
          if (blob instanceof Blob) hold(String(key), blob);
        }
      },
      get: (key) => items.get(String(key)) ?? null,
      // 内存里没有时（比如存进去之后才打开）从本机存储读
      async read(key) {
        const item = items.get(String(key));
        if (item) return item;
        const blob = await storage.read(String(key)).catch(() => null);
        return blob ? hold(String(key), blob) : null;
      },
      // 新视频：放进内存并存进本机
      put(key, blob) {
        hold(String(key), blob);
        return storage.put(String(key), blob);
      },
      // 预览里删掉实况（stored 为 false）时从本机存储删掉，内存里留着等撤销；撤销回来时再写回
      // 从本机存储读出来的 Blob 背后就是存储里的那个文件：记录一删，它可能就读不出来了，撤销时也就写不回去。
      // 所以删之前先把内容整个读进内存，换成不靠存储的一份；读不出来就不删（宁可多留一份）
      keepStored(key, stored) {
        key = String(key);
        return enqueue(key, async () => {
          const item = items.get(key);
          if (stored) return item ? storage.put(key, item.blob) : undefined;
          if (item) {
            const copy = new Blob([await item.blob.arrayBuffer()], { type: item.blob.type });
            if (items.get(key) === item) hold(key, copy);
          }
          return storage.remove(key);
        });
      },
      // 再也撤销不回来了：放掉内存里的这一份
      release: (key) => drop(String(key)),
    };
  }

  window.MediaCraftMedia = window.MediaCraftMedia || {};
  window.MediaCraftMedia.live = {
    DURATIONS,
    SPEEDS,
    ASPECTS,
    FRAME_RATE,
    normalizeCrop,
    settingsOf,
    complete,
    clipOf,
    fitted,
    loadVideo,
    probe,
    grab,
    coverImage,
    coverRegion,
    createLibrary,
  };
})();
