import Foundation

/// MediaCraft 的 MCP 服务（stdio）。终端里的 Claude Code 等 Agent 启动 `mediacraft-mcp`，经 stdin / stdout 收发 JSON-RPC 2.0，每行一条。
/// 协议版本两代都认：握手式的旧版本（先 `initialize`，2025-11-25 及以前）与现行的逐请求声明版本（`_meta` 里的
/// `io.modelcontextprotocol/protocolVersion`，2026-07-28，可以先 `server/discover`）。
/// 握手、`server/discover` 与 `ping` 在这里回答；工具清单与调用（`tools/list`、`tools/call`）经 `AppLink` 交给正在运行的 MediaCraft
/// 执行（页面里的 window.MediaCraftMCP），一次一个，按收到的顺序。
public final class MCPServer: @unchecked Sendable {
    public static let currentVersion = "2026-07-28"
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let supportedVersions = [currentVersion] + legacyVersions
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let serverInfo: [String: Any] = ["name": "mediacraft", "title": "Vibepost", "version": "1"]
    static let instructions = """
        MediaCraft 是用户这台 Mac 上的排版 App：把 Markdown 排成小红书图文卡片（3:4，每页 864 × 1152）或长文长图，再隔空投送到 iPhone。\
        工具操作的是 App 里正在编辑的那篇稿子，改动马上出现在用户眼前，每一步都能 ⌘Z 撤销、也列在 AI 助手的「外部 Agent 的操作」里。\
        一般流程：create_draft（或 list_drafts + open_draft）→ update_draft 写正文与标题 → set_theme / set_style 挑样式 → \
        render_pages 看每页的图、按需 insert_page_break / move_section 调分页 → export 导出或 send_to_iphone（会在 App 里弹出隔空投送，由用户选设备）。\
        正文是 Markdown，另有自定义标记：[[image:图片编号]]、[[分页]]、{{color:#色值|文字}}、{{bg:#色值|文字}}。内置说明书只读，先新建稿子再改。
        """

    private let link: AppLink
    private let output: LineChannel
    /// 交给 App 的调用排队依次执行，读 stdin 不被它们挡住（ping、取消照常处理）
    private let calls = DispatchQueue(label: "mediacraft-mcp.calls")
    private let lock = NSLock()
    /// 排着或正在执行的调用；客户端取消了其中的：还没执行的不执行，执行完的不再回答
    private var pending: Set<String> = []
    private var cancelled: Set<String> = []

    public init(link: AppLink, output: LineChannel) {
        self.link = link
        self.output = output
    }

    /// 读 input 直到结尾（客户端关掉 stdin），等已经收下的调用做完（回答照常写出），再断开与 App 的连接。
    public func run(input: LineChannel) {
        while let line = input.readLine() {
            receive(line)
        }
        calls.sync { link.close() }
    }

    private func receive(_ line: Data) {
        guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { return }
        guard let parsed = try? JSONSerialization.jsonObject(with: line) else {
            send(Self.error(NSNull(), code: -32700, "Parse error：不是 JSON"))
            return
        }
        guard let message = parsed as? [String: Any] else {
            send(Self.error(NSNull(), code: -32600, "Invalid Request：一行一条消息，不支持批量请求"))
            return
        }
        // 没有 method 的是客户端的回答（这个服务不发请求），不理
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = message["id"], !(id is NSNull) else {
            if method == "notifications/cancelled", let request = params["requestId"] {
                let key = Self.key(request)
                lock.withLock {
                    if pending.contains(key) { cancelled.insert(key) }
                }
            }
            return
        }
        let requested = (params["_meta"] as? [String: Any])?[Self.versionKey] as? String
        if let requested, !Self.supportedVersions.contains(requested) {
            send(Self.error(id, code: -32022, "Unsupported protocol version", data: [
                "supported": Self.supportedVersions, "requested": requested,
            ]))
            return
        }
        let modern = requested != nil
        switch method {
        case "initialize":
            send(Self.result(id, initialize(params)))
        case "server/discover":
            send(Self.result(id, Self.complete([
                "supportedVersions": Self.supportedVersions,
                "capabilities": ["tools": [:]],
                "_meta": ["io.modelcontextprotocol/serverInfo": Self.serverInfo],
                "instructions": Self.instructions,
            ])))
        case "ping":
            send(Self.result(id, modern ? Self.complete([:]) : [:]))
        case "tools/list", "tools/call":
            var forwarded = params
            forwarded["_meta"] = nil
            _ = lock.withLock { pending.insert(Self.key(id)) }
            calls.async { self.forward(id: id, method: method, params: forwarded, modern: modern) }
        default:
            send(Self.error(id, code: -32601, "Method not found：Vibepost 不支持 \(method)"))
        }
    }

    /// 握手：客户端要的旧版本认得就用它，否则回最新的旧版本（客户端不认时自己断开）
    private func initialize(_ params: [String: Any]) -> [String: Any] {
        let wanted = params["protocolVersion"] as? String ?? ""
        return [
            "protocolVersion": Self.legacyVersions.contains(wanted) ? wanted : Self.legacyVersions[0],
            "capabilities": ["tools": [:]],
            "serverInfo": Self.serverInfo,
            "instructions": Self.instructions,
        ]
    }

    private func forward(id: Any, method: String, params: [String: Any], modern: Bool) {
        let key = Self.key(id)
        defer {
            lock.withLock {
                pending.remove(key)
                cancelled.remove(key)
            }
        }
        guard !isCancelled(key) else { return }
        var reply: [String: Any]
        do {
            let result = try link.call(method: method, params: params)
            reply = Self.result(id, modern ? Self.complete(result) : result)
        } catch {
            let message = error.localizedDescription
            // 工具执行不了（App 打不开、关掉了外部连接……）按工具的错误回给模型，它能看到原因；清单拿不到是协议错误
            if method == "tools/call" {
                let failed: [String: Any] = ["content": [["type": "text", "text": message]], "isError": true]
                reply = Self.result(id, modern ? Self.complete(failed) : failed)
            } else {
                reply = Self.error(id, code: -32603, message)
            }
        }
        guard !isCancelled(key) else { return }
        send(reply)
    }

    private func isCancelled(_ key: String) -> Bool {
        lock.withLock { cancelled.contains(key) }
    }

    /// 回答写不进 stdout 时客户端已经走了，它随后会关掉 stdin，run 随之结束
    private func send(_ message: [String: Any]) {
        try? output.send(message)
    }

    private static func key(_ id: Any) -> String {
        if let number = id as? NSNumber { return "n:\(number.stringValue)" }
        return "s:\(id)"
    }

    private static func complete(_ result: [String: Any]) -> [String: Any] {
        result.merging(["resultType": "complete"]) { $1 }
    }

    private static func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(_ id: Any, code: Int, _ message: String, data: [String: Any]? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": error]
    }
}
