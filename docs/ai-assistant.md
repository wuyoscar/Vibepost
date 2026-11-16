# AI 助手

App 里的「AI 助手」启动这台电脑上的命令行 Agent（Claude Code、Codex，或接着别家模型的 OpenCode、Oh My Pi、Kimi Code），在这篇稿子里干活。终端里或别处的 Agent 经 MCP 连进来，见 [外部 Agent（MCP）](mcp.md)。两条路用的是同一套 App 工具，做了什么都列在 App 里，都能撤销。

- **用哪个**：每篇稿子选一个（AI 助手顶上的选单）。这篇有了对话就锁定，要换先在「更多」里点「重新开始这篇的对话」。模型与推理强度也是每篇各选。想用别家的模型见下面的[接别家的模型](#接别家的模型)；想接别的命令行 Agent 要改代码，接缝见 [App API 的「加一个后端」](app-api.md#加一个后端)。
- **怎么找到它**：App 在终端的环境里找 `claude` / `codex`（以及 `opencode` / `omp` / `kimi`）。装在别处时，在「AI 助手 › 设置（齿轮）」里填完整路径。它沿用自己在终端里的登录、技能、MCP 服务和权限规则，不用另填密钥（国产模型的密钥可以在 App 里填，见下面）。
- **它能做什么**：改这篇稿子的卡片内容、标题和小红书正文；用 App 的工具换主题、调字号行距、分页、挪段落、摆图片、给一块换样式、写这一篇的卡片 CSS、看每一页排出来的图；找配图或生图（图先进候选，你点了才插进稿子）。
- **你怎么管它**：文字改动不直接进稿子，标在编辑器里逐处接受或拒绝。每一轮之前自动存一个版本，随时撤回。运行命令、联网、改稿子以外的文件，都先在 App 里问你。
- **常见的用法**：
  - 稿子写好了：点「润色全文」，再点「一键排版」。
  - 手上有一篇现成的长文：整篇贴进对话框，说一句「排成小红书图文」。它分页、起标题、把稿子里的照片放到说到它们的地方，再写好小红书正文。
  - 还没有稿子：说一句想写什么方向。用 Claude Code 时它会联网找资料（联网之前先问你），找到出处以后写成一篇。
  - 快捷命令：出 5 个封面标题、写首图文案、去 AI 味、按要点重新分页、写小红书正文、加话题标签、收紧留白等。
- **生图**：用 Codex 时是它自带的生图。用别的后端时 App 直接调 OpenAI 的生图接口，用你环境里的 `OPENAI_API_KEY`，一轮最多 8 张。

每个后端怎么启动、权限怎么问、工具清单，见 [App API 的 ai 一节](app-api.md#aiai-会话本机-claude-code-或-codex)。

## 接别家的模型

Claude Code、Codex 用的是它们自家的模型。要用别家的（DeepSeek、Kimi、智谱 GLM、通义千问、MiniMax、豆包，或者你手上任何一个 OpenAI 兼容的接口），要两样东西：一个模型接口，和一个会读写文件的 Agent。光有接口的模型不会改稿子，所以 App 用现成的命令行 Agent 带着它，默认是 OpenCode。

**最短的办法：在 App 里填密钥**

1. 装好 OpenCode：`npm install -g opencode-ai`（不用在它那边登录）。
2. 「AI 助手 › 设置（齿轮）› 接别家的模型 › 接口 › 加一个接口」，选服务商、贴上密钥，保存。
3. AI 助手顶上的后端选 OpenCode，模型选单里就有这一家的模型。

能直接选的服务商：

| | 按量付费 | 包月套餐 |
| --- | --- | --- |
| DeepSeek | DeepSeek | |
| Kimi | Kimi（月之暗面开放平台） | Kimi 会员（Kimi For Coding） |
| 智谱 | 智谱 GLM | 智谱 GLM Coding Plan |
| 阿里云 | 通义千问（阿里云百炼） | 阿里云百炼 Coding Plan |
| MiniMax | MiniMax | MiniMax Token Plan |
| 火山引擎 | 豆包（火山方舟） | 火山方舟 Coding Plan |
| 其他 | 硅基流动、OpenRouter | |

智谱、Kimi、阿里云、MiniMax 另有国际站的选项。每家的接口地址和有哪些模型由 OpenCode 的模型目录管，会跟着它更新。

- **不在表里的接口**：服务商选「自定义接口（OpenAI 兼容）」，填名字、接口地址（像 `https://api.example.com/v1`）、模型名（服务商文档里的模型 ID，多个用逗号隔开）和密钥。公司的网关、自己架的模型服务都这样接。
- **密钥放在哪**：只存在这台电脑上（App 支持目录里一个只有你能读的文件），只在启动 OpenCode 时交给它。存了以后 App 里看不到密钥本身，只能重填或删掉。你自己的 OpenCode 配置和登录 App 不动。
- **它能做什么**：和 Claude Code、Codex 一样。改这篇稿子的文字（照样逐处给你确认），也能用 App 的工具换主题、调字号、分页、摆图片、看每页排出来的样子。App 把这组工具挂给 OpenCode（以及下面的 Oh My Pi、Kimi Code），模型只要会调工具就行。生图和用 Claude Code 时一样调 OpenAI 的接口，要你环境里有 `OPENAI_API_KEY`。
- **它问不问你**：改这篇稿子的文件不问；运行命令、联网、读写稿子以外的文件先问。

**已经在用这些 Agent 的**

选单里除了 OpenCode 还有两个，都沿用它们在终端里的登录和配置，App 里填的接口只给 OpenCode：

| 选单里的名字 | 终端里的命令 | 安装 |
| --- | --- | --- |
| OpenCode | `opencode` | `npm install -g opencode-ai` |
| Oh My Pi | `omp` | `bun install -g @oh-my-pi/pi-coding-agent` |
| Kimi Code | `kimi` | 照它官网的办法 |

在终端里登录、配好的（`opencode auth login`、`omp login`、`kimi login`，或它们配置文件里的 provider），模型选单里照样有，和 App 里填的并在一起。

Claude Code 自己也能换接口：它认 `ANTHROPIC_BASE_URL` 与 `ANTHROPIC_AUTH_TOKEN`（写在终端的环境或 `~/.claude/settings.json` 的 `env` 里），接口要说 Anthropic 的 Messages 格式；App 里的模型选「自定义…」填那边的模型 ID。各家网关对工具调用的支持不一样，接上了也可能改不了稿子，先在终端里用 `claude` 试一轮。

为什么这样接、有哪些没做到，见 [ADR 0009](adr/0009-acp-backends.md)。

## Agent 每轮都带着的两个技能

App 自带两个只读的技能，App 里的 AI 每一轮都用，外部 Agent 用 `get_writing_skill` / `get_manual` 读：

- **写作**（[src/skills/写作.md](../src/skills/写作.md)）：素材不够先问、不编，从一个具体时刻开头，按发生的顺序讲，先证据后判断，不升华，用作者自己的词，附一份 AI 腔清单。来由见[写作技能](writing-skills.md)。
- **使用 Vibepost**：就是[操作手册](manual.md)，App 认哪些样式和记号，什么时候用哪种，排版经验。

按题材挑着用的[写作手册](customize.md#写作手册)可以自己加。
