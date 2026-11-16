# Windows 使用、构建与验证

Windows 版本复用 `index.html` 和 `src/`，通过 `windows/` 中的 Electron 壳接入本机能力。版本号仍只读取根目录 `VERSION`。这是 Windows 移植的开发文档；安装包和真实桌面集成检查以实际构建结果为准。

## 功能范围

| 功能 | Windows | macOS |
| --- | --- | --- |
| Markdown、卡片分页、主题、图片裁剪与拼图 | 共享前端 | 原有实现 |
| 本机草稿、模板、写作手册、多窗口 | Electron 本机目录；每个窗口占用自己的稿子 | 原有存储与窗口实现 |
| PNG、全部卡片 ZIP、长图、公众号富文本 | 保存对话框 / 系统剪贴板 | 原有下载与剪贴板实现 |
| PDF 转图片 | 随包 PDF.js；应用集成结果见验证记录 | 原生 PDF 渲染 |
| 含视频的动态卡片 | 完整卡片 MP4 / GIF | 原生 Live Photo `.pvt` |
| 手机传输 | 局域网扫码下载文件和复制文字 | 原有 AirDrop 与通用剪贴板 |
| AI 助手 | 本机 Codex / Claude Code，或说 ACP 的 OpenCode / Oh My Pi / Kimi Code，可选 | 原有后端 |
| AI 系统通知 | AI 等你确认或回复完成时 toast，点击回到对应窗口；「AI 设置 › 通知」可关，窗口在前台时不打扰 | 无 |
| 外部 MCP Agent | 当前用户的 Windows 命名管道和令牌认证；默认关闭 | 原有 Unix 套接字；默认关闭 |
| 检查更新 | 打开 GitHub Releases，由用户选择安装 | 原有下载、校验与更新流程 |
| 窗口外观 | 没有原生毛玻璃：顶栏、稿件栏、检查器底下那一层是不透明的 `--ui-chrome`；滚动条换成细的；页面载入前窗口的底色（`windows/main.cjs` 的 `backgroundColor`）和它同色 | 原生毛玻璃，滚动条照系统 |

Windows 的 MP4 使用完整的 1440 × 1920 卡片画面、30 fps、H.264、`yuv420p`，需要声音时编码 AAC，并启用 faststart。GIF 为完整卡片的 864 × 1152、15 fps，不带声音。视频按照原来的起点、时长、倍速、显示方向、取景、居中铺满和圆角叠加在卡片中。

「导出 MP4 / GIF」导出含视频的页：只有一页时是单个媒体文件，多页时按原页码打包 ZIP；没有视频的页不会混入这个动作。普通的单页下载和全部卡片 ZIP 则保留所有页：静态页是 PNG，动态页是 MP4 加 PNG 封面。Windows 不生成 Apple Live Photo，不使用 AirDrop；macOS 的 `.pvt` 与发送行为保留。

## 启动与数据目录

运行已构建的解压目录版本不要求安装 Node.js。`win-unpacked` 目录中的所有文件需要一起保留，不能只拷贝 `Vibepost.exe`。

默认数据目录为 `%APPDATA%\Vibepost`。要把草稿、Chromium 存储、AI 工作副本与临时导出留在指定磁盘，启动时指定绝对目录：

```powershell
.\Vibepost.exe --data-dir 'E:\VibepostData'
```

相同的数据目录应持续使用；换目录后看到的是另一套本机草稿。关闭、重新载入窗口前会先保存；AI 的事件与取消请求带有窗口身份，旧页面的请求会被拒绝。

## 从源码构建

需要 Windows x64、PowerShell、Node.js 24、npm 和 [uv](https://docs.astral.sh/uv/)（Python 脚本用它跑，它自己备好 Python）。Electron、PDF.js 和打包工具的版本固定在 `windows/package-lock.json`。构建会联网下载已固定版本、核对哈希的 Electron / FFmpeg / 字体；首次准备时间取决于网络。

以下命令从仓库根目录运行。先设置缓存和临时目录，再安装依赖，可以让准备过程留在仓库所在的磁盘：

```powershell
$env:VIBEPOST_CACHE_DIR = Join-Path (Get-Location).Path '.scratch\windows-cache'
$env:MEDIACRAFT_FONT_CACHE_DIR = Join-Path $env:VIBEPOST_CACHE_DIR 'fonts'
$env:npm_config_cache = Join-Path $env:VIBEPOST_CACHE_DIR 'npm'
$env:TEMP = Join-Path $env:VIBEPOST_CACHE_DIR 'tmp'
$env:TMP = $env:TEMP
$env:ELECTRON_SKIP_BINARY_DOWNLOAD = '1'
New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null

npm ci
npm run build:codemirror
uv run scripts/fetch-fonts.py

Set-Location windows
npm ci
npm run prepare:assets
node scripts/runtime.cjs
npm start -- --data-dir (Join-Path (Get-Location).Path 'data')
```

`ELECTRON_SKIP_BINARY_DOWNLOAD=1` 跳过 npm 的另一份运行时下载；`runtime.cjs` 下载并校验项目固定的 Electron 运行时。`npm run dev -- --data-dir <绝对目录>` 额外打开开发者工具。

在 `windows/` 中运行测试和打包：

```powershell
$env:VIBEPOST_FFMPEG = Join-Path (Get-Location).Path 'resources\ffmpeg\ffmpeg.exe'
$env:VIBEPOST_FFPROBE = Join-Path (Get-Location).Path 'resources\ffmpeg\ffprobe.exe'
npm test
npm run test:app
npm run build
```

设置 FFmpeg 测试变量可确保实际编码检查执行；二进制不存在时相关测试会明确跳过。默认输出为根目录 `dist/windows/`，包含 `win-unpacked/` 与 `Vibepost-<版本>-Windows-Setup.exe`。`VIBEPOST_OUTPUT_DIR` 可改成其他绝对目录。NSIS 安装器允许选择安装位置。

Release 里的 `Vibepost-Windows-Setup.exe` 是 GitHub Actions 在 Windows 上跑完测试和冒烟后打的（步骤见 [发版](release.md)），没有代码签名。未签名的程序第一次运行会被 SmartScreen 拦下（点「更多信息」→「仍要运行」），公司管理的设备可能不让装；具体放行由设备用户决定。

## AI 的准备与模型

AI 功能可选。Codex CLI 和 Claude Code 不随 Windows 安装包打包，需要用户单独安装，并在终端完成相应登录。先检查：

```powershell
codex --version
codex login status
claude --version
```

在「AI 助手 › 设置」选择后端并检测程序。程序默认从 `PATH`、用户 `.local/bin` 和 npm 的用户级目录查找；找不到时可填写实际 `.exe` 或 JS 入口的绝对路径。标准 npm 命令包装器可被安全解析；不支持把任意 shell 命令填进路径栏。设置保存在数据目录 `AI/settings.json`。

Codex 的模型列表来自当前已登录 CLI 的 `app-server` / `model/list`。Claude 的模型选择由 CLI 和用户账户决定。列表随版本、账号权限和服务配置变化，不能将安装包版本或界面里的示例模型当作可用性承诺。每篇稿子保留独立会话、改动审阅和版本；两个后端的权限请求仍需用户在应用中处理。

本机真实 CLI 检查与假进程测试是不同证据；假进程通过不代表某个账户或模型的真实请求一定可用。应用的普通测试不应调用付费模型。

## 外部 MCP Agent

外部连接默认关闭。在「AI 助手 › 设置」打开后，「复制接入命令」提供 Claude Code 注册命令，「复制 Codex 配置」提供 TOML 片段，合并到已有 `config.toml` 后重启 Codex。应用按当前安装位置和数据目录生成配置，不要复用 macOS 的套接字路径；应用不会覆盖已有 CLI 配置。

Windows 的 stdio 辅助程序为 `windows/mcp/stdio.cjs`；打包后放在资源目录 `mcp/`。它连接当前用户受 ACL 限制的命名管道，并读取数据目录下的会话令牌。辅助进程用 `ELECTRON_RUN_AS_NODE=1` 运行，不开放手机传输的 HTTP 接口来处理 MCP 指令。关闭外部连接会断开客户端并撤销本次导出授权。

`export` 支持 Windows 的 PNG、ZIP、长图、MP4、GIF；发送工具为 `send_to_phone`。写出目录需要本机绝对路径，导出授权只在相应工具调用期间有效。完整工具说明见 [MCP 文档](mcp.md)。

## 手机预览与卡片出图

Windows 的「手机预览」包含笔记轮播、发现页和主页网格。卡片通过独立的 Chromium 截图宿主页出图，保留与舞台相同的字体、布局、图片裁剪和圆角；截图为真实 2 倍像素，不随屏幕缩放比例拉伸。Mac 继续使用原来的 WKWebView 出图路径。

每个编辑窗口使用独立的截图上下文与图片缓存；关窗、重新载入时释放。请求按序处理，并等待字体和图片完成加载。手机缩略图、主题缩略图及 PNG 导出共用这条出图链路。

在 `windows/` 运行 `npm run test:phone-preview`，使用真实 Electron 页面检查卡片内正方形与横图的像素比例、三个手机视图、翻页、主题、图片高度、窗口大小和预览开关。`VIBEPOST_TEST_DPR=1.25` 或 `2` 可检查 Windows 屏幕缩放；`VIBEPOST_TEST_EXE` 可检查免安装程序，`VIBEPOST_TEST_DATA` 指定独立测试目录。报告和截图写入该目录，不修改正常用户草稿。

## 手机接收

1. 电脑和手机连接同一个可信 Wi-Fi 或局域网，点击「发送到手机」。
2. Windows 防火墙首次提示时，允许应用使用当前可信的专用网络。
3. 用手机自带的浏览器扫二维码（微信等 App 里扫出来的页面多半不让下载，页面会提示换到浏览器打开）。图片长按存进相册，或逐个下载、下载 ZIP；标题、正文和话题可分别复制。
4. 保持电脑应用及传输窗口打开；关闭传输窗口立即停止服务，链接最多十分钟后到期。

服务使用随机的 256 位令牌，只允许读取本次明确导出的文件，支持视频预览的字节范围请求，不接受上传或写入。传输使用明文 HTTP；链接和文件不适合在公共、不可信网络中分享。接收者持有链接即可读取本次文件。

HTTP 页面上系统剪贴板可能不可用；页面会尝试浏览器复制，失败时选中文字，供长按复制。下载交给手机浏览器处理：ZIP 通常位于「文件」或「下载」，需要用户在手机上另行分享或保存到相册。应用不会宣称已经自动存入相册。扫码失败时查看传输窗口的其他网络地址、关闭手机 VPN，并检查防火墙与网络隔离；`127.0.0.1` 地址只能用于电脑本机验证。

接收页的几处是照手机浏览器的脾气写的（`windows/lib/phone.cjs`，`windows/tests/media-phone.test.cjs` 钉住）：视频地址带 `#t=0.001`，iPhone 的 Safari 才显示第一帧；内容安全策略的 `style-src` 是 `'unsafe-inline'`（Safari 的视频控件靠自己插的行内样式表排版，只认 nonce 时播放键会错位），脚本仍然只认 nonce，页面里没有不转义的内容；长图（高超过宽的 2.2 倍，按 PNG 文件头量）只预览开头一截；到期时间按手机的时区写成几点几分。2026-11-16 用 Playwright 的 WebKit（iPhone 15 / SE、iPad 的视口）与 Chromium（Pixel 7、Galaxy S9+、320 像素宽）检查过版式、复制与下载，浅色深色各一遍；iPhone 与 Android 实机接收尚未验证。

## 固定依赖与许可证

| Windows 组件 | 版本 | 随包许可证 |
| --- | --- | --- |
| Electron | 44.7.0 | Electron / Chromium 等第三方许可，由运行时分发包保留 |
| PDF.js (`pdfjs-dist`) | 6.4.299 | Apache-2.0 |
| Node 端 JSZip | 3.10.2 | MIT / GPLv3 双许可；项目按 MIT 使用 |
| QRCode | 1.5.4 | MIT |
| FFmpeg essentials（含 x264） | 9.0.2 | 下载构建所附 GNU GPL v3 文本 |

FFmpeg 固定下载为 [gyan.dev 的 9.0.2 essentials ZIP](https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip)，SHA-256：

```text
60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba
```

准备脚本复制 FFmpeg 的 `LICENSE`、`README.txt` 与记录上游 URL / 版本 / 哈希的 `source.json`；PDF.js 的许可证也随资源复制。项目自身的 CC BY-NC-SA 4.0 不替代第三方许可证。字体仍保留 SIL OFL 许可证。

## 验证记录与持续集成

2026-10-08：服务与回归测试包含 45 项，覆盖模拟 AI、真实 Windows named pipe、受限 IPC、多窗口归属、媒体编码和并发持久化。桌面冒烟测试另验证共享前端、PNG／ZIP、文件保存及取消、MP4／GIF、PDF、扫码传输及停止、稿件持久化，以及真实 stdio MCP 创建／改稿／导出／关闭流程。

媒体部分包含实际 FFmpeg 的尺寸、编码、音轨、旋转取景与圆角像素断言，以及 macOS `.pvt` / AirDrop 分支回归。真实 Claude Code 2.1.291 和 Codex 0.147.0 均已完成首次对话与续聊；Codex 使用账号模型列表中的 `gpt-5.6-sol`。本机配置的 `gpt-6.1-sol` 被账号拒绝，未修改用户的全局配置。生图使用模拟服务验证，未发起真实 Images API 请求。Android 实机接收尚未验证。

[Windows CI](../.github/workflows/windows.yml) 配置了依赖和资源准备、实际媒体测试、桌面烟雾测试；手动触发时可选择打包并上传产物。仓库此前没有工作流，因此同一配置另加 macOS 原生测试任务，用于检查共享前端修改。当前 Windows 机器未执行 macOS 原生测试，工作流文件的创建也不等于云端任务已成功。
