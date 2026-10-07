// AI 的修改、版本与预设命令（src/ai/review.js、versions.js、presets.js）落到正在编辑的这篇上：审阅时编辑器里的标注与舞台上的预览，
// 以及一步可撤销地改稿子（接受修改、撤回到某个版本、用 AI 起的标题）。
// 审阅时舞台只是预览（按「没拒绝的都接受」出图）：不能拖改图片、不能导出。
(function (root) {
  "use strict";

  // host：
  //   editor                 正文编辑器（showReview、edit）
  //   draftId() / images()   当前稿子的 id 与图片记录（含画面）
  //   fieldValues()          正文以外随正文一起撤销的字段（版本里存的也是这些），形状同稿件记录（docs/storage.md）
  //   assertEditable()       内置说明书不能改：抛错
  //   render                 出图流水线：request() / now()
  //   livePhotos             ensure(id, record)：实况的原视频放回内存
  function create(host) {
    let preview = null; // 审阅时舞台按它出图：{ content, title }；不在审阅时为 null

    // 版本里的图片只有信息，画面从现在的图片或本机媒体库里取（版本用着的不会被删）；实况的原视频放回内存
    async function imagesWithData(images) {
      await root.MediaCraftDrafts.flush();
      const current = host.images();
      // 现在的图片里没有的（版本里有、后来删掉的）才去本机媒体库读：别把这篇全部图片都读成 data URL 再大多丢掉
      const missing = Object.keys(images).filter((id) => !current[id]?.src);
      const stored = missing.length ? await root.MediaCraftDrafts.store.readMedia(host.draftId()) : { images: {} };
      const restored = Object.fromEntries(Object.entries(images).map(([id, info]) => [
        id,
        { ...info, src: current[id]?.src ?? stored.images[id] ?? info.src ?? "" },
      ]));
      await Promise.all(Object.entries(restored)
        .filter(([, image]) => image.kind === "live")
        .map(([id, image]) => host.livePhotos.ensure(id, image)));
      return restored;
    }

    const adapter = {
      // 显示 / 收起审阅：{ hunks, preview: { markdown, title }, decide } 或 null
      review(view) {
        const next = view && { content: view.preview.markdown, title: view.preview.title };
        // 预览是「没拒绝的都接受」：接受某一处时预览没变，只更新编辑器里的标注，不整篇重出图
        const same = Boolean(preview && next && preview.content === next.content && preview.title === next.title);
        preview = next;
        host.editor.showReview(view && { hunks: view.hunks, decide: view.decide });
        if (!same) host.render.request();
      },
      // 撤销历史里的一步：patch 可含 markdown 与 fieldValues() 里的任意字段（images 只要信息，不要画面）
      async edit(patch) {
        host.assertEditable();
        const next = { ...patch };
        if (patch.images) next.images = await imagesWithData(patch.images);
        const now = host.fieldValues();
        const fields = Object.keys(now)
          .filter((field) => field in next && (field === "images" || JSON.stringify(now[field]) !== JSON.stringify(next[field])))
          .map((field) => ({ field, before: now[field], after: next[field] }));
        host.editor.edit({ text: patch.markdown, fields });
        await host.render.now();
        await root.MediaCraftDrafts.flush();
      },
    };
    root.MediaCraftAI.review.connect(adapter);
    root.MediaCraftAI.versions.connect(adapter);
    root.MediaCraftAI.presets.connect(adapter);

    return {
      // 审阅中的预览（{ content, title }），不在审阅时为 null
      preview: () => preview,
      // 换了一篇稿子：上一篇的审阅预览作废（这一篇有待确认的修改时，review.js 在切换后重新显示）
      reset() {
        preview = null;
      },
    };
  }

  root.MediaCraftAI.createHost = create;
})(window);
