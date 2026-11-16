import Foundation
import MediaCraftMCP

/// 这一轮给说 ACP 的 Agent 挂的 MCP 服务（App 的工具）。
/// Claude Code 经控制通道、Codex 经动态工具拿到 App 的工具，都不另起进程；说 ACP 的 Agent 只认「开会话时挂上的 MCP 服务」
/// （`session/new` 的 `mcpServers`）。所以每一轮在一个只有本人进得去的临时目录里开一个 Unix 域套接字，
/// 让 Agent 用系统自带的 `/usr/bin/nc -U <套接字>` 当它的 stdio MCP 服务：nc 把它的 stdin / stdout 和套接字接在一起，
/// MCP 的消息（每行一条 JSON-RPC）就到了这里。壳不解读消息：原样推给页面（和后端的输出行走同一条路），
/// 页面里的工具（src/ai/tools.js 的 `handle`）回答，经 `ai/respond` 送回来、写回套接字。
/// 套接字只活这一轮：进程退出就关掉、删掉；路径是随机的，文件只有本人可读写。
final class AIToolServer: @unchecked Sendable {
    /// Agent 那边这组工具叫什么（和 Claude Code 里的一样）
    static let name = "mediacraft"
    /// 页面收到的一行的 method：`{ method, params: { connection, message } }`
    static let method = "vibepost/mcp"

    let path: String
    private let directory: URL
    private let lock = NSLock()
    private var listener: DispatchSourceRead?
    private var connections: [Int: LineChannel] = [:]
    private var nextConnection = 0
    private var closed = false
    /// 收到 Agent 的一条 MCP 消息：哪个连接、消息本身
    private let receive: @Sendable (Int, [String: Any]) -> Void

    init(receive: @escaping @Sendable (Int, [String: Any]) -> Void) throws {
        self.receive = receive
        // 套接字路径最长一百来个字符：放在系统的临时目录里（比 App 支持目录短），目录只有本人进得去
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibepost-tools-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("\(UUID().uuidString.prefix(12).lowercased()).sock").path
        let descriptor = try UnixSocket.listen(at: path)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "com.wuyoscar.mediacraft.ai.tools"))
        source.setEventHandler { [weak self] in
            while let client = UnixSocket.accept(descriptor) { self?.accept(client) }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        listener = source
        source.resume()
    }

    /// `session/new` 的 `mcpServers` 里的一项（stdio 的 MCP 服务）：nc 把 Agent 的 stdio 接到这一轮的套接字上
    static func entry(socket: String) -> [String: Any] {
        ["name": name, "command": "/usr/bin/nc", "args": ["-U", socket], "env": [Any]()]
    }

    private func accept(_ descriptor: Int32) {
        let channel = LineChannel(descriptor: descriptor)
        // 只接本人的进程（套接字文件本来也只有本人连得上）
        let id = lock.withLock { () -> Int? in
            guard !closed, UnixSocket.peerUserID(descriptor) == getuid() else { return nil }
            nextConnection += 1
            connections[nextConnection] = channel
            return nextConnection
        }
        guard let id else { return channel.close() }
        let reader = Thread { [weak self] in
            while let message = channel.readObject() { self?.receive(id, message) }
            self?.lock.withLock { _ = self?.connections.removeValue(forKey: id) }
            channel.close()
        }
        reader.name = "mediacraft.ai.tools"
        reader.start()
    }

    /// 页面的回答写回那个连接；连接已经没了时为 false
    func send(_ message: [String: Any], to connection: Int) -> Bool {
        guard let channel = lock.withLock({ connections[connection] }) else { return false }
        return (try? channel.send(message)) != nil
    }

    /// 这一轮结束：不再接连接，断开已有的，删掉套接字文件
    func close() {
        let (source, open) = lock.withLock { () -> (DispatchSourceRead?, [LineChannel]) in
            defer {
                listener = nil
                closed = true
            }
            return (listener, Array(connections.values))
        }
        source?.cancel()
        open.forEach { $0.shutdown() }
        unlink(path)
        // 目录里没有别的轮的套接字了就一起删（删不掉说明还有，留着）
        rmdir(directory.path)
    }
}
