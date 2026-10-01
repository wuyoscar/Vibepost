// 图片与 PDF 的总入口：导入（插入菜单、「/」菜单、粘贴、拖进编辑区或舞台；视频交给实况）、裁剪、拼图、
// 舞台上的选中 / 拖动 / 缩放 / 删除、检查器里的「图片」，以及署名头像的裁剪。
// 每个改动都经编辑器变成撤销历史里的一步：位置、拼图写在正文里，版式、裁剪作为图片属性的改动一起记下。
(() => {
  const { importer, placement, cropDialog, pairDialog, createStage, createPanel } = window.MediaCraftMedia;
  const { parseMarkdown } = window.MediaCraftEngine;

  // 正文里还引用着的图片 id
  function referencedIds(text) {
    const ids = new Set();
    for (const block of parseMarkdown(text).blocks) {
      if (block.type === "image" && block.imageId) ids.add(block.imageId);
      if (block.type === "imagePair") block.imageIds.forEach((id) => ids.add(id));
    }
    return ids;
  }

  // host：
  //   editor                    正文编辑器（MediaCraftEditor.create() 的接口）
  //   store                     当前稿子的图片记录（怎么存盘归稿子存储管，这里只经这几个方法）：
  //                             get(id) / ids() / add(id, record) / set(id, field, value) / remove(id)（可撤销地删掉）
  //   readOnly()                这篇不能改（内置说明书）
  //   render()                  请求重新出图
  //   notify(message)           状态栏提示
  //   editLivePhoto(id)         打开实况编辑器
  //   isVideo(file) / importVideos(files, at)  粘贴、拖进来的视频做成实况（src/media/live-photos.js）
  //   avatar                    署名头像：get() → { src, crop }；set({ src?, crop })
  //   elements                  { viewport, pages, panel, fileInput, avatarInput, avatarCrop }
  function create(host) {
    const { editor, store, elements } = host;

    function refresh() {
      editor.refreshMedia();
      panel.show(stage.selection());
    }

    function changed() {
      refresh();
      host.render();
    }

    function guard() {
      if (!host.readOnly()) return true;
      host.notify("内置说明书不能修改，请先新建稿子");
      return false;
    }

    // ===== 导入 =====

    // 插入一组图片标记（每张一行），规则同编辑器的插入整行
    function insertTags(tags, at) {
      editor.insertBlock(tags.join("\n"), at);
      changed();
    }

    // 图片 / PDF 文件按文件名排好插在 at；返回新图片 id（一张都没插进去时为 null）
    async function importFiles(files, at = editor.selection().start) {
      const list = Array.from(files || []);
      if (!list.length || !guard()) return null;
      const { images, problems } = await importer.readImages(list);
      if (problems.length) host.notify(problems.join("；"));
      if (!images.length) return null;
      const ids = images.map(() => importer.newImageId());
      images.forEach(({ name, src }, index) => {
        store.add(ids[index], { name, src, sourcePath: name, layout: { ...importer.DEFAULT_LAYOUT }, crop: null });
      });
      insertTags(ids.map((id) => placement.imageTag([id])), at);
      if (!problems.length) host.notify(`已插入 ${ids.length} 张图片`);
      return ids;
    }

    // 只读进这篇的图片、不插进正文（封面的底图）：返回图片 id，读不出来时为 null；PDF 只取第一页
    async function importDetached(file) {
      if (!guard()) return null;
      const { images, problems } = await importer.readImages([file]);
      if (problems.length) host.notify(problems.join("；"));
      if (!images.length) return null;
      const [{ name, src }] = images;
      const id = importer.newImageId();
      store.add(id, { name, src, sourcePath: name, layout: { ...importer.DEFAULT_LAYOUT }, crop: null });
      refresh();
      return id;
    }

    // 粘贴、拖进来的文件：图片与 PDF 直接插在 at，视频逐段打开实况编辑器
    async function importDropped(files, at) {
      if (!guard()) return;
      const list = Array.from(files || []);
      const videos = list.filter(host.isVideo);
      if (videos.length < list.length) await importFiles(list.filter((file) => !host.isVideo(file)), at);
      if (videos.length) await host.importVideos(videos, at);
    }

    // ===== 改图片属性（版式、裁剪、名字）=====

    function mediaEdit(id, field, after) {
      const image = store.get(id);
      return image ? { id, field, before: image[field] ?? null, after } : null;
    }

    // 编辑器落下来的属性改动（刚记下的，或撤销 / 重做到的）
    function applyEdits(edits) {
      for (const { id, field, after } of edits) store.set(id, field, after);
      changed();
    }

    function setLayouts(ids, change) {
      if (!guard()) return;
      editor.edit({ media: ids.map((id) => mediaEdit(id, "layout", change(store.get(id)?.layout ?? null))).filter(Boolean) });
    }

    // App API：改名字、整个换掉版式或裁剪（null 回到默认 / 不裁）
    function updateImage(id, patch) {
      const edits = [];
      if ("layout" in patch) edits.push(mediaEdit(id, "layout", patch.layout ? { ...patch.layout } : null));
      if ("crop" in patch) edits.push(mediaEdit(id, "crop", patch.crop ? { ...patch.crop } : null));
      if ("name" in patch) edits.push(mediaEdit(id, "name", String(patch.name)));
      editor.edit({ media: edits.filter(Boolean) });
    }

    // ===== 裁剪与拼图 =====

    async function cropImage(id) {
      const image = store.get(id);
      if (!image?.src) return;
      let crop;
      try {
        crop = await cropDialog.open({ name: image.name || id, src: image.src, crop: image.crop ?? null });
      } catch {
        host.notify(`「${image.name || id}」打不开，没法裁剪`);
        return;
      }
      if (crop !== undefined) editor.edit({ media: [mediaEdit(id, "crop", crop)].filter(Boolean) });
    }

    // ref：{ ids, source }，source 是拼图标记在正文里的范围
    async function editPair(ref) {
      const text = editor.getText();
      const range = placement.tagRange(text, ref.source);
      const tag = text.slice(range.from, range.to);
      const images = {};
      for (const id of ref.ids) {
        const image = store.get(id);
        if (!image?.src) return;
        images[id] = { name: image.name || id, src: image.src, crop: image.crop ?? null };
      }
      let result;
      try {
        result = await pairDialog.open({
          ids: ref.ids,
          ratio: placement.pairRatio(text, ref.source),
          images,
          cropImage: (id, crop) => cropDialog.open({ name: images[id].name, src: images[id].src, crop }),
        });
      } catch {
        host.notify("拼图里的图片打不开");
        return;
      }
      if (!result) return;
      const current = editor.getText();
      if (current.slice(range.from, range.to) !== tag) {
        host.notify("正文变了，拼图没有改");
        return;
      }
      const lines = result.split ? result.ids.map((id) => placement.imageTag([id])) : [placement.imageTag(result.ids, result.ratio)];
      const crops = Object.entries(result.crops).map(([id, crop]) => mediaEdit(id, "crop", crop)).filter(Boolean);
      editor.edit({ text: placement.replaceTag(current, ref.source, lines), media: crops });
      changed();
    }

    // 点了编辑器里的缩略图卡片或舞台上的图：图片裁剪、实况打开实况编辑器、拼图打开拼图对话框
    function edit(ref) {
      if (!ref || !guard()) return;
      if (ref.ids.length > 1) void editPair(ref);
      else if (store.get(ref.ids[0])?.kind === "live") host.editLivePhoto(ref.ids[0]);
      else void cropImage(ref.ids[0]);
    }

    // ===== 位置：删除、挪动、拼成一组 =====

    function remove(ref) {
      if (!ref || !guard()) return;
      const next = placement.remove(editor.getText(), ref.source);
      stage.clearSelection();
      editor.edit({ text: next });
      const still = referencedIds(next);
      for (const id of ref.ids) {
        if (!still.has(id) && store.get(id)) store.remove(id);
      }
      changed();
    }

    // 挪到落点 drop：{ target, after }（target 是排版给出的 dropTargets 里的一项）；返回是否挪动了
    function move(ref, drop) {
      if (!guard()) return false;
      const text = editor.getText();
      const next = placement.move(text, ref.source, placement.dropPosition(text, drop.target, drop.after));
      if (next === null) return false;
      editor.edit({ text: next });
      host.render();
      return true;
    }

    function pair(ref, target, side) {
      if (!guard()) return;
      const next = placement.pairUp(
        editor.getText(),
        { id: ref.ids[0], source: ref.source },
        { id: target.ids[0], source: target.source },
        side,
      );
      if (next === null) {
        host.notify("要拼图的那张图得单独占一行");
        return;
      }
      stage.selectAfterRender(`pair:${(side === "left" ? [ref.ids[0], target.ids[0]] : [target.ids[0], ref.ids[0]]).join("|")}`);
      editor.edit({ text: next });
      host.render();
    }

    // ===== 舞台与检查器 =====

    const stage = createStage({
      viewport: elements.viewport,
      pagesRoot: elements.pages,
      actions: {
        readOnly: host.readOnly,
        label: (id) => store.get(id)?.name || id,
        align: (id) => store.get(id)?.layout?.align ?? "center",
        select: (ref) => panel.show(ref),
        edit,
        remove,
        move,
        pair,
        resize: (ref, percent) => setLayouts([ref.ids[0]], (layout) => ({ align: layout?.align ?? "center", widthPercent: percent })),
        dropFiles: (files, drop) => {
          const text = editor.getText();
          void importDropped(files, drop ? placement.dropPosition(text, drop.target, drop.after) : text.length);
        },
      },
    });

    const panel = createPanel(elements.panel, {
      image: (id) => store.get(id),
      allIds: () => store.ids(),
      setLayouts,
      editSelected: () => edit(stage.selection()),
      removeSelected: () => remove(stage.selection()),
      deselect: () => stage.clearSelection(),
    });

    // ===== 文件选择、头像 =====

    elements.fileInput.addEventListener("change", () => {
      const files = Array.from(elements.fileInput.files);
      elements.fileInput.value = "";
      void importFiles(files, editor.selection().start);
    });

    // 换头像：读进来先裁一个正方形（取消就用整张图居中）
    elements.avatarInput.addEventListener("change", async () => {
      const [file] = elements.avatarInput.files;
      elements.avatarInput.value = "";
      if (!file) return;
      try {
        const src = await importer.readAsDataUrl(file);
        const crop = await cropDialog.open({ src, crop: null, lockAspect: 1 });
        await host.avatar.set({ src, crop: crop ?? null });
      } catch {
        host.notify(`「${file.name}」打不开，头像没换`);
      }
    });
    elements.avatarCrop.addEventListener("click", async () => {
      const { src, crop } = host.avatar.get();
      const next = await cropDialog.open({ src, crop, lockAspect: 1 }).catch(() => undefined);
      if (next !== undefined) await host.avatar.set({ crop: next });
    });

    // 拖文件到别处松手时拦下来，否则 WKWebView 会直接去打开这个文件
    for (const type of ["dragover", "drop"]) {
      document.addEventListener(type, (event) => {
        if (importer.hasFiles(event.dataTransfer)) event.preventDefault();
      });
    }

    return {
      importFiles,
      importDetached,
      importDropped,
      insertTags,
      newImageId: importer.newImageId,
      defaultLayout: () => ({ ...importer.DEFAULT_LAYOUT }),
      applyEdits,
      updateImage,
      edit,
      move,
      refresh,
      attachPage: stage.attach,
    };
  }

  window.MediaCraftMedia.create = create;
})();
