// 舞台卡片上的实况预览：在图片框里播放剪好的这一段（静音、按倍速、按取景铺满、圆角同卡片），角上标 LIVE。
// 翻到这一张时播一遍，指针停在图上时循环播放；其余时间藏起视频，露出画布上画好的封面。
// 只是预览，成片由原生壳合成（ADR 0004）。
(() => {
  const live = window.MediaCraftMedia.live;
  const CARD_WIDTH = 864;
  const CARD_HEIGHT = 1152;
  const VISIBLE_RATIO = 0.6; // 卡片露出这么多算翻到了这一张

  const percent = (value, total) => `${(value / total) * 100}%`;

  // 一个实况图片框：source 是 { url, blob?, settings }（找不到视频时为 null，只留 LIVE 角标）
  function createWell(hit, source) {
    const element = document.createElement("div");
    element.className = "stage-live";
    element.dataset.state = "resting";
    element.style.left = percent(hit.x, CARD_WIDTH);
    element.style.top = percent(hit.y, CARD_HEIGHT);
    element.style.width = percent(hit.width, CARD_WIDTH);
    element.style.height = percent(hit.height, CARD_HEIGHT);
    element.style.borderRadius = `${percent(hit.radius, hit.width)} / ${percent(hit.radius, hit.height)}`;
    const badge = document.createElement("span");
    badge.className = "stage-live-badge";
    badge.textContent = window.MediaCraftNative?.capabilities?.motionExport?.includes("mp4") ? "动态" : "LIVE";
    element.append(badge);
    if (!source) return { element, playOnce() {}, setHover() {}, stop() {} };

    const video = document.createElement("video");
    video.className = "stage-live-video";
    video.muted = true;
    video.playsInline = true;
    video.preload = "auto";
    video.setAttribute("aria-hidden", "true");
    // 有 blob 时舞台自己持有一份地址：素材库换稿子、释放视频时收回它的地址，不影响还没撤下的旧卡片（撤下时在 stop 里自己收回）
    const ownUrl = source.blob ? URL.createObjectURL(source.blob) : null;
    video.src = ownUrl ?? source.url;
    element.prepend(video);

    let clip = null;
    let looping = false;
    let playing = false;
    let timer = 0;

    // 取景框按图片框的比例居中铺满（和卡片上画封面一样）
    video.addEventListener("loadedmetadata", () => {
      const meta = { duration: video.duration, width: video.videoWidth, height: video.videoHeight };
      clip = live.clipOf(source.settings, meta.duration);
      const region = live.coverRegion(source.settings.crop, meta, hit.width / hit.height);
      video.style.width = `${100 / region.width}%`;
      video.style.height = `${100 / region.height}%`;
      video.style.left = `${(-region.x / region.width) * 100}%`;
      video.style.top = `${(-region.y / region.height) * 100}%`;
      if (element.dataset.pending) play();
    }, { once: true });

    function rest() {
      clearTimeout(timer);
      playing = false;
      video.pause();
      element.dataset.state = "resting";
    }

    // 到这一段的结尾：循环就回到起点，否则停下露出封面
    function watchEnd() {
      clearTimeout(timer);
      if (!playing) return;
      const left = (clip.start + clip.span - video.currentTime) / (video.playbackRate || 1);
      if (left > 0.03) {
        timer = setTimeout(watchEnd, Math.min(250, left * 1000));
        return;
      }
      if (!looping) {
        rest();
        return;
      }
      video.currentTime = clip.start;
      timer = setTimeout(watchEnd, 100);
    }

    function play() {
      if (!clip) {
        element.dataset.pending = "true";
        return;
      }
      delete element.dataset.pending;
      if (playing) return;
      playing = true;
      video.playbackRate = source.settings.speed;
      video.currentTime = clip.start;
      element.dataset.state = "playing";
      video.play().then(watchEnd, rest);
    }

    return {
      element,
      playOnce() {
        looping = false;
        play();
      },
      setHover(on) {
        looping = on;
        if (on) play();
      },
      stop() {
        rest();
        video.removeAttribute("src");
        video.load();
        if (ownUrl) URL.revokeObjectURL(ownUrl);
      },
    };
  }

  // pagesRoot：放卡片的容器（出图时整组换掉它的子元素）；sourceOf(imageId) → { url, blob?, settings } | null
  function createStage(pagesRoot, sourceOf) {
    let attached = []; // { frame, wells, observer }

    // 出图时每页调一次：frame 是这一页的卡片框（画布在里面），page 是排版结果
    function attachPage(frame, page) {
      const wells = page.imageHits.filter((hit) => hit.live).map((hit) => createWell(hit, sourceOf(hit.imageId)));
      if (!wells.length) return;
      // 卡片后面，操作层前面
      const card = frame.firstElementChild;
      for (const well of wells) card.after(well.element);

      // 翻到这一张时播一遍
      const observer = new IntersectionObserver(([entry]) => {
        if (entry.intersectionRatio >= VISIBLE_RATIO) wells.forEach((well) => well.playOnce());
      }, { threshold: [VISIBLE_RATIO] });
      observer.observe(frame);

      // 指针停在图上时循环播放（图上面压着选择框，所以按位置判断）
      const inside = (well, event) => {
        const rect = well.element.getBoundingClientRect();
        return event.clientX >= rect.left && event.clientX <= rect.right && event.clientY >= rect.top && event.clientY <= rect.bottom;
      };
      frame.addEventListener("pointermove", (event) => wells.forEach((well) => well.setHover(inside(well, event))));
      frame.addEventListener("pointerleave", () => wells.forEach((well) => well.setHover(false)));
      attached.push({ frame, wells, observer });
    }

    // 出图换掉了页面（含切到长文）：放掉旧页上的视频
    new MutationObserver(() => {
      attached = attached.filter((entry) => {
        if (entry.frame.isConnected) return true;
        entry.observer.disconnect();
        entry.wells.forEach((well) => well.stop());
        return false;
      });
    }).observe(pagesRoot, { childList: true });

    return { attachPage };
  }

  window.MediaCraftMedia.createLiveStage = createStage;
})();
