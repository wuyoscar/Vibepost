import AppKit
import MediaCraftMCP
import WebKit

/// 开一个窗口的要求：打开哪篇稿子，或新建一篇；都不给时照常打开上次那篇。
/// background：外部 Agent 开的窗口，放到前面但不抢键盘焦点（用户正在别的窗口里打字）
/// panel：一开就显示检查器的哪一栏（只有 "ai"：AI 助手顶上的「+」开的窗口）
public struct WindowRequest: Sendable, Equatable {
    public var draftId: String?
    public var fresh: Bool
    public var background: Bool
    public var panel: String?

    public init(draftId: String? = nil, fresh: Bool = false, background: Bool = false, panel: String? = nil) {
        self.draftId = draftId
        self.fresh = fresh
        self.background = background
        self.panel = panel == "ai" ? panel : nil
    }

    /// 页面地址上的参数（`?draft=<id>`、`?new=1`、`&panel=ai`），页面启动时照它打开；origin 不变（mediacraft://app），稿子存储还是同一份
    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if fresh {
            items.append(URLQueryItem(name: "new", value: "1"))
        } else if let draftId {
            items.append(URLQueryItem(name: "draft", value: draftId))
        }
        if let panel { items.append(URLQueryItem(name: "panel", value: panel)) }
        return items
    }
}

/// 恢复窗口用的记录：窗口开着的那篇与它的位置大小（`[x, y, 宽, 高]`）
public struct SavedWindow: Codable, Sendable, Equatable {
    public var draftId: String
    public var frame: [Double]?

    public init(draftId: String, frame: [Double]? = nil) {
        self.draftId = draftId
        self.frame = frame
    }
}

/// 全 App 共用的原生部分：AI 会话的进程、实况合成、外部 Agent 的套接字、卡片出图，以及页面的数据存储与各项设置。
/// 每个窗口一个 `ShellWebView`（一份网页），经各自的原生桥用这些服务：AI 的事件只推给发起那一轮的窗口，
/// 实况合成的进度与外部 Agent 的状态推给所有窗口，外部 Agent 的请求交给最前面的窗口。
/// 一篇稿子只在一个窗口里：每个窗口占着哪些稿子（正开着的、AI 还在跑的）由页面报来，记在这里；要开的那篇在别的窗口里时，
/// 把那个窗口调到前面、让它换到那篇。开着的窗口记在 `windows.json`，重开 App 时照着恢复。
/// 外部 Agent 的每次会话认定一篇稿子（记在这里，页面重新载入、换窗口都还在），它的请求交给开着那篇的窗口；
/// 它新建的稿子开在新窗口，打开的稿子用开着它的窗口、没开就开新窗口，不替换用户正在看的窗口。
@MainActor
public final class ShellCore {
    let webRoot: URL
    let dataStore: WKWebsiteDataStore
    let downloadsDirectory: URL
    let iPhoneSender: IPhoneSender
    let clipboard: TextClipboard
    let haptics: HapticPerformer
    let glass: Bool
    let configure: (WKWebViewConfiguration) -> Void
    let aiSessions: AISessions
    let livePhotos: LivePhotos
    let externalAgents: ExternalAgents
    /// HTML 卡片出图（`cards/raster`）：一个不上屏的 WKWebView，几个窗口的请求排着来
    let cardRasterizer: CardRasterizer
    /// 写作手册（`manuals/*`；AI 的每一轮也拷一份进工作副本）
    let writingManuals: WritingManuals
    /// 用户自己存的模板（`templates/*`）
    let templates: TemplateLibrary
    /// 开着的窗口（不拥有它们：窗口关掉就没了），最近到前面来的排在最后
    private var windows: [WeakPage] = []
    /// 要开新窗口（「新建窗口」、稿件列表里的「在新窗口打开」、外部 Agent 新建或打开的稿子）时怎么开，返回新窗口的网页：
    /// App（main.swift）或测试 harness 接上
    public var openWindow: ((WindowRequest) -> ShellWebView?)?
    /// 外部 Agent 的每次会话（mediacraft-mcp 的会话编号）认定的稿子
    private var agentDrafts: [String: String] = [:]
    /// 要关掉一个窗口（它要开的那篇已经不在了）时怎么关：App 或测试 harness 接上
    public var closeWindow: ((ShellWebView) -> Void)?
    /// 点了网页里的外链时怎么打开（默认交给默认浏览器 / 邮件 App）；测试 harness 换成记下来
    public var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// 页面里点了「检查更新…」（AI 设置的「关于」）：App（main.swift）接上更新器；nil 时页面不显示这一项
    public var checkForUpdates: (() -> Void)?
    /// 「关于」里显示的版本号（App 的 Info.plist；测试 harness 是 dev）
    public var appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    /// 「在 Finder 中显示」一份写作手册（是文件夹时打开那个文件夹）；测试 harness 换成记下来
    public var revealFile: (URL) -> Void = { url in
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    /// 用默认的 App 打开一份写作手册；测试 harness 换成记下来
    public var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// 每个窗口占着的稿子：current 是它正开着的（恢复窗口时照它开，可以是说明书），drafts 是别的窗口不能再开的
    private var occupancy: [String: Occupancy] = [:]
    /// 每个窗口现在的页面（页面自己起的 id）与它最近一次报占用的序号
    private var pageReports: [String: PageReport] = [:]
    /// 换掉了的页面的 id：它们迟到的报告不算
    private var retiredPages: Set<String> = []
    /// 记开着的窗口的文件；nil 时不记
    private let sessionFile: URL?
    /// App 正在退出：窗口一个个关掉时不再改记录（下次照退出前的样子恢复）
    private var sessionFrozen = false

    private struct WeakPage {
        weak var page: ShellWebView?
    }

    private struct Occupancy {
        var current: String?
        var drafts: Set<String> = []
    }

    private struct PageReport {
        var page: String
        var sequence: Int
    }

    /// - Parameters:
    ///   - webRoot: 网页根目录（含 index.html）。Debug 指向仓库，Release 指向 .app 内的副本。
    ///   - dataStore: 必须是持久化存储；非持久化存储下 IndexedDB 存不了 Blob（实况视频）。不给时用默认的。几个窗口共用。
    ///   - downloadsDirectory: 页面下载（`<a download>`）的保存位置。
    ///   - iPhoneSender / clipboard: 「发送到 iPhone」用到的 AirDrop 与剪贴板，测试时注入假实现。
    ///   - haptics: 拖到吸附点时的触控板反馈（页面经 `mediacraftHaptic` 消息要），测试时注入假实现。
    ///   - glass: 网页铺进透明标题栏、透出窗口后面的原生毛玻璃：网页不画底色，`<html data-glass="native">`，
    ///     接收页面报告的可拖区域，全屏时 `<html data-fullscreen>`（红绿灯收起，工具栏不再让位）。
    ///   - ai: AI 会话（本机 Claude Code、Codex）的工作副本位置与查找程序用的登录 shell，测试时换成临时目录与假的程序。
    ///   - mcp: 外部 Agent（MCP）连进来的套接字与设置的位置；nil 时不监听（测试默认，App 用 `.standard`）。
    ///   - configure: 在创建每个窗口的 WKWebView 前追加配置（测试 harness 用来注入诊断脚本）。
    ///   - session: 记开着的窗口的文件（App 是 `~/Library/Application Support/MediaCraft/windows.json`）；nil 时不记。
    public init(
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
        self.webRoot = webRoot
        sessionFile = session
        self.dataStore = dataStore ?? .default()
        self.downloadsDirectory = downloadsDirectory
        self.iPhoneSender = iPhoneSender
        self.clipboard = clipboard
        self.haptics = haptics
        self.glass = glass
        self.configure = configure
        // 示例手册随网页一起（build-app.sh 把 src/ 拷进 App）
        writingManuals = WritingManuals(folder: ai.writingManuals)
        templates = TemplateLibrary(folder: ai.templates)
        aiSessions = AISessions(configuration: ai, manuals: writingManuals)
        livePhotos = LivePhotos()
        externalAgents = ExternalAgents(configuration: mcp)
        cardRasterizer = CardRasterizer(root: webRoot)
        let ai = sink("mediacraft:native-ai")
        aiSessions.setSink { json, window in ai(json, window) }
        let live = sink("mediacraft:native-live-photo")
        livePhotos.setSink { json in live(json, nil) }
        let agents = sink("mediacraft:native-mcp")
        externalAgents.setSink { json in agents(json, nil) }
        externalAgents.setPage { [weak self] request in
            guard let self else { throw MCPFailure("Vibepost 正在关闭") }
            return try await self.routeAgent(request)
        }
        externalAgents.start()
    }

    /// 开着的窗口，最近到前面来的排在最后
    var pages: [ShellWebView] { windows.compactMap(\.page) }

    /// 新开的窗口先排在最后面（最旧）：它真的成了前面的窗口（didBecomeKey）才挪到最前——外部 Agent 开的窗口不抢焦点，不算最前
    func register(_ page: ShellWebView) {
        windows = [WeakPage(page: page)] + windows.filter { $0.page != nil && $0.page !== page }
    }

    func unregister(_ page: ShellWebView) {
        windows = windows.filter { $0.page != nil && $0.page !== page }
        occupancy[page.windowId] = nil
        saveSession()
    }

    /// 这个窗口到前面来了（外部 Agent 的请求先交给它）
    func bringToFront(_ page: ShellWebView) {
        windows = windows.filter { $0.page != nil && $0.page !== page } + [WeakPage(page: page)]
        saveSession()
    }

    // MARK: - 一篇稿子只在一个窗口里

    /// 窗口刚开、页面还没报来时，先记着它要开的那篇并替它占着（这时退出也照它恢复；同时恢复的别的窗口不会抢它）
    func expect(_ draftId: String?, in page: ShellWebView) {
        guard let draftId, occupancy[page.windowId] == nil else { return }
        occupancy[page.windowId] = Occupancy(current: draftId, drafts: [draftId])
    }

    /// 这个窗口换了一个页面（重新载入、页面进程崩了）：旧页面之后再报来的都不算了。新页面照地址上的 `?draft=` 重新打开
    /// 正开着的那篇，报来之前照旧替它占着；AI 占着的那些随旧页面的 AI 回复一起放开
    func pageReplaced(_ page: ShellWebView) {
        if let old = pageReports.removeValue(forKey: page.windowId) { retiredPages.insert(old.page) }
        occupancy[page.windowId] = occupancy[page.windowId].map { old in
            Occupancy(current: old.current, drafts: old.drafts.filter { $0 == old.current })
        }
    }

    /// 占着这篇的另一个窗口（不算 except）
    private func holder(of draftId: String, except window: String?) -> ShellWebView? {
        pages.last { $0.windowId != window && occupancy[$0.windowId]?.drafts.contains(draftId) == true }
    }

    /// 把这个窗口调到前面，让它的页面换到这篇
    private func focus(_ page: ShellWebView, on draftId: String) {
        page.webView.window?.makeKeyAndOrderFront(nil)
        bringToFront(page)
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "show", "draftId": draftId]) else { return }
        page.dispatch("mediacraft:native-window", json: String(decoding: data, as: UTF8.self))
    }

    /// window 这个窗口要开这篇：在别的窗口里时（focus 为真就把那个窗口调到前面、换到这篇）不能开；能开时先替它占着
    private func claim(_ draftId: String, for window: String, focus wanted: Bool) -> Bool {
        if let other = holder(of: draftId, except: window) {
            if wanted { focus(other, on: draftId) }
            return false
        }
        occupancy[window, default: Occupancy()].drafts.insert(draftId)
        return true
    }

    /// 页面报来的占用：换掉了的页面报的不算；同一个页面的，序号比收到过的旧（几个请求到壳的先后不一定）就丢掉
    private func occupy(current: String?, drafts: [String], page: String, sequence: Int, for window: String) {
        guard !retiredPages.contains(page) else { return }
        if let last = pageReports[window], last.page == page, sequence <= last.sequence { return }
        pageReports[window] = PageReport(page: page, sequence: sequence)
        occupancy[window] = Occupancy(current: current, drafts: Set(drafts))
        saveSession()
    }

    // MARK: - 重开 App 时恢复窗口

    /// 上次开着的窗口，按先后（最后一个在最前面）
    public func savedWindows() -> [SavedWindow] {
        guard let sessionFile, let data = try? Data(contentsOf: sessionFile),
              let saved = try? JSONDecoder().decode([SavedWindow].self, from: data)
        else { return [] }
        return saved
    }

    /// 记下现在开着的窗口（开、关、换稿子、到前面来、挪动、改大小时）
    func saveSession() {
        guard let sessionFile, !sessionFrozen else { return }
        let saved = pages.compactMap { page -> SavedWindow? in
            guard let current = occupancy[page.windowId]?.current else { return nil }
            let frame = page.webView.window?.frame
            return SavedWindow(draftId: current, frame: frame.map { [$0.minX, $0.minY, $0.width, $0.height] })
        }
        do {
            try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: sessionFile, options: .atomic)
        } catch {
            shellLog.error("windows.json 没能写：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 所有窗口的页面马上存稿并等写完（退出、更新重启之前），每个窗口最多等 timeout
    /// 返回是否每个窗口都存好了（或没回）；有页面明确说「没存上」时为 false（它内存里的改动会随退出丢掉，退出前该问一句）
    @discardableResult
    public func saveAllDrafts(timeout: Duration = .seconds(3)) async -> Bool {
        let pages = pages
        return await withTaskGroup(of: Bool.self) { group in
            for page in pages {
                group.addTask { @MainActor in await page.saveDraftsOutcome(timeout: timeout) != .failed }
            }
            var ok = true
            for await result in group { ok = ok && result }
            return ok
        }
    }

    /// App 退出前：记下所有窗口，之后它们一个个关掉时不再改记录
    public func freezeSession() {
        saveSession()
        sessionFrozen = true
    }

    /// 壳 → 页面：在主线程往窗口的页面派发 `window` 上的一个 CustomEvent，detail 是给的 JSON；window 为 nil 时推给所有窗口
    private nonisolated func sink(_ name: String) -> @Sendable (String, String?) -> Void {
        { [weak self] json, window in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for page in self.pages where window == nil || page.windowId == window {
                        page.dispatch(name, json: json)
                    }
                }
            }
        }
    }

    // MARK: - 外部 Agent

    /// 正开着这篇的窗口（它的页面上就是这篇）
    private func window(showing draftId: String) -> ShellWebView? {
        pages.last { occupancy[$0.windowId]?.current == draftId }
    }

    /// 外部 Agent 的一条请求（`{ session, method, params, … }`）交给哪个窗口的页面，并带上这次会话认定的稿子：
    /// - create_draft：开一个新窗口（里面新建的那篇就是它要的，`reuseBlank`）；
    /// - open_draft：那篇开着就交给那个窗口，没开就开一个新窗口打开它；
    /// - 别的：认定的那篇开着就交给那个窗口；没认定、或它已经不在任何窗口里开着时交给最前面的窗口
    ///   （页面认定它正开着的那篇，或说明「用户切到了别的稿子」）。
    private func routeAgent(_ text: String) async throws -> String {
        guard var request = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw MCPFailure("请求的格式不对")
        }
        let session = request["session"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        let tool = request["method"] as? String == "tools/call" ? params["name"] as? String : nil
        let bound = agentDrafts[session]
        let target: ShellWebView?
        switch tool {
        case "create_draft":
            // 只有真开了一个新窗口才让页面用那里新建的空稿子
            guard let fresh = openWindow?(WindowRequest(fresh: true, background: true)) else {
                return Self.toolError("Vibepost 现在开不了新窗口，没法新建稿子")
            }
            target = fresh
            request["reuseBlank"] = true
        case "open_draft":
            let wanted = ((params["arguments"] as? [String: Any])?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let wanted, window(showing: wanted) == nil, holder(of: wanted, except: nil) != nil {
                // 用户的一个窗口里 AI 正在改它（没显示出来）：不开新窗口、不把那个窗口换过去
                return Self.toolError("这篇稿子（id \(wanted)）的 AI 正在用户的一个窗口里改它，等它改完再打开")
            }
            target = wanted.flatMap { window(showing: $0) ?? openWindow?(WindowRequest(draftId: $0, background: true)) }
        default:
            target = bound.flatMap(window(showing:))
        }
        request["bound"] = bound ?? NSNull()
        request["boundOpen"] = bound.map { window(showing: $0) != nil } ?? false
        guard let page = target ?? pages.last else { throw MCPFailure("Vibepost 没有开着的窗口") }
        let data = try JSONSerialization.data(withJSONObject: request)
        return try await page.ask(String(decoding: data, as: UTF8.self))
    }

    /// 不交给页面、直接回给外部 Agent 的工具错误（页面回答的样子：`{ result: { content, isError } }`）
    private static func toolError(_ message: String) -> String {
        let reply: [String: Any] = ["result": ["content": [["type": "text", "text": message]], "isError": true]]
        return (try? JSONSerialization.data(withJSONObject: reply)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// 页面认定了这次会话改哪篇（第一次看、改稿子时正开着的那篇，新建、打开的那篇）
    private func bindAgent(_ session: String, to draftId: String) {
        agentDrafts[session] = draftId
    }

    /// 页面经原生桥 `window/<动作>` 要的窗口的事（window 是发来请求的窗口）：
    /// - open `{ draftId?, fresh?, panel? }`：开一个新窗口（panel 为 "ai" 时一开就是 AI 助手）；那篇在别的窗口里时把那个窗口调到前面，回 `{ elsewhere: true }`
    /// - claim `{ draftId, focus? }`：这个窗口能不能开这篇，`{ elsewhere }`
    /// - occupy `{ current, drafts, page, sequence }`：这个窗口占着的稿子（page 是页面自己起的 id，sequence 是它的第几次报告）
    /// - missing：这个窗口要开的那篇已经不在了，还有别的窗口时关掉它
    /// - bind-agent `{ session, draftId }`：外部 Agent 的这次会话认定这篇
    /// - edited `{ edited }`：这个窗口有没有还没存进本机的改动（关闭按钮上的小圆点）
    /// - app-info：`{ version, updates }`（版本号、能不能检查更新）；check-updates：像点了菜单里的「检查更新…」
    nonisolated func windowAction(_ action: String, _ request: [String: Any], from window: String) async -> NativeBridge.Reply {
        let draftId = (request["draftId"] as? String).flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 }
        switch action {
        case "open":
            let wanted = WindowRequest(draftId: draftId, fresh: request["fresh"] as? Bool ?? false, panel: request["panel"] as? String)
            return await MainActor.run {
                if let draftId = wanted.draftId, !wanted.fresh, let other = holder(of: draftId, except: nil) {
                    focus(other, on: draftId)
                    return .ok(["elsewhere": true])
                }
                guard let openWindow else { return .failure(404, "这里不能开新窗口") }
                _ = openWindow(wanted)
                return .ok(["elsewhere": false])
            }
        case "claim":
            guard let draftId else { return .failure(400, "稿子 id 不对") }
            let focus = request["focus"] as? Bool ?? true
            return await MainActor.run { .ok(["elsewhere": !claim(draftId, for: window, focus: focus)]) }
        case "occupy":
            let current = (request["current"] as? String).flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 }
            let drafts = (request["drafts"] as? [String] ?? []).filter { !$0.isEmpty && $0.count <= 200 }
            let page = request["page"] as? String ?? ""
            let sequence = request["sequence"] as? Int ?? Int.max
            await MainActor.run { occupy(current: current, drafts: drafts, page: page, sequence: sequence, for: window) }
            return .ok()
        case "bind-agent":
            guard let session = request["session"] as? String, !session.isEmpty, let draftId else {
                return .failure(400, "会话或稿子 id 不对")
            }
            await MainActor.run { bindAgent(session, to: draftId) }
            return .ok()
        case "app-info":
            return await MainActor.run { .ok(["version": appVersion, "updates": checkForUpdates != nil]) }
        case "check-updates":
            return await MainActor.run {
                guard let checkForUpdates else { return .failure(404, "这里不能检查更新") }
                checkForUpdates()
                return .ok()
            }
        case "edited":
            let edited = request["edited"] as? Bool ?? false
            await MainActor.run { pages.first { $0.windowId == window }?.webView.window?.isDocumentEdited = edited }
            return .ok()
        case "missing":
            return await MainActor.run {
                guard pages.count > 1, let page = pages.first(where: { $0.windowId == window }), let closeWindow else {
                    return .ok(["closed": false])
                }
                closeWindow(page)
                return .ok(["closed": true])
            }
        default:
            return .failure(404, "没有这个窗口动作：window/\(action)")
        }
    }

    // MARK: - 写作手册

    /// 页面经原生桥 `manuals/<动作>` 要的写作手册的事（见 WritingManuals.swift；文件夹不在时先用示例建好）：
    /// - list：`{ manuals: [{ name, description }], folder }`
    /// - read `{ name }`：`{ name, description, content }`（content 是正文，不含开头的 name / description）
    /// - save `{ name, description, content }`：新建或整份换掉（页面先问过用户），`{ name, description }`；名字、说明、正文不合规矩时 400 带原因
    /// - reveal `{ name? }`：在 Finder 里显示这份；没给 name 时打开文件夹
    /// - open `{ name }`：用默认的 App 打开这份
    nonisolated func manualAction(_ action: String, _ request: [String: Any]) async -> NativeBridge.Reply {
        let manuals = writingManuals
        let name = request["name"] as? String ?? ""
        do {
            switch action {
            case "list":
                let list = try manuals.list()
                return .ok(["manuals": list.map { ["name": $0.name, "description": $0.description] }, "folder": manuals.folder.path])
            case "read":
                let (manual, body) = try manuals.read(name)
                return .ok(["name": manual.name, "description": manual.description, "content": body])
            case "save":
                let saved = try manuals.save(
                    name: name, description: request["description"] as? String ?? "", body: request["content"] as? String ?? ""
                )
                return .ok(["name": saved.name, "description": saved.description])
            case "reveal":
                let target: URL
                if name.isEmpty {
                    try manuals.ensure()
                    target = manuals.folder
                } else {
                    target = try manuals.read(name).manual.file
                }
                await MainActor.run { revealFile(target) }
                return .ok()
            case "open":
                let file = try manuals.read(name).manual.file
                await MainActor.run { openFile(file) }
                return .ok()
            default:
                return .failure(404, "没有这个写作手册动作：manuals/\(action)")
            }
        } catch let failure as WritingManuals.Failure {
            return .failure(failure.status, failure.message)
        } catch {
            return .failure(500, "写作手册：\(error.localizedDescription)")
        }
    }

    // MARK: - 模板

    /// 页面经原生桥 `templates/<动作>` 要的用户模板的事（见 TemplateLibrary.swift；文件的格式页面自己读写）：
    /// - list：`{ templates: [{ name, content }], folder }`（content 是 模板.md 全文，按名字的拼音排）
    /// - read `{ name }`：`{ name, content, images: { 文件名: data URL } }`
    /// - save `{ name, content, images: [{ name, data }] }`（data 是 base64）：新建或整套换掉，`{ name, folder }`；名字、图片不合规矩时 400 带原因
    /// - remove `{ name }`：删掉那一套；没有时 404
    /// - reveal `{ name? }`：在 Finder 里显示那一套的文件夹；没给 name 时打开模板文件夹
    nonisolated func templateAction(_ action: String, _ request: [String: Any]) async -> NativeBridge.Reply {
        let templates = templates
        let name = request["name"] as? String ?? ""
        do {
            switch action {
            case "list":
                let list = try templates.list()
                return .ok(["templates": list.map { ["name": $0.name, "content": $0.content] }, "folder": templates.folder.path])
            case "read":
                let (template, images) = try templates.read(name)
                return .ok(["name": template.name, "content": template.content, "images": images])
            case "save":
                let images = try (request["images"] as? [[String: Any]] ?? []).map { item -> TemplateLibrary.Image in
                    let file = item["name"] as? String ?? ""
                    guard let data = Data(base64Encoded: item["data"] as? String ?? "") else { throw TemplateLibrary.Failure("图片的内容不是 base64：\(file)") }
                    return TemplateLibrary.Image(name: file, data: data)
                }
                let saved = try templates.save(name: name, content: request["content"] as? String ?? "", images: images)
                return .ok(["name": saved.name, "folder": saved.folder.path])
            case "remove":
                try templates.remove(name)
                return .ok()
            case "reveal":
                let target = try templates.location(of: name.isEmpty ? nil : name)
                await MainActor.run { revealFile(target) }
                return .ok()
            default:
                return .failure(404, "没有这个模板动作：templates/\(action)")
            }
        } catch let failure as TemplateLibrary.Failure {
            return .failure(failure.status, failure.message)
        } catch {
            return .failure(500, "模板：\(error.localizedDescription)")
        }
    }

    /// App 退出前调用：结束所有 AI 会话的进程，之后不再往页面推事件、不再接外部 Agent。
    /// 不阻塞主线程；进程都退出后（最多约 1.5 秒）在主线程调 completion。
    public func shutdown(completion: @escaping @MainActor @Sendable () -> Void = {}) {
        aiSessions.setSink(nil)
        livePhotos.setSink(nil)
        externalAgents.setSink(nil)
        externalAgents.setPage(nil)
        externalAgents.stop()
        aiSessions.terminate { MainActor.assumeIsolated { completion() } }
    }
}
