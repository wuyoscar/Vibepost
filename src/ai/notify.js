// AI 的系统通知：AI 在等你确认、一轮回复说完时，弹一条系统通知（点通知回到这篇稿子的窗口）。
// 只在壳支持（window.MediaCraftNative.notify，现在是 Windows）、窗口不在前台、开关开着时发；
// macOS 没有这个能力，「AI 设置 › 通知」这一组也不出现。开关存在 localStorage（PREF_KEY），默认开。
(function (root) {
  "use strict";

  const ai = root.MediaCraftAI;
  const mc = root.mediacraft;
  const PREF_KEY = "mediacraft.ai.notify";

  const supported = () => typeof root.MediaCraftNative?.notify === "function";

  function enabled() {
    if (!supported()) return false;
    try {
      return root.localStorage.getItem(PREF_KEY) !== "off";
    } catch {
      return true;
    }
  }

  function save(on) {
    try {
      root.localStorage.setItem(PREF_KEY, on ? "on" : "off");
    } catch {
      // 存不下只是下次不记得，不影响这次
    }
  }

  // 窗口正看着时不打扰；发不出去（系统关了通知等）就当没发
  function push(title, body) {
    if (!enabled() || document.hasFocus()) return;
    root.MediaCraftNative.notify({ title, body }).catch(() => undefined);
  }

  const backendName = (draftId) =>
    ai.backends[ai.history(draftId)?.backend]?.name ?? "AI";

  ai.on((event) => {
    if (event.type === "permission") {
      // 回答完一个、后面还排着时也算：报的是现在最上面的那个请求
      const [request] = ai.history(event.draftId)?.permissions ?? [];
      if (request)
        push("Vibepost · 等你确认", `${backendName(event.draftId)} 想${request.title}`);
    } else if (event.type === "turn" && event.state === "done") {
      void mc.drafts.current().then((draft) => {
        if (draft.id !== event.draftId) return;
        const title = draft.title?.trim() || "这篇稿子";
        push("Vibepost · 回复完成", `${backendName(event.draftId)} 说完了「${title}」这一轮，回来看看吧`);
      }).catch(() => undefined);
    }
  });

  // ===== 「AI 设置 › 通知」里的开关（壳支持时才出现） =====

  const group = document.querySelector("#notifySettings");
  const toggle = document.querySelector("#notifyEnabledInput");
  if (group && toggle && supported()) {
    group.hidden = false;
    toggle.checked = enabled();
    toggle.addEventListener("change", () => save(toggle.checked));
  }
})(window);
