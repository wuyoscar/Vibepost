<p align="center">
  <img src="brand/app-icon-256.png" alt="Vibepost 图标" width="128" />
</p>

<h1 align="center">Vibepost</h1>

<p align="center">把 Markdown 排成小红书图文卡片、长文长图和实况照片的桌面 App。你写字，本机的 Agent 排版、配图，每处改动由你确认。</p>

<p align="center">
  <a href="https://github.com/wuyoscar/Vibepost/releases">下载</a> ·
  <a href="#安装">安装</a> ·
  <a href="#怎么用">怎么用</a> ·
  <a href="#和-agent-一起用">和 Agent 一起用</a> ·
  <a href="#自己定制">自己定制</a> ·
  <a href="#文档">文档</a> ·
  <a href="#english">English</a>
</p>

<p align="center">
  <a href="docs/screenshots/vibepost.mp4">
    <img src="docs/screenshots/vibepost-cover.png" alt="Vibepost 演示视频的封面，点开播放" width="100%" />
  </a>
</p>

<p align="center">
  <img src="docs/screenshots/demo-film.webp" alt="演示视频里的一段：在对话里点一张 Agent 生成的配图，图飞进那道菜的卡片；再拖一条线，对比排版之前和现在" width="100%" />
</p>

<p align="center">上面的动图是演示视频里的一段。<a href="docs/screenshots/vibepost.mp4">完整的视频</a>是一篇稿子从写到发出去的全过程（带声音，14 MB；GitHub 页面上不能直接播放这么大的文件，点开后选 View raw 下载）。</p>

Vibepost 在你的电脑上排版，有 Mac 和 Windows 两个版本。左边像写文档一样写 Markdown，中间实时排成一张张卡片，右边换主题、调样式。排版、润色、配图可以交给这台电脑上的 Claude Code 或 Codex，改动标在正文里，一处一处接受或拒绝。终端里的 Agent 也能经 MCP 连进来操作 App。写完点「发送到 iPhone」，整组图片按页序隔空投送到手机，图片下面那段正文同时进剪贴板，打开小红书粘贴就能发。

稿子只存在你的电脑上，没有账号，不上传。

## 安装

### macOS

1. 从 [Releases](https://github.com/wuyoscar/Vibepost/releases) 下载最新的 `Vibepost-版本号.dmg`，双击打开。
2. 把窗口里的 Vibepost 拖到「应用程序」文件夹。
3. 第一次打开时，如果这个 DMG 没有经过 Apple 公证，macOS 会拦下来：
   - macOS 14：在「应用程序」里按住 Control 点 Vibepost，选「打开」，再点「打开」。
   - macOS 15 及以上：先双击打开一次（会提示无法验证），再到「系统设置 › 隐私与安全性」，在最下面点「仍要打开」。

   放行一次就行，以后照常双击打开。

- 需要 macOS 14 Sonoma 或更新，Apple 芯片和 Intel 都能用。系统里的 WebKit 较旧时，个别动效会简化，功能不受影响，见[兼容性](docs/compatibility.md)。
- 中英文字体已经打包在 App 里，不用另外安装。
- 装好以后，「Vibepost › 检查更新…」从 GitHub Release 找新版本，下载核对后替换、重新打开；每天也自动看一次。

### Windows

Windows 版和 Mac 版用同一套界面。发到手机是局域网扫码，带视频的卡片导出 MP4 / GIF；没有隔空投送和实况照片。现在还没有签名的安装包，要从源码运行或自己打包，见 [docs/windows.md](docs/windows.md)。

### AI 助手要的东西（可选）

AI 助手用的是这台电脑上的命令行 Agent，装其中一个，并在终端里登录过一次：

| | 安装 | 登录 |
| --- | --- | --- |
| [Claude Code](https://www.anthropic.com/claude-code) | `npm install -g @anthropic-ai/claude-code` | 在终端里运行一次 `claude` |
| [Codex](https://github.com/openai/codex) | `npm install -g @openai/codex` | 在终端里运行一次 `codex login` |

都不装也不影响写、排、查、发。

## 怎么用

一篇笔记有三部分：标题、卡片内容（编辑器里的 Markdown，排在图片上的字）、小红书正文（发布时图片下面的那段，连同 #话题）。从写到发是五步。

<p align="center">
  <img src="docs/screenshots/demo-write.webp" alt="在左边的编辑器里打字，中间的卡片跟着排好：先是小标题「出发前准备」，再是三条编号列表" width="100%" />
</p>

### 1. 写

点稿件栏的 + 开一篇空白稿子，或点「从模板新建」挑一套写好的改。在左边打字，`#` 是标题，`1.` 是列表，行首输入 `/` 插图片、分页和组件。

- **实时预览的编辑器**：看到的就是排好的样子，光标所在的那行才露出 Markdown 标记，⌘/ 切到源码。格式条、选中文字时的浮动条、行首的 `/` 菜单都能用，插图片、实况、分割线、分页和代码块不用记语法。
- **「样式」菜单**：格式条最左边写着光标所在那块现在是什么（正文、小标题、小标签、提示……），点一项就换。和卡片上点选一块后的「换样式」是同一份列表。
- **中文写法**：`[[分页]]` 手动分页，`{{字色:#…|字}}`、`{{高亮:#…|字}}` 给字上色，`[[图片:甲|乙|4x3]]` 是拼图，`:::小标签`…`:::` 是组件。英文写法照样认，旧稿子打开时自动换成中文。完整规则见 [Markdown 写法](docs/markdown-syntax.md)，有哪些样式、什么时候用哪种见[操作手册](docs/manual.md)。
- **模板与片段**：十三套写好的整篇（干货清单、踩坑经验、一周要闻、论文解读、工具实测、读书笔记、旅行日记等），点一套就复制成自己的稿子。「插入」和 `/` 菜单最后一组「片段」是十段写好的示范（三步教程、对比、金句页、时间线、FAQ 等），插进去就是排好的一块。
- **图片、PDF 与实况**：拖进编辑区或预览，松手的位置就是插入的位置。可以裁剪、拼图、改宽度与对齐。视频能做成实况（选时长、倍速、取景、封面），发到 iPhone 上就是 Live Photo。
- **小红书正文单独写**：在标题下面的「正文」栏，带 1000 字计数。
- **保存看得见**：改动后自动存进本机，顶栏标题旁写着「已保存 / 保存中 / 没存上」，⌘S 马上存。退出、关窗、重新载入前都先存完。

### 2. 排

右边「样式」里点一个主题，卡片结构、配色和字体一起换。字号、行距、封面在同一个面板里调，各项见[自己定制](#自己定制)。

<p align="center">
  <img src="docs/screenshots/demo-themes.webp" alt="在主题面板里依次点杂志、撞色、纯黑、清新，同一篇稿子的卡片换成对应的结构和配色" width="100%" />
</p>

- **12 个主题**，分三组：简洁（备忘、纯白、纯黑、报刊）、柔和（清新、手帐、柔光、陶土）、有态度（杂志、书卷、撞色、电光）。主题面板里的缩略图画的是你自己这篇的第一页，并标出会排成几页。
- **长文模式**：同一篇稿子排成一整页长文，存成长图，或带格式复制进公众号编辑器。
- **表情**：格式条上的笑脸按钮，按分类挑，插到光标所在处。

### 3. 改

想让 AI 帮忙，点右边的「AI 助手」。主按钮「一键排版」看过每一页以后调分页、块的样式和间距，不改你的字。「润色全文」只修错字、读不通和指代不清的地方。也可以直接在对话框里说要做什么。改动标在正文里，逐处接受或拒绝。这一步可以不用，细节见[和 Agent 一起用](#和-agent-一起用)。

### 4. 查

- **发布检查**：页脚的「检查」按本地词库标出极限词、医疗与收益承诺、引流词和联系方式，查标题宽度、正文字数、话题数和图片数，用过 AI 时提醒勾选 AI 声明。发送前自动查一遍，不联网。规则与出处见[发布检查](docs/publish-check.md)。
- **手机预览**：顶栏的「手机预览」在 iPhone 外框里看笔记页、发现页和主页网格。

### 5. 发

点「发送到 iPhone」，在隔空投送里选自己的手机。图片按页序到相册，正文在剪贴板里，发完还能分别复制标题、正文和话题。Windows 上是「发送到手机」，手机扫码接收。也能导出 PNG、ZIP 和长图，文件名跟着标题。

### 其他

- **多窗口**：一个窗口一篇稿子，各改各存。⌘⇧N 新建窗口，在稿件列表里 ⌘ 点一篇（或右键）就在新窗口打开。
- **内置说明书**：第一次打开有三本只读的说明书（图文卡片、长文、样式与写法）和四步新手引导。

| 12 个主题 | 手机预览 | AI 的改动逐处确认 |
| --- | --- | --- |
| ![12 个主题下同一篇稿子的封面，按简洁、柔和、有态度三组排成 4×3](docs/screenshots/themes.png) | ![手机预览](docs/screenshots/phone-preview.png) | ![AI 的改动在编辑器里逐处标出](docs/screenshots/ai.png) |

## 和 Agent 一起用

Agent 有两条路进来。App 里的「AI 助手」启动这台电脑上的 Claude Code 或 Codex，在这篇稿子里干活。终端里或别处的 Agent 经 MCP 连进正在运行的 App，自己新建稿子、排版、出图。两条路用的是同一套 App 工具，做了什么都列在 App 里，都能撤销。

### App 里的 AI 助手

- **用哪个**：Claude Code 或 Codex，每篇稿子选一个（AI 助手顶上的选单）。这篇有了对话就锁定，要换先在「更多」里点「重新开始这篇的对话」。模型与推理强度也是每篇各选。目前只有这两个后端；想接别的命令行 Agent 要改代码，接缝见 [App API 的「加一个后端」](docs/app-api.md#加一个后端)。
- **怎么找到它**：App 在终端的环境里找 `claude` / `codex`。装在别处时，在「AI 助手 › 设置（齿轮）」里填完整路径。它沿用自己在终端里的登录、技能、MCP 服务和权限规则，App 不另填密钥。
- **它能做什么**：改这篇稿子的卡片内容、标题和小红书正文；用 App 的工具换主题、调字号行距、分页、挪段落、摆图片、给一块换样式、写这一篇的卡片 CSS、看每一页排出来的图；找配图或生图（图先进候选，你点了才插进稿子）。
- **你怎么管它**：文字改动不直接进稿子，标在编辑器里逐处接受或拒绝。每一轮之前自动存一个版本，随时撤回。运行命令、联网、改稿子以外的文件，都先在 App 里问你。
- **常见的用法**：
  - 稿子写好了：点「润色全文」，再点「一键排版」。
  - 手上有一篇现成的长文：整篇贴进对话框，说一句「排成小红书图文」。它分页、起标题、把稿子里的照片放到说到它们的地方，再写好小红书正文。
  - 还没有稿子：说一句想写什么方向。用 Claude Code 时它会联网找资料（联网之前先问你），找到出处以后写成一篇。
  - 快捷命令：出 5 个封面标题、写首图文案、去 AI 味、按要点重新分页、写小红书正文、加话题标签、收紧留白等。
- **生图**：用 Codex 时是它自带的生图。用 Claude Code 时 App 直接调 OpenAI 的生图接口，用你环境里的 `OPENAI_API_KEY`，一轮最多 8 张。

每个后端怎么启动、权限怎么问、工具清单，见 [App API 的 ai 一节](docs/app-api.md#aiai-会话本机-claude-code-或-codex)。

### 外部 Agent（MCP）

App 自带一个 MCP 服务。任何会说 MCP（stdio）的 Agent 都能接：Claude Code、Codex、Claude Desktop、Cursor，或你自己写的程序。

| | |
| --- | --- |
| 服务名 | `mediacraft` |
| 可执行文件 | `/Applications/Vibepost.app/Contents/MacOS/mediacraft-mcp`（stdio，没有参数，不依赖 Node） |
| 开关 | AI 助手 › 设置（齿轮）› 外部 Agent（MCP）›「允许外部 Agent 连接」，默认关 |
| 套接字 | `~/Library/Application Support/MediaCraft/mcp.sock`（MCP 服务经它连到 App，只有同一个用户连得进） |

接入分两步。先在 App 里打开上面的开关，再在 Agent 那边登记一次：

```sh
# Claude Code（加 -s user 在所有项目里都能用）
claude mcp add mediacraft -- "/Applications/Vibepost.app/Contents/MacOS/mediacraft-mcp"

# Codex
codex mcp add mediacraft -- "/Applications/Vibepost.app/Contents/MacOS/mediacraft-mcp"
```

别的客户端按 stdio 服务配置，命令就是那个路径：

```json
{
  "mcpServers": {
    "mediacraft": { "command": "/Applications/Vibepost.app/Contents/MacOS/mediacraft-mcp" }
  }
}
```

登记之后，Agent 可以列出、新建（也能照模板）、打开稿子，写卡片内容、标题与小红书正文，插片段，换主题、配色、字体与版式，从本机路径插图，出图看每一页，导出 PNG / ZIP / 长图到指定文件夹，发送到 iPhone（由你在隔空投送里选设备）。App 没开时 MCP 服务会先把它打开。它的每一步改动都能 ⌘Z 撤销，也列在 AI 助手的「外部 Agent 的操作」里，可以单独撤销。

各客户端的写法（包括 `codex exec` 和 Windows）、工具清单、一个从新建稿子到出图的例子、协议与安全，见 [docs/mcp.md](docs/mcp.md)。配套的 Claude Code 技能在 [skills/vibepost](skills/vibepost/SKILL.md)，写了调研、写稿、排版、检查、发送这一套流程。

### Agent 每轮都带着的两个技能

App 自带两个只读的技能，App 里的 AI 每一轮都用，外部 Agent 用 `get_writing_skill` / `get_manual` 读：

- **写作**（[src/skills/写作.md](src/skills/写作.md)）：素材不够先问、不编，从一个具体时刻开头，按发生的顺序讲，先证据后判断，不升华，用作者自己的词，附一份 AI 腔清单。来由见[写作技能](docs/writing-skills.md)。
- **使用 Vibepost**：就是[操作手册](docs/manual.md)，App 认哪些样式和记号，什么时候用哪种，排版经验。

按题材挑着用的[写作手册](#写作手册)可以自己加。

## 自己定制

样式都在右边检查器的「样式」里，各节能收起，滑杆旁的数值框可以直接输入。除了署名，改的都是当前这一篇。

### 主题与配色

「主题」一节点一个主题，卡片结构、配色、字体一起换，这篇调过的配色重置；新稿子沿用上次选的主题。「配色」一节是卡片的五个颜色：背景、文字、强调、辅助、衬底。可以一个个改色块，从「配色库」的 48 组里挑，或在「色轮」上按类比、互补、三角等规则配，也可以粘贴一串色值。文字颜色会自动调到够清楚。调好的配色能存进「我的配色」，别的稿子也能用。界面本身跟随系统的浅色 / 深色，不跟着卡片主题变。规则见 [App API 的配色一节](docs/app-api.md#palettes配色库与色轮)。

### 版式：尺寸、字号、行距

「版式」一节：

- **图文尺寸**：标准卡片 3:4（默认）、文档页 A4 比例、竖屏 9:16、长页 1:2。宽度固定，改的是每页的高度。
- **排版密度**：大字卡片、舒适阅读、文档排版三档，只调字号与行距，不动正文和分页。
- **字号、行距、段距、图片高**：四根滑杆。字号也可以用格式条上的 A− / A+ 或 ⇧⌘< / ⇧⌘>。段距是块与块之间的距离，块之间太空就调小。

见 [App API 的「图文尺寸与排版密度」](docs/app-api.md#图文尺寸与排版密度)。

### 字体

「字体」一节分中文、英文、代码三个选单，默认「跟随主题」。打包的字体全部是 SIL OFL，排出来的图可以商用；选单里每一项都标着能不能商用。

### 封面

「封面」一节勾上「首页做封面」：第 1 张是封面，标题取自标题框，正文从第 2 张开始。可以填副标题、选一张底图（正文里的图、实况，或另外上传一张只给封面用）。

### 署名与头像

「样式」最下面的「署名」一节：

- **头像**：点头像换一张图，右边的裁剪按钮选取其中一块。没换过时是 App 的图标。
- **名字**和**账号**：账号可以不填。

署名所有稿子共用一份，改一次，每篇的卡片都跟着变。它出现在这几处：

- 第一张卡片的页眉：头像和名字（开了封面时挪到封面上）。
- 之后每张的页脚：一行署名。
- 结尾页（正文里写 `[[结尾]]`）：最后是大头像、名字和账号。
- 「手机预览」的主页。

名字空着时卡片上只有头像，发布检查会提醒一句，不拦发送。Agent 也能读写署名（`mediacraft.profile`，见 [App API](docs/app-api.md#profile署名)）。

### 写作手册

写作手册补充某类题材的口味，AI 按这篇的题材自己挑，也可以在输入框旁的「写作手册」里点名。App 内置四份：经验分享、教程攻略、测评种草、论文与技术解读。

- 想改内置的：AI 设置 › 写作手册里点「复制一份来改」。同名的用你那份，删掉文件就回到内置的。
- 想从一篇稿子里提炼：点快捷命令「存成我的写作手册」，AI 把这篇的写法写成一份新手册，保存前给你确认。
- 想自己写：往 `~/Library/Application Support/MediaCraft/写作手册/` 里放 Markdown 文件，每份开头写 `name` 和 `description`。

你自己的手册 App 从不删。格式见[存储](docs/storage.md#写作手册写作手册)，来由见[写作技能](docs/writing-skills.md#写作手册)。

### 模板

自己的稿子在稿件列表里右键「存为模板…」，之后在「从模板新建」的画廊里和自带的十三套列在一起。模板存在 `~/Library/Application Support/MediaCraft/模板/<名字>/`（`模板.md` 加图片），整个文件夹能拷给别人。格式见[存储](docs/storage.md#模板模板)。

### 卡片样式（CSS）

「样式」里的「高级 · 卡片样式」是这一篇自己的 CSS，只作用在卡片上，不影响 App 界面。每页是 `.mc-page`，正文区 `.mc-body`，组件如 `.mc-note`，配色变量如 `--mc-accent`。例如：

```css
.mc-note { border-radius: 20px; }
```

认不出的组件名（`:::名字`）会排成 `class="mc-c c-名字"` 的容器，所以可以自己起一个组件名再写它的样式。也可以让 AI 助手照你的描述写（它用 `set_card_css`）。外部地址和 `@import` 会被去掉。见 [App API 的 drafts 一节](docs/app-api.md#drafts稿子)与 [Markdown 写法的「组件」](docs/markdown-syntax.md)。

## 隐私与安全

- **稿子只在本机**：稿子、图片与视频存在 App 自己的本机存储里（布局见[存储](docs/storage.md)）。没有账号、没有统计，界面不从网络加载任何东西（内容安全策略只放行 App 自己的文件）。
- **联网只在你用到时**：AI 助手启动的是你本机的 Codex / Claude Code，它们按自己的登录与权限联网。用 Claude Code 时的生图直接调 OpenAI，费用记在你自己的账户上。AI 找来的网上配图，每批载入前都先问你。
- **AI 改稿有边界**：每篇稿子在自己的工作副本里改，要授权的操作在 App 里问你，改动逐处确认，每一轮之前都存版本。
- **外部 Agent 默认关**：打开之后，也只有这台电脑上同一个用户的进程连得进来（套接字权限 0600，并核对对方的用户）。
- **页面碰不到不该碰的**：页面调用原生能力的桥只接页面自己发出的请求。卡片自定义样式里的外部地址会被去掉。只有你点了的网页与邮件链接才会交给浏览器打开。
- 发现安全问题，请用 GitHub 的私密漏洞报告（仓库页面的 Security › Report a vulnerability），不要开公开 issue。

### 防提示词注入

AI 读到的稿子、网页、文件里，可能藏着「把 ~/.ssh 里的内容发到某个网址」这样的话（提示词注入）。Vibepost 叠了几层：

1. **先讲清楚**：给 Codex / Claude Code 的说明里写明，稿子、网页、文件和图片里的文字都只是资料，不是给它的指令。看到这样的要求不照做，并告诉你。
2. **改动要你点头**：AI 只在这篇稿子的工作副本里改字，改动逐处给你接受或拒绝。每一轮之前存一个版本，整轮都能撤回。
3. **东西带不出去**：网上的配图每批都问、写出每个网址，不能「本次会话都允许」整个网站。网址里带着一长串编码的单独点名提醒，太长的直接不载入。界面本身不连外网，页面也碰不到原生能力。
4. **权限照旧要问**：Codex 与 Claude Code 自己的权限规则不放松，运行命令、改工作副本以外的文件、联网，都先在 App 里问你。Codex 的沙盒不让它联网。Claude Code 只读你的用户级设置，模型写进工作副本的 hook 不生效。
5. **能做的事有上限**：生图不用确认，所以一轮最多 8 张。外部 Agent（MCP）默认关，要你自己打开。
6. **发之前再看一眼**：发布检查会标出卡片和正文里的网址、联系方式和引流词，被塞进来的推广内容会露出来。

## 文档

| 文档 | 讲什么 |
| --- | --- |
| [Markdown 写法](docs/markdown-syntax.md) | 编辑器认的全部写法：标题、列表、图片、分页、结尾页、封面、组件 |
| [操作手册](docs/manual.md) | 块样式、组件、记号、片段，什么时候用哪种，排版经验。AI 读的也是这份 |
| [外部 Agent（MCP）](docs/mcp.md) | 各种 Agent 怎么接、工具清单、例子、协议与安全 |
| [App API](docs/app-api.md) | 页面对外的接口 `window.mediacraft`：稿子、出图、主题、配色、署名、导出、AI 会话、窗口 |
| [写作技能](docs/writing-skills.md) | 两个内置技能与写作手册的来由和用法 |
| [发布检查](docs/publish-check.md) | 查什么、词库出处、字体许可 |
| [存储](docs/storage.md) | 稿子、AI 工作副本、写作手册、模板存在哪，什么格式 |
| [Windows](docs/windows.md) | Windows 版的功能范围、构建、手机接收与验证记录 |
| [兼容性](docs/compatibility.md) | 最低 macOS 14 的理由，用到的 WebKit 能力与退路 |
| [发版](docs/release.md) | tag、DMG 与校验文件的约定 |
| [动效](docs/design/motion.md) | 动效令牌与新控件怎么接 |
| [设计决定](docs/adr) | 为什么这么定（编辑器、卡片引擎、实况、许可证、AI 后端……） |
| [参与](CONTRIBUTING.md) | 怎么跑起来、改动要守的约定、PR 里写什么 |

## 开发与测试

### 从源码构建

**macOS**：需要 Xcode 命令行工具（Swift 5.10 以上）和 Python 3。版本号只写在 `VERSION` 一个文件里。

```sh
python3 scripts/fetch-fonts.py        # 下载打包字体到 fonts/（按固定版本校验，不进 git）
macos/build-app.sh                    # 构建 build.noindex/Vibepost.app
macos/build-app.sh --install          # 构建并拷进 /Applications
macos/build-app.sh debug              # 开发用：App 直接读仓库里的网页，改完 ⌘R 生效
scripts/make-dmg.sh                   # 打安装用的 DMG 到 dist/（签名与公证的参数见脚本开头）
```

只想看界面，也可以 `npm start` 后用浏览器打开 <http://127.0.0.1:5173>（发送到 iPhone、实况合成和 AI 只在 App 里可用）。

**Windows**：壳在 `windows/`（Electron），复用同一份 `index.html` 和 `src/`。需要 Node.js 24、Python 3 与 PowerShell。构建还没有配置代码签名，iPhone 与 Android 实机接收尚未验证。准备、测试、打包命令与功能差异见 [docs/windows.md](docs/windows.md)。

### 测试

测试在真实的 WKWebView 里加载页面，隔空投送、Codex、Claude Code 与生图接口都换成假的，不会调到真的服务：

```sh
macos/run-tests.sh --filter Guides 120            # 只跑名字匹配的一组，120 秒超时（平时这样跑）
caffeinate -dimu macos/run-tests.sh 3600          # 全部测试，约 36 分钟；机器睡眠会让它慢几十倍，所以挡住睡眠
```

### 架构

```
index.html + src/          网页界面，原生 JavaScript，不需要构建
  editor/                  CodeMirror 6 实时预览编辑器（Markdown 是唯一的底层格式）
  engine/                  Markdown 解析、卡片结构、配色规则、操作手册
  cards/ stage/            HTML 卡片排版与分页、预览舞台
  article/                 长文排版、长图与公众号富文本
  media/                   图片、PDF、拼图、裁剪、实况编辑与预览
  drafts/                  稿子的本机存储（IndexedDB）、稿件抽屉、多窗口
  templates/ skills/       模板库；内置技能与写作手册
  output/ publish/         导出与发送、发布检查
  ai/                      AI 会话（Codex / Claude Code）、修改对比、版本、App 的工具
  mcp/                     外部 Agent（MCP）的工具、操作记录与界面
macos/                     Swift 原生壳：WKWebView 窗口、隔空投送、卡片出图、实况合成、
                           启动本机 Codex / Claude Code、外部 Agent 的连接；
                           mediacraft-mcp（外部 Agent 用的 stdio MCP 服务）
windows/                   Electron 壳，用同一份网页
skills/vibepost/           Claude Code 技能：调研、写稿、排版、检查、发送
```

- 网页跑在原生壳里，以 `mediacraft://app/index.html` 加载。壳只提供网页做不到的事，通过一个 JS ↔ Swift 桥暴露。
- 页面对外只有一个稳定接口 `window.mediacraft`（[App API](docs/app-api.md)）。测试、AI 会话和外部 Agent 都只经过它读写稿子、出图、导出和发送。
- 代码、地址与存储里的 `MediaCraft` / `mediacraft` 是早期的名字，改了会读不到已经存下的稿子，所以保留。
- 各模块的说明在 [CLAUDE.md](CLAUDE.md)，参与的约定在 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 第三方组件

随 App 打包的开源组件，各自保留原来的许可证：

| 组件 | 用途 | 许可证 |
| --- | --- | --- |
| [CodeMirror 6](https://codemirror.net/)（含 @lezer、style-mod、w3c-keyname、crelt 等） | 编辑器 | MIT |
| [JSZip](https://stuk.github.io/jszip/) 3.10.1 | 打包 ZIP | MIT（与 GPLv3 双许可，这里按 MIT 使用） |
| [html2canvas](https://html2canvas.hertzen.com/) 1.4.1 | 长文长图 | MIT |
| [思源黑体 Noto Sans SC](https://github.com/notofonts/noto-cjk)、[思源宋体 Noto Serif SC](https://github.com/notofonts/noto-cjk) | 中文字体 | SIL OFL 1.1 |
| [霞鹜文楷 LXGW WenKai](https://github.com/lxgw/LxgwWenKai) | 中文字体 | SIL OFL 1.1 |
| [得意黑 Smiley Sans](https://github.com/atelier-anchor/smiley-sans) | 中文字体 | SIL OFL 1.1 |
| [Inter](https://rsms.me/inter/)、[IBM Plex Sans / Serif / Mono](https://github.com/IBM/plex)、[Source Serif 4](https://github.com/adobe-fonts/source-serif) | 英文字体 | SIL OFL 1.1 |
| [JetBrains Mono](https://www.jetbrains.com/lp/mono/)、[Fira Code](https://github.com/tonsky/FiraCode) | 等宽字体 | SIL OFL 1.1 |

各库的许可证文本在打包文件的开头。字体经 [Fontsource](https://fontsource.org/) 与各自的发布包下载，许可证文本随字体放在 `fonts/licenses/`。Windows 版另外打包的组件（Electron、PDF.js、FFmpeg 等）见 [docs/windows.md](docs/windows.md#固定依赖与许可证)。

## 许可证

Vibepost 自己的代码、文档与素材采用 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/deed.zh-hans)（署名—非商业性使用—相同方式共享 4.0 国际），全文在 [LICENSE](LICENSE)，决定见 [ADR 0005](docs/adr/0005-license-cc-by-nc-sa.md)。这是「源码公开」，不是 OSI 定义的开源：可以自由使用、修改和分享，但不能商用；想商用请联系作者。上表的第三方组件保留各自的许可证。

---

<a id="english"></a>

## English

**Vibepost** is a desktop app (macOS, with a Windows port) that lays out Markdown as Xiaohongshu (RedNote) image cards, long-form images and Live Photos. You write on the left, the cards render in the middle, and you pick a theme on the right. A coding agent on your computer (Claude Code or Codex) can do the layout, polishing and images, and you review every change. Press **Send to iPhone** and the whole set is AirDropped in page order, with the caption on your clipboard. Drafts stay on your computer. There is no account and nothing is uploaded.

- **Write**: a live-preview Markdown editor (CodeMirror 6) with a format bar, a floating selection toolbar and a `/` command menu. A small custom syntax covers page breaks, text color, highlight and image pairs. Thirteen templates and ten snippets are built in. The caption below the images is written in its own field.
- **Lay out**: 12 themes in three groups, each switching the card structure, palette and fonts together. Images, PDFs and Live Photos (composed natively with AVFoundation) are supported. Article mode exports a long image or rich text for WeChat. All bundled fonts are SIL OFL.
- **Publish**: a phone preview, an offline pre-publish check (absolute claims, traffic diversion, title width, topic and image limits, AI disclosure), AirDrop to iPhone, and PNG / ZIP / long-image export.

**Working with agents.**

- **Built-in assistant**: runs the Claude Code or Codex already installed on your computer, chosen per draft, with its own login, skills and permission rules. It edits the draft in a working copy and uses the app's tools (themes, pagination, images, per-draft card CSS, page screenshots). Every edit is reviewed hunk by hunk and every turn is versioned. Only these two backends exist today; the seam for adding one is described in [docs/app-api.md](docs/app-api.md#加一个后端).
- **External agents over MCP**: the app bundles a stdio MCP server, `mediacraft-mcp`, so any MCP client can create, write, lay out, render, export and send drafts. It is **off by default**. Turn it on in AI Assistant › Settings › External agents, then register it once:

  ```sh
  claude mcp add mediacraft -- "/Applications/Vibepost.app/Contents/MacOS/mediacraft-mcp"
  codex mcp add mediacraft -- "/Applications/Vibepost.app/Contents/MacOS/mediacraft-mcp"
  ```

  Other clients use the same path as a stdio command with no arguments. See [docs/mcp.md](docs/mcp.md) (in Chinese) for the tool list and a worked example.

**Customizing.** Everything is in the Style inspector: theme, the five palette colors (with a palette library and a color wheel), card size (3:4, A4, 9:16, 1:2), font size and spacing, fonts, the cover page, and per-draft card CSS. The byline (avatar, name and handle) is shared by all drafts and appears in the first card's header, later cards' footers and the ending page. Writing manuals and templates are plain Markdown files in `~/Library/Application Support/MediaCraft/`.

**Privacy and security.**
- The UI loads nothing from the network; its Content Security Policy allows only the app's own files.
- The network is used only when you use a feature that needs it: your local Codex or Claude Code, OpenAI image generation with your own `OPENAI_API_KEY` (at most 8 images per turn), and remote candidate images, which ask for your approval on every batch.
- The page-to-native bridge accepts only requests the page itself makes.
- Prompt injection is handled in layers:
  - The agent is told that text in drafts, web pages and files is data, not instructions.
  - Every edit is reviewed hunk by hunk, and every turn is versioned.
  - Remote images ask for approval on every batch, with no site-wide "allow for this session"; addresses that look like they carry encoded data are flagged, and overlong ones are refused.
  - Codex and Claude Code keep their own permission prompts, and Claude Code ignores project-level settings (such as hooks) written into the working copy.
  - Image generation is capped at 8 per turn, external agents are off by default, and the pre-publish check flags links and contact details.
- Report security issues privately through GitHub's **Security › Report a vulnerability**.

**Install.** Download `Vibepost-<version>.dmg` from [Releases](https://github.com/wuyoscar/Vibepost/releases) and drag Vibepost into Applications. If the DMG isn't notarized, macOS blocks the first launch:
- macOS 14: Control-click the app and choose Open.
- macOS 15 and later: open it once, then click Open Anyway in System Settings › Privacy & Security.

Vibepost requires macOS 14 Sonoma or later and runs on Apple silicon and Intel. The Windows port (`windows/`, Electron) shares the same UI, sends to a phone over the local network with a QR code, and exports cards with video as MP4 / GIF; it has no signed installer yet, so run or package it from source ([docs/windows.md](docs/windows.md)).

**Build from source.** Run `python3 scripts/fetch-fonts.py && macos/build-app.sh`. Run one group of tests with `macos/run-tests.sh --filter Guides 120`, or all of them (about 36 minutes) with `caffeinate -dimu macos/run-tests.sh 3600`; they use fake AirDrop, AI and image services. `scripts/make-dmg.sh` packages a DMG.

Licensed under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). The source is available, but commercial use is not allowed. Third-party components keep their own licenses.
