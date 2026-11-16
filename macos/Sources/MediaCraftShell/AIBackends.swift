import Foundation

/// AI 后端：本机的哪个命令行 Agent（Claude Code、Codex 在这个文件里，说 ACP 的几个在 ACPBackend.swift）、每一轮怎么起（参数、环境变量、开头写进 stdin 的几行）、读到哪一行算这一轮说完。
/// 输出行的意思由页面里对应的适配器解读（src/ai/backends/），回答也由它写好、经 `ai/respond` 写回 stdin——
/// 只写这个后端认得的几种，要紧的设置（Codex 线程的沙箱与审批）由壳定；壳（AISessions）起进程、转发输出、说完时收尾。
protocol AIBackend: Sendable {
    /// 页面请求里的 `backend`
    var id: String { get }
    /// 这一轮的请求这个后端用得了吗（缺了它必须有的字段就抛错）
    func validate(_ request: AISessions.TurnRequest) throws
    /// 在终端的环境变量之上另加的
    var environment: [String: String] { get }
    /// 起进程的参数
    func arguments(for request: AISessions.TurnRequest) -> [String]
    /// 进程起来后先写进 stdin 的几行（每行一个 JSON 对象）
    func openingLines(for request: AISessions.TurnRequest) -> [[String: Any]]
    /// 读到的一行：要不要推给页面（很大、页面用不上的不推）；读到它这一轮是不是说完了（说完就关上 stdin，等进程自己退出）。
    /// context 是这一轮壳自己记着的（如 Codex 的线程 id），只在读输出的线程与写 stdin 时用
    func classify(_ line: [String: Any], context: TurnContext) -> (forward: Bool, finished: Bool)
    /// 页面要写进 stdin 的一行：不是这个后端认得的样子时为 nil（不写）；可以改成壳要的样子（directory 是这一轮的工作目录）
    func outgoing(_ message: [String: Any], directory: URL, context: TurnContext) -> [String: Any]?
    /// 这一行里后端自己生成的图（如 Codex 自带的生图）；没有时为 nil
    func generatedImages(in line: [String: Any]) -> GeneratedImages?
    /// 推给页面之前把这一行削薄（去掉页面用不上的大块内容）；原样推时为 nil
    func slim(_ line: [String: Any]) -> [String: Any]?
    /// App 的工具要不要经一个这一轮的 MCP 服务挂给它（见 AIToolServer；Claude Code、Codex 各有自己的通道，不用）
    var mountsTools: Bool { get }
}

/// 一轮里壳自己记着的几样（读输出与写 stdin 在不同线程上，加锁）
final class TurnContext: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    subscript(key: String) -> String? {
        get { lock.withLock { values[key] } }
        set { lock.withLock { values[key] = newValue } }
    }
}

extension AIBackend {
    func validate(_ request: AISessions.TurnRequest) throws {}
    func generatedImages(in line: [String: Any]) -> GeneratedImages? { nil }
    func slim(_ line: [String: Any]) -> [String: Any]? { nil }
    var mountsTools: Bool { false }
}

/// 后端自己生成的图：壳读到时直接存成这篇的配图候选（是后端自己画的，不用再问用户；原图不动），
/// 推给页面的是 `line`（去掉了页面用不上、一张就几 MB 的原图数据），壳在里面加上 `vibepostCandidates`：
/// 每张 `{ id, name, width, height, thumb }`，存不了的是 `{ error }`。
struct GeneratedImages {
    enum Source {
        /// 后端存在本机的图
        case file(URL)
        /// 只给了图的数据（没存成文件时）
        case data(Data)
    }

    let sources: [Source]
    let line: [String: Any]
}

/// Claude Code：`claude -p`，stream-json 进出，在这篇稿子的工作副本目录里运行。
/// stdin 一直开到这一轮说完：claude 经 stdout 发来的控制请求（要不要允许某个操作、调用 App 的工具）由页面回答。
/// 说完（result）时关上 stdin——claude 读到 EOF 才退出。
struct ClaudeBackend: AIBackend {
    let id = "claude"

    /// App 自己的工具挂成一个 SDK MCP 服务：没有另外的进程或端口，工具调用走同一条控制通道（mcp_message），由页面执行。
    /// alwaysLoad：工具一开始就在 Claude 手边，不用先搜索工具。
    static let toolServer = "mediacraft"
    static let toolServerConfig = #"{"mcpServers":{"mediacraft":{"type":"sdk","name":"mediacraft","alwaysLoad":true}}}"#

    /// 关掉后台任务：后台任务会让 claude 在说完之后接着干活，那时 stdin 已关，它的权限请求全都送不到
    /// （页面见到这样的请求时明说并结束这一轮）。
    let environment = ["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1"]

    /// 会话 id 由页面定（--session-id 新建、--resume 接着），必须有
    func validate(_ request: AISessions.TurnRequest) throws {
        guard request.sessionId != nil else { throw AISessions.Failure("Claude Code 的一轮要带会话 id") }
    }

    /// 权限照 Claude Code 自己的设置与规则走；在终端里会问的，经控制通道（--permission-prompt-tool stdio）问页面。
    /// 工作副本里的 draft.md 自动接受修改（acceptEdits）；App 自己的工具可以撤销，直接允许；
    /// 用户在这篇的会话里点过「本次会话都允许」的规则接在后面。
    /// 只读用户级的设置（--setting-sources user）：工作副本里写进去的项目级 .claude/settings.json（比如 hook）不生效，
    /// 改稿子的模型没法借它绕开权限确认。
    func arguments(for request: AISessions.TurnRequest) -> [String] {
        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--permission-mode", "acceptEdits",
            "--permission-prompt-tool", "stdio", "--setting-sources", "user",
            "--mcp-config", Self.toolServerConfig, "--allowedTools", "mcp__\(Self.toolServer)",
        ] + request.allowedTools
        if !request.systemPrompt.isEmpty { arguments += ["--append-system-prompt", request.systemPrompt] }
        if let model = request.model { arguments += ["--model", model] }
        if let effort = request.effort { arguments += ["--effort", effort] }
        arguments += [request.resume ? "--resume" : "--session-id", request.sessionId?.uuidString.lowercased() ?? ""]
        return arguments
    }

    /// 一轮开头写进 stdin 的两行：登记 App 的工具服务（initialize），用户的话。
    func openingLines(for request: AISessions.TurnRequest) -> [[String: Any]] {
        let initialize: [String: Any] = [
            "type": "control_request",
            "request_id": "mediacraft-initialize",
            "request": ["subtype": "initialize", "sdkMcpServers": [Self.toolServer]],
        ]
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": request.prompt]]],
        ]
        return [initialize, message]
    }

    /// 页面只回答控制请求
    func outgoing(_ message: [String: Any], directory: URL, context: TurnContext) -> [String: Any]? {
        message["type"] as? String == "control_response" ? message : nil
    }

    /// 看到 result 就说完了。不推给页面的：claude 对 initialize 的回答（很大，页面用不上）与心跳。
    func classify(_ line: [String: Any], context: TurnContext) -> (forward: Bool, finished: Bool) {
        let type = line["type"] as? String
        return (forward: type != "control_response" && type != "keep_alive", finished: type == "result")
    }
}

/// Codex：`codex app-server`，stdio 上的 JSON-RPC（每行一条），在这篇稿子的工作副本目录里运行（它的工作区就是这个目录）。
/// 壳只写开头的握手（initialize、initialized）；开线程或续线程、发这一轮、回答它的审批与动态工具调用，都由页面的适配器
/// （src/ai/backends/codex.js）写好经 `ai/respond` 送进来，壳只放行这几种，线程的工作目录、沙箱与审批方式由壳定。
/// 收到这个线程这一轮的 turn/completed 就是说完了：关上 stdin，它读到 EOF 就退出。
struct CodexBackend: AIBackend {
    let id = "codex"
    let environment: [String: String] = [:]
    /// 推给页面的通知（页面用得上的）；别的（命令输出的增量、diff、推理、用量、额度、账户……）不推
    static let forwarded: Set<String> = ["item/started", "item/completed", "item/agentMessage/delta", "error", "turn/completed"]
    /// 页面能发的请求：开线程、续线程、发这一轮、中断
    static let requests: Set<String> = ["thread/start", "thread/resume", "turn/start", "turn/interrupt"]
    /// 线程只在这篇的工作副本里可写，要别的（联网、目录外、沙箱外的命令）先问
    static let sandbox = "workspace-write"
    static let approvalPolicy = "on-request"

    func arguments(for request: AISessions.TurnRequest) -> [String] {
        ["app-server"]
    }

    func openingLines(for request: AISessions.TurnRequest) -> [[String: Any]] {
        Self.handshake
    }

    /// 页面写的：对服务端请求（审批、动态工具）的回答，或开线程、续线程、发这一轮、中断。
    /// 线程的工作目录、沙箱与审批方式由壳定，页面只能给模型、说明、App 的工具（新线程）、续哪个线程；这一轮只带用户的话（文字）
    /// 与推理强度（小写字母的一个词），不带别的覆盖（工作目录、沙箱、审批……）。续线程不要整段历史（里面有每次看页面的图，越聊越大）。
    func outgoing(_ message: [String: Any], directory: URL, context: TurnContext) -> [String: Any]? {
        guard let id = message["id"], !(id is NSNull) else { return nil }
        guard let method = message["method"] as? String else {
            if let result = message["result"] { return ["id": id, "result": result] }
            if let error = message["error"] { return ["id": id, "error": error] }
            return nil
        }
        guard Self.requests.contains(method) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        var kept: [String: Any]
        switch method {
        case "thread/start", "thread/resume":
            let allowed: Set<String> = method == "thread/start"
                ? ["model", "developerInstructions", "dynamicTools"] : ["threadId", "model", "developerInstructions"]
            kept = params.filter { allowed.contains($0.key) }
            kept["cwd"] = directory.path
            kept["sandbox"] = Self.sandbox
            kept["approvalPolicy"] = Self.approvalPolicy
            if method == "thread/resume" { kept["excludeTurns"] = true }
            context["threadRequest"] = "\(id)"
        case "turn/start":
            let input = (params["input"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            kept = ["threadId": params["threadId"] ?? NSNull(), "input": input]
            if let effort = params["effort"] as? String, AISessions.TurnRequest.isEffort(effort) { kept["effort"] = effort }
            context["turnRequest"] = "\(id)"
        default:
            kept = params.filter { ["threadId", "turnId"].contains($0.key) }
        }
        return ["id": id, "method": method, "params": kept]
    }

    /// 回答我们的请求时记下线程与这一轮的 id；这个线程这一轮的 turn/completed 才算说完（Codex 的子线程也可能走这条连接）
    func classify(_ line: [String: Any], context: TurnContext) -> (forward: Bool, finished: Bool) {
        guard let method = line["method"] as? String else {
            if let id = line["id"].map({ "\($0)" }), let result = line["result"] as? [String: Any] {
                if id == context["threadRequest"], let thread = (result["thread"] as? [String: Any])?["id"] as? String {
                    context["thread"] = thread
                }
                if id == context["turnRequest"], let turn = (result["turn"] as? [String: Any])?["id"] as? String {
                    context["turn"] = turn
                }
            }
            return (forward: true, finished: false)
        }
        // 服务端的请求（审批、动态工具）：页面回答
        if line["id"] != nil { return (forward: true, finished: false) }
        guard Self.forwarded.contains(method) else { return (forward: false, finished: false) }
        guard method == "turn/completed" else { return (forward: true, finished: false) }
        let params = line["params"] as? [String: Any] ?? [:]
        let thread = params["threadId"] as? String
        let turn = (params["turn"] as? [String: Any])?["id"] as? String
        let ours = (thread == nil || context["thread"] == nil || thread == context["thread"])
            && (turn == nil || context["turn"] == nil || turn == context["turn"])
        return (forward: true, finished: ours)
    }

    /// 自带的生图（imageGeneration）说完了：图存在 savedPath（它自己的目录里，如 ~/.codex/generated_images/），
    /// 没有时 result 里是 base64 的图；没成功（failure）时两样都没有。推给页面的这一行去掉 result。
    func generatedImages(in line: [String: Any]) -> GeneratedImages? {
        guard line["method"] as? String == "item/completed",
              var params = line["params"] as? [String: Any],
              var item = params["item"] as? [String: Any], item["type"] as? String == "imageGeneration"
        else { return nil }
        var sources: [GeneratedImages.Source] = []
        if let path = item["savedPath"] as? String, !path.isEmpty {
            sources = [.file(URL(fileURLWithPath: path))]
        } else if let result = item["result"] as? String, !result.isEmpty, let data = Data(base64Encoded: result) {
            sources = [.data(data)]
        }
        item["result"] = ""
        params["item"] = item
        var trimmed = line
        trimmed["params"] = params
        return GeneratedImages(sources: sources, line: trimmed)
    }

    /// 握手：动态工具（App 的工具）是实验接口，要开 experimentalApi
    static let handshake: [[String: Any]] = [
        [
            "id": "initialize",
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "vibepost", "title": "Vibepost",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                ],
                "capabilities": ["experimentalApi": true],
            ],
        ],
        ["method": "initialized"],
    ]

    /// Codex 能用的模型（model/list）：起一个 app-server，握手、问一次就关上。
    /// 返回 [{ id, name, isDefault, efforts（这个模型能选的推理强度）, defaultEffort }]
    static func models(executable: URL, environment: [String: String], timeout: Duration = .seconds(20)) async throws -> [[String: Any]] {
        let request: [String: Any] = ["id": "models", "method": "model/list", "params": [:] as [String: Any]]
        let input = try (handshake + [request]).map { try JSONSerialization.data(withJSONObject: $0) + Data("\n".utf8) }
            .reduce(Data(), +)
        let reply = try await JSONLineExchange.run(executable, ["app-server"], environment: environment, input: input, timeout: timeout) { line in
            line["id"] as? String == "models"
        }
        if let error = reply["error"] as? [String: Any] {
            throw AISessions.Failure(error["message"] as? String ?? "model/list 出错")
        }
        let data = (reply["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return data.compactMap { model in
            guard let id = model["id"] as? String ?? model["model"] as? String else { return nil }
            let efforts = (model["supportedReasoningEfforts"] as? [Any] ?? []).compactMap { option in
                (option as? String) ?? (option as? [String: Any])?["reasoningEffort"] as? String
            }.filter(AISessions.TurnRequest.isEffort)
            let fallback = (model["defaultReasoningEffort"] as? String).flatMap { AISessions.TurnRequest.isEffort($0) ? $0 : nil }
            return [
                "id": id, "name": model["displayName"] as? String ?? id, "isDefault": model["isDefault"] as? Bool ?? false,
                "efforts": efforts, "defaultEffort": fallback ?? NSNull(),
            ]
        }
    }
}

/// 起一个说 JSON 行的程序：写进 input，读 stdout 直到有一行满足 until，然后关上 stdin 等它退出（超时就结束它）。
enum JSONLineExchange {
    static func run(
        _ executable: URL, _ arguments: [String], environment: [String: String], input: Data, timeout: Duration,
        directory: URL? = nil, until: @escaping @Sendable ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(input)
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var finished = false
            let finish = { (result: Result<[String: Any], Error>) in
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                try? stdin.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                continuation.resume(with: result)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.dispatchInterval) {
                finish(.failure(AISessions.Failure("没有在 \(timeout.components.seconds) 秒内回答")))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                while true {
                    let chunk = stdout.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], until(object) {
                            finish(.success(object))
                            return
                        }
                    }
                }
                finish(.failure(AISessions.Failure("没有回答就退出了")))
            }
        }
    }
}
