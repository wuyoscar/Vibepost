import Foundation

/// 假的本机 Claude Code（`Fixtures/ai/fake-claude`）：复制进一个临时目录，按回放脚本输出 stream-json，
/// 并把每次调用（参数、工作目录、stdin、收到的信号……）记在 `calls/` 里。脚本写法见 fake-claude 开头的说明。
final class FakeClaude {
    static let fixtures = ShellHarness.repoRoot.appendingPathComponent("macos/Tests/Fixtures/ai")

    /// 放 claude 的目录：放进「终端」PATH（`ShellHarness(terminalPath:)`）就能被自动找到
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-fake-claude-\(UUID().uuidString)")
    var executable: URL { directory.appendingPathComponent("claude") }

    /// script：默认的回放脚本（每次调用都用它，除非给某一次单独写了 `script(_:call:)`）
    init(script: [String] = FakeClaude.fixture("reply-ok.jsonl")) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("fake-claude"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try self.script(script)
    }

    /// 录下来的真实 claude 输出（会话 id、目录是占位符）
    static func fixture(_ name: String) -> [String] {
        let text = (try? String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// 写回放脚本：call 为 nil 时是默认脚本，否则只给第几次调用用
    func script(_ lines: [String], call: Int? = nil) throws {
        let name = call.map { "script-\($0).jsonl" } ?? "script.jsonl"
        try (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 让停在 `#wait-file 名字` 的脚本继续
    func release(_ gate: String) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(gate).path, contents: Data())
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

    /// 第 index 次调用 stdin 收到的每一行（解析成 JSON）
    func stdin(_ index: Int) -> [[String: Any]] {
        let calls = calls()
        guard index < calls.count else { return [] }
        return (calls[index]["stdin"] as? [String] ?? []).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// 第 index 次调用 stdin 收到的用户消息里说的话
    func prompt(_ index: Int) -> String {
        guard let message = stdin(index).first(where: { $0["type"] as? String == "user" }),
              let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return "" }
        return content.compactMap { $0["text"] as? String }.joined()
    }

    /// 第 index 次调用里，页面对控制请求 requestId 的回答（control_response 的 response 部分）
    func response(_ index: Int, _ requestId: String) -> [String: Any]? {
        let calls = calls()
        guard index < calls.count else { return nil }
        return (calls[index]["responses"] as? [String: Any])?[requestId] as? [String: Any]
    }

    /// 某个选项后面的值（`--resume` 后面的会话 id 之类）
    static func option(_ name: String, in call: [String: Any]) -> String? {
        let argv = call["argv"] as? [String] ?? []
        guard let index = argv.firstIndex(of: name), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }

    /// 等这个进程真的没了（退出并被回收），最多 timeout
    static func waitUntilGone(_ pid: Int32, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 按真实 claude 的 stream-json 形状（见 Fixtures/ai/*.jsonl）拼回放脚本的事件。
enum StreamJSON {
    static func line(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    static func initEvent(model: String = "claude-opus-4-6") -> String {
        line(["type": "system", "subtype": "init", "cwd": "{{CWD}}", "session_id": "{{SESSION}}", "model": model,
              "permissionMode": "acceptEdits", "claude_code_version": "9.9.9", "tools": ["Read", "Edit", "Write"]])
    }

    private static func streamEvent(_ event: [String: Any]) -> String {
        line(["type": "stream_event", "event": event, "session_id": "{{SESSION}}", "parent_tool_use_id": NSNull()])
    }

    static func textStart(index: Int = 0) -> String {
        streamEvent(["type": "content_block_start", "index": index, "content_block": ["type": "text", "text": ""]])
    }

    static func textDelta(_ text: String, index: Int = 0) -> String {
        streamEvent(["type": "content_block_delta", "index": index, "delta": ["type": "text_delta", "text": text]])
    }

    static func assistant(_ content: [[String: Any]]) -> String {
        line(["type": "assistant", "message": ["model": "claude-opus-4-6", "role": "assistant", "type": "message", "content": content],
              "parent_tool_use_id": NSNull(), "session_id": "{{SESSION}}"])
    }

    static func assistantText(_ text: String) -> String {
        assistant([["type": "text", "text": text]])
    }

    static func toolUse(_ name: String, _ input: [String: Any]) -> String {
        assistant([["type": "tool_use", "id": "toolu_\(UUID().uuidString.prefix(8))", "name": name, "input": input]])
    }

    static func result(_ text: String, cost: Double = 0.0123, durationMs: Int = 4200, isError: Bool = false) -> String {
        line(["type": "result", "subtype": isError ? "error_during_execution" : "success", "is_error": isError, "result": text,
              "session_id": "{{SESSION}}", "total_cost_usd": cost, "duration_ms": durationMs, "num_turns": 1])
    }

    /// 一段完整的回复：流式片段 → 完整文字 → 结果
    static func reply(_ pieces: [String]) -> [String] {
        [initEvent(), textStart()] + pieces.map { textDelta($0) } + [assistantText(pieces.joined()), result(pieces.joined())]
    }

    // MARK: 控制通道（形状照真实 claude 2.1.280 发出的请求）

    /// 回放脚本的一行：发控制请求并等回答（wait 为 false 时只发，之后用 `#await 请求 id` 等）
    static func control(_ requestId: String, _ request: [String: Any], wait: Bool = true) -> String {
        "#\(wait ? "control" : "send-control") \(line(["request_id": requestId, "request": request]))"
    }

    /// 要不要允许一个操作（在终端里会问用户的那种）；extra 是另外的字段（比如 blocked_path）。
    /// 像真的 claude 一样附上「以后不再问」的建议：命令的话是这条命令，否则是这个工具；suggest 为 false 时不给建议。
    static func permission(
        _ requestId: String, tool: String, input: [String: Any], extra: [String: Any] = [:], suggest: Bool = true,
        wait: Bool = true
    ) -> String {
        let rule: [String: Any] = input["command"].map { ["toolName": tool, "ruleContent": $0] } ?? ["toolName": tool]
        var request: [String: Any] = [
            "subtype": "can_use_tool", "tool_name": tool, "display_name": tool, "input": input,
            "description": input["description"] ?? "", "decision_reason": "This command requires approval",
            "decision_reason_type": "other", "tool_use_id": "toolu_\(requestId)",
        ]
        if suggest {
            request["permission_suggestions"] = [["type": "addRules", "rules": [rule], "behavior": "allow", "destination": "localSettings"]]
        }
        return control(requestId, request.merging(extra) { $1 }, wait: wait)
    }

    /// 发给 App 工具服务（mediacraft）的一条 MCP 消息
    static func mcp(_ requestId: String, method: String, params: [String: Any] = [:], id: Int = 1) -> String {
        control(requestId, [
            "subtype": "mcp_message", "server_name": "mediacraft",
            "message": ["jsonrpc": "2.0", "id": id, "method": method, "params": params],
        ])
    }

    /// 调用 App 的一个工具
    static func toolCall(_ requestId: String, _ name: String, _ arguments: [String: Any] = [:]) -> String {
        mcp(requestId, method: "tools/call", params: ["name": name, "arguments": arguments])
    }
}
