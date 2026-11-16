import Foundation

/// 说 ACP（Agent Client Protocol）的本机 Agent：`<程序> acp`，stdio 上的 JSON-RPC（每行一条），在这篇稿子的工作副本目录里运行。
/// 一个实现管几个程序（OpenCode、Oh My Pi、Kimi Code），各自只差程序名、子命令与另加的环境变量。
/// 壳只写开头的 initialize（说明这边不提供读写文件、终端：它用自己的工具）；开会话或续会话、换模型与推理强度、发这一轮、
/// 回答它的权限请求，都由页面的适配器（src/ai/backends/acp.js）写好经 `ai/respond` 送进来，壳只放行这几种，
/// 会话的工作目录由壳定、不给它挂 MCP 服务。收到这一轮 session/prompt 的回答就是说完了：关上 stdin，它读到 EOF 就退出。
struct ACPBackend: AIBackend {
    let id: String
    /// 起 ACP 服务的参数（都是 `acp`）
    var command = ["acp"]
    let environment: [String: String]

    /// OpenCode 默认什么都不问（命令也直接跑）：改成工作副本里的文件可以改，运行命令、联网、目录外的读写先问（经 ACP 的权限请求问页面）
    static let opencode = ACPBackend(id: "opencode", environment: [
        "OPENCODE_PERMISSION": #"{"edit":"allow","bash":"ask","webfetch":"ask","external_directory":"ask"}"#,
    ])
    /// Oh My Pi 的 ACP 模式本来就是改文件不问、运行命令先问
    static let omp = ACPBackend(id: "omp", environment: [:])
    static let kimi = ACPBackend(id: "kimi", environment: [:])

    /// 握手的请求 id（页面的适配器从 2 起用）
    static let initializeId = 1
    /// 页面能发的请求
    static let requests: Set<String> = ["session/new", "session/resume", "session/load", "session/set_config_option", "session/prompt"]
    /// 推给页面的会话更新：流式的回复、工具调用；别的（思考、可用的命令、会话设置的更新、用量……）页面用不上，有的一条几十 KB
    static let forwarded: Set<String> = ["agent_message_chunk", "tool_call", "tool_call_update"]

    func arguments(for request: AISessions.TurnRequest) -> [String] { command }

    func openingLines(for request: AISessions.TurnRequest) -> [[String: Any]] { [Self.initialize] }

    static let initialize: [String: Any] = [
        "jsonrpc": "2.0",
        "id": initializeId,
        "method": "initialize",
        "params": [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": [
                "name": "vibepost", "title": "Vibepost",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            ],
        ],
    ]

    /// 页面写的：对它的请求（权限）的回答，或开会话、续会话、换设置、发这一轮。
    /// 会话的工作目录由壳定，不挂 MCP 服务；这一轮只带文字。
    func outgoing(_ message: [String: Any], directory: URL, context: TurnContext) -> [String: Any]? {
        guard let id = message["id"], !(id is NSNull) else { return nil }
        guard let method = message["method"] as? String else {
            if let result = message["result"] { return ["jsonrpc": "2.0", "id": id, "result": result] }
            if let error = message["error"] { return ["jsonrpc": "2.0", "id": id, "error": error] }
            return nil
        }
        guard Self.requests.contains(method) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        var kept: [String: Any] = [:]
        switch method {
        case "session/new", "session/resume", "session/load":
            if method != "session/new" {
                guard let session = params["sessionId"] as? String, !session.isEmpty else { return nil }
                kept["sessionId"] = session
            }
            kept["cwd"] = directory.path
            kept["mcpServers"] = [Any]()
        case "session/set_config_option":
            guard let session = params["sessionId"] as? String, let option = params["configId"] as? String,
                  let value = params["value"] as? String
            else { return nil }
            kept = ["sessionId": session, "configId": option, "value": value]
        default:
            guard let session = params["sessionId"] as? String else { return nil }
            let prompt = (params["prompt"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            kept = ["sessionId": session, "prompt": prompt]
            context["prompt"] = "\(id)"
        }
        return ["jsonrpc": "2.0", "id": id, "method": method, "params": kept]
    }

    /// 我们这一轮 session/prompt 的回答才算说完。它的请求（权限）都推给页面回答；会话更新只推页面用得上的几种。
    func classify(_ line: [String: Any], context: TurnContext) -> (forward: Bool, finished: Bool) {
        guard let method = line["method"] as? String else {
            let id = line["id"].map { "\($0)" }
            return (forward: true, finished: id != nil && id == context["prompt"])
        }
        if line["id"] != nil { return (forward: true, finished: false) }
        guard method == "session/update",
              let update = (line["params"] as? [String: Any])?["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String
        else { return (forward: false, finished: false) }
        return (forward: Self.forwarded.contains(kind), finished: false)
    }

    /// 工具调用的更新里有整份文件、命令的全部输出：页面只要它是什么、动了哪里、怎么样了
    func slim(_ line: [String: Any]) -> [String: Any]? {
        guard line["method"] as? String == "session/update", line["id"] == nil,
              var params = line["params"] as? [String: Any], let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String, kind == "tool_call" || kind == "tool_call_update"
        else { return nil }
        var kept: [String: Any] = ["sessionUpdate": kind]
        for key in ["toolCallId", "title", "kind", "status"] {
            if let value = update[key] as? String { kept[key] = String(value.prefix(Self.textLimit)) }
        }
        if let locations = update["locations"] as? [[String: Any]] {
            kept["locations"] = locations.prefix(20).compactMap { location in
                (location["path"] as? String).map { ["path": String($0.prefix(Self.textLimit))] }
            }
        }
        if let input = update["rawInput"] as? [String: Any] {
            var fields: [String: Any] = [:]
            for key in ["command", "path", "filePath", "file_path", "url"] {
                if let value = input[key] as? String { fields[key] = String(value.prefix(Self.textLimit)) }
            }
            kept["rawInput"] = fields
        }
        params["update"] = kept
        var trimmed = line
        trimmed["params"] = params
        return trimmed
    }

    /// 推给页面的一段文字（命令、路径、标题）最多这么长
    static let textLimit = 2000

    /// 这个 Agent 的会话设置（模型、推理强度的选单）：起一次 `acp`，握手后开一个会话就关上，返回它报的 configOptions
    /// （页面的 acpModels 挑出模型）。会话开在 directory 里（一个只放这个用的空目录）。
    func sessionOptions(
        executable: URL, environment: [String: String], directory: URL, timeout: Duration = .seconds(30)
    ) async throws -> [[String: Any]] {
        let open: [String: Any] = [
            "jsonrpc": "2.0", "id": 2, "method": "session/new",
            "params": ["cwd": directory.path, "mcpServers": [Any]()] as [String: Any],
        ]
        let input = try [Self.initialize, open].map { try JSONSerialization.data(withJSONObject: $0) + Data("\n".utf8) }.reduce(Data(), +)
        let reply = try await JSONLineExchange.run(
            executable, command, environment: environment.merging(self.environment) { $1 }, input: input, timeout: timeout,
            directory: directory
        ) { line in line["method"] == nil && (line["id"] as? Int) == 2 }
        if let error = reply["error"] as? [String: Any] {
            throw AISessions.Failure(error["message"] as? String ?? "session/new 出错")
        }
        return (reply["result"] as? [String: Any])?["configOptions"] as? [[String: Any]] ?? []
    }
}
