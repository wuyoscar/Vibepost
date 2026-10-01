import Foundation

/// 假的本机 Codex（`Fixtures/ai/fake-codex`）：复制进一个临时目录（名字叫 codex），在 stdio 上像 `codex app-server` 一样说 JSON-RPC，
/// 按回放脚本发通知与请求，并把每次开线程或续线程的进程（一次调用）记在 `calls/` 里。脚本写法见 fake-codex 开头的说明。
final class FakeCodex {
    /// 放 codex 的目录：放进「终端」PATH（`ShellHarness(terminalPath:)`）就能被自动找到
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-fake-codex-\(UUID().uuidString)")
    var executable: URL { directory.appendingPathComponent("codex") }

    /// script：默认的回放脚本（每次调用都用它，除非给某一次单独写了 `script(_:call:)`）
    init(script: [String] = FakeCodex.reply("好的")) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: FakeClaude.fixtures.appendingPathComponent("fake-codex"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try self.script(script)
    }

    /// 写回放脚本：call 为 nil 时是默认脚本，否则只给第几次调用用（从 1 起）
    func script(_ lines: [String], call: Int? = nil) throws {
        let name = call.map { "script-\($0).jsonl" } ?? "script.jsonl"
        try (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 没登录（`codex login status` 退出码 1）
    func logOut() {
        FileManager.default.createFile(atPath: directory.appendingPathComponent("logged-out").path, contents: Data())
    }

    /// 下一次 thread/resume 报这个错（线程还在，只是这次续不上）；nil 时恢复
    func resumeError(_ message: String?) {
        let file = directory.appendingPathComponent("resume-error")
        if let message { FileManager.default.createFile(atPath: file.path, contents: Data(message.utf8)) } else { try? FileManager.default.removeItem(at: file) }
    }

    /// Codex 那边的线程都没了（下一次 thread/resume 报错）
    func forgetThreads() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("threads"))
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("threads"), withIntermediateDirectories: true)
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

    /// 第 index 次调用里页面发来的某个方法的请求（thread/start、turn/start……）的参数
    func params(_ index: Int, _ method: String) -> [String: Any]? {
        stdin(index).first { $0["method"] as? String == method }?["params"] as? [String: Any]
    }

    /// 第 index 次调用里，页面对服务端请求 requestId 的回答（JSON-RPC 的 result）
    func response(_ index: Int, _ requestId: Int) -> [String: Any]? {
        let calls = calls()
        guard index < calls.count else { return nil }
        return (calls[index]["responses"] as? [String: Any])?[String(requestId)] as? [String: Any]
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 脚本里的一行

    static func line(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    /// 一条通知：像真的 app-server 一样带上这个线程与这一轮的 id（给了就用给的，如子线程的）
    static func notify(_ method: String, _ params: [String: Any]) -> String {
        var params = params
        if params["threadId"] == nil { params["threadId"] = "{{THREAD}}" }
        if params["turnId"] == nil && method != "turn/completed" { params["turnId"] = "{{TURN}}" }
        return line(["method": method, "params": params])
    }

    /// 一段流式回复：item/started → 一个个 delta → item/completed
    static func text(_ pieces: [String], id: String = "msg-1") -> [String] {
        [notify("item/started", ["item": ["type": "agentMessage", "id": id, "text": ""]])]
            + pieces.map { notify("item/agentMessage/delta", ["itemId": id, "delta": $0]) }
            + [notify("item/completed", ["item": ["type": "agentMessage", "id": id, "text": pieces.joined()]])]
    }

    /// 回复一句就说完
    static func reply(_ text: String) -> [String] {
        Self.text([text])
    }

    /// 一个服务端请求（审批、动态工具调用）：发出去，等页面回答再往下走。id 像真的 app-server 一样是整数，
    /// 每个进程从 0 数起（不同的一轮、不同的稿子都会有同样的 id）
    static func request(_ id: Int, _ method: String, _ params: [String: Any]) -> String {
        var full = params
        full["threadId"] = "{{THREAD}}"
        full["turnId"] = "{{TURN}}"
        return "#request " + line(["id": id, "method": method, "params": full])
    }

    /// 要运行一条命令，问能不能
    static func commandApproval(_ id: Int, _ command: String, reason: String? = nil) -> String {
        request(id, "item/commandExecution/requestApproval", [
            "itemId": "cmd-\(id)", "startedAtMs": 0, "command": command,
            "availableDecisions": ["accept", "acceptForSession", "decline", "cancel"],
            "reason": reason ?? NSNull(),
        ])
    }

    /// 它开始改文件（item/started 的 fileChange；审批改文件时，确认框里的路径从这里来）
    static func fileChange(_ itemId: String, _ paths: [String]) -> String {
        notify("item/started", ["item": [
            "type": "fileChange", "id": itemId, "status": "inProgress",
            "changes": paths.map { ["path": $0, "kind": ["type": "add"], "diff": ""] as [String: Any] },
        ]])
    }

    /// 要改工作区以外的文件，问能不能（itemId 对上之前的 fileChange）
    static func fileChangeApproval(_ id: Int, itemId: String, reason: String? = nil) -> String {
        request(id, "item/fileChange/requestApproval", [
            "itemId": itemId, "startedAtMs": 0, "reason": reason ?? NSNull(), "grantRoot": NSNull(),
        ])
    }

    /// 要更多权限（联网、目录外的读写），permissions 是 { network, fileSystem }
    static func permissionsApproval(_ id: Int, _ permissions: [String: Any], reason: String? = nil) -> String {
        request(id, "item/permissions/requestApproval", [
            "itemId": "perm-\(id)", "environmentId": NSNull(), "startedAtMs": 0, "cwd": "{{CWD}}",
            "reason": reason ?? NSNull(), "permissions": permissions,
        ])
    }

    /// 调用 App 的一个工具（动态工具）
    static func toolCall(_ id: Int, _ tool: String, _ arguments: [String: Any] = [:]) -> String {
        request(id, "item/tool/call", ["callId": "call-\(id)", "tool": tool, "arguments": arguments])
    }
}
