import Foundation

/// `mediacraft-mcp` 到正在运行的 MediaCraft 的连接：Unix 域套接字，每行一条 JSON。
/// 连上后 App 先回一行：`{ "ready": true }`，或拒绝的原因 `{ "error": "…" }`（没有打开「允许外部 Agent 连接」、不是同一个用户）后断开。
/// 之后发 `{ id, session, method, params }`，App 回 `{ id, result }` 或 `{ id, error }`；App 要断开时先发一行 `{ "error": "…" }` 说明原因。
/// 连不上（App 没开）时先打开 App（`launch`），再等它的套接字出现，最多等 `launchTimeout`。
/// 只在一个线程里用（MCP 服务的调用队列）。
public final class AppLink: @unchecked Sendable {
    /// 一次调用最多等这么久（导出很多实况也够用）；过了就断开，免得一直挂着
    private static let callTimeout = 600
    /// 这个 MCP 服务进程（一次 Agent 会话）的编号：每个请求都带上，App 按它记这次会话在改哪篇稿子，重连后不变
    private let session = UUID().uuidString
    private let socketPath: String
    private let launchTimeout: Duration
    private let launch: @Sendable () throws -> Void
    private var channel: LineChannel?
    private var nextId = 0

    public init(socketPath: String, launchTimeout: Duration = .seconds(20), launch: @escaping @Sendable () throws -> Void) {
        self.socketPath = socketPath
        self.launchTimeout = launchTimeout
        self.launch = launch
    }

    /// 握手时要操作手册（manual/get）：App 没在运行、没打开外部连接时不为它把 App 打开，也最多等这么久
    private static let peekTimeout = 5

    /// 和 call 一样，但 App 没在运行时不打开它、连不上或出错时返回 nil，最多等几秒（握手时取操作手册用）
    public func callIfRunning(method: String, params: [String: Any]) -> [String: Any]? {
        guard let channel = try? connected(launching: false) else { return nil }
        channel.setReadTimeout(Self.peekTimeout)
        defer { channel.setReadTimeout(Self.callTimeout) }
        return try? call(method: method, params: params)
    }

    /// 交给 App 执行一个请求（tools/list、tools/call），返回 App 的结果。
    public func call(method: String, params: [String: Any]) throws -> [String: Any] {
        let channel = try connected()
        nextId += 1
        let id = nextId
        do {
            try channel.send(["id": id, "session": session, "method": method, "params": params])
        } catch {
            close()
            throw MCPFailure("和 Vibepost 的连接断了，这次调用没有送到：\(error.localizedDescription)")
        }
        while let reply = channel.readObject() {
            guard let replyId = reply["id"] as? Int else {
                if let notice = reply["error"] as? String {
                    close()
                    throw MCPFailure(notice)
                }
                continue
            }
            guard replyId == id else { continue }
            if let error = reply["error"] as? String { throw MCPFailure(error) }
            return reply["result"] as? [String: Any] ?? [:]
        }
        close()
        throw MCPFailure(
            "Vibepost 在处理这次调用时断开了连接（App 退出、重新载入），或者 \(Self.callTimeout / 60) 分钟都没有回答；这次调用可能没有完成"
        )
    }

    public func close() {
        channel?.close()
        channel = nil
    }

    /// 现在能用的连接：上次的还连着、没有动静就用它；App 断开过（退出、重新打开、关掉了外部连接）就重连一次，
    /// 由重连的结果说明现在的情况；连不上就打开 App 再等。
    private func connected(launching: Bool = true) throws -> LineChannel {
        if let channel, !channel.hasActivity() { return channel }
        close()
        let descriptor: Int32
        if let existing = try? UnixSocket.connect(to: socketPath) {
            descriptor = existing
        } else {
            guard launching else { throw MCPFailure("Vibepost 没有在运行") }
            try launch()
            descriptor = try waitForApp()
        }
        let channel = LineChannel(descriptor: descriptor)
        // App 接连接不在主线程，正常马上就回；10 秒都没回就算没准备好
        channel.setReadTimeout(10)
        let greeting = channel.readObject()
        channel.setReadTimeout(Self.callTimeout)
        if let refusal = greeting?["error"] as? String {
            channel.close()
            throw MCPFailure(refusal)
        }
        guard greeting?["ready"] as? Bool == true else {
            channel.close()
            throw MCPFailure("Vibepost 没有回应连接，稍后再试")
        }
        self.channel = channel
        return channel
    }

    private func waitForApp() throws -> Int32 {
        let deadline = ContinuousClock.now + launchTimeout
        while ContinuousClock.now < deadline {
            if let descriptor = try? UnixSocket.connect(to: socketPath) { return descriptor }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw MCPFailure(
            "已经打开 Vibepost，但它没有在 \(launchTimeout.components.seconds) 秒内准备好外部 Agent 的连接（\(socketPath)）。"
                + "确认装的是带 MCP 的版本，再试一次"
        )
    }
}
