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

    /// 关掉一个窗口：只结束它自己发起的 AI 进程；最后一个关掉时 App 退出（见下）
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = windows.removeValue(forKey: ObjectIdentifier(window))
        else { return }
        entry.shell.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 退出：记下开着的窗口（下次照着恢复），先结束所有窗口的 AI 进程（不卡主线程），都退出了再退。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        core.freezeSession()
        core.shutdown { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// 显示 › 重新载入：最前面的那个窗口
    @objc func reloadPage(_ sender: Any?) {
        guard let window = NSApp.keyWindow, let entry = windows[ObjectIdentifier(window)] else { return }
        entry.shell.webView.reload()
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
            .separator(),
            item("隐藏 Vibepost", #selector(NSApplication.hide(_:)), "h"),
            item("退出 Vibepost", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        // 一个窗口一篇稿子；新窗口里是一篇新稿子（稿件列表里 ⌘ 点一篇也会在新窗口打开）
        menu.addItem(submenu("文件", [
            item("新建窗口", #selector(AppDelegate.newWindow(_:)), "N"),
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
