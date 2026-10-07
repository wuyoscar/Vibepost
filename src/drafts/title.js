// 标题与小红书字数：标题框改了就自动保存（不影响卡片画面，不重排）；图文卡片模式下实时计数，超出 20 字标红。
// 标题按小红书的显示宽度折算（中文、全角符号、emoji 算 1 个字，英文、数字、半角符号算半个，见 src/publish/check.js）。
// 正文（图片下面的那段）的 1000 字计数在正文栏里（src/drafts/caption.js）。
(function (root) {
  "use strict";

  const drafts = root.MediaCraftDrafts;
  const mc = root.mediacraft;
  const publish = root.MediaCraftPublish;
  const TITLE_LIMIT = publish.LIMITS.title;
  const titleInput = document.querySelector("#titleInput");
  const titleCount = document.querySelector("#titleCount");

  function showTitleCount() {
    const count = publish.titleLength(titleInput.value);
    const over = count > TITLE_LIMIT;
    titleCount.textContent = `${count}/${TITLE_LIMIT}`;
    titleCount.classList.toggle("is-over", over);
    titleInput.setAttribute("aria-invalid", String(over));
  }

  // 改了就交给稿件模块过一会儿存（顶栏的保存按钮跟着显示状态）
  titleInput.addEventListener("input", () => {
    showTitleCount();
    drafts.saveSoon();
  });
  // 20 字是小红书的限制，只在图文卡片模式下显示；长文（公众号）不显示，也不占地方
  mc.on("rendered", ({ mode }) => {
    titleCount.hidden = mode === "article";
    showTitleCount();
  });
})(window);
