import Foundation

/// AI 会话：每一轮对话起一个 AI 后端的进程（本机的命令行 Agent，见 AIBackends.swift），在这篇稿子的工作副本目录里运行。
/// 页面经原生桥 `POST /__native/ai/<动作>`（body 是 JSON）调用；进程的输出逐行推回页面，由页面按后端解读（见 docs/app-api.md）。
/// stdin 一直开到这一轮说完：后端发来的请求（要不要允许某个操作、调用 App 的工具）由页面回答，
/// 回答经 `ai/respond` 原样写回 stdin。后端说这一轮说完时关上 stdin——进程读到 EOF 才退出——并有上限地等它退出。
/// 每篇稿子同时最多一轮；读写进程都在后台线程，停止时 SIGINT → SIGTERM → SIGKILL，App 退出时全部结束。
/// 几个窗口共用这一份：每一轮记着是哪个窗口发起的，它的事件只推给那个窗口，那个窗口重新载入、关掉时只结束它自己的。
final class AISessions: @unchecked Sendable {
    /// 推给页面的事件（JSON 文本）与要推给哪个窗口，由 ShellCore 转成那个窗口页面里的 `mediacraft:native-ai` 事件。
    typealias Sink = @Sendable (_ json: String, _ window: String) -> Void

    private static let stderrLimit = 8192
    /// 页面重新载入、App 退出时先 SIGTERM，过这么久还没退出的 SIGKILL
    private static let terminateGrace: DispatchTimeInterval = .milliseconds(1500)
    /// 认得的后端（页面请求里的 backend）
    private static let backends: [String: any AIBackend] = ["claude": ClaudeBackend(), "codex": CodexBackend()]

    /// 往已经退出的后端进程的 stdin 写字时，默认的 SIGPIPE 会让整个进程（App、跑测试的进程）退出；
    /// 壳一建好 AI 会话就忽略它（整个进程只设这一次），写入只得到 EPIPE 错误，由这里报给页面。
    private static let brokenPipesIgnored: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private let configuration: AIConfiguration
    /// 终端里的环境变量（登录 shell 读出来的），查找程序与读生图密钥共用
    private let terminal: TerminalEnvironment
    /// 每个后端的程序在哪（claude、codex）
    private let locators: [String: AgentLocator]
    private let candidates: AICandidates
    private let images: AIImages
    private let approvals = CandidateApprovals()
    private let lock = NSLock()
    private var turns: [String: Turn] = [:]
    /// 每个窗口在里面跑过 AI 的稿子（那个窗口重新载入时，这些稿子的配图放行记录跟着页面一起忘掉）
    private var windowDrafts: [String: Set<String>] = [:]
    /// 关掉了的窗口：它的页面在关掉之前发出、之后才到的请求不再起进程
    private var closedWindows: Set<String> = []
    /// 每个窗口的页面换了几次（重新载入时加一）：旧页面发出、换页之后才起得来的一轮不再起（新页面不认识它，没人回答它）
    private var windowEpochs: [String: Int] = [:]
    /// 正在载入的配图候选（删稿子时先取消、等它们停下，免得删完又写进来）
    private var loading: [String: [UUID: Task<AICandidates.Candidate, Error>]] = [:]
    /// 正在删除的稿子：不再起新的一轮、不再载入候选
    private var removing: Set<String> = []
    private var sink: Sink?

    init(configuration: AIConfiguration) {
        _ = Self.brokenPipesIgnored
        self.configuration = configuration
        let terminal = TerminalEnvironment(configuration: configuration)
        self.terminal = terminal
        let settings = AgentSettings(root: configuration.root)
        locators = [
            "claude": AgentLocator(program: .claude, settings: settings, terminal: terminal),
            "codex": AgentLocator(program: .codex, settings: settings, terminal: terminal),
        ]
        candidates = AICandidates(root: configuration.root)
        images = AIImages(api: configuration.imageAPI)
    }

    func setSink(_ sink: Sink?) {
        lock.withLock { self.sink = sink }
    }

    /// window 是发来这个请求的窗口（原生桥知道，页面说了不算）：只能动这个窗口自己发起的那一轮
    /// 这个窗口现在是第几个页面（原生桥收到请求时就记下，见 AppSchemeHandler）：换页面之前发出的「开始一轮」不再起
    func epoch(window: String) -> Int {
        lock.withLock { windowEpochs[window, default: 0] }
    }

    func handle(action: String, body: Data, window: String, epoch: Int? = nil) async -> NativeBridge.Reply {
        let request = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        switch action {
        case "status":
            guard let locator = locator(request) else { return .failure(400, "不认识的 AI 后端") }
            return .ok(await locator.status(refresh: request["refresh"] as? Bool ?? false).fields)
        case "settings":
            return await saveSettings(request)
        case "models":
            return await models(request)
        case "send":
            return await start(request, window: window, epoch: epoch ?? self.epoch(window: window))
        case "cancel":
            return .ok(["cancelled": cancel(draftId: request["draftId"] as? String ?? "", window: window)])
        case "respond":
            return await respond(request, window: window)
        case "work-file":
            return workFile(request, window: window)
        case "candidate":
            return await candidate(request, window: window)
        case "generate-image":
            return await generateImage(request, window: window)
        case "generate-cancel":
            return .ok(["cancelled": images.cancel(draftId: request["draftId"] as? String ?? "")])
        case "candidate-file":
            return candidateFile(request)
        case "remove":
            return await removeDraft(request)
        default:
            return .failure(404, "没有这个 AI 动作：ai/\(action)")
        }
    }

    /// 请求里的 backend（没给时是 claude，这版之前的页面不带）对应的查找器
    private func locator(_ request: [String: Any]) -> AgentLocator? {
        locators[request["backend"] as? String ?? "claude"]
    }

    /// 在设置里指定某个后端程序的路径：`{ backend, path }`（这版之前的页面发 `{ claudePath }`）
    private func saveSettings(_ request: [String: Any]) async -> NativeBridge.Reply {
        guard let locator = locator(request) else { return .failure(400, "不认识的 AI 后端") }
        do {
            let path = request["path"] as? String ?? request["claudePath"] as? String
            return .ok(try await locator.setPath(path).fields)
        } catch {
            return .failure(500, "设置没能保存：\(error.localizedDescription)")
        }
    }

    /// 后端能用的模型（现在只有 Codex 有列表）：`{ models: [{ id, name, isDefault }] }`
    private func models(_ request: [String: Any]) async -> NativeBridge.Reply {
        guard (request["backend"] as? String) == "codex", let locator = locators["codex"] else { return .ok(["models": []]) }
        let status = await locator.status(refresh: false)
        guard status.available, let path = status.path else { return .failure(400, status.error ?? "找不到本机 Codex") }
        do {
            return .ok(["models": try await CodexBackend.models(executable: URL(fileURLWithPath: path), environment: status.environment)])
        } catch {
            return .failure(500, "没能读出 Codex 的模型：\(error.localizedDescription)")
        }
    }

    private func start(_ request: [String: Any], window: String, epoch: Int) async -> NativeBridge.Reply {
        do {
            try await send(TurnRequest(request), window: window, epoch: epoch)
            return .ok()
        } catch {
            return .failure(400, error.localizedDescription)
        }
    }

    /// 页面写的一行（回答后端的请求，或主动发的请求）写进这一轮的 stdin：真写进去之后才回 delivered；
    /// 写失败（进程已经退出、不再读……）回错误，页面据此结束这一轮
    private func respond(_ request: [String: Any], window: String) async -> NativeBridge.Reply {
        guard let message = request["message"] as? [String: Any] else { return .failure(400, "AI 回应的字段不对") }
        guard let turn = runningTurn(request, window: window) else { return .ok(["delivered": false]) }
        guard let outgoing = turn.backend.outgoing(message, directory: turn.directory, context: turn.context),
              let line = try? JSONSerialization.data(withJSONObject: outgoing)
        else { return .failure(400, "AI 回应的字段不对") }
        do {
            return .ok(["delivered": try await turn.deliver(line + Data("\n".utf8))])
        } catch {
            return .failure(500, "回答没能写进 \(turn.backend.id)：\(error.localizedDescription)")
        }
    }

    private func candidateFile(_ request: [String: Any]) -> NativeBridge.Reply {
        do {
            return .ok(try candidates.file(draftId: try Self.draftDirectoryName(request), id: request["id"] as? String ?? ""))
        } catch {
            return .failure(404, error.localizedDescription)
        }
    }

    private func removeDraft(_ request: [String: Any]) async -> NativeBridge.Reply {
        guard let draftId = request["draftId"] as? String else { return .failure(400, "稿子 id 不对") }
        // 不能当目录名的 id 从来没有工作副本（ai/send 也不收），没什么可删
        guard TurnRequest.isSafeDirectoryName(draftId) else { return .ok() }
        do {
            try await remove(draftId: draftId)
            return .ok()
        } catch {
            return .failure(500, error.localizedDescription) // 页面说明是工作副本没删掉
        }
    }

    private static func draftDirectoryName(_ request: [String: Any]) throws -> String {
        guard let draftId = request["draftId"] as? String, TurnRequest.isSafeDirectoryName(draftId) else {
            throw Failure("稿子 id 不对")
        }
        return draftId
    }

    /// 请求里的 draftId、turnId 对得上、又是这个窗口发起的那一轮（还在跑）
    private func runningTurn(_ request: [String: Any], window: String) -> Turn? {
        guard let draftId = request["draftId"] as? String, let turnId = request["turnId"] as? String else { return nil }
        return lock.withLock { turns[draftId] }.flatMap { $0.request.turnId == turnId && $0.window == window ? $0 : nil }
    }

    /// 这一轮进行中读写工作副本的 draft.md：工具在编辑器里改了分页、段落顺序或图片位置时，把同样的改动写进来，
    /// 免得 Claude 读到的稿子与编辑器对不上。body 带 markdown 时先写，都返回写完后的内容。
    private func workFile(_ request: [String: Any], window: String) -> NativeBridge.Reply {
        guard let turn = runningTurn(request, window: window) else { return .failure(409, "这一轮已经结束") }
        let file = turn.directory.appendingPathComponent("draft.md")
        do {
            if let markdown = request["markdown"] as? String {
                try Data(markdown.utf8).write(to: file, options: .atomic)
            }
            return .ok(["markdown": try String(contentsOf: file, encoding: .utf8)])
        } catch {
            return .failure(500, "工作副本读写失败：\(error.localizedDescription)")
        }
    }

    /// 配图候选（App 的工具 propose_images）：这篇工作目录里的直接读；网上的、目录以外的要用户同意过——
    /// 页面带着壳发的凭据（`approval`）再来、或这个目录在这篇的会话里放行过（`session`，只有本机目录）才读，否则回 `{ needsApproval, approval, scope? }`。
    /// 下载途中重定向到放行范围以外的站点：停下，同样回 `needsApproval`（`scope` 是那个站点，`redirect` 是跳去的网址）。
    private func candidate(_ request: [String: Any], window: String) async -> NativeBridge.Reply {
        do {
            let draftId = try Self.draftDirectoryName(request)
            guard let turn = runningTurn(request, window: window) else { return .failure(409, "这一轮已经结束") }
            let source = request["source"] as? String ?? ""
            let origin = try candidates.origin(of: source, draftId: draftId)
            var allowed = approvals.sessionScopes(draftId)
            // 这张图的凭据：对得上就算用户同意了这张图，外加凭据上的范围（原来的站点 / 目录，或重定向去的站点）
            let granted = (request["approval"] as? String).flatMap {
                approvals.redeem(
                    $0, draftId: draftId, turnId: turn.request.turnId, key: origin.key, session: request["session"] as? Bool ?? false
                )
            }
            if let granted { allowed.insert(granted) }
            if origin.needsApproval && granted == nil && !allowed.contains(origin.scope) {
                return askFirst(turn, key: origin.key, scope: origin.scope)
            }
            allowed.insert(origin.scope)
            do {
                return .ok(try await loadCandidate(draftId: draftId, origin: origin, source: source, allowed: allowed).fields)
            } catch let redirect as CandidateRedirect {
                return askFirst(turn, key: origin.key, scope: redirect.scope, redirect: redirect.target)
            }
        } catch {
            return .failure(400, error.localizedDescription)
        }
    }

    /// 要先问用户：发一张凭据，页面问过带着它再来
    private func askFirst(_ turn: Turn, key: String, scope: CandidateScope, redirect: URL? = nil) -> NativeBridge.Reply {
        let token = approvals.issue(draftId: turn.request.draftId, turnId: turn.request.turnId, key: key, scope: scope)
        var fields: [String: Any] = ["needsApproval": true, "approval": token]
        // 只有本机目录能「本次会话都允许」；网上的图不给这个范围，确认框也就不提供它
        if case .directory = scope { fields["scope"] = scope.label }
        if let redirect { fields["redirect"] = redirect.absoluteString }
        return .ok(fields)
    }

    /// 载入一张候选，登记在这篇稿子名下：删稿子时先取消、等它停下。正在删的稿子不再载入。
    private func loadCandidate(
        draftId: String, origin: AICandidates.Origin, source: String, allowed: Set<CandidateScope>
    ) async throws -> AICandidates.Candidate {
        let task = Task { [candidates] in
            try await candidates.add(draftId: draftId, origin: origin, source: source, allowed: allowed)
        }
        let key = UUID()
        let accepted = lock.withLock { () -> Bool in
            guard !removing.contains(draftId) else { return false }
            loading[draftId, default: [:]][key] = task
            return true
        }
        guard accepted else {
            task.cancel()
            throw Failure("这篇稿子正在删除")
        }
        defer {
            lock.withLock {
                loading[draftId]?[key] = nil
                if loading[draftId]?.isEmpty == true { loading[draftId] = nil }
            }
        }
        return try await task.value
    }

    /// 一轮里最多生这么多张图：生图不用确认、要花钱，被提示词注入的模型也不能一直调下去
    static let imagesPerTurn = 8

    /// 生图（App 的工具 generate_image，只在这一轮进行中可用）：生成的图存成配图候选，返回 `{ images: [{ id, name, width, height, thumb }] }`。
    /// 密钥先找登录 shell 的环境，没有时重新读一次（刚在 ~/.zshrc 里加上的也读得到），再找 `~/.env`。
    private func generateImage(_ request: [String: Any], window: String) async -> NativeBridge.Reply {
        do {
            let draftId = try Self.draftDirectoryName(request)
            guard let turn = runningTurn(request, window: window) else { return .failure(409, "这一轮已经结束") }
            let job = try AIImages.Request(request)
            guard turn.reserveImages(job.count, limit: Self.imagesPerTurn) else {
                throw Failure("这一轮已经生成了 \(turn.imagesGenerated) 张图，一轮最多 \(Self.imagesPerTurn) 张；还要的话请用户再发一条")
            }
            var keys = await imageKeys(refresh: false)
            if keys[AIImages.keyName, default: ""].isEmpty { keys = await imageKeys(refresh: true) }
            let generated: [Data]
            do {
                generated = try await images.generate(draftId: draftId, request: job, keys: keys)
            } catch {
                turn.releaseImages(job.count)
                throw error
            }
            // 生成完正赶上删稿子：不再往 .candidates 里写
            guard !lock.withLock({ removing.contains(draftId) }) else { throw Failure("这篇稿子正在删除") }
            let stored = try generated.enumerated().map { index, data in
                try candidates.store(draftId: draftId, data: data, name: "生图 \(index + 1)").fields
            }
            return .ok(["images": stored])
        } catch {
            return .failure(400, error.localizedDescription)
        }
    }

    /// 能找到的生图密钥：登录 shell 的环境优先，`~/.env` 补缺
    private func imageKeys(refresh: Bool) async -> [String: String] {
        let environment = await terminal.snapshot(refresh: refresh).variables.filter { !$0.value.isEmpty }
        return AIImages.dotenv(configuration.keyFile).merging(environment) { $1 }
    }

    /// 删稿子时：先取消正在载入的配图候选并等它们停下，停掉这篇还在跑的一轮并等进程真正退出（有上限），
    /// 再删掉它的工作副本目录与配图候选，忘掉它放行过的范围——删完不会再有东西写回来。
    /// 后端自己的会话记录（`~/.claude/projects/`、`~/.codex/sessions/`）不归 App 管，不删。
    private func remove(draftId: String) async throws {
        let pending = lock.withLock { () -> [Task<AICandidates.Candidate, Error>] in
            removing.insert(draftId)
            return Array((loading[draftId] ?? [:]).values)
        }
        defer { lock.withLock { _ = removing.remove(draftId) } }
        pending.forEach { $0.cancel() }
        for task in pending { _ = try? await task.value }
        await stopAndWait(draftId: draftId)
        approvals.forget(draftId: draftId)
        for directory in [configuration.root.appendingPathComponent(draftId, isDirectory: true), candidates.folder(draftId)] {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue // 没用过 AI（或没放过配图候选）的稿子没有这个目录
            }
        }
    }

    /// 停掉这篇还在跑的一轮，等进程退出：SIGINT、SIGTERM、SIGKILL 各隔一个 cancelGrace，最多等到 SIGKILL 之后一秒
    private func stopAndWait(draftId: String) async {
        guard let turn = lock.withLock({ turns[draftId] }) else { return }
        _ = cancel(draftId: draftId)
        let limit = (configuration.cancelGrace * 2 + .seconds(1)).dispatchInterval
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = turn.exited.wait(timeout: .now() + limit)
                continuation.resume()
            }
        }
    }

    // MARK: - 一轮对话

    struct TurnRequest {
        let turnId: String
        let draftId: String
        /// 哪个后端（没给时是 claude，这版之前的页面不带）
        let backend: String
        /// 后端那边的会话 id（Claude Code 由页面定，必须有；Codex 的线程由页面经 stdin 开、续，不带）
        let sessionId: UUID?
        let resume: Bool
        let prompt: String
        let markdown: String
        let title: String
        /// 小红书正文（发布时图片下面的那段），写进 `caption.txt`
        let caption: String
        let systemPrompt: String
        /// 工作副本里的 `AGENTS.md`：页面给的操作手册全文（每轮重写，Agent 改了也不留）；空着时不写
        let agentsFile: String
        /// 这篇稿子选的模型（别名如 `opus` 或模型 ID），nil 是跟随 Claude Code 自己的设置（不传 `--model`）
        let model: String?
        /// 这篇稿子选的推理强度（Claude Code 的 `--effort`；Codex 由页面写进 turn/start），nil 是跟随后端自己的设置
        let effort: String?
        /// 这篇稿子的会话里点过「本次会话都允许」的权限规则（Claude Code 的写法，如 `Bash(npm test:*)`），每轮都带上
        let allowedTools: [String]

        init(_ fields: [String: Any]) throws {
            guard let turnId = fields["turnId"] as? String, !turnId.isEmpty,
                  let draftId = fields["draftId"] as? String, Self.isSafeDirectoryName(draftId),
                  let prompt = fields["prompt"] as? String, !prompt.isEmpty,
                  let markdown = fields["markdown"] as? String
            else { throw Failure("AI 请求的字段不对") }
            self.turnId = turnId
            self.draftId = draftId
            backend = fields["backend"] as? String ?? "claude"
            if let session = fields["sessionId"] as? String {
                guard let id = UUID(uuidString: session) else { throw Failure("会话 id 不对：\(session)") }
                sessionId = id
            } else {
                sessionId = nil
            }
            resume = fields["resume"] as? Bool ?? false
            self.prompt = prompt
            self.markdown = markdown
            title = fields["title"] as? String ?? ""
            caption = fields["caption"] as? String ?? ""
            systemPrompt = fields["systemPrompt"] as? String ?? ""
            agentsFile = String((fields["agentsFile"] as? String ?? "").prefix(Self.agentsFileLimit))
            model = fields["model"] as? String
            if let model, !Self.isModel(model) { throw Failure("模型 ID 不对：\(model)") }
            effort = fields["effort"] as? String
            if let effort, !Self.isEffort(effort) { throw Failure("推理强度不对：\(effort)") }
            allowedTools = (fields["allowedTools"] as? [String] ?? []).filter(Self.isRule)
        }

        /// AGENTS.md 最多这么多字（操作手册不到一万字，留足余量）
        static let agentsFileLimit = 200_000

        /// 权限规则只能是一个参数：不空、不换行、不以 `-` 开头（免得被当成选项）
        static func isRule(_ rule: String) -> Bool {
            !rule.isEmpty && rule.count <= 500 && !rule.hasPrefix("-") && !rule.contains(where: \.isNewline)
        }

        /// 推理强度只能是 1–16 个小写字母（low、medium、high、xhigh、max……），免得被当成别的参数
        static func isEffort(_ effort: String) -> Bool {
            effort.range(of: #"^[a-z]{1,16}$"#, options: .regularExpression) != nil
        }

        /// 模型只能是一个参数：1–100 个字母、数字与 `._:@/[]-`，不以 `-` 开头（和页面的检查一样）
        static func isModel(_ model: String) -> Bool {
            model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:@/\[\]-]{0,99}$"#, options: .regularExpression) != nil
        }

        /// 稿子 id 用作工作副本的目录名：只允许字母、数字、`_`、`-`。
        static func isSafeDirectoryName(_ name: String) -> Bool {
            (1...120).contains(name.count) && name.unicodeScalars.allSatisfy {
                ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-"
            }
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// 正在跑的一轮。stdin 的写入与关闭都排在同一个串行队列上，关闭一定在写完之后。
    private final class Turn: @unchecked Sendable {
        let request: TurnRequest
        /// 发起这一轮的窗口：事件只推给它
        let window: String
        let backend: any AIBackend
        let process: Process
        let input: FileHandle
        let directory: URL
        /// 这一轮壳自己记着的（后端用，见 `TurnContext`）
        let context = TurnContext()
        let inputQueue = DispatchQueue(label: "com.wuyoscar.mediacraft.ai.stdin")
        /// 进程退出（terminationHandler）时离开，`terminate` 等它
        let exited = DispatchGroup()
        private let lock = NSLock()
        private var inputOpen = true
        private var cancelledFlag = false
        private var stderrTail = Data()

        init(request: TurnRequest, window: String, backend: any AIBackend, process: Process, input: FileHandle, directory: URL) {
            self.request = request
            self.window = window
            self.backend = backend
            self.process = process
            self.input = input
            self.directory = directory
            exited.enter()
        }

        var cancelled: Bool { lock.withLock { cancelledFlag } }
        func markCancelled() { lock.withLock { cancelledFlag = true } }

        /// 这一轮已经生成（或正在生成）的图有几张：占上 count 张，超出 limit 时不占、返回 false
        private var generatedImages = 0
        func reserveImages(_ count: Int, limit: Int) -> Bool {
            lock.withLock {
                guard generatedImages + count <= limit else { return false }
                generatedImages += count
                return true
            }
        }
        func releaseImages(_ count: Int) { lock.withLock { generatedImages -= count } }
        var imagesGenerated: Int { lock.withLock { generatedImages } }

        /// 排进 stdin，不等写完（开头的几行：写不进去说明进程已经退出，退出会结束这一轮）
        func enqueue(_ data: Data) {
            inputQueue.async { [self] in
                guard lock.withLock({ inputOpen }) else { return }
                try? input.write(contentsOf: data)
            }
        }

        /// 写进 stdin 并等真的写完：写进去了为 true；stdin 已经关上（这一轮说完、停止）为 false；写失败时抛错。
        /// 和 enqueue 排在同一个队列上，先后不乱。
        func deliver(_ data: Data) async throws -> Bool {
            try await withCheckedThrowingContinuation { continuation in
                inputQueue.async { [self] in
                    guard lock.withLock({ inputOpen }) else { return continuation.resume(returning: false) }
                    do {
                        try input.write(contentsOf: data)
                        continuation.resume(returning: true)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        /// 关掉 stdin：claude 答完这一轮、读到 EOF 就退出。
        func closeInput() {
            inputQueue.async { [self] in
                guard lock.withLock({ () -> Bool in
                    defer { inputOpen = false }
                    return inputOpen
                }) else { return }
                try? input.close()
            }
        }

        func appendStderr(_ data: Data) {
            lock.withLock {
                stderrTail.append(data)
                if stderrTail.count > AISessions.stderrLimit { stderrTail = stderrTail.suffix(AISessions.stderrLimit) }
            }
        }

        var stderr: String { lock.withLock { String(decoding: stderrTail, as: UTF8.self) } }

        func signal(_ number: Int32) {
            if process.isRunning { kill(process.processIdentifier, number) }
        }
    }

    private func send(_ request: TurnRequest, window: String, epoch: Int) async throws {
        guard let backend = Self.backends[request.backend], let locator = locators[request.backend] else {
            throw Failure("不认识的 AI 后端：\(request.backend)")
        }
        try backend.validate(request)
        let status = await locator.status(refresh: false)
        guard status.available, let path = status.path else {
            throw Failure(status.error ?? "找不到本机的 \(locator.program.name)")
        }
        let directory = try prepareWorkCopy(for: request)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = backend.arguments(for: request)
        process.environment = status.environment.merging(backend.environment) { $1 }
        process.currentDirectoryURL = directory
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let turn = Turn(request: request, window: window, backend: backend, process: process, input: input.fileHandleForWriting, directory: directory)

        let readers = try launch(turn, epoch: epoch)
        for line in backend.openingLines(for: request) {
            turn.enqueue(try JSONSerialization.data(withJSONObject: line) + Data("\n".utf8))
        }
        startReading(turn, output: output.fileHandleForReading, errors: errors.fileHandleForReading, readers: readers)
    }

    /// 工作副本：这篇稿子的常驻目录（`--resume` 要在同一个目录里），每轮开始时写进最新的卡片内容、标题与小红书正文，
    /// 以及 `AGENTS.md`（操作手册；Codex 自己会读它，Claude Code 的说明书里指向它）。
    private func prepareWorkCopy(for request: TurnRequest) throws -> URL {
        let directory = configuration.root.appendingPathComponent(request.draftId, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(request.markdown.utf8).write(to: directory.appendingPathComponent("draft.md"), options: .atomic)
        try Data(request.title.utf8).write(to: directory.appendingPathComponent("title.txt"), options: .atomic)
        try Data(request.caption.utf8).write(to: directory.appendingPathComponent("caption.txt"), options: .atomic)
        if !request.agentsFile.isEmpty {
            try Data(request.agentsFile.utf8).write(to: directory.appendingPathComponent("AGENTS.md"), options: .atomic)
        }
        return directory
    }

    /// 起进程并登记为这篇稿子正在跑的一轮（epoch：页面发起时这个窗口的页面是第几个，换过页面就不起）。
    /// 返回等两个读管道读完的组（stdout、stderr 各占一个）。
    /// 进程一退出这篇稿子就可以开始下一轮；输出通常随即读完，万一有孙进程占着管道，最多再等 3 秒。
    private func launch(_ turn: Turn, epoch: Int) throws -> DispatchGroup {
        let draftId = turn.request.draftId
        let readers = DispatchGroup()
        readers.enter()
        readers.enter()
        turn.process.terminationHandler = { [self] _ in
            lock.withLock {
                if turns[draftId] === turn { turns[draftId] = nil }
            }
            turn.exited.leave()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                _ = readers.wait(timeout: .now() + 3)
                finish(turn)
            }
        }
        try lock.withLock {
            guard !closedWindows.contains(turn.window) else { throw Failure("这个窗口已经关了") }
            guard windowEpochs[turn.window, default: 0] == epoch else { throw Failure("这个窗口刚重新载入，这一轮没有起") }
            guard !removing.contains(draftId) else { throw Failure("这篇稿子正在删除") }
            guard turns[draftId] == nil else { throw Failure("这篇稿子的 AI 还在回复，先停止或等它说完") }
            try turn.process.run()
            turns[draftId] = turn
            windowDrafts[turn.window, default: []].insert(draftId)
        }
        return readers
    }

    /// 后台读 stdout（推给页面）与 stderr（留最后一段，出错时给页面看），读完各自离组。
    private func startReading(_ turn: Turn, output: FileHandle, errors: FileHandle, readers: DispatchGroup) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            readOutput(output, of: turn)
            readers.leave()
        }
        DispatchQueue.global(qos: .utility).async {
            while let chunk = Self.readAvailable(errors) {
                turn.appendStderr(chunk)
            }
            readers.leave()
        }
    }

    /// 逐行读（每行一个 JSON），每读到一块就把其中的完整行推给页面；后端说这一轮说完了就关掉 stdin 让进程退出（见 `settle`）。
    /// 哪些行不推给页面由后端定（很大、页面用不上的）。
    private func readOutput(_ handle: FileHandle, of turn: Turn) {
        var buffer = Data()
        while let chunk = Self.readAvailable(handle) {
            buffer.append(chunk)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let (forward, finished) = turn.backend.classify(object, context: turn.context)
                if finished { settle(turn) }
                guard forward else { continue }
                if let generated = turn.backend.generatedImages(in: object) {
                    var annotated = generated.line
                    annotated["vibepostCandidates"] = storeGenerated(generated.sources, turn: turn)
                    guard let data = try? JSONSerialization.data(withJSONObject: annotated) else { continue }
                    lines.append(String(decoding: data, as: UTF8.self))
                    continue
                }
                lines.append(String(decoding: line, as: UTF8.self))
            }
            if !lines.isEmpty {
                emit(["type": "lines", "turnId": turn.request.turnId, "draftId": turn.request.draftId, "lines": lines], to: turn.window)
            }
        }
    }

    /// 后端自己生成的图存成这篇的配图候选（见 `GeneratedImages`），在读输出的线程上做完再推这一行，页面收到时候选已经在了。
    /// 正在删的稿子不再存。
    private func storeGenerated(_ sources: [GeneratedImages.Source], turn: Turn) -> [[String: Any]] {
        let draftId = turn.request.draftId
        return sources.map { source in
            do {
                guard !lock.withLock({ removing.contains(draftId) }) else { throw Failure("这篇稿子正在删除") }
                switch source {
                case .file(let file):
                    return try candidates.store(draftId: draftId, generated: file, name: "生图").fields
                case .data(let data):
                    return try candidates.store(draftId: draftId, data: data, name: "生图").fields
                }
            } catch {
                return ["error": error.localizedDescription]
            }
        }
    }

    /// 读到多少算多少（FileHandle.read(upToCount:) 读管道时要凑满才返回，流式输出不能用）；读完（EOF）或出错时为 nil。
    private static func readAvailable(_ handle: FileHandle) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(handle.fileDescriptor, &buffer, buffer.count)
            if count > 0 { return Data(buffer[0..<count]) }
            if count < 0 && errno == EINTR { continue }
            return nil
        }
    }

    /// 进程退出、输出读完：把工作副本读回来一起交给页面（页面决定怎样套用到稿子上）。
    private func finish(_ turn: Turn) {
        turn.closeInput()
        images.cancel(draftId: turn.request.draftId)
        turn.process.terminationHandler = nil
        approvals.endTurn(turn.request.turnId)
        let read = { (name: String) -> Any in
            (try? String(contentsOf: turn.directory.appendingPathComponent(name), encoding: .utf8)) ?? NSNull()
        }
        let process = turn.process
        let signaled = process.terminationReason == .uncaughtSignal
        emit(to: turn.window, [
            "type": "exit",
            "turnId": turn.request.turnId,
            "draftId": turn.request.draftId,
            "status": signaled ? NSNull() : process.terminationStatus,
            "signal": signaled ? process.terminationStatus : NSNull(),
            "cancelled": turn.cancelled,
            "stderr": turn.stderr,
            "markdown": read("draft.md"),
            "title": read("title.txt"),
            "caption": read("caption.txt"),
        ])
    }

    private func emit(_ event: [String: Any], to window: String) {
        guard let sink = lock.withLock({ sink }),
              let data = try? JSONSerialization.data(withJSONObject: event)
        else { return }
        sink(String(decoding: data, as: UTF8.self), window)
    }

    private func emit(to window: String, _ event: [String: Any]) {
        emit(event, to: window)
    }

    /// 说完了：关上 stdin，进程读到 EOF 就退出；过了 exitGrace 还没退出（还有别的事占着它）就 SIGTERM，再不退出 SIGKILL。
    private func settle(_ turn: Turn) {
        turn.closeInput()
        let grace = configuration.exitGrace.dispatchInterval
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            guard turn.process.isRunning else { return }
            turn.signal(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminateGrace) {
                turn.signal(SIGKILL)
            }
        }
    }

    // MARK: - 停止

    /// 停止这篇稿子正在跑的一轮（只停 window 这个窗口发起的；window 为 nil 时不论哪个窗口，删稿子时用）：
    /// 先 SIGINT（claude 会中断这一轮），不退出再 SIGTERM、SIGKILL。
    func cancel(draftId: String, window: String? = nil) -> Bool {
        guard let turn = lock.withLock({ turns[draftId] }), window == nil || turn.window == window else { return false }
        images.cancel(draftId: draftId)
        turn.markCancelled()
        turn.signal(SIGINT)
        turn.closeInput()
        let grace = configuration.cancelGrace.dispatchInterval
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            guard turn.process.isRunning else { return }
            turn.signal(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                turn.signal(SIGKILL)
            }
        }
        return true
    }

    /// 结束进程：window 这个窗口发起的（它重新载入、关掉时），window 为 nil 时全部（App 退出时）。
    /// 先 SIGTERM 并关上 stdin，约 1.5 秒后还没退出的 SIGKILL。
    /// 不阻塞调用的线程（通常是主线程）；都退出后在主线程调 completion（App 退出时等它再退）。
    func terminate(window: String? = nil, completion: (@Sendable () -> Void)? = nil) {
        let running = lock.withLock { () -> [Turn] in
            if let window { windowEpochs[window, default: 0] += 1 }
            return turns.values.filter { window == nil || $0.window == window }
        }
        let exited = DispatchGroup()
        for turn in running {
            turn.markCancelled()
            turn.signal(SIGTERM)
            turn.closeInput()
            exited.enter()
            turn.exited.notify(queue: .global()) { exited.leave() }
        }
        if !running.isEmpty {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminateGrace) {
                for turn in running { turn.signal(SIGKILL) }
            }
        }
        exited.notify(queue: .main) { completion?() }
    }

    /// 这个窗口关掉了：结束它发起的进程，之后它的页面还在路上的请求也不再起进程
    func close(window: String) {
        lock.withLock { _ = closedWindows.insert(window) }
        terminate(window: window)
        forgetApprovals(window: window)
    }

    /// 这个窗口换了一个页面（重新载入）或关掉了：它的稿子的配图放行记录跟着页面里的「本次会话都允许」一起忘掉
    func forgetApprovals(window: String) {
        let drafts = lock.withLock { windowDrafts.removeValue(forKey: window) ?? [] }
        for draftId in drafts { approvals.forget(draftId: draftId) }
    }
}
