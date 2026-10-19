# MCP 服务：让外部 Agent 操作 Vibepost

终端里的 Claude Code（或别的 MCP 客户端）可以直接操作正在运行的 Vibepost：列出、新建（也能照模板）、打开稿子，写卡片内容、标题与小红书正文，插片段，换主题、配色、字体与版式，从本机路径插图，出图看每一页，导出 PNG / ZIP / 长图到指定文件夹，发送到 iPhone。和 App API（[app-api.md](app-api.md)）是同一套能力与校验：工具在页面里只经 `window.mediacraft` 执行，改动马上出现在 App 里。

目标是这样的工作方式：Agent 收集信息、写稿，用 Vibepost 自动排版、看图检查；人在 App 里看一眼、改几个字，点发送。仓库里的 Claude Code 技能 [`skills/vibepost/SKILL.md`](../skills/vibepost/SKILL.md) 写了这套流程，装进 Claude Code：`ln -s "$PWD/skills/vibepost" ~/.claude/skills/vibepost`（在仓库根目录运行）。

## 接入

先在 App 里打开 AI 助手 › 设置（齿轮）›「允许外部 Agent 连接」（默认是关的，见下面的「安全」）。

MCP 服务是 App 里的一个小程序 `Vibepost.app/Contents/MacOS/mediacraft-mcp`（Swift，stdio，不依赖 Node）。在终端里登记一次：

```sh
claude mcp add mediacraft -- "/Applications/Vibepost.app/Contents/MacOS/mediacraft-mcp"
```

这行也可以在 App 里复制：AI 助手 › 设置（齿轮）› 外部 Agent（MCP）›「复制接入命令」（复制的是这台 Mac 上 App 实际的位置）。`claude mcp add` 默认只在当前项目里登记（local）；想在所有项目里都能用，加 `-s user`。登记之后新开的 Claude Code 会话里就有 `mcp__mediacraft__*` 这些工具，`/mcp` 里能看到它连没连上。

别的 MCP 客户端（Claude Desktop、Cursor……）按 stdio 服务配置，命令就是上面那个路径、没有参数，例如：

```json
{
  "mcpServers": {
    "mediacraft": { "command": "/Applications/Vibepost.app/Contents/MacOS/mediacraft-mcp" }
  }
}
```

开发时用 Debug 构建（`macos/build-app.sh debug`）的话，路径换成 `build.noindex/Vibepost.app/Contents/MacOS/mediacraft-mcp`。环境变量 `MEDIACRAFT_MCP_SOCKET` 可以换套接字的位置（测试用）。

### Windows 接入

Windows 版同样先在 AI 助手 › 设置打开「允许外部 Agent 连接」，默认关闭。点击「复制接入命令」得到按实际安装位置生成的 PowerShell 命令：它登记 bundled Electron 可执行文件与 `resources/mcp/stdio.cjs`，并为这个 MCP 进程设置 `ELECTRON_RUN_AS_NODE=1`。服务不要求另装 Node。开发环境的命令另带 `--app-arg` 指向 `windows/`，打包后的命令直接使用 `Vibepost.exe`。

Codex 点击同一区域的「复制 Codex 配置」，将 TOML 片段合并到已有的 `config.toml`，再重启 Codex。其他 stdio 客户端可通过 App API `await mediacraft.mcp.status()` 获取 `claudeConfig` JSON 或 `codexConfig` TOML。两者都包括 `--data-dir`，以便连接同一份稿件数据。App 只复制内容，不写入或覆盖 Claude/Codex 的全局配置。配置结构示例（路径换成 App 实际返回的值）：

```json
{
  "mcpServers": {
    "mediacraft": {
      "command": "E:\\Apps\\Vibepost\\Vibepost.exe",
      "args": ["E:\\Apps\\Vibepost\\resources\\mcp\\stdio.cjs", "--data-dir", "E:\\VibepostData", "--app", "E:\\Apps\\Vibepost\\Vibepost.exe"],
      "env": { "ELECTRON_RUN_AS_NODE": "1" }
    }
  }
}
```

Windows 的链路为 `客户端 → stdio helper → 本机 Windows 命名管道 → Electron 主进程 → 原有页面 MCP → window.mediacraft`。协议版本、错误码、取消通知与逐请求 `resultType: "complete"` 规则和上文一致。握手只尝试读取正在运行的 App 的手册，不启动 App；工具清单或工具调用连接不上时可启动 App，启动时移除继承的 `ELECTRON_RUN_AS_NODE` 并传入 `--data-dir`。已经发送的调用在断线或重启后不会重放：客户端会看到「可能没有完成」，下一次调用再重连，进程的会话编号保持不变。

数据目录中的 `mcp/endpoint.json` 保存本机管道位置，`mcp/token` 为每次 App 启动生成的随机令牌；`mcp/` 与令牌使用仅当前 Windows 用户的 DACL，管道另用仅当前用户的 DACL 并明确拒绝 NETWORK 身份（远程 SMB 连接）。认证成功后才返回 `{ "ready": true }`。关闭连接开关会断开已认证客户端并使进行中的导出令牌失效。MCP 不监听 TCP 端口；手机下载是独立的临时局域网服务。第二个使用相同数据目录的 App 不抢先前实例的 endpoint。

Windows 图片导入支持 PNG、JPEG、WebP、GIF、BMP，HEIC 先转换成 PNG；沿用一次 20 张、每张 20 MB、总计 60 MB、每张 6400 万像素的上限，并先检查尺寸再解码。图片与导出目录需为已经存在的本机磁盘绝对路径，`~` 可用，UNC 网络路径不接受。导出只接受当前调用的临时令牌，不接受目录分隔符、Windows 设备名或已有同名文件（显式 `overwrite: true` 才覆盖），覆盖通过临时文件替换实现。

Windows 按原生能力提供 `send_to_phone`，替代不支持的 `send_to_iphone`；其他工具顺序保持不变。`export.format` 另支持 `mp4`、`gif`：给 `page` 时导出该动效页，省略时导出全部动效页（仅一页直接保存，多页打包 ZIP，静态页不加入）；`zip` 的动效页为 MP4。不会生成 Apple `.pvt` / Live Photo。`send_to_phone` 在 App 显示有过期时间的二维码，手机同一局域网打开下载页后自行下载文件、复制小红书正文，保存进相册需由用户在手机上完成。

## 怎么连

```
Claude Code ──stdio（JSON-RPC）── mediacraft-mcp ──Unix 域套接字── Vibepost.app（ExternalAgents.swift）── 页面（src/mcp/）── window.mediacraft
```

- `mediacraft-mcp` 由 Agent 启动，自己回答握手（`initialize` / `server/discover`）与 `ping`；`tools/list`、`tools/call` 经 `~/Library/Application Support/MediaCraft/mcp.sock` 交给正在运行的 App，一次一个，按收到的顺序。
- **握手说明**（`instructions`）：一段通用说明（App 是什么、一般流程），App 开着、打开了「允许外部 Agent 连接」时后面再接上**操作手册全文**（向 App 要 `manual/get`，页面从 `src/engine/manual.js` 写出，和 [docs/manual.md](manual.md) 一样）。连不上时只有通用说明，提示用 `get_manual` 读手册——不为了握手把 App 打开，最多等 5 秒。
- **App 没开**时它先打开 App（`open -b com.wuyoscar.mediacraft`），最多等 20 秒套接字出现；打不开、等不到都在工具结果里说明原因。App 中途退出或重新打开过，下一次调用自动重连。一次调用最多等 10 分钟（导出很多实况也够），过了就断开、说明可能没做完。
- 每个 `mediacraft-mcp` 进程（一次 Agent 会话）有自己的会话编号，每个请求都带上：App 按它记这次会话在改哪篇稿子，重连、页面重新载入都还记得。
- 同时开着两个 Vibepost（比如 Debug 构建与装好的）时，后开的不抢先开的套接字（它不接外部 Agent，设置里也不显示开关），退出时也不删别人的。
- 工具清单也由 App 给：Claude Code 启动会话时就要清单，所以登记了 `mediacraft` 的会话一开始就会把 Vibepost 打开（只登记在需要它的项目里就不会打扰别处）。
- 协议版本两代都认：握手式的旧版本（`initialize`，`2025-11-25`、`2025-06-18`、`2025-03-26`、`2024-11-05`）与现行的逐请求声明版本（`_meta` 里的 `io.modelcontextprotocol/protocolVersion`，`2026-07-28`，结果带 `resultType: "complete"`）。不认的版本回 `-32022`（`UnsupportedProtocolVersionError`），不支持的方法回 `-32601`。
- 不支持批量请求（一行 JSON 数组），回 `-32600`。
- App 这一侧的协议（套接字上每行一条 JSON）：连上后 App 先回 `{ "ready": true }`，或拒绝的原因 `{ "error": "…" }` 后断开；之后 `{ id, session, method, params }` → `{ id, result }` 或 `{ id, error }`；App 要断开时先发一行 `{ "error": "…" }`。页面怎么接见 [app-api.md 的 mcp 一节](app-api.md#mcp外部-agent)。

## 安全

- 套接字文件权限 0600，只有自己能连；连进来的进程还要是同一个用户（`getpeereid`），不是就拒绝并说明原因。
- **「允许外部 Agent 连接」**（AI 助手 › 设置，默认关，存在 `mcp.json`）：本机任何同一用户的进程都能连这个套接字，所以要你自己打开；关着时新连接被拒绝，关掉时已连着的先收到原因再断开，Agent 看到的是「Vibepost 里没有打开「允许外部 Agent 连接」」。
- 有外部 Agent 连着时每个窗口的顶栏都出现「外部 Agent」；它每个改稿子的调用都是撤销历史里的一步（⌘Z），同时列进那个窗口 AI 助手里的「外部 Agent 的操作」，每行可以单独撤销（之后的改动保留）；新建、打开、导出、发送也列进去（没有撤销）。
- **一个窗口一篇稿子**：它新建的稿子开在一个新窗口里（放到前面但不抢你正在打字的窗口的键盘焦点），不替换你正在看的窗口；`open_draft` 打开的那篇已经在哪个窗口里开着就用那个窗口，没开就开一个新窗口。
- 它只看、只改自己认定的那篇（新建、打开的那篇；没有时是它第一次看、改稿子时最前面那个窗口正开着的那篇），认定由 App 记着（断开重连、页面重新载入都还在），它的请求交给开着那篇的窗口。你在那个窗口里切到别的稿子、或关掉了那个窗口后，那篇不在任何窗口里开着，它的看稿、改稿、出图、导出、发送都报错，要它先 `open_draft`，不会改错稿子。几个 Agent 同时连着时各改各的。
- 内置说明书只读，改它的调用都拒绝。
- 本机文件只由壳碰：`import_images` 的路径要是绝对路径（`~` 可用）、存在的图片文件（每张不超过 20 MB、6400 万像素，一次一共不超过 60 MB，HEIC 等转成 PNG），壳读好、校验过再交给页面；`export` 的文件夹要是已经存在、写得进去的绝对路径，页面做好的文件只能写进这一次调用登记的文件夹，同名文件已经有了时不覆盖，除非给 `overwrite: true`。
- 发送到 iPhone 只会在 App 里弹出隔空投送面板，由人选设备、确认。

## 工具

工具全名在 Claude Code 里是 `mcp__mediacraft__<名字>`。标 ★ 的和 AI 助手里 Claude 用的是同一个工具（`src/ai/tools.js`），其余在 `src/mcp/tools.js`。

| 工具 | 做什么 |
| --- | --- |
| `get_manual` | 操作手册全文（Markdown）：块样式、组件、记号的写法，什么时候用哪种，排版经验（与 docs/manual.md 一样） |
| `list_writing_manuals` | 用户的写作手册（只管写什么、什么口味）：每份一行「名字：说明」，Agent 按这篇的题材挑一份，用户点名的优先 |
| `read_writing_manual` | 一份写作手册的全文（开头 `name` / `description`，后面是正文 Markdown）；没有这份时回错误 |
| `save_writing_manual` ★ | 提议新建或整份改写一份写作手册（`name`、`description`、`content`）：App 弹确认框给用户看改动（新建的看开头，修改的看 +N / −M 行与前几行），用户同意才存，拒绝时回「用户没有同意保存这份写作手册」；名字不合规矩直接回错误。不用先认定稿子，列进「外部 Agent 的操作」 |
| `list_templates` ★ | 模板库（仓库自带的整篇示范稿与用户自己存的，`drafts.templates()`）：每套一行「名字（id）— 说明（题材 / 风格，主题）」。不用先认定稿子 |
| `list_drafts` | 全部稿子：id、标题、模式、是不是内置说明书、是不是正在编辑的那篇、最近修改时间 |
| `get_draft` | 认定的那篇（还没新建、打开过时是正在编辑的那篇）：id、只读、标题、小红书正文 `caption`、卡片内容 Markdown、模式、主题、颜色、字体、字号行距、分页个数、图片，以及可选的主题、字体与取值范围 |
| `create_draft` | 新建并在新窗口里打开（标题、卡片内容、小红书正文、模式、主题可一起给；卡片内容里的英文记号收下时换成中文写法）。`template` 给模板的 id 或名字时先照那套模板复制（`drafts.create({ template })`，连示例图一起），再套用其余字段；没有这个模板时回错误 |
| `open_draft` | 打开一篇（之后的工具改这篇）：开着它的窗口，或一个新窗口 |
| `update_draft` | 改标题、小红书正文和 / 或整篇卡片内容（一步可撤销；英文记号收下时换成中文写法） |
| `set_theme` ★ | 换主题（id 或中文名） |
| `set_style` ★ | 颜色、字体、页面尺寸、字号、行距、段距（blockGap）、图片最大高，只改给了的项 |
| `set_mode` ★ | 图文卡片 `cards` / 长文 `article` |
| `list_palettes` | 配色库（内置 48 组与我的配色），可只列浅色或深色 |
| `apply_palette` | 套一组配色（配色 id 或一串色值） |
| `insert_page_break` ★ / `remove_page_break` ★ | 在某一块前后插入 `[[分页]]` / 去掉第 n 个或全部 |
| `move_section` ★ | 把一块或一整节挪到别处 |
| `set_card_css` ★ | 这一篇自己的卡片样式（CSS）：整段换掉或接在后面 |
| `restyle_block` ★ | 给一块换样式：组件（小标签、提示、页尾、等宽、标签列表、步骤）、对齐、标题级别 |
| `insert_section` ★ | 插一个片段（`snippet`：登记表里的 id 或中文名，见操作手册的「片段」一节）或一段 Markdown（`markdown`，英文记号收下时换成中文写法），二选一；位置是 `before` / `after` 的原文或 `position` 的 `start` / `end`（都不给插在末尾）。规则同「插入」菜单里插片段（前后隔空行、首尾多余的 `[[分页]]` 去掉、含 `[[结尾]]` 的只能在末尾），一步可撤销。片段里没有图片，配图用 `import_images` / `insert_image` |
| `import_images` | 按本机绝对路径插图，插在某一块之前或之后（都不给插在末尾），每张一行 |
| `insert_image` ★ / `move_image` ★ / `resize_image` ★ / `crop_image` ★ | 把素材里的图插回正文 / 挪图 / 大小与对齐 / 裁剪 |
| `get_pages` ★ | 每页放了哪些块、正文区用了多少、怎么换的页，以及这一页的问题（⚠ 只有标题、太空、偏挤、溢出） |
| `render_pages` | 同上，并附每页卡片的 PNG（MCP 的 image 内容，默认 540 像素宽，一次最多 9 页） |
| `export` | 导出 `zip` / `png`（第几页）/ `long`（长文长图）到指定文件夹，返回写下的路径 |
| `send_to_iphone` | 按页序交给隔空投送（人选设备），小红书正文进剪贴板（空着时不动） |

定位一块用稿子里的一段原文（照抄、不跨行、只出现在一处）；标题指它连同下面的整节。

## 测试

`macos/Tests/MediaCraftShellTests/MCPTests.swift`：测试的客户端经管道对着 `mediacraft-mcp` 的核心（`MCPServer`，可执行文件里跑的就是它）说 JSON-RPC，核心经真的套接字连到 ShellHarness 里的 App，AirDrop 是假接收端。覆盖握手与两代协议版本、工具清单、写作手册的列出 / 读取 / 提议保存（`WritingManualsTests.swift`）、新建 → 写正文 → 换主题 → 出图 → 导出 → 发送、内置说明书只读、按路径插图、模板与片段（`list_templates`、`create_draft` 带 `template`、`insert_section` 与撤销、操作记录）、⌘Z 与逐条撤销、切走稿子后不再改（重连后仍记得）、开关与复制接入命令、用户检查、两个 Vibepost 不抢套接字、App 没开时先打开它。

Windows：`node --test windows/tests/mcp*.test.cjs` 以真实 stdio 子进程连接真实本机命名管道，验证 Swift 的全部协议版本、工具转发、令牌与管道实际 DACL、默认关闭与保存、关开关断线、导入各项上限、导出令牌与覆盖、断线不重放、取消排队调用，以及 Mac 原有 30 工具与 Windows 能力分支；另执行实际主进程的窗口路由与 IPC 处理代码，以窗口替身验证跨窗口导出令牌、页面版本、内置只读稿绑定与后台 AI 占用。Unix 环境可注入 socket 路径运行相同服务测试；测试素材与数据在仓库 `.scratch/windows-mcp-tests/` 下，结束后清理。
