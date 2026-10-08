import Foundation
import MediaCraftMCP

/// 外部 Agent（MCP）的连接设置。
public struct MCPConfiguration: Sendable {
    /// 套接字 `mcp.sock` 与设置 `mcp.json`（「允许外部 Agent 连接」开没开）放在这里
    public var directory: URL
    /// 只让这个用户的进程连进来（getpeereid）
    public var peerUserID: uid_t
    /// `mediacraft-mcp` 的完整路径，「复制接入命令」里用
    public var serverPath: String

    public init(directory: URL, peerUserID: uid_t = getuid(), serverPath: String) {
        self.directory = directory
        self.peerUserID = peerUserID
        self.serverPath = serverPath
    }

    /// `~/Library/Application Support/MediaCraft/mcp.sock`；MCP 服务就在 App 可执行文件旁边（MediaCraft.app/Contents/MacOS/）
    public static var standard: MCPConfiguration {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return MCPConfiguration(
            directory: MCPPaths.supportDirectory,
            serverPath: executable.deletingLastPathComponent().appendingPathComponent(MCPPaths.serverName).path
        )
    }

    var socketPath: String { directory.appendingPathComponent(MCPPaths.socketName).path }
    var settingsFile: URL { directory.appendingPathComponent("mcp.json") }
}

/// 外部 Agent 的连接：终端里的 Claude Code 等启动的 `mediacraft-mcp` 经 Unix 域套接字连进来（协议见 `AppLink`），
/// 工具清单与调用交给页面执行（`window.MediaCraftMCP`，只经 App API），一个连接上的请求按顺序一个个做。
/// 安全：套接字文件 0600，连进来的进程必须是同一个用户（getpeereid）；「允许外部 Agent 连接」关掉时拒绝新连接、断开已有的。
/// 本机文件只由这里碰：插图（import_images）时按 Agent 给的路径读图、校验后把内容交给页面；导出（export）时 Agent 给的目录先校验，
/// 页面做好的文件经 `mcp/write` 交回来，只能写进这一次调用登记的目录，同名不覆盖（除非 overwrite）。
final class ExternalAgents: @unchecked Sendable {
    /// 推给页面的事件（JSON 文本），由 ShellWebView 转成页面里的 `mediacraft:native-mcp` 事件
    typealias Sink = @Sendable (String) -> Void
    /// 把一条请求（JSON 文本）交给页面，返回页面的回答（JSON 文本）
    typealias Page = @Sendable (String) async throws -> String

    private static let refusedDisabled = "Vibepost 里没有打开「允许外部 Agent 连接」（AI 助手 › 设置，默认是关的）。请用户打开后再试"
    private static let refusedUser = "只允许这台 Mac 上的当前用户连接 Vibepost"
    private static let refusedStopped = "Vibepost 正在关闭"
    private static let imageLimit = 20
    /// 一次插图读进来的图片一共最多这么大（base64 之后整个交给页面）
    private static let importByteLimit = 60 * 1024 * 1024

    private struct ExportTarget {
        let directory: URL
        let overwrite: Bool
    }

    private let configuration: MCPConfiguration?
    private let lock = NSLock()
    private var enabled: Bool
    private var listener: DispatchSourceRead?
    /// 自己建的套接字文件：退出时只删它（另一个 MediaCraft 之后建的不动）
    private var socketInode: ino_t?
    private var clients: [Int: LineChannel] = [:]
    private var nextClient = 0
    private var exports: [String: ExportTarget] = [:]
    private var sink: Sink?
    private var page: Page?

    /// configuration 为 nil 时不监听（测试的默认，浏览器里也没有这些）
    init(configuration: MCPConfiguration?) {
        self.configuration = configuration
        // 没打开过「允许外部 Agent 连接」时是关的：本机任何进程都能连这个套接字，要用户自己打开
        enabled = configuration.flatMap(Self.readEnabled) ?? false
    }

    func setSink(_ sink: Sink?) {
        lock.withLock { self.sink = sink }
    }

    func setPage(_ page: Page?) {
        lock.withLock { self.page = page }
    }

    // MARK: - 监听

    /// 开始监听；套接字建不起来时外部 Agent 连不上，App 照常用（状态里 available 为 false）
    func start() {
        guard let configuration, lock.withLock({ listener == nil }) else { return }
        do {
            try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
            let descriptor = try UnixSocket.listen(at: configuration.socketPath)
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "mediacraft.mcp.accept"))
            source.setEventHandler { [weak self] in
                while let client = UnixSocket.accept(descriptor) { self?.accept(client) }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            lock.withLock {
                listener = source
                socketInode = UnixSocket.inode(at: configuration.socketPath)
            }
            source.resume()
        } catch {
            shellLog.error("MCP 套接字没建起来：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 停止监听、断开所有连接、删掉套接字文件（窗口关闭、App 退出时）
    func stop() {
        let (source, inode, open) = lock.withLock { () -> (DispatchSourceRead?, ino_t?, [LineChannel]) in
            defer {
                listener = nil
                socketInode = nil
            }
            return (listener, socketInode, Array(clients.values))
        }
        source?.cancel()
        open.forEach { $0.shutdown() }
        if let inode, let configuration, UnixSocket.inode(at: configuration.socketPath) == inode {
            unlink(configuration.socketPath)
        }
    }

    private var listening: Bool { lock.withLock { listener != nil } }

    private func accept(_ descriptor: Int32) {
        let channel = LineChannel(descriptor: descriptor)
        let sameUser = UnixSocket.peerUserID(descriptor) == configuration?.peerUserID
        // 查开关与登记在同一次加锁里：关开关、停止监听时不会漏掉正在接进来的连接
        let (id, refusal) = lock.withLock { () -> (Int, String?) in
            guard sameUser else { return (0, Self.refusedUser) }
            guard listener != nil else { return (0, Self.refusedStopped) }
            guard enabled else { return (0, Self.refusedDisabled) }
            nextClient += 1
            clients[nextClient] = channel
            return (nextClient, nil)
        }
        if let refusal {
            try? channel.send(["error": refusal])
            channel.close()
            return
        }
        try? channel.send(["ready": true])
        announceClients()
        // 读在自己的线程里（阻塞读），请求交给一个任务按顺序做；断开（对方走了、关掉了开关）后收尾
        let (lines, feed) = AsyncStream<Data>.makeStream()
        let reader = Thread {
            while let line = channel.readLine() { feed.yield(line) }
            feed.finish()
        }
        reader.name = "mediacraft.mcp.client"
        reader.start()
        Task {
            for await line in lines {
                let reply = await self.respond(to: line)
                try? channel.send(reply)
            }
            lock.withLock { _ = clients.removeValue(forKey: id) }
            channel.close()
            announceClients()
        }
    }

    private func announceClients() {
        let (sink, count) = lock.withLock { (self.sink, self.clients.count) }
        sink?(Self.json(["type": "clients", "count": count]))
    }

    // MARK: - 请求

    /// session 是 mediacraft-mcp 这次会话的编号（重连不变），页面按它记这次会话在改哪篇稿子
    private func respond(to line: Data) async -> [String: Any] {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = request["id"], let method = request["method"] as? String, let session = request["session"] as? String
        else { return ["error": "请求的格式不对"] }
        // manual/get：握手时 MCP 服务要操作手册（页面从 src/engine/manual.js 写出）
        guard ["tools/list", "tools/call", "manual/get"].contains(method) else { return ["id": id, "error": "Vibepost 不支持 \(method)"] }
        let params = request["params"] as? [String: Any] ?? [:]
        var message: [String: Any] = ["session": session, "method": method, "params": params]
        var exportRequest: String?
        defer {
            if let exportRequest { lock.withLock { _ = exports.removeValue(forKey: exportRequest) } }
        }
        if method == "tools/call" {
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                switch params["name"] as? String {
                case "import_images":
                    message["files"] = try images(arguments["paths"])
                case "export":
                    let token = UUID().uuidString
                    let target = ExportTarget(directory: try directory(arguments["directory"]), overwrite: arguments["overwrite"] as? Bool ?? false)
                    lock.withLock { exports[token] = target }
                    exportRequest = token
                    message["exportRequest"] = token
                default:
                    break
                }
            } catch {
                return ["id": id, "result": ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]]
            }
        }
        do {
            guard let page = lock.withLock({ page }) else { throw MCPFailure("Vibepost 的页面还没准备好") }
            let answer = try await page(Self.json(message))
            guard let reply = try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any] else {
                throw MCPFailure("页面的回答不对")
            }
            if let error = reply["error"] as? String { return ["id": id, "error": error] }
            return ["id": id, "result": reply["result"] ?? [:]]
        } catch {
            return ["id": id, "error": "Vibepost 没能完成这次调用：\(error.localizedDescription)"]
        }
    }

    /// 插图：每个路径都要是绝对路径（`~` 可用）、存在的图片文件，读进来校验（与配图候选同样的上限），把内容交给页面；
    /// 一次一共不超过 60 MB
    private func images(_ value: Any?) throws -> [[String: Any]] {
        guard let paths = value as? [String], !paths.isEmpty else { throw MCPFailure("paths 要给一个或几个图片文件的绝对路径") }
        guard paths.count <= Self.imageLimit else { throw MCPFailure("一次最多插 \(Self.imageLimit) 张图") }
        var total = 0
        return try paths.map { path in
            let file = try Self.absolute(path, what: "图片")
            let (data, name) = try AICandidates.readLocal(file, source: path)
            let image = try AICandidates.prepare(data, name: name)
            total += image.bytes.count
            guard total <= Self.importByteLimit else { throw MCPFailure("这批图片一共超过 60 MB，分几次插") }
            return ["path": file.path, "name": name, "type": image.mimeType, "data": image.bytes.base64EncodedString()]
        }
    }

    /// 导出的目录：绝对路径（`~` 可用）、已经存在、写得进去
    private func directory(_ value: Any?) throws -> URL {
        guard let path = value as? String, !path.isEmpty else { throw MCPFailure("directory 要给一个已经存在的文件夹的绝对路径") }
        let folder = try Self.absolute(path, what: "文件夹")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MCPFailure("没有这个文件夹：\(path)（要先建好）")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw MCPFailure("这个文件夹写不进去：\(path)") }
        return folder
    }

    private static func absolute(_ path: String, what: String) throws -> URL {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw MCPFailure("\(what)要给绝对路径：\(path)") }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - 页面 → 壳（原生桥 mcp/*）

    func handle(action: String, query: [String: String], body: Data) -> NativeBridge.Reply {
        switch action {
        case "status":
            return .ok(status())
        case "settings":
            guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let enabled = request["enabled"] as? Bool
            else { return .failure(400, "要给 enabled") }
            do {
                try setEnabled(enabled)
                return .ok(status())
            } catch {
                return .failure(500, "设置没能保存：\(error.localizedDescription)")
            }
        case "write":
            return write(request: query["request"] ?? "", name: query["name"] ?? "", data: body)
        default:
            return .failure(404, "没有这个动作：mcp/\(action)")
        }
    }

    private func status() -> [String: Any] {
        let (enabled, count) = lock.withLock { (self.enabled, self.clients.count) }
        return [
            "available": listening,
            "enabled": enabled,
            "clients": count,
            "command": configuration.map { "claude mcp add mediacraft -- \"\($0.serverPath)\"" } ?? NSNull(),
        ]
    }

    /// 开关存进 mcp.json；关掉时断开已有的连接（先告诉对方为什么）
    private func setEnabled(_ value: Bool) throws {
        guard let configuration else { throw MCPFailure("这里没有外部 Agent 的连接") }
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["allowExternalAgents": value]).write(to: configuration.settingsFile, options: .atomic)
        let open = lock.withLock { () -> [LineChannel] in
            enabled = value
            return value ? [] : Array(clients.values)
        }
        for channel in open {
            try? channel.send(["error": Self.refusedDisabled])
            channel.shutdown()
        }
    }

    private static func readEnabled(_ configuration: MCPConfiguration) -> Bool? {
        guard let data = try? Data(contentsOf: configuration.settingsFile),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return settings["allowExternalAgents"] as? Bool
    }

    /// 导出时页面把做好的文件交回来：只能写进这次调用登记的目录；已有同名文件时不覆盖（除非 Agent 给了 overwrite）
    private func write(request: String, name: String, data: Data) -> NativeBridge.Reply {
        guard let target = lock.withLock({ exports[request] }) else { return .failure(403, "这次导出不是外部 Agent 发起的，或者已经结束了") }
        let safeName = (name as NSString).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else { return .failure(400, "文件名不对：\(name)") }
        let destination = target.directory.appendingPathComponent(safeName)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard target.overwrite, !isDirectory.boolValue else {
                return .failure(409, "\(destination.path) 已经有了；要覆盖就给 overwrite: true，或者换一个文件夹")
            }
        }
        do {
            try data.write(to: destination, options: .atomic)
            return .ok(["path": destination.path, "name": safeName])
        } catch {
            return .failure(500, "没能写进 \(destination.path)：\(error.localizedDescription)")
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
