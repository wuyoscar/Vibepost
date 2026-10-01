// 一个窗口一篇稿子（App 里）：同一篇只在一个窗口里开——正在看的，和 AI 还在跑的。
// 要开的那篇在别的窗口里时，壳把那个窗口调到前面、换到那篇（claim）；这个窗口占着哪些稿子随时告诉壳（occupy），
// 壳记着，重开 App 时照着恢复窗口；壳要这个窗口换到某一篇时照办（mediacraft:native-window 的 show）。
// 浏览器里只有一个窗口，都能开、什么都不报。
(function (root) {
  "use strict";

  const native = root.MediaCraftNative?.windows ?? null;
  const drafts = root.MediaCraftDrafts;
  // 这个窗口里 AI 还在跑的稿子（src/ai/session.js 的 turn 事件）
  const running = new Set();
  let reported = null;
  // 这个页面的 id 与每次报告的序号：壳丢掉比它收到过的旧的（几个请求到壳的先后不一定），也丢掉换掉了的页面迟到的报告
  const page = crypto.randomUUID();
  let sequence = 0;

  // 这个窗口能不能打开这篇（src/drafts/drafts.js 的 host.claim）。focus：那篇在别的窗口里时把那个窗口调到前面、换到那篇
  async function claim(id, { focus = true } = {}) {
    if (!native) return true;
    const { elsewhere } = await native.claim({ draftId: id, focus });
    return !elsewhere;
  }

  // 告诉壳这个窗口占着哪些稿子：current 是正开着的（恢复窗口时照它开，可以是说明书），drafts 是别的窗口不能再开的
  // （正开着的自己的稿子，与 AI 还在跑的）。一样的不再报
  function report() {
    const current = drafts.currentId();
    if (!native || !current) return;
    const held = [...new Set([drafts.isBuiltIn(current) ? null : current, ...running].filter(Boolean))];
    const key = JSON.stringify([current, held]);
    if (key === reported) return;
    reported = key;
    sequence += 1;
    native.occupy({ current, drafts: held, page, sequence }).catch(() => {
      reported = null;
    });
  }

  // 再报一次（打开没成功时：壳替这个窗口占着的那篇要放回去）
  function resync() {
    reported = null;
    report();
  }

  // 开始跟着这个窗口的稿子与 AI 报给壳，接壳让换稿子的请求（app.js 在稿件存储就绪后调用）
  function start({ ai }) {
    if (!native) return;
    drafts.on("list", report);
    ai.on((event) => {
      if (event.type !== "turn") return;
      if (event.state === "running") running.add(event.draftId);
      else running.delete(event.draftId);
      report();
    });
    root.addEventListener("mediacraft:native-window", (event) => {
      const { type, draftId } = event.detail ?? {};
      if (type === "show" && draftId && draftId !== drafts.currentId()) void drafts.open(draftId).catch(() => undefined);
    });
    report();
  }

  // 这个窗口要开的那篇已经不在了（恢复的窗口）：告诉壳，还有别的窗口时它把这个窗口关掉
  function missing() {
    native?.missing().catch(() => undefined);
  }

  root.MediaCraftWindows = { claim, start, missing, resync };
})(window);
