// 实况的总入口：把视频做成实况插进稿子（插入菜单、「/」菜单、粘贴、拖进编辑区或舞台，或 App API），
// 打开实况编辑器改设置，舞台上的预览播放，当前稿子的实况视频放在哪，以及导出时交给原生壳合成的素材。
// 实况在稿子里就是一张图（[[image:…]]）：记录里的 src 是封面（按取景截下的那一帧，排版按它的比例），
// 另记原视频的信息与 liveSettings（docs/storage.md）。改设置与改版式一样是撤销历史里的一步。
(() => {
  const { live, liveDialog, createLiveStage } = window.MediaCraftMedia;

  const VIDEO_EXTENSION = /\.(mp4|m4v|mov)$/i;
  const isVideo = (file) => file.type.startsWith("video/") || VIDEO_EXTENSION.test(file.name || "");

  // host：
  //   editor                    正文编辑器（MediaCraftEditor.create() 的接口）
  //   store                     当前稿子的图片记录：get(id) / add(id, record)（同 MediaCraftMedia.create 的 store）
  //   insert(tag, at)           把一行图片标记插在 at
  //   newImageId() / defaultLayout()
  //   storage                   本机存储里的实况视频：put(key, blob) / remove(key) / read(key)，都返回 Promise
  //   readOnly() / notify(message)
  //   elements                  { videoInput（选视频的文件框）, pages（放卡片的容器）}
  function create(host) {
    const { editor, store } = host;
    const library = live.createLibrary(host.storage);

    const keyOf = (id, record) => String(record?.videoKey || id);
    const liveRecord = (id) => {
      const record = store.get(id);
      return record?.kind === "live" ? record : null;
    };

    function guard() {
      if (!host.readOnly()) return true;
      host.notify("内置说明书不能修改，请先新建稿子");
      return false;
    }

    function storeVideo(key, blob) {
      library.put(key, blob).catch(() => host.notify("实况视频没能存进本机，重新打开后可能要再插一次"));
    }

    // 视频的时长与画面大小：记录里有就用，没有（比如内置说明书）就读一遍
    async function metaOf(record, url) {
      const meta = { duration: Number(record.videoDuration), width: Number(record.videoWidth), height: Number(record.videoHeight) };
      return meta.duration > 0 && meta.width > 0 && meta.height > 0 ? meta : live.probe(url);
    }

    // ===== 插入 =====

    // 设置好了：截封面、存视频、写记录、在 at 插一行标记。返回新图片 id
    async function add(file, url, meta, settings, at) {
      const cover = await live.coverImage(url, settings, meta);
      const id = host.newImageId();
      storeVideo(id, file);
      store.add(id, {
        kind: "live",
        src: cover,
        name: `${file.name || "视频"} · 实况`,
        videoKey: id,
        videoName: file.name || "video.mov",
        videoType: file.type || "video/quicktime",
        videoDuration: meta.duration,
        videoWidth: meta.width,
        videoHeight: meta.height,
        liveSettings: settings,
        crop: null,
        layout: host.defaultLayout(),
      });
      host.insert(window.MediaCraftManual.imageTag([id]), at);
      return id;
    }

    // 界面上来的视频（可以几段）：逐段打开实况编辑器，点「插入」的插在 at
    async function importVideos(files, at) {
      if (!guard()) return;
      const draftId = window.MediaCraftDrafts?.currentId?.() ?? null;
      for (const file of files) {
        const url = URL.createObjectURL(file);
        try {
          const meta = await live.probe(url);
          const settings = await liveDialog.open({ name: file.name, src: url, meta, settings: live.complete({}, meta), confirmLabel: "插入" });
          // 对话框开着的时候这个窗口被切到了另一篇（别的窗口或 Agent 让它切的）：这段视频不往新稿子里插
          if (settings && draftId !== (window.MediaCraftDrafts?.currentId?.() ?? null)) {
            host.notify(`切到了另一篇稿子，「${file.name}」没有插入`);
            continue;
          }
          if (settings) await add(file, url, meta, settings, at);
        } catch (error) {
          host.notify(`「${file.name}」没能做成实况：${error.message}`);
        } finally {
          URL.revokeObjectURL(url);
        }
      }
    }

    // App API：不弹编辑器，按给的设置（没给的用默认值）直接插在 at
    async function insert(file, settings, at) {
      const url = URL.createObjectURL(file);
      try {
        const meta = await live.probe(url).catch(() => {
          throw new Error(`「${file.name}」读不出来（支持 MP4、MOV）`);
        });
        return await add(file, url, meta, live.complete(settings, meta), at);
      } finally {
        URL.revokeObjectURL(url);
      }
    }

    // ===== 改设置 =====

    // 新设置连同新封面作为一步改动（可撤销）
    async function apply(id, settings, url, meta) {
      const record = liveRecord(id);
      const cover = await live.coverImage(url, settings, meta);
      const edits = [
        { id, field: "liveSettings", before: record.liveSettings ?? null, after: settings },
        { id, field: "src", before: record.src, after: cover },
      ];
      editor.edit({ media: edits });
    }

    async function source(id) {
      const record = liveRecord(id);
      const item = record ? await library.read(keyOf(id, record)) : null;
      if (!item) throw new Error("实况视频找不到了，请删掉后重新插入这段视频");
      return { record, url: item.url, meta: await metaOf(record, item.url) };
    }

    // 点了编辑器里的实况卡片、舞台上的实况或检查器里的「编辑实况」
    async function edit(id) {
      if (!guard()) return;
      try {
        const { record, url, meta } = await source(id);
        const settings = await liveDialog.open({
          name: record.videoName || record.name, src: url, meta, settings: live.settingsOf(record), confirmLabel: "完成",
        });
        if (settings) await apply(id, settings, url, meta);
      } catch (error) {
        host.notify(error.message);
      }
    }

    // App API：改一段实况的设置（patch 只给要改的几项）
    async function update(id, patch) {
      const { record, url, meta } = await source(id);
      const settings = live.fitted({ ...live.settingsOf(record), ...patch }, meta.duration);
      await apply(id, settings, url, meta);
    }

    // ===== 选视频、舞台预览 =====

    const { videoInput } = host.elements;
    videoInput.addEventListener("change", () => {
      const files = Array.from(videoInput.files).filter(isVideo);
      videoInput.value = "";
      if (files.length) void importVideos(files, editor.selection().start);
    });

    const stage = createLiveStage(host.elements.pages, (id) => {
      const record = liveRecord(id);
      if (!record) return null;
      if (record.previewVideoSrc) return { url: record.previewVideoSrc, settings: live.settingsOf(record) };
      const item = library.get(keyOf(id, record));
      return item ? { url: item.url, blob: item.blob, settings: live.settingsOf(record) } : null;
    });

    return {
      isVideo,
      importVideos,
      insert,
      edit,
      update,
      attachPage: stage.attachPage,
      // 换了一篇稿子：videos 是这一篇存在本机的实况视频 { key: Blob }
      load: (videos) => library.load(videos),
      // 预览里删掉一段实况（stored 为 false）或撤销回来：本机存储里的视频跟着删掉或写回
      keepStored(id, record, stored) {
        library.keepStored(keyOf(id, record), stored).catch(() => undefined);
      },
      // 删掉后再也撤销不回来了：放掉内存里的视频
      release: (id, record) => library.release(keyOf(id, record)),
      // 撤回到旧版本时：内存里没有这段视频就从本机存储读回来
      ensure: (id, record) => library.read(keyOf(id, record)),
      // App API 的 MediaInfo.live
      info(id) {
        const record = liveRecord(id);
        if (!record) return null;
        const { duration, speed, start, coverOffset, sound } = live.settingsOf(record);
        return { videoKey: keyOf(id, record), videoName: record.videoName || "", duration, speed, start, coverOffset, sound };
      },
      // App API：实况视频本体在内存里与本机存储里各多少字节
      async videoBytes(key) {
        const memory = library.get(key);
        const stored = await host.storage.read(String(key)).catch(() => null);
        return { key: String(key), memoryBytes: memory?.blob.size ?? null, storedBytes: stored?.size ?? null };
      },
      // 导出时交给原生壳合成的素材（src/output/）：原视频与这一段怎么剪；视频找不到时为 null
      async exportSource(id) {
        const record = liveRecord(id);
        if (!record) return null;
        const video = record.previewVideoSrc
          ? await fetch(record.previewVideoSrc).then((response) => (response.ok ? response.blob() : null)).catch(() => null)
          : (await library.read(keyOf(id, record)))?.blob;
        if (!video) return null;
        const settings = live.settingsOf(record);
        const clip = live.clipOf(settings, Number(record.videoDuration));
        return {
          video,
          videoName: record.videoName || "video.mov",
          start: clip.start,
          span: clip.span,
          speed: settings.speed,
          cover: clip.cover,
          sound: settings.sound,
          crop: settings.crop,
        };
      },
    };
  }

  window.MediaCraftMedia.createLivePhotos = create;
})();
