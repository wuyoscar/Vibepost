// 小红书正文：发布时图片下面的那段文字（纯文本，可以带 #话题、emoji、换行），和编辑器里卡片上的内容分开写。
// 标题框下面一栏：收起时一行（第一行字或占位提示），展开是随内容长高的输入框；右边是小红书的字数 x/1000（空白不计，超出标红）。
// 只在图文卡片模式下有（长文由 CSS 藏起来）。改了停一下自动保存（不影响卡片画面，不重排）；
// 稿子换了、经 App API 或撤销改了时跟着稿件模块的 change 事件更新。手机预览、发布检查经 MediaCraftCaption.focus 跳过来。
(function (root) {
  "use strict";

  const drafts = root.MediaCraftDrafts;
  const mc = root.mediacraft;
  const publish = root.MediaCraftPublish;
  const LIMIT = publish.LIMITS.caption;
  // 输入框最多长到这么高（CSS 像素），再多就在框里滚动
  const MAX_HEIGHT = 320;
  const field = document.querySelector("#captionField");
  const input = document.querySelector("#captionInput");
  const preview = document.querySelector("#captionPreview");
  const count = document.querySelector("#bodyCount");

  // 输入框跟着内容长高（收起、长文模式时量不出高度，展开时再量）
  function grow() {
    if (!field.open) return;
    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, MAX_HEIGHT)}px`;
  }

  function show() {
    const first = input.value.split("\n").find((line) => line.trim())?.trim() ?? "";
    preview.textContent = first || input.placeholder;
    preview.classList.toggle("is-placeholder", !first);
    const length = publish.captionLength(input.value);
    const over = length > LIMIT;
    count.textContent = `${length}/${LIMIT}`;
    count.classList.toggle("is-over", over);
    input.setAttribute("aria-invalid", String(over));
    grow();
  }

  // 改了就交给稿件模块过一会儿存（顶栏的保存按钮跟着显示状态）
  input.addEventListener("input", () => {
    show();
    drafts.saveSoon();
  });
  // 自己点开的（点这一行，或焦点在这一行上按回车 / 空格）：光标直接进输入框，不用再点一次。
  // 别处展开的（稿子换了、focus() 跳过来）各管各的焦点。
  // 收起时焦点还在输入框里：还给这一行，不留在看不见的框里。
  const summary = field.querySelector("summary");
  let openedByHand = false;
  summary.addEventListener("click", () => {
    openedByHand = !field.open;
  });
  field.addEventListener("toggle", () => {
    grow();
    if (field.open && openedByHand) input.focus();
    else if (!field.open && document.activeElement === input) summary.focus();
    openedByHand = false;
  });
  mc.on("change", show);

  // 展开、聚焦正文栏，给了范围就选中那几个字
  function focus(from, to = from) {
    field.open = true;
    grow();
    input.focus();
    if (Number.isInteger(from)) input.setSelectionRange(from, to);
  }

  show();
  root.MediaCraftCaption = { focus };
})(window);
