import Foundation

/// AI 会话（本机的 Claude Code、Codex）放在哪、怎样找到它们。
public struct AIConfiguration: Sendable {
    /// 每篇稿子的工作副本（`<稿子 id>/draft.md`、`title.txt`）与设置（`settings.json`）
    public var root: URL
    /// 用户的登录 shell。从访达打开的 App 不继承终端的 PATH，要靠它读出终端里的环境变量。
    public var loginShell: URL
    /// 停止一轮时先发 SIGINT，过这么久还没退出发 SIGTERM，再过这么久 SIGKILL。
    public var cancelGrace: Duration
    /// 说完、关上 stdin 之后最多等后端的进程自己退出这么久，还没退出就结束它（SIGTERM，再不退出 SIGKILL）。
    public var exitGrace: Duration
    /// 读登录 shell 的环境变量最多等这么久（含读完输出）；到了就结束它和它启动的所有进程。
    public var shellTimeout: Duration
    /// App 自己的环境变量：登录 shell 在它之上运行，读不出终端的环境时退回它。
    public var appEnvironment: [String: String]
    /// 生图工具（generate_image）调的接口
    public var imageAPI: ImageAPI
    /// 登录 shell 的环境里没有生图密钥时再找这个 dotenv 文件（默认 `~/.env`，和 gpt-image 技能读的一样）
    public var keyFile: URL

    public init(
        root: URL, loginShell: URL, cancelGrace: Duration = .seconds(2), exitGrace: Duration = .seconds(10),
        shellTimeout: Duration = .seconds(15), appEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        imageAPI: ImageAPI = .standard,
        keyFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".env")
    ) {
        self.root = root
        self.loginShell = loginShell
        self.cancelGrace = cancelGrace
        self.exitGrace = exitGrace
        self.shellTimeout = shellTimeout
        self.appEnvironment = appEnvironment
        self.imageAPI = imageAPI
        self.keyFile = keyFile
    }

    /// `~/Library/Application Support/MediaCraft/ai`，登录 shell 取账户设置里的那个。
    public static var standard: AIConfiguration {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var shell = "/bin/zsh"
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_shell, !String(cString: path).isEmpty {
            shell = String(cString: path)
        }
        return AIConfiguration(root: support.appendingPathComponent("MediaCraft/ai"), loginShell: URL(fileURLWithPath: shell))
    }
}

/// 要找的一个命令行 Agent：在 PATH 里找的可执行文件名、设置里指定路径的键、找到之后还要确认的（codex：登录了没有）。
struct AgentProgram: Sendable {
    /// 可执行文件名（claude / codex），出错说明里也这样称呼它
    let name: String
    /// 设置（settings.json）里指定路径的键
    let settingsKey: String
    /// 找到、能运行之后还要确认的：返回不能用的原因，能用为 nil
    let check: (@Sendable (_ path: String, _ environment: [String: String]) async -> String?)?

    static let claude = AgentProgram(name: "claude", settingsKey: "claudePath", check: nil)
    /// Codex 要先用 ChatGPT（或 API key）登录过：`codex login status` 退出码不是 0 就是没登录
    static let codex = AgentProgram(name: "codex", settingsKey: "codexPath") { path, environment in
        let result = try? await Subprocess.run(URL(fileURLWithPath: path), ["login", "status"], environment: environment, timeout: .seconds(10))
        return result?.status == 0 ? nil : "Codex 还没有登录：在终端里运行一次 codex login"
    }
}

/// 找到的程序：可执行文件、版本，以及启动它要用的环境变量（终端里的那一套）。
struct AgentStatus: Sendable {
    var available = false
    var path: String?
    var version: String?
    /// "settings"：在设置里指定的；"login-shell"：在终端的 PATH 里找到的
    var source: String?
    var error: String?
    /// 不能用的原因（页面的指引照它说怎么办）："missing" 没找到，"broken" 找到了但运行不起来，"login" 还没登录（codex）
    var reason: String?
    var environment: [String: String] = [:]

    var fields: [String: Any] {
        [
            "available": available,
            "path": path ?? NSNull(),
            "version": version ?? NSNull(),
            "source": source ?? NSNull(),
            "error": error ?? NSNull(),
            "reason": reason ?? NSNull(),
        ]
    }
}

/// 终端里的环境变量：`登录 shell -l -i -c env -0`，几个程序共用一份，到要求重新查找时再读。
/// 读不出来时退回 App 自己的环境，并记下原因。
actor TerminalEnvironment {
    private static let envMarker = "__MEDIACRAFT_ENV__"
    private static let endMarker = "__MEDIACRAFT_END__"

    struct Snapshot: Sendable {
        let variables: [String: String]
        /// 登录 shell 出了什么问题（没问题为 nil）
        let failure: String?
    }

    private let configuration: AIConfiguration
    private var cached: Snapshot?

    init(configuration: AIConfiguration) {
        self.configuration = configuration
    }

    func snapshot(refresh: Bool) async -> Snapshot {
        if !refresh, let cached { return cached }
        let script = "printf '\\n\(Self.envMarker)\\n'; /usr/bin/env -0; printf '\(Self.endMarker)'"
        let shell = configuration.loginShell.path
        var environment = configuration.appEnvironment
        var failure: String?
        do {
            let result = try await Subprocess.run(
                configuration.loginShell, ["-l", "-i", "-c", script], environment: environment, timeout: configuration.shellTimeout
            )
            if let parsed = Self.parseEnvironment(result.stdout) {
                environment = parsed
            } else {
                let reason = String(decoding: result.stderr, as: UTF8.self).split(separator: "\n").last
                    .map { "：\($0.trimmingCharacters(in: .whitespaces).prefix(200))" } ?? ""
                failure = "登录 shell \(shell) 没有输出环境变量，退出码 \(result.status)\(reason)"
            }
        } catch {
            failure = "登录 shell \(shell) \(error.localizedDescription)"
        }
        for key in ["PWD", "OLDPWD", "SHLVL", "_"] { environment[key] = nil }
        let snapshot = Snapshot(variables: environment, failure: failure)
        cached = snapshot
        return snapshot
    }

    /// 标记之间是 `env -0` 的输出（每项以 NUL 结尾）；前面可能混着 shell 集成打印的转义序列。
    static func parseEnvironment(_ output: Data) -> [String: String]? {
        let text = String(decoding: output, as: UTF8.self)
        guard let start = text.range(of: envMarker + "\n"),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
        else { return nil }
        var environment: [String: String] = [:]
        for entry in text[start.upperBound..<end.lowerBound].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment.isEmpty ? nil : environment
    }
}

/// 查找本机的一个命令行 Agent（claude、codex）：设置里指定的路径优先，否则在登录 shell 的 PATH 里找；结果缓存到下次要求重新查找。
actor AgentLocator {
    private static let versionTimeout: Duration = .seconds(10)

    let program: AgentProgram
    private let settings: AgentSettings
    private let terminal: TerminalEnvironment
    private var cached: AgentStatus?
    /// 正在进行的查找：没有要求重新查找的调用者等它，不另起一次
    private var pending: Task<AgentStatus, Never>?

    init(program: AgentProgram, settings: AgentSettings, terminal: TerminalEnvironment) {
        self.program = program
        self.settings = settings
        self.terminal = terminal
    }

    /// 查找之间会等（登录 shell、`--version`、codex 的登录检查），期间可能又开始了新的查找（改了路径、重新查找）：
    /// 以最后开始的那次为准，早开始的晚回来也不覆盖它，等它的调用者拿到的也是最新的。
    func status(refresh: Bool) async -> AgentStatus {
        if !refresh, let cached { return cached }
        if !refresh, let pending { return await pending.value }
        let lookup = Task { await locate(refresh: refresh) }
        pending = lookup
        let status = await lookup.value
        if pending == lookup {
            pending = nil
            cached = status
        }
        if let newer = pending { return await newer.value }
        return cached ?? status
    }

    /// 在设置里指定这个程序的路径；nil 或空字符串恢复自动查找。别的程序的设置原样留着。
    func setPath(_ path: String?) async throws -> AgentStatus {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try await settings.set(program.settingsKey, trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath)
        return await status(refresh: true)
    }

    private func locate(refresh: Bool) async -> AgentStatus {
        let login = await terminal.snapshot(refresh: refresh)
        let environment = login.variables
        let name = program.name
        var status: AgentStatus
        if let path = await settings.value(program.settingsKey) {
            status = await verify(path: path, source: "settings", environment: environment)
        } else if let path = (environment["PATH"] ?? "").split(separator: ":").lazy
            .map({ (String($0) as NSString).appendingPathComponent(name) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            status = await verify(path: path, source: "login-shell", environment: environment)
        } else {
            status = AgentStatus(error: "在终端的 PATH 里没有找到 \(program.name)", reason: "missing", environment: environment)
        }
        // 没找到、跑不起来时，登录 shell 出过的问题也说出来：多半就是它让 PATH 不对
        if !status.available, let failure = login.failure, let error = status.error {
            status.error = "\(error)（\(failure)）"
        }
        return status
    }

    /// 跑一次 `<程序> --version`：确认能启动（npm 装的要找得到 node），顺便拿到版本号；再做这个程序自己的检查。
    private func verify(path: String, source: String, environment: [String: String]) async -> AgentStatus {
        var status = AgentStatus(path: path, source: source, environment: Self.environment(environment, program: path))
        guard FileManager.default.isExecutableFile(atPath: path) else {
            status.error = "这个路径不是可以运行的 \(program.name)：\(path)"
            status.reason = "missing"
            return status
        }
        do {
            let result = try await Subprocess.run(
                URL(fileURLWithPath: path), ["--version"], environment: status.environment, timeout: Self.versionTimeout
            )
            let output = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0, let version = Self.version(in: output) else {
                let reason = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                status.error = "\(program.name) 运行失败：\(reason.isEmpty ? "退出码 \(result.status)" : String(reason.prefix(300)))"
                status.reason = "broken"
                return status
            }
            status.version = version
        } catch {
            status.error = "\(program.name) 运行失败：\(error.localizedDescription)"
            status.reason = "broken"
            return status
        }
        if let problem = await program.check?(path, status.environment) {
            status.error = problem
            status.reason = "login"
            return status
        }
        status.available = true
        return status
    }

    /// 版本输出里第一段像版本号的（「2.1.280 (Claude Code)」「codex-cli 0.157.0」）；都不像时取第一段
    static func version(in output: String) -> String? {
        let words = output.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.first { $0.range(of: #"^v?\d+(\.\d+)+"#, options: .regularExpression) != nil } ?? words.first
    }

    /// 程序所在目录放到 PATH 最前：npm 装的 claude、codex 是 `#!/usr/bin/env node`，node 就在它旁边。
    private static func environment(_ base: [String: String], program path: String) -> [String: String] {
        var environment = base
        let directory = (path as NSString).deletingLastPathComponent
        environment["PATH"] = [directory, base["PATH"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
        return environment
    }
}

/// 在「AI 设置」里指定的程序路径（`<AI 根目录>/settings.json`，如 `{ "claudePath": …, "codexPath": … }`）。
/// 几个程序的查找共用这一个，读改写排着来，同时保存两个路径也不会丢掉一个。
actor AgentSettings {
    private let file: URL

    init(root: URL) {
        file = root.appendingPathComponent("settings.json")
    }

    private func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return settings
    }

    func value(_ key: String) -> String? {
        guard let value = read()[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// nil 时删掉这一项；别的项原样留着
    func set(_ key: String, _ value: String?) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var settings = read()
        settings[key] = value
        try JSONSerialization.data(withJSONObject: settings).write(to: file, options: .atomic)
    }
}

/// 跑一个短命令并收集输出。命令在自己的进程组里运行；总超时（含读完输出）到了就结束整个进程组
/// （登录 shell 与它启动的子进程一起），不再等输出。
enum Subprocess {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    struct Timeout: LocalizedError {
        let seconds: Int64
        var errorDescription: String? { "没有在 \(seconds) 秒内结束，已结束它和它启动的所有进程" }
    }

    struct LaunchFailure: LocalizedError {
        let code: Int32
        var errorDescription: String? { "启动失败：\(String(cString: strerror(code)))" }
    }

    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try SubprocessJob.launch(executable, arguments, environment: environment, timeout: timeout) {
                    continuation.resume(with: $0)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// 一次 `Subprocess.run`：posix_spawn 让子进程自成一个进程组（超时时 kill 整组），stdin 接 /dev/null，
/// 别的文件描述符都不带过去；stdout、stderr 用非阻塞的读源收集。状态只在自己的串行队列上改。
/// 进程退出后先不回收（`waitid` 带 `WNOWAIT`，留着僵尸），直到这次运行结束：组号一直归这次启动的进程，
/// 超时时对进程组发的 SIGKILL 不会落到系统重新分配了这个号码的别的进程组上。
private final class SubprocessJob: @unchecked Sendable {
    typealias Completion = (Result<Subprocess.Result, Error>) -> Void

    private let pid: pid_t
    private let queue = DispatchQueue(label: "com.wuyoscar.mediacraft.subprocess")
    private var output = [Data(), Data()]
    private var readers: [DispatchSourceRead] = []
    private var openReaders = 2
    private var status: Int32?
    private var completion: Completion?
    private var reaped = false

    private init(pid: pid_t, completion: @escaping Completion) {
        self.pid = pid
        self.completion = completion
    }

    static func launch(
        _ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration,
        completion: @escaping Completion
    ) throws {
        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { throw Subprocess.LaunchFailure(code: errno) }
        guard pipe(&errorPipe) == 0 else {
            let code = errno
            outputPipe.forEach { close($0) }
            throw Subprocess.LaunchFailure(code: code)
        }
        let pid: pid_t
        do {
            pid = try spawn(executable, arguments, environment: environment, stdout: outputPipe[1], stderr: errorPipe[1])
        } catch {
            (outputPipe + errorPipe).forEach { close($0) }
            throw error
        }
        close(outputPipe[1])
        close(errorPipe[1])
        SubprocessJob(pid: pid, completion: completion).start(reading: [outputPipe[0], errorPipe[0]], timeout: timeout)
    }

    private static func spawn(
        _ executable: URL, _ arguments: [String], environment: [String: String], stdout: Int32, stderr: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        // 自成一个进程组（组号就是自己的进程号），只带 0、1、2 过去，信号处理恢复默认（App 忽略了 SIGPIPE）
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard code == 0 else { throw Subprocess.LaunchFailure(code: code) }
        return pid
    }

    private func start(reading descriptors: [Int32], timeout: Duration) {
        queue.sync {
            for (index, descriptor) in descriptors.enumerated() {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
                let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                reader.setEventHandler { [self] in drain(descriptor, into: index, reader: reader) }
                reader.setCancelHandler { [self] in
                    close(descriptor)
                    openReaders -= 1
                    finishIfDone()
                }
                readers.append(reader)
                reader.resume()
            }
        }
        // 等进程退出（不回收，见上），放在别的线程上；进程组被 kill 后它随即返回
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
            queue.async { [self] in
                status = Self.exitStatus(info)
                finishIfDone()
                reapIfFinished()
            }
        }
        queue.asyncAfter(deadline: .now() + timeout.dispatchInterval) { [self] in
            // 还没结束就一定还没回收：组号仍是这次启动的进程的
            guard completion != nil else { return }
            kill(-pid, SIGKILL)
            // 进程已经退出、只是还有它启动的进程占着输出：用已经读到的；进程还没退出才算超时
            if let status {
                finish(.success(Subprocess.Result(status: status, stdout: output[0], stderr: output[1])))
            } else {
                finish(.failure(Subprocess.Timeout(seconds: timeout.components.seconds)))
            }
        }
    }

    /// 读源有数据时读到没有为止；读完（EOF）或出错时关掉这个读源
    private func drain(_ descriptor: Int32, into index: Int, reader: DispatchSourceRead) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                output[index].append(contentsOf: buffer[0..<count])
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                if !(count < 0 && errno == EAGAIN) { reader.cancel() }
                return
            }
        }
    }

    private func finishIfDone() {
        guard let status, openReaders == 0 else { return }
        finish(.success(Subprocess.Result(status: status, stdout: output[0], stderr: output[1])))
    }

    private func finish(_ result: Result<Subprocess.Result, Error>) {
        guard let completion else { return }
        self.completion = nil
        readers.forEach { $0.cancel() }
        completion(result)
        reapIfFinished()
    }

    /// 这次运行结束、进程也已经退出了：回收它（之后组号才会被系统重新分配）
    private func reapIfFinished() {
        guard completion == nil, status != nil, !reaped else { return }
        reaped = true
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) < 0 && errno == EINTR {}
    }

    /// waitid 的结果 → 退出码；被信号结束时是 128 + 信号（和 shell 一样）
    private static func exitStatus(_ info: siginfo_t) -> Int32 {
        info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
    }
}

extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
