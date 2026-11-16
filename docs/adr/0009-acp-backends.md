# 0009：说 ACP 的 Agent 也能当 AI 后端

- 状态：已采纳（2026-11-16）

## 背景

AI 助手只接 Claude Code 和 Codex（[ADR 0008](0008-ai-backend-claude-or-codex.md)），能用的模型也就是这两家的。Oscar 要接的模型越多越好：国产模型、自己手上的 OpenAI 兼容接口、OpenRouter。一个一个接模型接口不是 App 该做的事，App 也没有自己的 Agent 循环（读写文件、跑命令、问权限）。

手上已经有几个接着很多家模型的命令行 Agent：OpenCode、Oh My Pi（omp）、Kimi Code。它们都说同一种协议 ACP（Agent Client Protocol，stdio 上的 JSON-RPC）：`<程序> acp` 起一个服务，`initialize` → `session/new` 或 `session/resume` → `session/prompt`，流式的回复与工具调用是 `session/update` 通知，要授权的操作是 `session/request_permission` 请求，能选的模型在会话的 `configOptions` 里。2026-11-16 用 opencode 1.18.34、omp 18.12.1 实测过一轮改文件、权限请求、换模型、新进程续会话；kimi 0.41.0 只测到握手与「没登录」。

## 决定

- **一个通用的 ACP 后端，几个 Agent 共用。** 页面一个适配器（`src/ai/backends/acp.js`），壳一个 `ACPBackend`（`ACPBackend.swift`，Windows 在 `windows/lib/ai.cjs` 的 ACP 分支），登记了 OpenCode、Oh My Pi、Kimi Code 三个，各自只差程序名和另加的环境变量。再加一个说 ACP 的 Agent 是登记一行，不用再写协议。
- **照 ADR 0008 的三层与一轮一个进程。** 壳只写开头的 `initialize`（说明这边不提供读写文件和终端，它用自己的工具），收到这一轮 `session/prompt` 的回答就关上 stdin。续会话用 `session/resume`（没有时用 `session/load`，重放的历史不看）。
- **模型由 Agent 自己报。** 开会话时的 `configOptions` 里 category 是 `model` 的选单就是能选的模型，`thought_level` 的是推理强度；这篇选了的在发这一轮之前用 `session/set_config_option` 换好，没选过就跟随 Agent 自己的设置。App 不存任何接口地址和密钥：要接新的模型（包括自己的 OpenAI 兼容接口），在那个 Agent 自己的配置里加。
- **不挂 App 的工具。** ACP 让客户端给会话挂 MCP 服务，但 App 的工具是页面里的（Claude Code 走控制通道、Codex 走动态工具，都不另起进程），没有现成的 MCP 服务可挂；外部 Agent 用的 `mediacraft-mcp` 是另一条要用户开开关的路，权限模型不一样，不混进来。所以这类后端只改工作副本里的 `draft.md` / `title.txt` / `caption.txt`，说明书里写明换主题、摆图片、看排版、生图做不了。
- **说明书随新会话的第一句给。** ACP 没有系统提示词这一项；工作副本里的 `AGENTS.md`（两份内置技能的全文）这几个 Agent 自己会读。
- **权限**：壳定的只有会话的工作目录（工作副本）和「不挂 MCP 服务」。问不问由 Agent 自己的规则定：Oh My Pi 的 ACP 模式改文件不问、运行命令先问；OpenCode 默认什么都不问，所以壳起它时带上 `OPENCODE_PERMISSION`（改文件允许，运行命令、联网、目录外的读写先问）。权限请求在 App 的确认框里答，回的是它给的选项里的一个。「本次会话都允许」对它也只答「允许这一次」，规则由页面记着、一模一样的操作再来时直接放行：它自己的「总是允许」范围各家不一样，往往比这一条命令宽，它每轮是新进程也记不到下一轮。

## 后果

- 这类后端没有 Codex 那样的沙箱：拦得住什么取决于那个 Agent 自己问不问。Kimi Code 没登录、没测过它问权限的情况，登记了但要用真的走一轮再说它可靠。
- 没有 App 的工具，「一键排版」里要看排版效果、换主题的部分它做不了；这是和 Claude Code / Codex 最大的差别，选单上不写，说明书里告诉了模型。
- 问模型要开一个会话（`session/new`），Agent 那边会留下一个空会话（开在 `ai/.acp-models/` 里，一次 App 运行每个后端最多问一次）。
- 我们对协议的假设写在假的 Agent（`macos/Tests/Fixtures/ai/fake-acp`）与 `AIACPTests` 里；这些 Agent 升级后要用真的走一轮。
- 以后要给它们挂 App 的工具，得先把 `src/ai/tools.js` 做成一个能被外面的进程连上的 MCP 服务，是另一个决定。
