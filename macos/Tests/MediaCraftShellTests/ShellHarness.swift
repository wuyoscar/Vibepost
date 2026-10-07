import AppKit
import WebKit
import Testing
@testable import MediaCraftShell

/// 在 WKWebView 里加载仓库中的真实页面，收集页面报错。唯一的测试 seam。
@MainActor
final class ShellHarness: NSObject {
    nonisolated static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // MediaCraftShellTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // macos
        .deletingLastPathComponent() // repo

    /// 清空了、没人在用的持久化数据存储。WebKit 的网络进程每接一个新的持久化数据存储都要拿一批沙盒扩展，
    /// 删掉存储也不还；同一个进程里开到约 185 个之后就拿不到了（errno 12），新存储的 IndexedDB 打不开，
    /// 页面报「Unable to open database file on disk」。所以不每个 harness 新建一个，而是清空了循环用：
    /// 串行跑时整个测试进程只用一个；同时开着几个 harness 时各借各的。
    private static var idleDataStores: [WKWebsiteDataStore] = []

    let shell: ShellWebView
    var webView: WKWebView { shell.webView }
    /// 另外开的窗口（`openWindow`，或页面经原生桥要开的：「在新窗口打开」「新建窗口」），按开的先后；共用同一份 ShellCore 与存储
    private(set) var windows: [HarnessWindow] = []
    /// 页面里点开、交给默认浏览器的外链（`ShellCore.openExternal`）
    private(set) var openedExternally: [URL] = []
    /// 要在 Finder 中显示的（`ShellCore.revealFile`）与要用默认的 App 打开的（`ShellCore.openFile`）写作手册
    private(set) var revealedFiles: [URL] = []
    private(set) var openedFiles: [URL] = []
    /// 模拟系统切换浅色 / 深色外观（页面的界面皮肤跟着 prefers-color-scheme 走）
    func setAppearance(dark: Bool) {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
    private let window: NSWindow
    private let dataStore: WKWebsiteDataStore
    private(set) var pageErrors: [String] = []
    let sender = FakeIPhoneSender()
    let clipboard = FakeClipboard()
    let haptics = FakeHaptics()
    let downloadsDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mediacraft-harness-\(UUID().uuidString)")
    /// AI 会话的工作副本与设置（代替 ~/Library/Application Support/MediaCraft/ai）
    let aiRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("mediacraft-ai-\(UUID().uuidString)")

    /// 不测新手引导的 suite 传 false：第一次 `load()` 之前经 `prepareStorage` 把引导记为看过（测试自己调了
    /// `prepareStorage` 时顺带记下），不必开头去点「跳过」。
    private var onboardingPending: Bool

    /// - glass: 与 MediaCraft.app 一样开原生毛玻璃（网页透明、报告可拖区域与深浅外观）。
    /// - terminalPath: 「终端」PATH 里除 /usr/bin、/bin 之外的目录（放假的 claude 的地方）；默认没有，找不到 claude。
    /// - onboarding: false 时新环境不弹新手引导（见 `onboardingPending`）。
    /// - loginShell: 代替默认假登录 shell 的脚本（测查找 claude 时登录 shell 出问题）；shellTimeout 是读它的总超时。
    /// - pageScripts: 每次载入页面时先于页面脚本执行的脚本（测试用来模拟浏览器 API 出错）。
    /// - mcp: 外部 Agent（MCP）的套接字与设置放在哪；默认不监听。
    /// - terminalVariables: 「终端」环境里另外的变量（生图的密钥）。这台 Mac 上真的 OPENAI_API_KEY / GEMINI_API_KEY 一律去掉，
    ///   也不读真的 ~/.env（换成 aiRoot 里的 test.env，测试可以往里写）。
    /// - imageAPI: 生图接口的地址（假接口 `FakeImageAPI`）；默认是连不上的本机端口，测试不会调到真的生图接口。
    init(
        webRoot: URL = ShellHarness.repoRoot, glass: Bool = false, terminalPath: [URL] = [], onboarding: Bool = true,
        loginShell: String? = nil, shellTimeout: Duration = .seconds(15), pageScripts: [String] = [], mcp: MCPConfiguration? = nil,
        terminalVariables: [String: String] = [:], imageAPI: URL = URL(string: "http://127.0.0.1:9")!
    ) {
        let store = Self.idleDataStores.popLast() ?? WKWebsiteDataStore(forIdentifier: UUID())
        dataStore = store
        onboardingPending = !onboarding
        let recorder = MessageRecorder()
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        let shellURL = Self.writeLoginShell(
            in: aiRoot,
            script: loginShell ?? Self.loginShellScript(path: terminalPath.map(\.path) + ["/usr/bin", "/bin"], variables: terminalVariables)
        )
        // App 自己的环境里只留系统目录、没有生图的密钥：登录 shell 出问题、退回它时也找不到这台 Mac 上真的 claude 与密钥
        var appEnvironment = ProcessInfo.processInfo.environment
        appEnvironment["PATH"] = "/usr/bin:/bin"
        for key in Self.imageKeys { appEnvironment[key] = nil }
        let ai = AIConfiguration(
            root: aiRoot, loginShell: shellURL, cancelGrace: .milliseconds(500), exitGrace: .seconds(2), shellTimeout: shellTimeout,
            appEnvironment: appEnvironment, imageAPI: ImageAPI(openAI: imageAPI),
            keyFile: aiRoot.appendingPathComponent("test.env"),
            // 写作手册（代替 ~/Library/Application Support/MediaCraft/写作手册）：第一次用时照 src/writing-manuals/ 建好
            writingManuals: aiRoot.appendingPathComponent("写作手册", isDirectory: true)
        )
        shell = ShellWebView(
            webRoot: webRoot, dataStore: store, downloadsDirectory: downloadsDirectory,
            iPhoneSender: sender, clipboard: clipboard, haptics: haptics, ai: ai, mcp: mcp, glass: glass,
            configure: { config in
                config.userContentController.addUserScript(WKUserScript(
                    source: Self.errorForwardingScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                ))
                config.userContentController.add(recorder, name: "harnessErrors")
                for source in [Self.uiHelperScript] + pageScripts {
                    config.userContentController.addUserScript(WKUserScript(
                        source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true
                    ))
                }
            },
            // 开着的窗口记在这里（重开 App 时恢复，见 ShellCore.savedWindows）
            session: aiRoot.appendingPathComponent("windows.json")
        )
        window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1440, height: 960),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        super.init()
        recorder.onMessage = { [weak self] in self?.pageErrors.append($0) }
        // 页面要开新窗口时像 App 一样开一个（不上屏），测试从 `windows` 里拿；要关掉一个（它要开的那篇不在了）时关掉它
        shell.core.openWindow = { [weak self] request in
            guard let self else { return nil }
            let window = HarnessWindow(core: self.shell.core)
            self.windows.append(window)
            window.start(request)
            return window.shell
        }
        // 点开的外链只记下来，不真的打开浏览器
        shell.core.openExternal = { [weak self] url in self?.openedExternally.append(url) }
        // 写作手册的「在 Finder 中显示」「打开」也只记下来
        shell.core.revealFile = { [weak self] url in self?.revealedFiles.append(url) }
        shell.core.openFile = { [weak self] url in self?.openedFiles.append(url) }
        shell.core.closeWindow = { [weak self] page in
            guard let window = self?.windows.first(where: { $0.shell === page }) else { return }
            Task { await window.close() }
        }
        // 界面皮肤跟随系统外观（ADR 0007）：测试固定在浅色，不随跑测试这台 Mac 的设置变；要深色的测试自己切
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = webView
        window.orderBack(nil)
    }

    /// 载入 App 页面，等它报告启动完成：稿件存储就绪、打开了第一篇并画完（App API 的方法在那之前都先等着，
    /// 新环境的新手引导这时已经弹出）。测试自己的网页根目录里没有 App API，载入完就算。
    func load() async throws {
        if onboardingPending { try await prepareStorage("") }
        // 重新载入前先放掉页面上的视频：程序发起的载入不给页面反应的机会，载到一半的视频会被打断报错（用户不会重新载入 App）
        if webView.url != nil {
            _ = try? await evaluate("document.querySelectorAll('video').forEach((video) => { video.removeAttribute('src'); video.load(); });")
        }
        try await shell.loadEntry()
        _ = try await evaluate(Self.startedScript)
    }

    /// 等页面启动完成：打开了第一篇并画完（App API 的方法在那之前都先等着）
    static let startedScript = """
        if (!window.mediacraft) return;
        let timer;
        try {
          await Promise.race([
            window.mediacraft.drafts.current(),
            new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("页面 30 秒内没有启动完成")), 30000); }),
          ]);
        } finally {
          clearTimeout(timer);
        }
    """

    /// 另开一个窗口（同一份 ShellCore、同一份存储，像「新建窗口」），等它的页面启动完成
    @discardableResult
    func openWindow(_ request: WindowRequest = WindowRequest()) async throws -> HarnessWindow {
        let window = HarnessWindow(core: shell.core)
        windows.append(window)
        window.start(request)
        try await window.ready()
        return window
    }

    /// 等页面要开的第 count 个另外的窗口开好（页面经原生桥要开的）
    func window(_ count: Int, timeout: Duration = .seconds(20)) async throws -> HarnessWindow {
        let deadline = ContinuousClock.now + timeout
        while windows.count < count {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await windows[count - 1].ready()
        return windows[count - 1]
    }

    /// 打开 App 之前，先在同一 origin 的空白页里准备本机存储（比如更新前旧版留下的稿子），再 `load()`。
    func prepareStorage(_ script: String, arguments: [String: Any] = [:]) async throws {
        let blank = URL(string: "\(ShellWebView.scheme)://\(ShellWebView.host)/macos/Tests/Fixtures/blank.html")!
        // 换掉页面、不留历史（见 ShellWebView.replacePage）：还在写库的旧页面不会被挂进往返缓存占着库
        if webView.url == nil {
            webView.load(URLRequest(url: blank))
        } else {
            webView.evaluateJavaScript("location.replace('\(blank.absoluteString)')", completionHandler: nil)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while (try? await evaluate(
            "return location.href === href && document.readyState === 'complete'", arguments: ["href": blank.absoluteString]
        ) as? Bool) != true {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(50))
        }
        let onboarding = onboardingPending ? "localStorage.setItem('mediacraft.onboarding.v1', 'done');\n" : ""
        _ = try await evaluate(onboarding + script, arguments: arguments)
        onboardingPending = false
    }

    func evaluate(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }

    /// 轮询页面里的一个布尔表达式，直到为真或超时。
    func waitForPage(_ condition: String, timeout: Duration = .seconds(20)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try await evaluate("return Boolean(\(condition))") as? Bool) == true { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// 给人看的截图：环境变量 `MEDIACRAFT_SCREENSHOTS` 是一个目录时，把 selector 那一块（默认整页）存成 `<name>.png`；没设时什么都不做。
    func screenshot(_ name: String, of selector: String? = nil) async throws {
        guard let directory = ProcessInfo.processInfo.environment["MEDIACRAFT_SCREENSHOTS"], !directory.isEmpty else { return }
        let configuration = WKSnapshotConfiguration()
        if let selector,
           let rect = try await evaluate(
               "const r = document.querySelector(selector).getBoundingClientRect(); return [r.x, r.y, r.width, r.height];",
               arguments: ["selector": selector]
           ) as? [Double], rect.count == 4 {
            configuration.rect = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        }
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    func tearDown() async {
        for window in windows { await window.close() }
        shell.shutdown()
        window.orderOut(nil)
        if await showBlankPage() {
            await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            Self.idleDataStores.append(dataStore)
        }
        try? FileManager.default.removeItem(at: downloadsDirectory)
        try? FileManager.default.removeItem(at: aiRoot)
    }

    /// 换成空白页让页面停下，存储清空之后它就不会再往里写。等的是 WKWebView 自己的加载状态，不在换页途中调页面脚本：
    /// 那时旧页面可能已经被挂起，callAsyncJavaScript 永远等不到回复。10 秒内没换好返回 false，这个存储就不再给别人用。
    private func showBlankPage() async -> Bool {
        let blank = URL(string: "about:blank")!
        await Self.replace(webView, with: blank)
        let deadline = ContinuousClock.now + .seconds(10)
        while webView.isLoading || webView.url != blank {
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: .milliseconds(20))) != nil else { return false }
        }
        return true
    }

    /// 换成这个地址、不留历史（见 ShellWebView.replacePage）；不等页面脚本的回复（换页途中它可能永远不回）
    static func replace(_ webView: WKWebView, with url: URL) async {
        guard webView.url != nil else {
            webView.load(URLRequest(url: url))
            return
        }
        webView.evaluateJavaScript("location.replace('\(url.absoluteString)')", completionHandler: nil)
    }

    private static let imageKeys = ["OPENAI_API_KEY", "GEMINI_API_KEY"]

    /// 假的登录 shell：PATH 只有给定的目录，去掉真的生图密钥、加上给定的变量，其余照常执行 `-c` 后面的命令（壳在这个 PATH 里找 claude）。
    private static func loginShellScript(path: [String], variables: [String: String]) -> String {
        let exports = variables.map { "export \($0.key)='\($0.value)'\n" }.joined()
        return "#!/bin/sh\nexport PATH='\(path.joined(separator: ":"))'\nunset \(imageKeys.joined(separator: " "))\n\(exports)"
            + "for last; do :; done\nexec /bin/sh -c \"$last\"\n"
    }

    private static func writeLoginShell(in directory: URL, script: String) -> URL {
        let url = directory.appendingPathComponent("login-shell")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// 测试脚本里像用户一样找界面：按可访问名称（aria-labelledby / aria-label / 文字 / title）找看得见的控件。
    /// 测试只通过 `window.mediacraft`、这里的 `ui` 与原生桥说话，不碰 `src/app.js` 的内部名字。
    private static let uiHelperScript = """
    window.ui = (() => {
      const text = (element) => (element?.textContent || "").replace(/\\s+/g, " ").trim();
      const name = (element) => {
        const labelledBy = element.getAttribute("aria-labelledby");
        if (labelledBy) return labelledBy.split(/\\s+/).map((id) => text(document.getElementById(id))).join(" ").trim();
        const label = element.getAttribute("aria-label");
        if (label) return label.trim();
        if (element.labels?.length) return text(element.labels[0]);
        return text(element) || (element.getAttribute("title") || "").trim();
      };
      const visible = (element) => element.getClientRects().length > 0 && getComputedStyle(element).visibility !== "hidden";
      const controls = 'button, summary, a[href], input, textarea, select, [role="button"], [role="option"], [role="slider"]';
      const root = (within) => {
        if (!within) return document;
        if (within instanceof Element) return within;
        return [...document.querySelectorAll("[aria-label]")].find((element) => element.getAttribute("aria-label") === within) ?? null;
      };
      // 先找名字完全一样的，没有再找以它开头的。
      const all = (accessibleName, { within } = {}) => {
        const candidates = [...(root(within)?.querySelectorAll(controls) ?? [])].filter(visible);
        const exact = candidates.filter((element) => name(element) === accessibleName);
        return exact.length ? exact : candidates.filter((element) => name(element).startsWith(accessibleName));
      };
      return {
        name,
        all,
        find: (accessibleName, options) => all(accessibleName, options)[0] ?? null,
        click(accessibleName, options) {
          const element = all(accessibleName, options)[0];
          if (!element) throw new Error(`界面上找不到「${accessibleName}」`);
          element.click();
          return element;
        },
        // 展开一个折叠的控件（稿件列表、菜单）：已经展开就不再点
        expand(accessibleName, options) {
          const element = all(accessibleName, options)[0];
          if (!element) throw new Error(`界面上找不到「${accessibleName}」`);
          const open = element.tagName === "SUMMARY" ? element.parentElement.open : element.getAttribute("aria-expanded") === "true";
          if (!open) element.click();
          return element;
        },
        // 看得见的对话框：alert() 是确认 / 提示框，dialogs() 是全部
        dialogs: () => [...document.querySelectorAll('[role="dialog"], [role="alertdialog"]')].filter(visible),
        alert: () => [...document.querySelectorAll('[role="alertdialog"]')].find(visible) ?? null,
      };
    })();
    """

    private static let errorForwardingScript = """
    (() => {
      const post = (kind, detail) => window.webkit.messageHandlers.harnessErrors.postMessage(`${kind}: ${detail}`);
      const originalError = console.error.bind(console);
      console.error = (...args) => { post("console.error", args.map(String).join(" ")); originalError(...args); };
      // 「ResizeObserver loop completed with undelivered notifications」不是页面脚本出错：观察回调里尺寸又变了，
      // 剩下的通知按规范挪到下一帧送，出不出现要看这一帧机器忙不忙
      const benign = /^ResizeObserver loop completed with undelivered notifications/;
      window.addEventListener("error", (event) => benign.test(event.message || "") || post("error", event.message || `${event.target?.tagName}#${event.target?.id || ""}.${event.target?.className || ""} in ${event.target?.parentElement?.id || ""}.${event.target?.parentElement?.className || ""} ${event.target?.src || event.target?.href || ""}`), true);
      window.addEventListener("unhandledrejection", (event) => post("unhandledrejection", String(event.reason)));
      // 内容安全策略（index.html）挡下的每一次：哪条规则、挡了什么
      document.addEventListener("securitypolicyviolation", (event) => post("csp", `${event.effectiveDirective} ${event.blockedURI || "(inline)"} ${event.sourceFile || ""}:${event.lineNumber || 0}`), true);
    })();
    """
}

private final class MessageRecorder: NSObject, WKScriptMessageHandler {
    var onMessage: ((String) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage?(String(describing: message.body))
    }
}

/// harness 另外开的一个窗口：同一份 ShellCore（AI 进程、存储……），自己的网页与原生桥
@MainActor
final class HarnessWindow {
    let shell: ShellWebView
    var webView: WKWebView { shell.webView }
    private let window: NSWindow
    private var loading: Task<Void, Error>?
    /// 关掉了（测试关的，或壳关的）
    private(set) var closed = false
    /// 等页面启动完成的：窗口关掉时也放行（页面换成空白页后，还在等的 callAsyncJavaScript 可能永远不回）
    private var closeWaiters: [() -> Void] = []

    init(core: ShellCore) {
        shell = ShellWebView(core: core)
        window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1440, height: 960),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = shell.webView
        window.orderBack(nil)
    }

    /// 开始载入页面（request 说打开哪篇），`ready()` 等它启动完成
    func start(_ request: WindowRequest) {
        loading = Task { [shell] in
            try await shell.loadEntry(request)
            _ = try await shell.webView.callAsyncJavaScript(ShellHarness.startedScript, arguments: [:], contentWorld: .page)
        }
    }

    func ready() async throws {
        guard let loading, !closed else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let finish = { (result: Result<Void, Error>) in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            closeWaiters.append { finish(.success(())) }
            Task { finish(await loading.result) }
        }
    }

    /// 重新载入这个窗口的页面（像按了 ⌘R：还是它开着的那篇），等它启动完成
    func reload() async throws {
        loading = Task { [shell] in
            try await shell.reload()
            _ = try await shell.webView.callAsyncJavaScript(ShellHarness.startedScript, arguments: [:], contentWorld: .page)
        }
        try await ready()
    }

    func evaluate(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }

    /// 关掉这个窗口（像用户点了关闭）：结束它发起的 AI 进程，页面换成空白页停下
    func close() async {
        guard !closed else { return }
        closed = true
        closeWaiters.forEach { $0() }
        closeWaiters = []
        shell.close()
        window.orderOut(nil)
        let blank = URL(string: "about:blank")!
        await ShellHarness.replace(webView, with: blank)
        let deadline = ContinuousClock.now + .seconds(10)
        while webView.isLoading || webView.url != blank {
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: .milliseconds(20))) != nil else { return }
        }
    }
}
