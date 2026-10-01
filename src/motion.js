// 动效的共同部分（规范见 docs/design/motion.md）。状态从不等动画：调用方先把 hidden / aria-* / 焦点改好，这里只补视觉。
// - <html data-motion>：full 正常播放；reduced 系统开了「减少动态效果」，位移取消、只留透明度变化；
//   paused 窗口整个看不见（被挡住、最小化）——WebKit 这时停住动画时间线，动画会停在第一帧，干脆不播，回来时已是最终状态。
//   styles.css 按它收掉过渡与动画，这里的脚本动画也看它。
// - track(container, selector)：选中标记（分段控件的滑块、胶片当前页的框、主题格的底色）跟着选中项滑过去。
// - play(element, keyframes, options)：在已经更新好的元素上补一段视觉动画；reduced 时去掉位移，只剩透明度。
// - flip(elements, change)：同步执行 change，再让 elements 从原来的位置平移到新位置。
// - 界面皮肤跟随系统浅色 / 深色（<html data-ui-theme>，ADR 0007）：系统外观一变，这一小段时间里的颜色变化淡入淡出。
// - returnFocus(layer, target)：关上对话框时把焦点还回去；还不回去就当下移出对话框（它退场时还画在屏幕上）。
(function (root) {
  "use strict";

  const html = document.documentElement;
  const reducedQuery = root.matchMedia("(prefers-reduced-motion: reduce)");
  // 换皮肤时颜色过渡的时长（--motion-moderate）再留一点余量
  const RESKIN_MS = 320;
  // 分段控件里被选中的那一段
  const SEGMENT = ':scope > :is([aria-pressed="true"], [aria-selected="true"])';

  function syncMode() {
    html.dataset.motion = document.visibilityState === "hidden" ? "paused" : reducedQuery.matches ? "reduced" : "full";
  }
  syncMode();
  document.addEventListener("visibilitychange", syncMode);
  reducedQuery.addEventListener("change", syncMode);

  const mode = () => html.dataset.motion;
  const token = (name) => getComputedStyle(html).getPropertyValue(name).trim();

  // duration：fast / quick / moderate / slow（--motion-*）；easing：standard / decelerate / exit / spring（--ease-*）
  function play(element, keyframes, { duration = "moderate", easing = "standard", delay = 0 } = {}) {
    if (!element || mode() === "paused") return null;
    let frames = keyframes;
    if (mode() === "reduced") {
      frames = keyframes.map(({ transform, translate, scale, ...rest }) => rest);
      if (!frames.some((frame) => "opacity" in frame)) return null;
    }
    return element.animate(frames, {
      duration: parseFloat(token(`--motion-${duration}`)),
      easing: token(`--ease-${easing}`),
      delay,
      fill: "backwards",
    });
  }

  function flip(elements, change) {
    if (mode() !== "full") {
      change();
      return;
    }
    const before = elements.map((element) => element.getBoundingClientRect());
    change();
    elements.forEach((element, index) => {
      const after = element.getBoundingClientRect();
      const dx = before[index].left - after.left;
      const dy = before[index].top - after.top;
      if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return;
      play(element, [{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "none" }], { easing: "decelerate" });
    });
  }

  // 关上浮层（对话框）时把焦点还给打开前的控件；还不回去（原来在 body 上、已经不在页面上）就当下移出浮层：
  // 退场的那一小段浮层还画在屏幕上，键盘不能再按到里面
  function returnFocus(layer, target) {
    target?.focus?.({ preventScroll: true });
    if (layer.contains(document.activeElement)) document.activeElement.blur();
  }

  // 本文件在 <head> 里载入：页面画出来之前就换上对的皮肤，不会先闪一下浅色
  const darkQuery = root.matchMedia("(prefers-color-scheme: dark)");
  let reskinTimer = 0;
  function syncSkin() {
    const id = darkQuery.matches ? "dark" : "light";
    if (html.dataset.uiTheme === id) return;
    // 第一次上皮肤（打开 App）直接换，不从浅色淡过去
    if (html.dataset.uiTheme && mode() !== "paused") {
      html.classList.add("is-reskinning");
      clearTimeout(reskinTimer);
      reskinTimer = setTimeout(() => html.classList.remove("is-reskinning"), RESKIN_MS);
    }
    html.dataset.uiTheme = id;
  }
  syncSkin();
  darkQuery.addEventListener("change", syncSkin);

  // ===== 选中标记 =====
  // container 上写 --sel-left / top / width / height / right / bottom（相对 container 内边距盒的像素），
  // styles.css 用它们画 ::before / ::after。第一次、尺寸变了时直接到位（先去掉 is-tracked 上的过渡），选中项变了才滑过去。
  const tracked = new WeakSet();

  function track(container, selector) {
    if (tracked.has(container)) return;
    tracked.add(container);
    let last = null;

    function place(glide) {
      const item = container.querySelector(selector);
      const shown = Boolean(item) && item.offsetWidth > 0;
      container.classList.toggle("has-selection", shown);
      if (!shown) {
        last = null;
        return;
      }
      const box = { left: item.offsetLeft, top: item.offsetTop, width: item.offsetWidth, height: item.offsetHeight };
      const moved = !last || Object.keys(box).some((key) => box[key] !== last[key]);
      const jump = !glide || !last;
      last = box;
      if (!moved) return;
      if (jump) container.classList.remove("is-tracked");
      const values = {
        ...box,
        right: container.clientWidth - box.left - box.width,
        bottom: container.clientHeight - box.top - box.height,
      };
      for (const [key, value] of Object.entries(values)) container.style.setProperty(`--sel-${key}`, `${value}px`);
      if (jump) {
        void container.offsetWidth; // 先按新位置算好样式，再挂回过渡，这一下不动画
        container.classList.add("is-tracked");
      }
    }

    new MutationObserver((records) => place(!records.some((record) => record.type === "childList"))).observe(container, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["aria-pressed", "aria-selected", "aria-current"],
    });
    new ResizeObserver(() => place(false)).observe(container);
    place(false);
  }

  // 分段控件：页面里现有的一打开就接上；之后才加进来的（比如检查器里新的浮层）第一次碰到时接上
  const trackSegmented = (group) => track(group, SEGMENT);
  document.addEventListener("DOMContentLoaded", () => document.querySelectorAll(".segmented").forEach(trackSegmented));
  for (const type of ["pointerdown", "focusin"]) {
    document.addEventListener(type, (event) => {
      const group = event.target.closest?.(".segmented");
      if (group) trackSegmented(group);
    }, true);
  }

  root.MediaCraftMotion = { play, flip, track, returnFocus };
})(window);
