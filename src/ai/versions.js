// 版本：每轮 AI 之前把稿子存一份（正文、标题、主题、配色、字体、版式、图片），可以撤回到任一轮之前。
// 版本随稿子存在稿件模块里（src/drafts/drafts.js，每篇最多 50 个，旧的先删；版本用着的图片与实况视频不删）。
// 撤回是撤销历史里的一步：⌘Z 撤销这次撤回，更早的 ⌘Z / ⇧⌘Z 照常；撤回也不动版本列表。
// 对外是 mediacraft.ai.versions，见 docs/app-api.md。
(function (root) {
  "use strict";

  const ai = (root.MediaCraftAI ||= {});
  const drafts = root.MediaCraftDrafts;
  const mc = () => root.mediacraft;
  const LABEL_LENGTH = 40;

  // 应用给的适配（src/ai/host.js）：edit(patch) 一步可撤销地改稿子
  let host = null;

  // 这一轮开始前（src/ai/session.js）：给正在编辑的这篇存一个版本，id 就是这一轮的 id，label 是这一轮说的话
  function snapshot(draftId, turnId, label) {
    const text = Array.from(label.replace(/\s+/g, " ").trim());
    return drafts.addVersion(draftId, { id: turnId, label: text.length > LABEL_LENGTH ? `${text.slice(0, LABEL_LENGTH - 1).join("")}…` : text.join("") });
  }

  function publicVersion({ id, at, label, draft }) {
    const { images, ...fields } = structuredClone(draft);
    return { id, at, label, draft: { ...fields, imageIds: Object.keys(images || {}) } };
  }

  async function list(draftId) {
    const id = draftId ?? (await mc().drafts.current()).id;
    return drafts.versions(id).map(publicVersion).reverse();
  }

  // 撤回到这一轮之前：还没确认的 AI 修改先丢掉，再把正文、标题、主题配色字体版式与图片一次换回去（可以 ⌘Z）
  async function revert(id) {
    const draft = await mc().drafts.current();
    if (draft.readOnly) throw new Error("内置说明书没有版本");
    if (ai.running(draft.id)) throw new Error("AI 还在回复，先停止或等它说完再撤回");
    const version = drafts.versions(draft.id).find((item) => item.id === id);
    if (!version) throw new Error(`这篇稿子没有这个版本：${id}`);
    await ai.review.dismiss(draft.id);
    const saved = structuredClone(version.draft);
    // 这版之前存的版本没有「单独调过」的标记：按版本里的颜色推断一次（只有三色的都算没调过）
    const tunedColors = saved.tunedColors ?? root.MediaCraftPalettes.inferTuned(saved.colors);
    await host.edit({ ...saved, tunedColors });
    return mc().drafts.current();
  }

  ai.versions = {
    connect(adapter) {
      host = adapter;
    },
    snapshot,
    // 有版本的那几轮（会话记录里显示「撤回到这一轮之前」）
    ids: (draftId) => drafts.versions(draftId).map((version) => version.id),
    // mediacraft.ai.versions（App API）
    api: { list, revert },
  };
})(window);
