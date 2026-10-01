import Foundation
import ImageIO
import MediaCraftMCP
@testable import MediaCraftShell

/// 测试里的 MCP 客户端：经两根管道对着 mediacraft-mcp 的核心（`MCPServer`，可执行文件里跑的就是它）说 JSON-RPC，
/// 核心再经真的 Unix 域套接字连到 ShellHarness 里的 App。App 没开时核心调 `launch`（测试里默认说打不开）。
final class MCPTestClient: @unchecked Sendable {
    /// 一次工具调用的结果：文字、图片（PNG 的字节）、是不是出错
    struct ToolResult {
        var text: String
        var images: [Data]
        var isError: Bool
        var json: Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
    }

    private let toServer = Pipe()
    private let fromServer = Pipe()
    private let lock = NSLock()
    private var responses: [Int: [String: Any]] = [:]
    /// id 为 null 的回答（解析不了、不收的请求）
    private var unaddressed: [[String: Any]] = []
    private var nextId = 0

    init(
        socketPath: String, launchTimeout: Duration = .seconds(2),
        launch: @escaping @Sendable () throws -> Void = { throw MCPFailure("测试里不打开 App") }
    ) {
        let server = MCPServer(
            link: AppLink(socketPath: socketPath, launchTimeout: launchTimeout, launch: launch),
            output: LineChannel(descriptor: fromServer.fileHandleForWriting.fileDescriptor)
        )
        let input = LineChannel(descriptor: toServer.fileHandleForReading.fileDescriptor)
        Thread { server.run(input: input) }.start()
        let output = LineChannel(descriptor: fromServer.fileHandleForReading.fileDescriptor)
        Thread { [weak self] in
            while let message = output.readObject() {
                self?.lock.withLock {
                    if let id = message["id"] as? Int { self?.responses[id] = message } else { self?.unaddressed.append(message) }
                }
            }
        }.start()
    }

    /// 发一个请求，等它的回答（整条 JSON-RPC 消息）
    func request(_ method: String, _ params: [String: Any] = [:], timeout: Duration = .seconds(60)) async throws -> [String: Any] {
        let id = lock.withLock { () -> Int in
            nextId += 1
            return nextId
        }
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = ContinuousClock.now + timeout
        while true {
            if let response = lock.withLock({ responses.removeValue(forKey: id) }) { return response }
            guard ContinuousClock.now < deadline else { throw MCPFailure("\(method) 没有在限定时间内回答") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func send(_ message: [String: Any]) throws {
        try toServer.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data("\n".utf8))
    }

    /// 原样写一行（测不合规的消息）
    func sendRaw(_ line: String) throws {
        try toServer.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// 下一个 id 为 null 的回答
    func unaddressedResponse(timeout: Duration = .seconds(10)) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let response = lock.withLock({ unaddressed.isEmpty ? nil : unaddressed.removeFirst() }) { return response }
            guard ContinuousClock.now < deadline else { throw MCPFailure("没有等到 id 为 null 的回答") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 旧版握手：initialize + notifications/initialized
    func initialize() async throws -> [String: Any] {
        let response = try await request("initialize", [
            "protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "测试", "version": "1"],
        ])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return response["result"] as? [String: Any] ?? [:]
    }

    func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> ToolResult {
        let response = try await request("tools/call", ["name": tool, "arguments": arguments])
        let result = response["result"] as? [String: Any] ?? [:]
        let content = result["content"] as? [[String: Any]] ?? []
        return ToolResult(
            text: content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n"),
            images: content.filter { $0["type"] as? String == "image" && $0["mimeType"] as? String == "image/png" }
                .compactMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } },
            isError: result["isError"] as? Bool ?? false
        )
    }

    /// 关掉 stdin：核心随之断开与 App 的连接
    func close() {
        try? toServer.fileHandleForWriting.close()
    }

    /// PNG 的像素宽
    static func pixelWidth(_ png: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyPixelWidth] as? Int
    }
}

extension MCPConfiguration {
    /// 测试用：放在一个短路径的临时目录里（套接字路径不能超过 104 字节）。allowExternalAgents 写进 mcp.json，
    /// 默认当作用户已经打开了「允许外部 Agent 连接」；nil 时没有 mcp.json（刚装好的 App，默认关）
    static func temporary(peerUserID: uid_t = getuid(), allowExternalAgents: Bool? = true) -> MCPConfiguration {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mc-\(UUID().uuidString.prefix(8))")
        let config = MCPConfiguration(directory: directory, peerUserID: peerUserID, serverPath: "/Applications/MediaCraft.app/Contents/MacOS/mediacraft-mcp")
        if let allowExternalAgents {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: ["allowExternalAgents": allowExternalAgents]).write(to: config.settingsFile)
        }
        return config
    }
}
