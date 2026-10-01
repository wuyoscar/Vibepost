// 外部 Agent（MCP）在界面上：顶栏里连着时的提示、AI 助手设置里的开关与「复制接入命令」、AI 助手里「外部 Agent 的操作」
// （每行同会话里的动作行，可以逐个撤销，src/ai/panel.js 的 actionLine）。只经 App API（mediacraft.mcp）与 src/mcp/server.js 工作。
(function (root) {
  "use strict";

  const mc = root.mediacraft;
  const server = root.MediaCraftMCP;
  const $ = (selector) => document.querySelector(selector);

  const indicator = $("#mcpIndicator");
  const indicatorText = $("#mcpIndicatorText");
  const settings = $("#mcpSettings");
  const enabledInput = $("#mcpEnabledInput");
  const settingsState = $("#mcpSettingsState");
  const command = $("#mcpCommand");
  const copyButton = $("#mcpCopyBtn");
  const logBox = $("#mcpLogBox");
  const logDot = $("#mcpLogDot");
  const logCount = $("#mcpLogCount");
  const logList = $("#mcpLog");
  const logEmpty = $("#mcpLogEmpty");
  const aiButton = $("#aiButton");
  const appStatus = $("#statusText");

  const time = (at) => new Date(at).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });

  function report(task) {
    task().catch((error) => {
      appStatus.textContent = error.message || String(error);
      render();
    });
  }

  function render() {
    const status = server.status();
    const log = server.log();
    const connected = status.available && status.clients > 0;
    indicator.hidden = !connected;
    indicatorText.textContent = status.clients > 1 ? `外部 Agent × ${status.clients}` : "外部 Agent";
    indicator.setAttribute("aria-label", `外部 Agent 已连接（${status.clients} 个），看它做了什么`);
    indicator.title = "有外部 Agent（MCP）连着 Vibepost：点开看它做了什么";

    settings.hidden = !status.available;
    enabledInput.checked = status.enabled;
    settingsState.textContent = !status.enabled ? "已关闭：外部 Agent 连不上" : connected ? `${status.clients} 个已连接` : "没有连接";
    command.textContent = status.command ?? "";

    logBox.hidden = !connected && !log.length;
    logDot.dataset.state = connected ? "busy" : "idle";
    logCount.textContent = log.length ? String(log.length) : "";
    logEmpty.hidden = log.length > 0;
    // 新的在上面
    logList.replaceChildren(...[...log].reverse().map((entry) => {
      const node = root.MediaCraftAI.actionLine(entry, () => mc.mcp.undo(entry.id));
      node.title = time(entry.at);
      return node;
    }));
  }

  enabledInput.addEventListener("change", () => report(() => mc.mcp.setEnabled(enabledInput.checked)));
  copyButton.addEventListener("click", () => report(async () => {
    const { command: line } = await mc.mcp.status();
    if (!line) throw new Error("没有接入命令");
    await root.MediaCraftNative.copyText(line);
    appStatus.textContent = "已复制接入命令，在终端里运行一次即可";
  }));
  // 顶栏的提示：切到 AI 助手，展开外部 Agent 的操作
  indicator.addEventListener("click", () => {
    if (aiButton.getAttribute("aria-pressed") !== "true") aiButton.click();
    logBox.open = true;
    logBox.scrollIntoView({ block: "nearest" });
  });

  server.on(render);
  render();
})(window);
