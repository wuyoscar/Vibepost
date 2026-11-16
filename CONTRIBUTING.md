# 参与 Vibepost

欢迎提 issue 和 PR。这份文件讲三件事：怎么跑起来、改动要守的几条约定、PR 里写什么。

## 从源码构建

**macOS**：需要 Xcode 命令行工具（Swift 5.10 以上）和 [uv](https://docs.astral.sh/uv/)（仓库里的 Python 脚本都用 `uv run` 跑，依赖写在文件开头，不往系统的 Python 里装东西）。版本号只写在 `VERSION` 一个文件里。

```sh
uv run scripts/fetch-fonts.py         # 下载打包字体到 fonts/（按固定版本校验，不进 git）
macos/build-app.sh                    # 构建 build.noindex/Vibepost.app
macos/build-app.sh --install          # 构建并拷进 /Applications
macos/build-app.sh debug              # 开发用：App 直接读仓库里的网页，改完 ⌘R 生效
scripts/make-dmg.sh                   # 打安装用的 DMG 到 dist/（签名与公证的参数见脚本开头）
```

只想看界面，也可以 `npm start` 后用浏览器打开 <http://127.0.0.1:5173>。浏览器里没有壳：发送到 iPhone、实况合成和 AI 用不了，出图走的是另一条只为开发准备的路，像素以 App 为准。

**Windows**：壳在 `windows/`（Electron），复用同一份 `index.html` 和 `src/`。需要 Node.js 24、uv 与 PowerShell。安装包没有代码签名，iPhone 与 Android 实机接收尚未验证。准备、测试、打包命令与功能差异见 [docs/windows.md](docs/windows.md)。

## 测试

测试在真实的 WKWebView 里加载页面，隔空投送、Codex、Claude Code 与生图接口都换成假的，不会调到真的服务：

```sh
macos/run-tests.sh --filter Guides 120            # 只跑名字匹配的一组，120 秒超时（平时这样跑）
caffeinate -dimu macos/run-tests.sh 3600          # 全部测试，约 36 分钟；机器睡眠会让它慢几十倍，所以挡住睡眠
```

## 架构

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
- 各模块是做什么的、彼此怎么接，见 [CLAUDE.md](CLAUDE.md)（给 AI 助手看的项目说明，人读也一样）；为什么这么定见 [docs/adr/](docs/adr/)。

## 约定

1. **测试在一个地方**：在真实的 WKWebView 里加载真实的页面，从界面或 App API 进去，断言用户看得到的结果（收到的文件、剪贴板、界面上的字）。隔空投送、Codex、Claude Code、生图接口都是假的，测试不连网。新功能和修掉的 bug 都带一条这样的测试。
2. **改共享的网页要想到两只壳**：`src/` 的改动在 Mac 和 Windows 上都会生效。快捷键用 `MediaCraftPlatform.mod(event)`，界面上的快捷键照 Mac 的写法写（⌘B），`src/platform.js` 会在别的系统上换成 Ctrl+B。窗口缩到最小（Mac 1100 × 720、Windows 900 × 650）也要排得下。
3. **这些名字不改**：bundle id `com.wuyoscar.mediacraft`、`mediacraft://app`、`Application Support/MediaCraft`、存储键名、MCP 服务名 `mediacraft`、代码里的 `MediaCraft*`。改了会让已有用户丢稿子，或让登记过的 Agent 连不上。
4. **生成的文件一起提交**：改了 `src/engine/manual.js` 运行 `node scripts/build-manual.mjs`，改了 `src/skills/写作.md` 或 `src/skills/手册/*.md` 运行 `node scripts/build-skills.mjs`，改了 `src/templates/*.md` 运行 `node scripts/build-templates.mjs`；有测试比对它们是不是最新的。
5. **兼容性**：最低 macOS 14，用到比 Safari 17.0 新的 CSS / JS 要有退路，清单在 [docs/compatibility.md](docs/compatibility.md)。
6. **不加统计、不加联网**：界面不从网络加载任何东西，稿子只在用户的电脑上。要联网的功能先开 issue 讨论。
7. 字体不进 git（`scripts/fetch-fonts.py` 按固定版本下载）；`build.noindex/`、`dist/`、`fonts/` 都不提交。

## PR 里写什么

- 改了什么、为什么，界面上的改动附截图。
- 跑了哪些测试（哪几组，或全量）；没法验证的平台照实写，例如「没有 Windows 机器，只跑了 `windows/` 的单元测试」。
- 一个 PR 做一件事。大的改动先开 issue 说想法。

## 许可证

提交的内容按仓库的许可证 [CC BY-NC-SA 4.0](LICENSE) 发布。引入第三方组件时，把它的许可证加进 README 的「第三方组件」。

安全问题请走 GitHub 的私密漏洞报告（仓库页面的 Security › Report a vulnerability），不要开公开 issue。
