import AppKit
import MediaCraftMCP
import MediaCraftShell

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// 全 App 共用的原生部分（AI 进程、外部 Agent、实况合成、出图），几个窗口共用
    private var core: ShellCore!
    /// 开着的窗口与各自的网页
    private var windows: [ObjectIdentifier: (window: NSWindow, shell: ShellWebView)] = [:]
    /// 新窗口在最前面那个窗口的基础上往右下错开这么多
    private static let cascade: CGFloat = 28
    /// 正在关的窗口：先等它的页面存完稿（windowShouldClose），存完再真正关上
    private var closing: Set<ObjectIdentifier> = []
    /// 已经在退出了（存稿、结束 AI 进程中）：再按 ⌘Q 不重来一遍
    private var terminating = false
    /// 已经回复过 AppKit 的 terminateLater（正常路径与兜底二选一，不回复两次）
    private var repliedToTerminate = false
    private var terminateFallback: Timer?
    /// 检查更新（MediaCraftShell/Updater.swift）：「检查更新…」与每天一次的自动检查；准备好的新版在退出时换上
    private var updater: Updater!
    private var preparedUpdate: Updater.Prepared?
    /// 「现在更新」：换好之后重新打开
    private var relaunchAfterUpdate = false
    private var checkingForUpdates = false

    /// 启动：照退出前开着的窗口恢复（各自的稿子、位置大小），没有记录时开一个窗口打开上次那篇
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        core = ShellCore(
            webRoot: Self.webRoot(), mcp: .standard, glass: true,
            session: MCPPaths.supportDirectory.appendingPathComponent("windows.json")
        )
        core.openWindow = { [weak self] request in self?.openWindow(request) }
        core.closeWindow = { [weak self] shell in
            self?.windows.values.first { $0.shell === shell }?.window.close()
        }
        let saved = core.savedWindows()
        if saved.isEmpty { openWindow(WindowRequest()) }
        for entry in saved {
            openWindow(WindowRequest(draftId: entry.draftId), frame: entry.frame.flatMap(Self.frame))
        }
        // 上次留下的下载与暂存清掉；稍等一会儿再自动检查更新（一天最多一次）。页面里（AI 设置 › 关于）也能点「检查更新…」
        updater = Updater.forRunningApp()
        Task { await updater.cleanStaging() }
        core.checkForUpdates = { [weak self] in Task { await self?.checkForUpdates(automatic: false) } }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            await self?.checkForUpdates(automatic: true)
        }
    }

    /// 记下的位置大小，挪回到屏幕里（上次的显示器可能不在了）
    private static func frame(_ values: [Double]) -> NSRect? {
        guard values.count == 4, let screen = NSScreen.main else { return nil }
        let rect = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
        let visible = (NSScreen.screens.first { $0.visibleFrame.intersects(rect) } ?? screen).visibleFrame
        let size = NSSize(width: min(rect.width, visible.width), height: min(rect.height, visible.height))
        let x = min(max(rect.minX, visible.minX), visible.maxX - size.width)
        let y = min(max(rect.minY, visible.minY), visible.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    /// 开一个窗口，里面的页面照 request 打开稿子（不给时打开上次那篇）。给了 frame 就用它（恢复的窗口）；
    /// 否则第一个窗口用上次的位置大小，之后的在最前面那个窗口的右下方错开一点。
    @discardableResult
    private func openWindow(_ request: WindowRequest, frame: NSRect? = nil) -> ShellWebView {
        let shell = ShellWebView(core: core)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 960),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Vibepost"
        // 网页工具栏铺进标题栏；红绿灯保留原生。空工具栏只用来把标题栏撑到 52 点，让红绿灯与网页工具栏垂直居中。
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = NSToolbar(identifier: "MediaCraftMain")
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 1100, height: 720)
        window.contentView = Self.glass(behind: shell.webView)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let frame {
            window.setFrame(frame, display: false)
        } else if let front = NSApp.keyWindow ?? windows.values.map(\.window).last {
            window.setFrame(front.frame, display: false)
            window.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + Self.cascade, y: front.frame.maxY - Self.cascade))
        } else {
            window.setFrameAutosaveName("MediaCraftMain")
            if !window.setFrameUsingName("MediaCraftMain") { window.center() }
        }
        windows[ObjectIdentifier(window)] = (window, shell)
        // 外部 Agent 开的窗口放到前面，但不抢用户正在打字的那个窗口的键盘焦点
        if request.background && NSApp.keyWindow != nil { window.orderFront(nil) } else { window.makeKeyAndOrderFront(nil) }
        Task { try? await shell.loadEntry(request) }
        return shell
    }

    /// 文件 › 新建窗口（⌘⇧N）：新窗口里是一篇新稿子
    @objc func newWindow(_ sender: Any?) {
        openWindow(WindowRequest(fresh: true))
    }

    /// 文件 › 保存（⌘S）：最前面那个窗口的稿子马上存（页面自己也接 ⌘S，这一项是给点菜单的）
    @objc func saveDraft(_ sender: Any?) {
        guard let window = NSApp.keyWindow, let entry = windows[ObjectIdentifier(window)] else { return }
        Task { await entry.shell.saveDrafts() }
    }

    /// 点了关闭：先让这个窗口的页面把稿子存完（最多等 3 秒，页面卡住也照样关），再真正关上。存的途中再点关闭不重来。
    /// 页面明确说「没存上」（写不进本机，改动还在它内存里）时问一句，别静默丢掉
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let key = ObjectIdentifier(sender)
        guard let entry = windows[key] else { return true }
        guard !closing.contains(key) else { return false }
        closing.insert(key)
        Task {
            if await entry.shell.saveDraftsOutcome() == .failed, await !confirmDiscard("这个窗口的稿子没能存进本机", "仍要关闭") {
                closing.remove(key)
                return
            }
            sender.close()
        }
        return false
    }

    /// 没存上时的确认：true = 仍要关 / 退出
    private func confirmDiscard(_ title: String, _ action: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "改动还在页面里，现在关掉就丢了。可以先点顶栏的「没存上」再试一次，或者把内容复制出来。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: action)
        return await runModal(alert) == .alertSecondButtonReturn
    }

    /// 关掉一个窗口：只结束它自己发起的 AI 进程；最后一个关掉时 App 退出（见下）
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        closing.remove(ObjectIdentifier(window))
        guard let entry = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.shell.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 退出：记下开着的窗口（下次照着恢复），每个窗口先把稿子存完（各最多等 3 秒），再结束所有窗口的 AI 进程
    /// （不卡主线程），都退出了再退。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 已经在退了（存稿、结束 AI 进程中）：这一次不另起一遍，也不留一个永远不回答的 terminateLater
        guard !terminating else { return .terminateCancel }
        terminating = true
        repliedToTerminate = false
        core.freezeSession()
        Task {
            // 有页面明确说没存上：问一句，取消就不退了（下次再退重新来）
            if await !core.saveAllDrafts(), await !confirmDiscard("有稿子没能存进本机", "仍要退出") {
                terminateFallback?.invalidate()
                terminateFallback = nil
                terminating = false
                repliedToTerminate = true
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            installPreparedUpdate()
            core.shutdown { self.replyToTerminate() }
        }
        // 兜底：上面那条路要靠 MainActor 的任务跑；terminateLater 之后 AppKit 在 terminate: 里原地转嵌套 run loop 等回复，
        // 要是 terminate 是从主队列的 block（GCD、MainActor 任务）里调的，嵌套 loop 不再 drain 主队列，那条路就永远到不了。
        // 所以兜底用 run loop 的 Timer（加进 common 模式，嵌套 loop 里照样响）：20 秒后直接换上准备好的新版并回复，
        // App 不会卡在「退出中」出不去、菜单里的退出变灰
        let fallback = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.repliedToTerminate else { return }
                self.updater.note("退出：存稿或结束 AI 进程 20 秒没完成，直接退出")
                self.installPreparedUpdate()
                self.replyToTerminate()
            }
        }
        RunLoop.main.add(fallback, forMode: .common)
        terminateFallback = fallback
        return .terminateLater
    }

    /// 弹一个挡住整个 App 的对话框：从 run loop 的回调里进入，而不是在 MainActor 的 async 任务（= 主队列的 block）里直接 runModal。
    /// 从主队列的 block 里转起来的嵌套 run loop 不 drain 主队列：弹窗期间页面的桥请求、AI 的事件、别的任务全停摆，
    /// 「现在更新」之后的退出更是永远等不到回复（2026-10-08 用户卡死的根因）。经 run loop 进入就没有这个问题
    private func runModal(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume(returning: MainActor.assumeIsolated { alert.runModal() })
            }
        }
    }

    private func replyToTerminate() {
        guard !repliedToTerminate else { return }
        repliedToTerminate = true
        terminateFallback?.invalidate()
        terminateFallback = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: - 检查更新

    /// Vibepost › 检查更新…
    @objc func checkForUpdatesFromMenu(_ sender: Any?) {
        Task { await checkForUpdates(automatic: false) }
    }

    /// 自动检查（automatic）一天最多一次，有新版（且没被跳过）才说话；手动检查总有回答
    private func checkForUpdates(automatic: Bool) async {
        if let prepared = preparedUpdate {
            if !automatic { await offerRestart(prepared) }
            return
        }
        guard !checkingForUpdates, !automatic || updater.dueForAutomaticCheck() else { return }
        checkingForUpdates = true
        defer { checkingForUpdates = false }
        do {
            switch try await updater.check() {
            case .upToDate(let version):
                if !automatic { await inform("已是最新版本", "你用的 Vibepost \(version) 就是最新的。") }
            case .available(let release):
                if automatic, updater.isSkipped(release.version) { return }
                await offer(release)
            }
        } catch {
            if !automatic { await inform("没能检查更新", error.localizedDescription) }
        }
    }

    private func offer(_ release: UpdateRelease) async {
        let alert = NSAlert()
        alert.messageText = "Vibepost \(release.version) 可以更新了"
        alert.informativeText = "你现在用的是 \(updater.current)。" + Self.summary(release.notes)
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过这个版本")
        switch await runModal(alert) {
        case .alertFirstButtonReturn: await download(release)
        case .alertThirdButtonReturn: updater.skip(release.version)
        default: break
        }
    }

    /// 下载、核对（挂一个转圈的提示在最前面的窗口上，可以先关掉它，在后台接着下），好了问要不要现在更新
    private func download(_ release: UpdateRelease) async {
        let progress = NSAlert()
        progress.messageText = "正在下载 Vibepost \(release.version)…"
        progress.informativeText = "下载、核对好之后会问你要不要现在更新。"
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        progress.accessoryView = spinner
        progress.addButton(withTitle: "在后台下载")
        let host = NSApp.keyWindow ?? windows.values.first?.window
        if let host { progress.beginSheetModal(for: host) { _ in } }
        let result: Result<Updater.Prepared, Error>
        do {
            result = .success(try await updater.prepare(release))
        } catch {
            result = .failure(error)
        }
        if let host, let sheet = host.attachedSheet, sheet === progress.window { host.endSheet(sheet) }
        switch result {
        case .success(let prepared):
            preparedUpdate = prepared
            await offerRestart(prepared)
        case .failure(let error):
            updater.note("更新没装上：\(error.localizedDescription)")
            await inform("更新没装上", error.localizedDescription)
        }
    }

    /// 准备好了：现在就退出、换上、重新打开；或者等用户自己退出时再换。App 所在的位置不能写时打开 DMG 让用户自己拖
    private func offerRestart(_ prepared: Updater.Prepared) async {
        guard updater.canReplace else {
            preparedUpdate = nil
            NSWorkspace.shared.open(prepared.dmg)
            await inform("请手动安装 Vibepost \(prepared.release.version)", UpdateError.notWritable(Bundle.main.bundleURL.path).localizedDescription)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Vibepost \(prepared.release.version) 已经准备好"
        alert.informativeText = "现在重新打开 Vibepost 完成更新？开着的稿子会先存好，重新打开后还是这几个窗口。选「稍后」就在你退出 Vibepost 时换上新版。"
        alert.addButton(withTitle: "现在更新")
        alert.addButton(withTitle: "稍后")
        if await runModal(alert) == .alertFirstButtonReturn {
            relaunchAfterUpdate = true
            // 不在这个 async 任务里直接 terminate，也不经 GCD 派发（两种都会让 terminateLater 的回复永远跑不到，见 runModal 的说明）：
            // 经 run loop 派发，和 AppKit 自己「最后一窗关闭后退出」一样
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
    }

    /// 退出时（稿子都存完之后）换上准备好的新版；换不了就打开 DMG
    private func installPreparedUpdate() {
        guard let prepared = preparedUpdate else { return }
        preparedUpdate = nil // 正常路径与兜底都会来：只起一次替换脚本
        do {
            try updater.install(prepared, relaunch: relaunchAfterUpdate)
        } catch {
            updater.note("起不了替换脚本：\(error.localizedDescription)，打开 DMG 让用户自己拖")
            NSWorkspace.shared.open(prepared.dmg)
        }
    }

    private func inform(_ title: String, _ message: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        _ = await runModal(alert)
    }

    /// 更新说明（Release 的正文）的开头一段
    /// Release 的正文是 Markdown，对话框只显示纯文字：去掉粗体、代码的记号，列表换成「·」，标题行照常
    private static func summary(_ notes: String) -> String {
        let lines = notes.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var text = String(line).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            while text.hasPrefix("#") { text.removeFirst() }
            if text.hasPrefix("- ") { text = "· " + text.dropFirst(2) }
            return text.trimmingCharacters(in: .whitespaces)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return "\n\n" + (text.count > 600 ? String(text.prefix(600)) + "…" : text)
    }

    /// 显示 › 重新载入：最前面的那个窗口（先存稿）
    @objc func reloadPage(_ sender: Any?) {
        guard let window = NSApp.keyWindow, let entry = windows[ObjectIdentifier(window)] else { return }
        Task { try? await entry.shell.reload() }
    }

    /// 窗口后面的原生毛玻璃：网页透明处（工具栏、稿件栏）透出它，内容区自己画不透明底色。
    private static func glass(behind webView: NSView) -> NSView {
        let glass = NSVisualEffectView()
        glass.material = .sidebar
        glass.blendingMode = .behindWindow
        glass.state = .followsWindowActiveState
        webView.frame = glass.bounds
        webView.autoresizingMask = [.width, .height]
        glass.addSubview(webView)
        return glass
    }

    /// Debug 构建在 Info.plist 写入仓库路径（改完 ⌘R 生效），也认环境变量 MEDIACRAFT_WEB_ROOT；Release 用 .app 内的网页副本
    /// （不认环境变量：别的进程能经 launchctl setenv 设它，让 App 载入别处的网页、拿到原生桥）。
    private static func webRoot() -> URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["MEDIACRAFT_WEB_ROOT"] {
            return URL(fileURLWithPath: override)
        }
        #endif
        if let repo = Bundle.main.object(forInfoDictionaryKey: "MCWebRoot") as? String {
            return URL(fileURLWithPath: repo)
        }
        return Bundle.main.resourceURL!.appendingPathComponent("web")
    }
}

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu("Vibepost", [
            item("关于 Vibepost", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("检查更新…", #selector(AppDelegate.checkForUpdatesFromMenu(_:))),
            .separator(),
            item("隐藏 Vibepost", #selector(NSApplication.hide(_:)), "h"),
            item("退出 Vibepost", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        // 一个窗口一篇稿子；新窗口里是一篇新稿子（稿件列表里 ⌘ 点一篇也会在新窗口打开）
        menu.addItem(submenu("文件", [
            item("新建窗口", #selector(AppDelegate.newWindow(_:)), "N"),
            .separator(),
            item("保存", #selector(AppDelegate.saveDraft(_:)), "s"),
        ]))
        // 没有 Edit 菜单时，⌘C / ⌘V 在 WKWebView 里不生效。
        menu.addItem(submenu("编辑", [
            item("撤销", Selector(("undo:")), "z"),
            item("重做", Selector(("redo:")), "Z"),
            .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x"),
            item("拷贝", #selector(NSText.copy(_:)), "c"),
            item("粘贴", #selector(NSText.paste(_:)), "v"),
            item("全选", #selector(NSText.selectAll(_:)), "a"),
        ]))
        // 全屏用系统标准的 ⌃⌘F；⌘F 留给页面里的查找替换。
        menu.addItem(submenu("显示", [
            item("重新载入", #selector(AppDelegate.reloadPage(_:)), "r"),
            item("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command]),
        ]))
        menu.addItem(submenu("窗口", [
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("关闭", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        return menu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        items.forEach(sub.addItem)
        parent.submenu = sub
        return parent
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
