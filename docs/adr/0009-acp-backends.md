# 0009：说 ACP 的 Agent 也能当 AI 后端

- 状态：已采纳（2026-11-16；2026-11-17 加上「在 App 里填接口」和「App 的工具经 MCP 挂给它」）

## 背景

AI 助手只接 Claude Code 和 Codex（[ADR 0008](0008-ai-backend-claude-or-codex.md)），能用的模型也就是这两家的。Oscar 要接的模型越多越好：国产模型、自己手上的 OpenAI 兼容接口、OpenRouter。一个一个接模型接口不是 App 该做的事，App 也没有自己的 Agent 循环（读写文件、跑命令、问权限）。

手上已经有几个接着很多家模型的命令行 Agent：OpenCode、Oh My Pi（omp）、Kimi Code。它们都说同一种协议 ACP（Agent Client Protocol，stdio 上的 JSON-RPC）：`<程序> acp` 起一个服务，`initialize` → `session/new` 或 `session/resume` → `session/prompt`，流式的回复与工具调用是 `session/update` 通知，要授权的操作是 `session/request_permission` 请求，能选的模型在会话的 `configOptions` 里。2026-11-16 用 opencode 1.18.34、omp 18.12.1 实测过一轮改文件、权限请求、换模型、新进程续会话；kimi 0.41.0 只测到握手与「没登录」。

## 决定

- **一个通用的 ACP 后端，几个 Agent 共用。** 页面一个适配器（`src/ai/backends/acp.js`），壳一个 `ACPBackend`（`ACPBackend.swift`，Windows 在 `windows/lib/ai.cjs` 的 ACP 分支），登记了 OpenCode、Oh My Pi、Kimi Code 三个，各自只差程序名和另加的环境变量。再加一个说 ACP 的 Agent 是登记一行，不用再写协议。
- **照 ADR 0008 的三层与一轮一个进程。** 壳只写开头的 `initialize`（说明这边不提供读写文件和终端，它用自己的工具），收到这一轮 `session/prompt` 的回答就关上 stdin。续会话用 `session/resume`（没有时用 `session/load`，重放的历史不看）。
- **模型由 Agent 自己报。** 开会话时的 `configOptions` 里 category 是 `model` 的选单就是能选的模型，`thought_level` 的是推理强度；这篇选了的在发这一轮之前用 `session/set_config_option` 换好，没选过就跟随 Agent 自己的设置。App 自己不调任何模型接口。
- **接口可以在 App 里填，经 OpenCode 使用。** 只让用户去终端里登录、改 Agent 的配置文件，不懂技术的人接不上。所以 AI 设置里能填：一家服务商的密钥（DeepSeek、Kimi、智谱、通义千问、MiniMax、豆包和它们的包月套餐，接口地址与模型由 OpenCode 的模型目录管），或一个自定义的 OpenAI 兼容接口（地址、模型名、密钥）。一个带工具的 Agent 就够了：这些接口都交给 OpenCode，壳起它时用环境变量 `OPENCODE_CONFIG_CONTENT` 带一段内联配置（它会和用户自己的配置合并），不改用户的 `opencode.json` 与凭据；Oh My Pi、Kimi Code 仍然只用它们自己的配置。
- **密钥存在壳里，只进不出。** `ai/providers.json`，只有本人可读写（和这些 Agent 自己存凭据的办法一样；没用钥匙串：App 没有固定的签名身份时每次更新都要重新授权）。页面存的时候给，之后只知道填了没有；换了接口地址的那一项要重新填密钥，免得一把密钥被改了地址的配置带去别处。密钥只进 OpenCode 这个进程的环境变量，配置里写的是 `{env:…}`；它的出错信息给页面之前打码。
- **App 的工具经 MCP 挂给它。** 第一版没挂，这类后端只能改文件，换主题、摆图片、看排版都做不了，等于白接。ACP 开会话时能带一组 MCP 服务（`mcpServers`），所以壳每一轮开一个只给这一轮用的 MCP 服务：Mac 上是临时目录里一个只有本人连得上的 Unix 域套接字，让 Agent 用系统自带的 `/usr/bin/nc -U` 当 stdio 的 MCP 服务（`AIToolServer.swift`）；Windows 上是一条限制到本人的命名管道，Agent 启动中继小程序 `windows/mcp/turn-relay.cjs`，连上后先交这一轮的口令。壳不解读 MCP 消息，原样推给页面，由页面里那一套工具（`src/ai/tools.js`，Claude Code、Codex 用的同一套）回答，所以动作照样列在会话里、能撤销，该问用户的工具自己问。外部 Agent 用的 `mediacraft-mcp` 是另一条要用户开开关的路，没有借它：那条路不属于某一轮，权限模型不一样。2026-11-17 用真的 OpenCode（DeepSeek 的模型，经在 App 里填的接口）和真的 Oh My Pi 在测试夹具的真实页面里各走过一轮换主题、看分页。
- **说明书随新会话的第一句给。** ACP 没有系统提示词这一项；工作副本里的 `AGENTS.md`（两份内置技能的全文）这几个 Agent 自己会读。
- **权限**：壳定的是会话的工作目录（工作副本）和挂哪个 MCP 服务（只有 App 的工具，页面给的不算）。问不问由 Agent 自己的规则定：Oh My Pi 的 ACP 模式改文件不问、运行命令先问；OpenCode 默认什么都不问，所以壳起它时带上 `OPENCODE_PERMISSION`（改文件允许，运行命令、联网、目录外的读写先问）。权限请求在 App 的确认框里答，回的是它给的选项里的一个。「本次会话都允许」对它也只答「允许这一次」，规则由页面记着、一模一样的操作再来时直接放行：它自己的「总是允许」范围各家不一样，往往比这一条命令宽，它每轮是新进程也记不到下一轮。

## 后果

- 这类后端没有 Codex 那样的沙箱：拦得住什么取决于那个 Agent 自己问不问。Kimi Code 没登录、没测过它问权限的情况，登记了但要用真的走一轮再说它可靠。
- 在 App 里填的密钥是明文存在本机文件里的，拿得到这台电脑上这个用户的文件就拿得到它；被提示词带偏的模型也可能让 Agent 运行命令去读环境变量（运行命令要先问用户）。
- 预设的服务商 id 照 OpenCode 的模型目录写（2026-11-17 对着 1.18.34 核对过）：它改了 id，那一项就列不出模型，要跟着改 `src/ai/providers.js`。目录里没有的 id 它会略过，不报错。
- App 的工具能不能用好，看模型会不会调工具；各家 Agent 给这组工具起的名字不一样（OpenCode 是 `mediacraft_<工具>`，Oh My Pi 是 `mcp__mediacraft_<工具>`），页面按名字认出它们、不重复记一行，认不出的会多记一行「使用工具」。Kimi Code 没登录，没测过。
- 这一轮的工具服务开不起来时（临时目录写不了）不挂，它照样能改文件，但说明书里仍然写着有工具。
- 问模型要开一个会话（`session/new`），Agent 那边会留下一个空会话（开在 `ai/.acp-models/` 里，一次 App 运行每个后端最多问一次）。
- 我们对协议的假设写在假的 Agent（`macos/Tests/Fixtures/ai/fake-acp`）与 `AIACPTests` 里；这些 Agent 升级后要用真的走一轮。
