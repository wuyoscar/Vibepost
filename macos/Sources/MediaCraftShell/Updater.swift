import CryptoKit
import Foundation
import OSLog

let updateLog = Logger(subsystem: "com.wuyoscar.mediacraft", category: "update")

/// 版本号：按数字段比较（0.6.0 > 0.5.10 > 0.5.1；0.6 与 0.6.0 相同），可以带开头的 v（tag 的写法）
public struct UpdateVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let parts: [Int]
    public let description: String

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" { trimmed.removeFirst() }
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 6, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(piece) else { return nil }
            parts.append(value)
        }
        self.parts = parts
        description = trimmed
    }

    private var padded: [Int] { parts + Array(repeating: 0, count: 4 - parts.count) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.padded.lexicographicallyPrecedes(rhs.padded) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.padded == rhs.padded }
    public func hash(into hasher: inout Hasher) { hasher.combine(padded) }
}

/// 检查、下载、安装更新时出的错（说给用户听的原因）
public enum UpdateError: LocalizedError, Equatable {
    case developmentBuild
    case network(String)
    case needsCLI(String)
    case cli(String)
    case badRelease(String)
    case missingAsset(String)
    case checksumMismatch
    case wrongApp(String)
    case tool(String)
    case notWritable(String)

    public var errorDescription: String? {
        switch self {
        case .developmentBuild: "开发版不检查更新（用 macos/build-app.sh 重新构建）"
        case .network(let reason): "连不上 GitHub：\(reason)"
        case .needsCLI(let repository):
            "GitHub 上看不到 \(repository) 的 Release：仓库是私有的话，先在终端里装好并登录 GitHub CLI（brew install gh，再 gh auth login）"
        case .cli(let reason): "GitHub CLI（gh）出错：\(reason)"
        case .badRelease(let reason): "Release 的信息不对：\(reason)"
        case .missingAsset(let name): "Release 里没有 \(name)"
        case .checksumMismatch: "下载的 DMG 和 Release 里的校验和对不上（可能没下载完整），没有安装"
        case .wrongApp(let reason): "DMG 里的 App 不对，没有安装：\(reason)"
        case .tool(let reason): reason
        case .notWritable(let path): "没有权限替换 \(path)：已经打开新版的 DMG，把 Vibepost 拖进「应用程序」就行"
        }
    }
}

/// GitHub 上的一个 Release（只用得到的几项）
public struct UpdateRelease: Sendable {
    public let version: UpdateVersion
    public let tag: String
    /// 更新说明（Release 的正文）
    public let notes: String
    let assets: [UpdateAsset]
    /// 经哪条路拿到的：直接下载（公开仓库），还是借 gh（私有仓库）
    let via: UpdateChannel

    /// 安装用的 DMG 与它的校验和：`Vibepost-<版本>.dmg`、`Vibepost-<版本>.dmg.sha256`（scripts/make-dmg.sh 生成）
    var dmgName: String { "Vibepost-\(version).dmg" }

    static func parse(_ data: Data, via: UpdateChannel) throws -> UpdateRelease {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UpdateError.badRelease("不是 JSON")
        }
        guard let tag = object["tag_name"] as? String, let version = UpdateVersion(tag) else {
            throw UpdateError.badRelease("tag \(object["tag_name"] as? String ?? "（没有）") 不是版本号")
        }
        let assets = (object["assets"] as? [[String: Any]] ?? []).compactMap { item -> UpdateAsset? in
            guard let name = item["name"] as? String else { return nil }
            let url = (item["browser_download_url"] as? String).flatMap(URL.init(string:))
            return UpdateAsset(name: name, url: url, size: item["size"] as? Int ?? 0)
        }
        return UpdateRelease(version: version, tag: tag, notes: object["body"] as? String ?? "", assets: assets, via: via)
    }
}

struct UpdateAsset: Sendable {
    let name: String
    let url: URL?
    let size: Int
}

enum UpdateChannel: Sendable {
    case web
    case cli(GitHubCLI)
}

/// 本机的 GitHub CLI（gh）与运行它要用的环境变量（终端里的那一套，含它的登录状态）
public struct GitHubCLI: Sendable {
    public let path: String
    public let environment: [String: String]

    public init(path: String, environment: [String: String]) {
        self.path = path
        self.environment = environment
    }

    /// 在终端的 PATH 里找 gh（从访达打开的 App 不继承终端的 PATH），再看 Homebrew 的两个默认位置。
    /// 只把 gh 用得到的环境变量交给它（登录信息在 HOME 下的配置或钥匙串里，另认 GH_* / GITHUB_* 与代理），终端里别的密钥不带过去
    static func locate(in terminal: TerminalEnvironment) async -> GitHubCLI? {
        let variables = await terminal.snapshot(refresh: false).variables
        let directories = (variables["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let path = directories.lazy.map({ ($0 as NSString).appendingPathComponent("gh") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return GitHubCLI(path: path, environment: variables.filter { Self.passes($0.key) })
    }

    static func passes(_ name: String) -> Bool {
        let exact: Set = ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL", "SSH_AUTH_SOCK", "NO_PROXY", "no_proxy"]
        let prefixes = ["GH_", "GITHUB_", "XDG_", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]
        return exact.contains(name) || prefixes.contains { name.hasPrefix($0) }
    }
}

/// 更新的来源：GitHub 上这个仓库的最新 Release。先不带凭据直接问 GitHub；问不到（私有仓库是 404）时借本机登录好的 gh。
public struct GitHubReleases: Sendable {
    public let repository: String
    let api: URL
    let cli: @Sendable () async -> GitHubCLI?
    /// DMG 再大也不会超过这么多，超了就是不对
    static let sizeLimit = 1 << 30

    public init(repository: String, api: URL = URL(string: "https://api.github.com")!, cli: @escaping @Sendable () async -> GitHubCLI?) {
        self.repository = repository
        self.api = api
        self.cli = cli
    }

    func latest() async throws -> UpdateRelease {
        var request = URLRequest(url: api.appendingPathComponent("repos/\(repository)/releases/latest"), timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let status: Int
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            data = body
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        if status == 200 { return try UpdateRelease.parse(data, via: .web) }
        guard [401, 403, 404].contains(status) else { throw UpdateError.network("GitHub 回了 HTTP \(status)") }
        guard let cli = await cli() else { throw UpdateError.needsCLI(repository) }
        let result = try await run(cli, ["api", "repos/\(repository)/releases/latest"], timeout: .seconds(30))
        return try UpdateRelease.parse(result, via: .cli(cli))
    }

    /// 把 Release 里的一个附件下载进 directory，返回下载好的文件
    func download(_ asset: UpdateAsset, of release: UpdateRelease, into directory: URL) async throws -> URL {
        guard asset.size <= Self.sizeLimit else { throw UpdateError.badRelease("\(asset.name) 有 \(asset.size) 字节，太大了") }
        let destination = directory.appendingPathComponent(asset.name)
        try? FileManager.default.removeItem(at: destination)
        switch release.via {
        case .web:
            guard let url = asset.url else { throw UpdateError.badRelease("\(asset.name) 没有下载地址") }
            do {
                let (temporary, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw UpdateError.network("下载 \(asset.name) 时 GitHub 回了 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch let error as UpdateError {
                throw error
            } catch {
                throw UpdateError.network(error.localizedDescription)
            }
        case .cli(let cli):
            _ = try await run(cli, [
                "release", "download", release.tag, "--repo", repository, "--pattern", asset.name, "--dir", directory.path, "--clobber",
            ], timeout: .seconds(900))
        }
        guard FileManager.default.fileExists(atPath: destination.path) else { throw UpdateError.missingAsset(asset.name) }
        return destination
    }

    private func run(_ cli: GitHubCLI, _ arguments: [String], timeout: Duration) async throws -> Data {
        let result: Subprocess.Result
        do {
            result = try await Subprocess.run(URL(fileURLWithPath: cli.path), arguments, environment: cli.environment, timeout: timeout)
        } catch {
            throw UpdateError.cli(error.localizedDescription)
        }
        guard result.status == 0 else {
            let reason = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.cli(reason.isEmpty ? "退出码 \(result.status)" : String(reason.prefix(300)))
        }
        return result.stdout
    }
}

/// 检查更新与安装：「Vibepost › 检查更新…」与每天一次的自动检查（main.swift 接界面）。
/// - 检查：GitHub 上最新的 Release 比现在的版本新才算有更新。
/// - 准备：下载 DMG 与校验和 → 核对校验和 → 只读挂载 → 里面的 App 包名、版本号与 Release 一致、签名完好
///   （现在的 App 用了正式签名时，新 App 还要是同一个开发者）→ 拷到暂存目录 → 卸载。
/// - 安装：起一个独立的小脚本，等 App 退出后把旧 App 挪进废纸篓、新 App 放到原处（失败就把旧的挪回来），要的话再打开它。
@MainActor
public final class Updater {
    public enum Check: Sendable {
        case upToDate(UpdateVersion)
        case available(UpdateRelease)
    }

    /// 下载、核对好了的新版：暂存目录里的 App 与下载的 DMG
    public struct Prepared: Sendable {
        public let release: UpdateRelease
        public let app: URL
        public let dmg: URL
    }

    public let current: UpdateVersion
    let bundleURL: URL
    let bundleIdentifier: String
    let source: GitHubReleases
    let staging: URL
    let trash: URL
    let defaults: UserDefaults
    let enabled: Bool

    static let lastCheckKey = "MCUpdateLastCheck"
    static let skippedKey = "MCUpdateSkippedVersion"
    /// 自动检查的间隔
    static let interval: TimeInterval = 24 * 60 * 60

    public init(
        current: UpdateVersion, bundleURL: URL, bundleIdentifier: String, source: GitHubReleases,
        staging: URL, trash: URL, defaults: UserDefaults, enabled: Bool = true
    ) {
        self.current = current
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.source = source
        self.staging = staging
        self.trash = trash
        self.defaults = defaults
        self.enabled = enabled
    }

    /// 正在运行的这个 App：版本、位置与仓库取自它的 Info.plist（仓库是构建脚本写的 MCUpdateRepository）；
    /// Debug 构建（直接读仓库网页）不检查更新。
    public static func forRunningApp() -> Updater {
        let bundle = Bundle.main
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(UpdateVersion.init)
        let repository = bundle.object(forInfoDictionaryKey: "MCUpdateRepository") as? String ?? "wuyoscar/Vibepost"
        let terminal = TerminalEnvironment(configuration: .standard)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let trash = (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: bundle.bundleURL, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return Updater(
            current: version ?? UpdateVersion("0")!, bundleURL: bundle.bundleURL,
            bundleIdentifier: bundle.bundleIdentifier ?? "com.wuyoscar.mediacraft",
            source: GitHubReleases(repository: repository) { await GitHubCLI.locate(in: terminal) },
            staging: caches.appendingPathComponent("MediaCraft/update"), trash: trash, defaults: .standard,
            enabled: version != nil && bundle.object(forInfoDictionaryKey: "MCWebRoot") == nil
        )
    }

    // MARK: - 检查

    public func check() async throws -> Check {
        guard enabled else { throw UpdateError.developmentBuild }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        let release = try await source.latest()
        updateLog.notice("最新的 Release 是 \(release.tag, privacy: .public)，现在是 \(self.current.description, privacy: .public)")
        return release.version > current ? .available(release) : .upToDate(current)
    }

    /// 到了该自动检查的时候（上次检查超过一天，或者没查过）
    public func dueForAutomaticCheck(now: Date = Date()) -> Bool {
        guard enabled else { return false }
        guard let last = defaults.object(forKey: Self.lastCheckKey) as? Date else { return true }
        return now.timeIntervalSince(last) >= Self.interval || now < last
    }

    public func skip(_ version: UpdateVersion) {
        defaults.set(version.description, forKey: Self.skippedKey)
    }

    public func isSkipped(_ version: UpdateVersion) -> Bool {
        (defaults.string(forKey: Self.skippedKey)).flatMap(UpdateVersion.init) == version
    }

    // MARK: - 准备

    public func prepare(_ release: UpdateRelease) async throws -> Prepared {
        guard let dmgAsset = release.assets.first(where: { $0.name == release.dmgName }) else {
            throw UpdateError.missingAsset(release.dmgName)
        }
        guard let checksumAsset = release.assets.first(where: { $0.name == "\(release.dmgName).sha256" }) else {
            throw UpdateError.missingAsset("\(release.dmgName).sha256")
        }
        let work = staging.appendingPathComponent(release.version.description)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = try await source.download(dmgAsset, of: release, into: work)
        let checksumFile = try await source.download(checksumAsset, of: release, into: work)
        let expected = (try? String(contentsOf: checksumFile, encoding: .utf8))?
            .split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        let actual = try await Task.detached { try Self.sha256(of: dmg) }.value
        guard expected.count == 64, expected == actual else { throw UpdateError.checksumMismatch }

        let mount = work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await tool("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path], "挂载 DMG")
        let staged = work.appendingPathComponent("Vibepost.app")
        do {
            let app = mount.appendingPathComponent("Vibepost.app")
            guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.wrongApp("DMG 里没有 Vibepost.app") }
            try await verify(app, version: release.version)
            try await tool("/usr/bin/ditto", [app.path, staged.path], "拷出新版")
        } catch {
            await detach(mount)
            throw error
        }
        await detach(mount)
        updateLog.notice("已经准备好 \(release.tag, privacy: .public)：\(staged.path, privacy: .public)")
        return Prepared(release: release, app: staged, dmg: dmg)
    }

    /// 包名、版本号与 Release 一致，签名完好；现在的 App 是正式签名（有开发者团队）时新 App 也得是同一个团队
    func verify(_ app: URL, version: UpdateVersion) async throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let identifier = info["CFBundleIdentifier"] as? String ?? "（没有）"
        guard identifier == bundleIdentifier else { throw UpdateError.wrongApp("包名是 \(identifier)，不是 \(bundleIdentifier)") }
        let found = info["CFBundleShortVersionString"] as? String ?? "（没有）"
        guard UpdateVersion(found) == version else { throw UpdateError.wrongApp("版本是 \(found)，Release 写的是 \(version)") }
        let check = try await Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path], environment: [:], timeout: .seconds(120)
        )
        guard check.status == 0 else {
            let reason = String(decoding: check.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.wrongApp("签名不完整：\(reason.prefix(200))")
        }
        if let team = await Self.team(of: bundleURL), await Self.team(of: app) != team {
            throw UpdateError.wrongApp("签名的开发者和现在的 App 不是同一个")
        }
    }

    /// 签名里的开发者团队（ad-hoc 签名没有）
    static func team(of app: URL) async -> String? {
        guard let result = try? await Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/codesign"), ["-dv", "--verbose=2", app.path], environment: [:], timeout: .seconds(30)
        ) else { return nil }
        let text = String(decoding: result.stderr, as: UTF8.self)
        let team = text.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
        return team == "not set" ? nil : team
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func tool(_ path: String, _ arguments: [String], _ what: String) async throws {
        let result = try await Subprocess.run(URL(fileURLWithPath: path), arguments, environment: [:], timeout: .seconds(300))
        guard result.status == 0 else {
            let reason = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.tool("\(what)失败：\(reason.isEmpty ? "退出码 \(result.status)" : String(reason.prefix(200)))")
        }
    }

    private func detach(_ mount: URL) async {
        for arguments in [["detach", mount.path, "-quiet"], ["detach", mount.path, "-quiet", "-force"]] {
            if (try? await Subprocess.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments, environment: [:], timeout: .seconds(60)))?.status == 0 {
                return
            }
        }
    }

    // MARK: - 安装

    /// App 所在的位置能不能直接替换（不能的话打开 DMG 让用户自己拖）
    public var canReplace: Bool {
        let manager = FileManager.default
        return manager.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) && manager.isWritableFile(atPath: bundleURL.path)
    }

    /// 起替换脚本：等进程 pid（默认就是这个 App）退出，旧 App 进废纸篓、新 App 放原处，失败就把旧的挪回来；relaunch 时再打开它。
    /// 调用之后 App 应该退出（main.swift 在存完稿之后调用）。
    public func install(_ prepared: Prepared, relaunch: Bool, waitingFor pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        guard canReplace else { throw UpdateError.notWritable(bundleURL.path) }
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let backup = ShellWebView.uniqueURL(in: trash, name: "Vibepost \(current).app")
        let script = staging.appendingPathComponent("install.sh")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(pid), bundleURL.path, prepared.app.path, backup.path, relaunch ? "1" : "0"]
        try process.run()
        updateLog.notice("替换脚本已启动：\(self.bundleURL.path, privacy: .public) ← \(prepared.app.path, privacy: .public)")
    }

    /// 上次留下的下载与暂存（装好了或放弃了）：启动时清掉
    public func cleanStaging() {
        try? FileManager.default.removeItem(at: staging)
    }

    /// 参数：1 旧 App 的进程号，2 App 的位置，3 新 App（暂存），4 旧 App 挪去的地方（废纸篓），5 换好后打开（1）不打开（0）。
    /// 参数都经 "$@" 传进来，不拼进脚本。最多等旧进程两分钟。
    static let installScript = """
        #!/bin/sh
        pid="$1"; current="$2"; staged="$3"; backup="$4"; relaunch="$5"
        i=0
        while kill -0 "$pid" 2>/dev/null; do
          i=$((i + 1))
          [ "$i" -gt 600 ] && exit 1
          sleep 0.2
        done
        if mv "$current" "$backup"; then
          if ! mv "$staged" "$current"; then
            mv "$backup" "$current"
          fi
        fi
        if [ "$relaunch" = 1 ]; then
          open "$current"
        fi
        exit 0

        """
}
