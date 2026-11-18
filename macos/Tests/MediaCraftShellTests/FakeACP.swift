import Foundation

/// 假的 ACP Agent（`Fixtures/ai/fake-acp`）：复制进一个临时目录（名字叫 opencode、omp 或 kimi），在 stdio 上像 `<程序> acp` 一样说 ACP，
/// 按回放脚本发会话更新与请求，并把每次续会话或发这一轮的进程（一次调用）记在 `calls/` 里。脚本写法见 fake-acp 开头的说明。
final class FakeACP {
    /// 放程序的目录：放进「终端」PATH（`ShellHarness(terminalPath:)`）就能被自动找到
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-fake-acp-\(UUID().uuidString)")
    let program: String
    var executable: URL { directory.appendingPathComponent(program) }

    /// script：默认的回放脚本（每次调用都用它，除非给某一次单独写了 `script(_:call:)`）
    init(program: String = "opencode", script: [String] = FakeACP.reply("好的")) throws {
        self.program = program
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: FakeClaude.fixtures.appendingPathComponent("fake-acp"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try self.script(script)
    }

    /// 写回放脚本：call 为 nil 时是默认脚本，否则只给第几次调用用（从 1 起）
    func script(_ lines: [String], call: Int? = nil) throws {
        let name = call.map { "script-\($0).jsonl" } ?? "script.jsonl"
        try (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 同目录里的一个开关文件（logged-out：没登录；no-resume：不报 session/resume，只能 session/load）
    func flag(_ name: String, _ on: Bool = true) {
        let file = directory.appendingPathComponent(name)
        if on { FileManager.default.createFile(atPath: file.path, contents: Data()) } else { try? FileManager.default.removeItem(at: file) }
    }

    /// 下一次续会话报这个错；nil 时恢复
    func resumeError(_ message: String?) {
        let file = directory.appendingPathComponent("resume-error")
        if let message { FileManager.default.createFile(atPath: file.path, contents: Data(message.utf8)) } else { try? FileManager.default.removeItem(at: file) }
    }

    /// 它那边的会话都没了（下一次续会话报错）
    func forgetSessions() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("sessions"))
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    }

    /// 按先后顺序的每次调用记录
    func calls() -> [[String: Any]] {
        let folder = directory.appendingPathComponent("calls")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> (Int, [String: Any])? in
            guard name.hasSuffix(".json"), let index = Int(name.dropLast(5)),
                  let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return (index, record)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// 第 index 次调用（从 0 起）stdin 收到的每一行（解析成 JSON）
    func stdin(_ index: Int) -> [[String: Any]] {
        let calls = calls()
        guard index < calls.count else { return [] }
        return (calls[index]["stdin"] as? [String] ?? []).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// 第 index 次调用里页面发来的请求的方法名，按先后
    func methods(_ index: Int) -> [String] {
        stdin(index).compactMap { $0["method"] as? String }
    }

    /// 第 index 次调用里页面发来的某个方法的请求的参数（有几个时是第 nth 个）
    func params(_ index: Int, _ method: String, nth: Int = 0) -> [String: Any]? {
        let matches = stdin(index).filter { $0["method"] as? String == method }
        return nth < matches.count ? matches[nth]["params"] as? [String: Any] : nil
    }

    /// 第 index 次调用里这一轮的话（session/prompt 的第一段文字）
    func prompt(_ index: Int) -> String {
        ((params(index, "session/prompt")?["prompt"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    /// 第 index 次调用里，页面对它的请求 requestId 的回答（JSON-RPC 的 result；回的是错误时为 `{ error }`）
    func response(_ index: Int, _ requestId: Int) -> [String: Any]? {
        let calls = calls()
        guard index < calls.count else { return nil }
        return (calls[index]["responses"] as? [String: Any])?[String(requestId)] as? [String: Any]
    }

    /// 第 index 次调用里，它经挂上的 MCP 服务（App 的工具）发的消息得到的回答，按先后（JSON-RPC 的整条回答）
    func mcpReplies(_ index: Int) -> [[String: Any]] {
        let calls = calls()
        return index < calls.count ? calls[index]["mcp"] as? [[String: Any]] ?? [] : []
    }

    /// 页面对一个权限请求选了哪个选项（optionId）
    func chosen(_ index: Int, _ requestId: Int) -> String? {
        (response(index, requestId)?["outcome"] as? [String: Any])?["optionId"] as? String
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 脚本里的一行

    static func line(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    /// 一条会话更新（session/update）
    static func update(_ kind: String, _ fields: [String: Any], session: String = "{{SESSION}}") -> String {
        var update = fields
        update["sessionUpdate"] = kind
        return line(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": session, "update": update]])
    }

    /// 一段流式回复：一个个 agent_message_chunk
    static func text(_ pieces: [String]) -> [String] {
        pieces.map { update("agent_message_chunk", ["content": ["type": "text", "text": $0]]) }
    }

    static func reply(_ text: String) -> [String] {
        Self.text([text])
    }

    /// 一个工具调用从开始到结束（或没成功）：tool_call（pending）→ tool_call_update（status）。
    /// 结束那条像真的一样带着大块的内容（content、rawOutput），壳不该把它们推给页面
    static func tool(_ id: String, kind: String, title: String, input: [String: Any], status: String = "completed") -> [String] {
        [
            update("tool_call", ["toolCallId": id, "title": title, "kind": kind, "status": "pending", "rawInput": [:] as [String: Any]]),
            update("tool_call_update", [
                "toolCallId": id, "status": status, "rawInput": input,
                "content": [["type": "content", "content": ["type": "text", "text": String(repeating: "很长的输出", count: 400)]]],
                "rawOutput": ["output": String(repeating: "x", count: 4000)],
            ]),
        ]
    }

    /// 它的一个请求（权限……）：发出去，等页面回答再往下走
    static func request(_ id: Int, _ method: String, _ params: [String: Any]) -> String {
        "#request " + line(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    /// 经挂上的 MCP 服务发一条消息（握手、列工具、调工具）；id 为 nil 的是通知
    static func mcp(_ id: Int?, _ method: String, _ params: [String: Any]? = nil) -> String {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        message["id"] = id
        message["params"] = params
        return "#mcp " + line(message)
    }

    /// 调 App 的一个工具
    static func appTool(_ id: Int, _ name: String, _ arguments: [String: Any] = [:]) -> String {
        mcp(id, "tools/call", ["name": name, "arguments": arguments])
    }

    /// 要做一个操作，问能不能（选项像 OpenCode 的：once / always / reject）
    static func permission(_ id: Int, kind: String, title: String, input: [String: Any], callId: String? = nil) -> String {
        request(id, "session/request_permission", [
            "sessionId": "{{SESSION}}",
            "toolCall": ["toolCallId": callId ?? "call-\(id)", "title": title, "kind": kind, "status": "pending", "rawInput": input],
            "options": [
                ["optionId": "once", "kind": "allow_once", "name": "Allow once"],
                ["optionId": "always", "kind": "allow_always", "name": "Always allow"],
                ["optionId": "reject", "kind": "reject_once", "name": "Reject"],
            ],
        ])
    }

    /// 要运行一条命令，问能不能
    static func commandPermission(_ id: Int, _ command: String) -> String {
        permission(id, kind: "execute", title: command, input: ["command": command])
    }
}
