// 当前稿子的图片记录（draft.images）：图片与实况模块只经这里读写。
// - copy-on-write：每次改动都把整组换成新的（冻结的）对象，不在原来的上面改；出图、存盘拿到的引用就是那一刻的快照。
// - 预览里删掉的图片（含实况）可以撤销：撤销时连同画面和视频一起回来，重做时再删掉；
//   撤销历史里再也回不到引用它的那一步（切换稿子、历史步数超限）时才真正丢弃。
(() => {
  "use strict";

  const IMAGE_TAG = /\[\[image:([\w|-]+)\]\]/g;

  // 正文里出现的图片 id（拼图里的两张都算）
  const idsIn = (content) => new Set([...String(content || "").matchAll(IMAGE_TAG)].flatMap((match) => match[1].split("|")));

  const without = (images, id) => Object.fromEntries(Object.entries(images).filter(([key]) => key !== id));

  // host：
  //   images() / setImages(next)   当前稿子的图片记录（next 是新的对象，由调用方冻结后换上）
  //   livePhotos()                 keepStored(id, record, stored) / release(id, record)（src/media/live-photos.js）
  //   refresh()                    撤销 / 重做让图片有进有出之后，刷新编辑器缩略图与检查器
  function create(host) {
    const deletions = new Map(); // imageId → { image, deleted }

    // 删掉（deleted）或经撤销找回一张图；实况的视频跟着从本机存储里删掉或写回（内存里留着，撤销得回来）。
    function setDeleted(imageId, image, deleted) {
      if (!image) return;
      deletions.set(imageId, { image, deleted });
      const images = host.images();
      host.setImages(deleted ? without(images, imageId) : { ...images, [imageId]: image });
      if (image.kind === "live") host.livePhotos().keepStored(imageId, image, !deleted);
    }

    return {
      // ===== MediaCraftMedia.create / createLivePhotos 的 store =====
      get: (id) => host.images()[id] ?? null,
      ids: () => Object.keys(host.images()),
      add(id, record) {
        host.setImages({ ...host.images(), [id]: record });
      },
      set(id, field, value) {
        const image = host.images()[id];
        if (image) host.setImages({ ...host.images(), [id]: { ...image, [field]: structuredClone(value) } });
      },
      // 可撤销地删掉：⌘Z 回到还引用它的那一步时连同画面（实况连同视频）一起回来
      remove: (id) => setDeleted(id, host.images()[id], true),

      // 撤销 / 重做到某一步时，预览里删过的图片跟着这一步的正文出现或消失。
      syncDeletions(content) {
        const referenced = idsIn(content);
        let changed = false;
        deletions.forEach(({ image, deleted }, id) => {
          const wanted = referenced.has(id);
          if (wanted !== deleted) return;
          setDeleted(id, host.images()[id] || image, !wanted);
          changed = true;
        });
        if (changed) host.refresh();
      },

      // 换了一篇稿子（撤销历史从头开始）：正文里不再引用的删图再也找不回来了，放掉内存里的实况视频。
      forgetDeletions(content) {
        const referenced = idsIn(content);
        deletions.forEach(({ image, deleted }, id) => {
          if (referenced.has(id)) return;
          deletions.delete(id);
          if (deleted && image.kind === "live") host.livePhotos().release(id, image);
        });
      },

      // 编辑器里缩略图卡片要的素材：ref 是 { id }（[[image:…]]）或 { path }（![说明](文件名)）
      editorInfo(ref) {
        const engine = window.MediaCraftEngine;
        const images = host.images();
        const id = ref.id ?? engine.mediaLookup(images).get(engine.imageFileKey(ref.path));
        const image = id ? images[id] : null;
        if (!image) return { id: id ?? "", name: ref.path ?? ref.id, src: "", kind: "image", missing: true };
        return { id, name: image.name || id, src: image.src || "", kind: image.kind === "live" ? "live" : "image", missing: false };
      },
    };
  }

  window.MediaCraftMedia.createImageStore = create;
})();
