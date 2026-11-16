# 参与 Vibepost

欢迎提 issue 和 PR。这份文件讲三件事：怎么跑起来、改动要守的几条约定、PR 里写什么。

## 跑起来

构建与测试的命令在 README 的[从源码构建](README.md#从源码构建)，Windows 的在 [docs/windows.md](docs/windows.md)。最短的路：

```sh
uv run scripts/fetch-fonts.py         # 第一次要下载打包字体
macos/build-app.sh debug              # 开发用的 App：直接读仓库里的网页，改完 ⌘R 生效
macos/run-tests.sh --filter Guides 120
```

只改界面也可以 `npm start` 后用浏览器看；浏览器里没有壳，出图走的是另一条只为开发准备的路，像素以 App 为准。

## 代码在哪

- 网页：`index.html` + `src/`，原生 JS，没有构建步骤。Mac 的壳在 `macos/`（Swift + WKWebView），Windows 的壳在 `windows/`（Electron），两只壳用同一份网页。
- 各模块是做什么的、彼此怎么接，见 [CLAUDE.md](CLAUDE.md)（给 AI 助手看的项目说明，人读也一样）；接口见 [docs/app-api.md](docs/app-api.md)，为什么这么定见 [docs/adr/](docs/adr/)。

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
