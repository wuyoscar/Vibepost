import AppKit
import MediaCraftMCP
import OSLog
import WebKit

let shellLog = Logger(subsystem: "com.wuyoscar.mediacraft", category: "shell")

/// 一个窗口里承载网页的 WKWebView：固定 origin `mediacraft://app`、Safari UA、文件选择、下载、外链。
/// 几个窗口共用一份 `ShellCore`（AI 进程、实况合成、外部 Agent、出图、数据存储）；这个窗口的原生桥带着 `windowId`。
@MainActor
public final class ShellWebView: NSObject {
    public static let scheme = "mediacraft"
    public static let host = "app"

    public let webView: WKWebView
    /// 这个窗口的 id：原生桥带着它，AI 的事件按它推
    public let windowId: String
    public let core: ShellCore
    /// 下载完成前文件还不在磁盘上，同时进行的下载靠这里避开同名。
    private var reservedDownloads: [ObjectIdentifier: URL] = [:]
    private var pendingLoad: CheckedContinuation<Void, Error>?
    private var observers: [NSObjectProtocol] = []

    public init(core: ShellCore, windowId: String = UUID().uuidString) {
        self.core = core
        self.windowId = windowId
        let config = WKWebViewConfiguration()
        config.websiteDataStore = core.dataStore
        let bridge = NativeBridge(
            downloadsDirectory: core.downloadsDirectory, iPhoneSender: core.iPhoneSender, clipboard: core.clipboard, ai: core.aiSessions,
            livePhotos: core.livePhotos, externalAgents: core.externalAgents, cards: core.cardRasterizer, window: windowId,
            windows: { [weak core] action, request in
                await core?.windowAction(action, request, from: windowId) ?? .failure(410, "Vibepost 正在关闭")
            }
        )
        config.setURLSchemeHandler(AppSchemeHandler(root: core.webRoot, bridge: bridge), forURLScheme: Self.scheme)
        // 页面按 UA 里的 `Safari/` 判断浏览器分支。
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.userContentController.add(HapticMessages(performer: core.haptics), name: HapticMessages.name)
        if core.glass {
            config.userContentController.addUserScript(WKUserScript(
                source: "document.documentElement.dataset.glass = 'native';",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        core.configure(config)
        let chromeView = ChromeWebView(frame: .zero, configuration: config)
        webView = chromeView
        #if DEBUG
        // 开发时用 Safari 的网页检查器调试；Release 版不开
        webView.isInspectable = true
        #endif
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        core.register(self)
        observeWindow()
        if core.glass {
            webView.setValue(false, forKey: "drawsBackground")
            config.userContentController.add(WindowChromeMessages(webView: chromeView), name: WindowChromeMessages.name)
        }
    }

    /// 只开一个窗口时（测试 harness）：自带一份 ShellCore。App 的几个窗口共用一份（见 main.swift）。
    public convenience init(
        webRoot: URL,
        dataStore: WKWebsiteDataStore? = nil,
        downloadsDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
        iPhoneSender: IPhoneSender = AirDropSender(),
        clipboard: TextClipboard = SystemClipboard(),
        haptics: HapticPerformer = SystemHaptics(),
        ai: AIConfiguration = .standard,
        mcp: MCPConfiguration? = nil,
        glass: Bool = false,
        configure: @escaping (WKWebViewConfiguration) -> Void = { _ in },
        session: URL? = nil
    ) {
        let core = ShellCore(
            webRoot: webRoot, dataStore: dataStore, downloadsDirectory: downloadsDirectory, iPhoneSender: iPhoneSender,
            clipboard: clipboard, haptics: haptics, ai: ai, mcp: mcp, glass: glass, configure: configure, session: session
        )
        self.init(core: core, windowId: "main")
    }

    /// 这个窗口到前面来（外部 Agent 的请求先交给它）；全屏时 `<html data-fullscreen>`
    private func observeWindow() {
        let center = NotificationCenter.default
        let ours = { [weak self] (notification: Notification) -> Bool in
            MainActor.assumeIsolated { self != nil && notification.object as? NSWindow === self?.webView.window }
        }
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, ours(notification) else { return }
                self.core.bringToFront(self)
            }
        })
        // 挪了、改了大小：记下来（重开 App 时照着恢复）
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, ours(notification) else { return }
                    self.core.saveSession()
                }
            })
        }
        guard core.glass else { return }
        for (name, fullScreen) in [
            (NSWindow.didEnterFullScreenNotification, true),
            (NSWindow.willExitFullScreenNotification, false),
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, ours(notification) else { return }
                    self.webView.evaluateJavaScript("document.documentElement.toggleAttribute('data-fullscreen', \(fullScreen))")
                }
            })
        }
    }

    /// 壳 → 这个窗口的页面：派发 `window` 上的一个 CustomEvent，detail 是给的 JSON
    func dispatch(_ name: String, json: String) {
        webView.callAsyncJavaScript(
            "window.dispatchEvent(new CustomEvent(name, { detail: JSON.parse(json) }))",
            arguments: ["name": name, "json": json], in: nil, in: .page, completionHandler: nil
        )
    }

    public static let entryURL = URL(string: "\(scheme)://\(host)/index.html")!

    /// 载入 App 页面；request 说这个窗口打开哪篇稿子（或新建一篇），不给时照常打开上次那篇
    public func loadEntry(_ request: WindowRequest = WindowRequest()) async throws {
        core.expect(request.draftId, in: self)
        var components = URLComponents(url: Self.entryURL, resolvingAgainstBaseURL: false)!
        let items = request.queryItems
        components.queryItems = items.isEmpty ? nil : items
        try await replacePage(with: components.url!)
    }

    /// 换成这个地址。已经有页面时用 location.replace 换掉它：不给它留历史记录，它就不会进往返缓存——
    /// 进了缓存的页面被挂起时若正在写库，事务一直占着库，新的页面连第一次读都等不到
    public func replacePage(with url: URL) async throws {
        try await waitForLoad {
            if webView.url == nil {
                webView.load(URLRequest(url: url))
            } else {
                webView.evaluateJavaScript("location.replace(\(Self.jsonString(url.absoluteString)))") { [weak self] _, error in
                    if let error { self?.finishLoad(error) }
                }
            }
        }
    }

    /// 发起一次换页，等它载完（didFinish / didFail）。前一次还在等的不再等（报错放手），免得它永远挂着
    private func waitForLoad(_ start: () -> Void) async throws {
        finishLoad(CancellationError())
        try await withCheckedThrowingContinuation { continuation in
            pendingLoad = continuation
            start()
        }
    }

    private static func jsonString(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [text])).map { String(String(decoding: $0, as: UTF8.self).dropFirst().dropLast()) }
            ?? "\"\""
    }

    /// 重新载入这个窗口（⌘R）：页面地址上记着它开着的那篇，还是打开那篇
    public func reload() async throws {
        try await waitForLoad { webView.reload() }
    }

    /// 这个窗口关掉了：结束它发起的 AI 进程，之后不再往它的页面推事件
    public func close() {
        core.unregister(self)
        core.aiSessions.close(window: windowId)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// 只开一个窗口时，App 退出、测试结束前调用：同 `ShellCore.shutdown`
    public func shutdown(completion: @escaping @MainActor @Sendable () -> Void = {}) {
        core.shutdown(completion: completion)
    }

    /// 外部 Agent 的一条请求交给这个窗口的页面（src/mcp/server.js）。窗口刚打开时页面可能还在载入、稿子还没打开：
    /// 等它准备好（每次最多问一秒），一共最多 30 秒。
    func ask(_ request: String) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(30)
        let ready = """
            if (!window.MediaCraftMCP || !window.mediacraft) return false;
            return await Promise.race([
              window.mediacraft.drafts.current().then(() => true, () => false),
              new Promise((resolve) => setTimeout(() => resolve(false), 1000)),
            ]);
        """
        while (try? await webView.callAsyncJavaScript(ready, arguments: [:], in: nil, contentWorld: .page) as? Bool) != true {
            guard ContinuousClock.now < deadline else { throw MCPFailure("Vibepost 的页面没有在 30 秒内准备好") }
            try await Task.sleep(for: .milliseconds(100))
        }
        let reply = try await webView.callAsyncJavaScript(
            "return await window.MediaCraftMCP.handle(request)", arguments: ["request": request], in: nil, contentWorld: .page
        )
        guard let reply = reply as? String else { throw MCPFailure("页面没有回答") }
        return reply
    }

    private func finishLoad(_ error: Error?) {
        guard let continuation = pendingLoad else { return }
        pendingLoad = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    private static func isInternal(_ url: URL) -> Bool {
        ["mediacraft", "blob", "data", "about"].contains(url.scheme?.lowercased() ?? "")
    }

    /// 能交出去打开的外链只有网页与邮件地址：file:、别的 App 的 URL scheme 一律不开（拖进窗口的 .command 不会被运行）
    private static func isOpenable(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }
}

extension ShellWebView: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if action.shouldPerformDownload {
            decisionHandler(.download)
        } else if let url = action.request.url, !Self.isInternal(url) {
            // 只有点了链接才交出去；拖进窗口的地址、页面自己的跳转都不开
            if action.navigationType == .linkActivated, Self.isOpenable(url) { core.openExternal(url) }
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// 换了一个页面（重新载入）：旧页面发起的 AI 回复没人接了，结束它们（只是这个窗口的）；配图的放行记录随旧页面一起忘掉；
    /// 旧页面报的占用不算了（新页面会重新报）。
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        core.aiSessions.terminate(window: windowId)
        core.aiSessions.forgetApprovals(window: windowId)
        core.pageReplaced(self)
    }

    /// 页面进程崩了：像换了一个页面那样收拾（结束它的 AI、放开它占着的稿子），再重新载入（地址上记着它开着的那篇）
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        shellLog.error("窗口 \(self.windowId, privacy: .public) 的页面进程结束了，重新载入")
        core.aiSessions.terminate(window: windowId)
        core.aiSessions.forgetApprovals(window: windowId)
        core.pageReplaced(self)
        finishLoad(URLError(.cancelled))
        webView.reload()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(nil)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(error)
    }
}

extension ShellWebView: WKDownloadDelegate {
    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        let destination = Self.uniqueURL(
            in: core.downloadsDirectory, name: suggestedFilename, reserved: Set(reservedDownloads.values)
        )
        reservedDownloads[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        reservedDownloads[ObjectIdentifier(download)] = nil
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        reservedDownloads[ObjectIdentifier(download)] = nil
        shellLog.error("download failed: \(error.localizedDescription, privacy: .public)")
    }

    /// `卡片.png` 已存在时改为 `卡片 2.png`、`卡片 3.png`…
    nonisolated static func uniqueURL(in directory: URL, name: String, reserved: Set<URL> = []) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate) {
            let numbered = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            index += 1
        }
        return candidate
    }
}

extension ShellWebView: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// `window.open` / `target=_blank`：网页与邮件地址交给默认浏览器 / 邮件 App。
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url, !Self.isInternal(url), Self.isOpenable(url) {
            core.openExternal(url)
        }
        return nil
    }
}
