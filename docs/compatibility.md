# 兼容性：最低系统与退化

**最低 macOS 14.0（Sonoma）**，Apple 芯片与 Intel 都能用（DMG 里是通用二进制）。这个版本写在两处：`macos/Package.swift` 的 `.macOS(.v14)` 和 `macos/build-app.sh` 写进 Info.plist 的 `LSMinimumSystemVersion`，两处要一起改。

## 为什么是 14

- **原生壳最低要 13.3。** 部署目标设成 14 后，编译器会逐个检查 API 的可用版本，现在编译干净。拿同一份代码对 macOS 13.0 做类型检查（`swiftc -typecheck -target arm64-apple-macos13.0`），只报 `WKWebView.isInspectable`（13.3）一处；对 12.0 检查，还会多报 `Duration` 一类的并发 API（13.0）。
- **网页用的是系统的 WebKit。** macOS 14.0 自带 Safari 17.0，界面离不开的特性这一版都已经有：`color-mix()`、`:has()`、容器查询单位、`structuredClone` 等，见下表。比 17.0 新的特性只用在动效和细节上，旧版本上都有退路。Sonoma 上的 Safari 最高能升到 26.x（[Safari 27 不再支持 Sonoma](https://support.apple.com/en-us/149039)），而 26.x 已经包含本 App 用到的所有特性。
- **不选 13。** Ventura 自带 Safari 16.0，还没有 `color-mix()`。界面上悬停、按下、边框、焦点环的颜色都由它推出来，要到 13.1 的 Safari 16.2 才有。[Safari 26 起也不再提供给 Ventura](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/)，它的 WebKit 最多停在 18.x。另外手边没有 13 的机器能验证。原生壳降到 13.3 只要加一处 `if #available`，但网页要整套在 Safari 16.x 上重新确认一遍，收益小。
- **不选更高。** 15 和 26 没有本 App 非用不可的新 API。没用 `NSGlassEffectView`（macOS 26 的 Liquid Glass），窗口的毛玻璃用的是 `NSVisualEffectView`。

### WKWebView 的 WebKit 跟着 Safari 走

第三方 App 里的 WKWebView 用的是系统的 WebKit。在老系统上装 Safari 更新，更新里的 WebKit 装进 StagedFrameworks，第三方 App 也从这里加载，所以 WKWebView 会跟着升级：

- Safari 17.0 的说明写着，新加的 JPEG XL 支持在 macOS Sonoma、Ventura、Monterey 上的 Safari 17.0 和 WKWebView 里都能用（[WebKit blog](https://webkit.org/blog/14445/)）。Ventura、Monterey 本来不带 17.0，WKWebView 能用上，只能是跟着 Safari 更新拿到的。
- WebKit 源码里有一句 “In downlevel updates, a WebKit client in the OS is loading from the StagedFrameworks/ directory”（[commit bd48a12](https://github.com/WebKit/WebKit/commit/bd48a12c4f646022b1e8f2efa91672c414da2152)）。

所以同一台 macOS 14 上，WKWebView 可能是 Safari 17.0 到 26.x 之间的任何一版：14.0 自带 17.0，14.2 是 17.2，14.4 是 17.4，14.5 是 17.5，14.6 是 17.6，用户也可能自己装过更新的 Safari。页面只做特性检测（`@supports`、`"x" in obj`），不看版本号。壳固定写的 UA `Version/26.0 Safari/…` 只给页面认浏览器分支用，跟真实的 WebKit 版本无关。

## 用到的能力

### 网页（WebKit）

| 能力 | 最低 Safari（macOS） | 用在哪 | 低于它时 | 出处 |
| --- | --- | --- | --- | --- |
| `color-mix()` | 16.2 | 界面令牌：悬停、按下、边框、焦点环、浮层（`styles.css` 开头） | 14.0 自带，不用退路 | [MDN](https://developer.mozilla.org/docs/Web/CSS/Reference/Values/color_value/color-mix) |
| 相对颜色语法 `oklch(from …)` | 16.4 | 清新主题的薄荷、奶黄色团：从强调色转色相推出来（`cards/structures.css` 的 `--fresh-mint`） | 同上 | [WebKit 16.4](https://webkit.org/blog/13966/webkit-features-in-safari-16-4/) |
| `overflow: clip` | 16.0 | `html, body`：页面本身连程序性滚动（`focus()` / `scrollIntoView()`）也不允许，顶栏不会被滚出窗口（`styles.css`） | 退成 `hidden`：界面照常，只是极端情况下页面可能被滚走 | [MDN](https://developer.mozilla.org/docs/Web/CSS/overflow#browser_compatibility) |
| 容器查询、`cqw` / `cqh` | 16.0 | 舞台上卡片的尺寸（`.stage-scroller`） | 同上 | [MDN](https://developer.mozilla.org/docs/Web/CSS/Reference/At-rules/@container) |
| `:has()`、`:focus-visible`、无前缀 `appearance`、`structuredClone`、`Array.prototype.at` / `findLast`、`Object.hasOwn` | 15.4 | 各处 | 同上 | [WebKit 15.4](https://webkit.org/blog/12445/new-webkit-features-in-safari-15-4/) |
| `crypto.randomUUID` | 15.4 | 图片、AI 会话、原生桥请求的编号 | 同上 | [MDN](https://developer.mozilla.org/docs/Web/API/Crypto/randomUUID) |
| `inert` | 15.5 | 说明书只读时关掉菜单 | 同上 | [WebKit 15.5](https://webkit.org/blog/12669/new-webkit-features-in-safari-15-5/) |
| `createImageBitmap`、`aspect-ratio` | 15.0 | 导入图片时校验、版式 | 同上 | [MDN](https://developer.mozilla.org/docs/Web/API/Window/createImageBitmap) |
| 单独的 `translate` / `scale` / `rotate`、`inset`、`Intl.Segmenter` | 14.1 | 动效；按字素数字数（`engine/text.js` 已做特性检测） | 同上 | [MDN](https://developer.mozilla.org/docs/Web/CSS/Reference/Properties/translate) |
| `ClipboardItem` | 13.1 | 长文带格式复制（只在浏览器里用，App 里走原生剪贴板） | 同上 | [MDN](https://developer.mozilla.org/docs/Web/API/ClipboardItem) |
| `linear()` 缓动 | 17.2（14.2） | 动效令牌 `--ease-spring`（弹簧，过冲 2%） | `@supports not` 把令牌换成 `cubic-bezier(0.35, 0.7, 0.1, 1.12)`，按同一条曲线拟合，峰值 1.020。不换的话，用到它的整条过渡都会作废 | [WebKit 17.2](https://webkit.org/blog/14787/webkit-features-in-safari-17-2/) |
| `transition-behavior: allow-discrete` | 17.4（14.4）；`display` 真正能过渡要 18.0（15.0） | 浮层、对话框、手机预览、导出进度的退场 | 单独写成一行 `transition-behavior`：旧 WebKit 只丢掉这一行。要是写进 `transition` 简写，整条过渡都会被丢掉。退场时直接消失，没有淡出 | [WebKit 17.4](https://webkit.org/blog/15063/webkit-features-in-safari-17-4/)、[18.0](https://webkit.org/blog/15865/webkit-features-in-safari-18-0/) |
| `@starting-style` | 17.5（14.5） | 浮层、对话框、提示条的进场 | 整条规则被忽略：直接出现，没有进场动画。状态从不等动画（`docs/design/motion.md`） | [WebKit 17.5](https://webkit.org/blog/15383/webkit-features-in-safari-17-5/) |
| 无前缀 `backdrop-filter` | 18.0（15.0） | 实况角标、胶片页码的底（`media/media.css`） | 同时写 `-webkit-backdrop-filter`（Safari 9 起就有） | [WebKit 18.0](https://webkit.org/blog/15865/webkit-features-in-safari-18-0/) |
| `scrollbar-width` | 18.2 | 舞台、胶片不显示滚动条 | `::-webkit-scrollbar { display: none }` | [WebKit 18.2](https://webkit.org/blog/16301/webkit-features-in-safari-18-2/) |
| canvas `letterSpacing` | 18.4（15.4） | 卡片装饰标签的字距（`engine/paint.js`，已做特性检测） | 标签照常画，只是不加字距 | [MDN](https://developer.mozilla.org/docs/Web/API/CanvasRenderingContext2D/letterSpacing) |
| `field-sizing: content` | 26.2 | AI 输入框跟着内容长高 | 输入框停在两行，写多了在框里滚动 | [WebKit 26.2](https://webkit.org/blog/17640/webkit-features-for-safari-26-2/) |
| 无前缀 `user-select` | **任何正式版 Safari 都不支持** | 6 处：拖编辑区宽度时、编辑器里的媒体块、检查器的图片框、AI 会话的文字 | 只有带前缀的 `-webkit-user-select` 生效。本机 macOS 26.6 的 WKWebView 实测 `CSS.supports("user-select", "none")` 为 `false`，所以这 6 处在所有版本上都不起作用。这是已有的问题，跟最低版本无关，另外处理 | [MDN](https://developer.mozilla.org/docs/Web/CSS/Reference/Properties/user-select) |

### 原生壳（macOS）

| 能力 | 最低 macOS | 用在哪 | 出处 |
| --- | --- | --- | --- |
| `WKWebView.isInspectable` | 13.3 | 允许用 Safari 的 Web 检查器调试页面（`ShellWebView.swift`） | [Apple](https://developer.apple.com/documentation/webkit/wkwebview/isinspectable) |
| `Duration`（`.seconds(…)`、`.components`） | 13.0 | 查找与启动 claude 的超时（`ClaudeCode.swift`） | 编译器可用性检查 |
| `AVAssetImageGenerator.image(at:)`（async） | 13.0 | 实况封面帧（`LivePhoto.swift`） | [Apple](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/image(at:)) |
| `AVAsset.load(_:)`、`loadTracks(withMediaType:)` | 12.0 | 实况读视频 | [Apple](https://developer.apple.com/documentation/avfoundation/avasynchronouskeyvalueloading/load(_:isolation:)) |
| `URLSession.bytes(for:)` | 12.0 | AI 找配图时下载图片（`AICandidates.swift`） | [Apple](https://developer.apple.com/documentation/foundation/urlsession/bytes(for:delegate:)) |
| `WKDownload` | 11.3 | 页面里的下载（`ShellWebView.swift`） | [Apple](https://developer.apple.com/documentation/webkit/wkdownload) |
| `NSWindow.titlebarSeparatorStyle`、`toolbarStyle` | 11.0 | 网页铺进透明标题栏（`main.swift`） | [Apple](https://developer.apple.com/documentation/appkit/nswindow/toolbarstyle-swift.property) |
| 原生毛玻璃 `NSVisualEffectView` | 12.0 以下 | 窗口后面的毛玻璃（`main.swift`） | 编译器可用性检查 |
| HEVC 编码（`AVAssetWriter`） | 12.0 以下，还要有硬件编码器 | 实况视频 | 编码器用不了时退回 H.264（`LivePhoto.swift` 已有） |
| `NSHapticFeedbackManager` | 10.11 | 拖到吸附点时触控板震一下（`Haptics.swift`） | [Apple](https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager)；没有 Force Touch 触控板就不震 |
| 隔空投送 `NSSharingService(.sendViaAirDrop)`、自定义 scheme `WKURLSchemeHandler` | 12.0 以下 | 发送到 iPhone、`mediacraft://app` | 编译器可用性检查 |

表里「编译器可用性检查」的意思是：对 12.0 做类型检查时它们没被报出来，所以最低版本不高于 12.0。部署目标高于这些版本，所以代码里不需要 `if #available`。以后要用 macOS 14 以后才有的 API，比如 `NSGlassEffectView`，必须用 `if #available(macOS 26, *)` 包起来，旧系统走现在的写法。

## 签名、公证与 entitlements

`scripts/make-dmg.sh` 不加参数时只做 ad-hoc 签名。加 `--sign` 会用 Developer ID 签名，开强化运行时（`--options runtime`），带安全时间戳。加 `--notarize` 会提交公证并把票据钉进 DMG。这三样都是[公证的前提](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。

强化运行时下，**不需要任何 entitlements**：

- 没开 App 沙盒。要启动用户自己装的 `claude`，要读写 `~/Library/Application Support/MediaCraft`，沙盒都会挡住。
- 不需要 JIT 权限：WKWebView 的 JavaScript JIT 在 WebKit 自己的 WebContent 进程里跑，这个进程由系统签名。
- 不加载第三方动态库，不需要关掉库校验。
- 强化运行时只约束 App 自己的进程。启动的 `/bin/zsh`、`claude`、`node` 各有各的签名，照常运行。
- 不发 Apple Events，不用摄像头、麦克风、定位。隔空投送走的 `NSSharingService` 不需要权限。

没有公证时，别人下载后第一次打开会被 Gatekeeper 拦下。macOS 14 可以按住 Control 点 App 选「打开」；[macOS 15 起这招不能用了](https://developer.apple.com/news/?id=saqachfa)，要到「系统设置 → 隐私与安全性」里点「仍要打开」（[Apple 支持](https://support.apple.com/guide/mac-help/mh40617/mac)）。

## 怎么验证

- **动效退化已经有测试覆盖。** harness 的窗口是看不见的，页面处在 `<html data-motion="paused">`，全部过渡和动画都关着。所以整套测试本来就在「没有进退场动画」的条件下跑，跟旧 WebKit 丢掉 `@starting-style` 和离散过渡时一样。功能不依赖动效，这点每次跑测试都会确认。
- **CSS 写法有静态检查。** `macos/Tests/MediaCraftShellTests/CompatibilityTests.swift` 读样式表源码，确认四件事：`allow-discrete` 没写进 `transition` 简写；每个 `backdrop-filter` 前面都有 `-webkit-` 版本；`linear()` 只出现在 `--ease-spring`，并且有 `@supports not` 退路；隐藏滚动条的地方都有 `::-webkit-scrollbar` 退路。
- **真机手动检查。** 每次发版前，最好在 macOS 14.0–14.3（Safari 17.0–17.3）上打开 DMG 里的 App，确认：
  1. 首次打开能放行；窗口是毛玻璃，红绿灯和网页工具栏在同一条线上。
  2. 下拉菜单、对话框、手机预览、导出进度都能正常开关（直接出现、直接消失，不闪、不卡住）。
  3. 写一段字，关掉 App 再打开，稿子还在（自定义 scheme 下的 IndexedDB）。
  4. 实况合成（没有 HEVC 硬件编码的旧 Intel Mac 上退回 H.264）、发送到 iPhone、导出 PNG / ZIP / 长图都能用。
  5. AI 输入框停在两行、多了能滚动；装了 Claude Code 的话能对话。
- **加新的 CSS / JS 特性时**，先查它从哪个 Safari 版本开始支持（WebKit blog 或 MDN）。高于 17.0 的要给退路，并把它加进上表。
