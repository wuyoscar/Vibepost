import Foundation
import Testing
@testable import MediaCraftShell

/// 检查更新（壳里的更新模块，不经页面；界面在 main.swift）：GitHub 公开时直接下载，私有时借 gh；
/// 校验和、包名、版本、签名不对都不装；替换脚本等 App 退出后换上新版，换不了就把旧的放回去。
/// 不连网：GitHub 是本机的假 HTTP 服务（LocalHTTPServer），gh 是假的脚本，DMG 现场用 hdiutil 做。
@MainActor
struct UpdaterTests {
    static let repository = "wuyoscar/Vibepost"

    /// 一次测试用的临时目录：假的新版 App、DMG、假 gh、暂存与废纸篓
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-update-\(UUID().uuidString)")
        var assets: URL { root.appendingPathComponent("assets") }
        var staging: URL { root.appendingPathComponent("staging") }
        var trash: URL { root.appendingPathComponent("Trash") }
        var applications: URL { root.appendingPathComponent("Applications") }
        let defaults: UserDefaults
        private let suite = "mediacraft-update-tests-\(UUID().uuidString)"

        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            for directory in [assets, staging, trash, applications] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        deinit {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        /// 一个能通过 codesign 检查的最小 App（可执行文件是 /usr/bin/true 的副本，ad-hoc 签名），里面放一个记号文件
        @discardableResult
        func makeApp(at app: URL, identifier: String = "com.wuyoscar.mediacraft", version: String, marker: String = "") throws -> URL {
            let macOS = app.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Vibepost"))
            let info: [String: Any] = [
                "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleVersion": version,
                "CFBundleExecutable": "Vibepost", "CFBundlePackageType": "APPL", "CFBundleName": "Vibepost",
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            let resources = app.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try marker.write(to: resources.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
            try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
            return app
        }

        /// assets 里的 Vibepost-<版本>.dmg 与 .sha256（checksum 给了就写它，不对的校验和）
        func makeRelease(version: String, appVersion: String? = nil, identifier: String = "com.wuyoscar.mediacraft", checksum: String? = nil) throws {
            let folder = root.appendingPathComponent("dmg-\(UUID().uuidString)")
            try makeApp(at: folder.appendingPathComponent("Vibepost.app"), identifier: identifier, version: appVersion ?? version, marker: "new")
            let dmg = assets.appendingPathComponent("Vibepost-\(version).dmg")
            try Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Vibepost", "-srcfolder", folder.path, "-format", "UDZO", "-ov", "-o", dmg.path])
            let sum = try checksum ?? Updater.sha256(of: dmg)
            try "\(sum)  Vibepost-\(version).dmg\n".write(to: assets.appendingPathComponent("Vibepost-\(version).dmg.sha256"), atomically: true, encoding: .utf8)
        }

        /// GitHub API 回的 Release（只有用得到的几项）；base 是附件的下载地址前缀
        func releaseJSON(tag: String, base: String) throws -> Data {
            let names = try FileManager.default.contentsOfDirectory(atPath: assets.path).sorted()
            let assets = try names.map { name -> [String: Any] in
                let size = try FileManager.default.attributesOfItem(atPath: self.assets.appendingPathComponent(name).path)[.size] as? Int ?? 0
                return ["name": name, "size": size, "browser_download_url": "\(base)/download/\(tag)/\(name)"]
            }
            return try JSONSerialization.data(withJSONObject: ["tag_name": tag, "body": "这一版的更新说明", "assets": assets])
        }

        /// 假的 gh：`gh api …` 输出 release.json，`gh release download … --pattern 名字 --dir 目录` 把附件拷进去；每次调用记在 calls.log
        func fakeCLI(tag: String) throws -> GitHubCLI {
            let directory = root.appendingPathComponent("gh")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try releaseJSON(tag: tag, base: "https://example.invalid").write(to: directory.appendingPathComponent("release.json"))
            let script = """
                #!/bin/sh
                dir="$(cd "$(dirname "$0")" && pwd)"
                echo "$*" >> "$dir/calls.log"
                case "$1" in
                  api) cat "$dir/release.json" ;;
                  release)
                    while [ $# -gt 0 ]; do
                      case "$1" in
                        --pattern) name="$2"; shift 2 ;;
                        --dir) out="$2"; shift 2 ;;
                        *) shift ;;
                      esac
                    done
                    cp "\(assets.path)/$name" "$out/$name" ;;
                  *) echo "不认识的命令：$*" >&2; exit 1 ;;
                esac

                """
            let gh = directory.appendingPathComponent("gh")
            try script.write(to: gh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
            return GitHubCLI(path: gh.path, environment: ["PATH": "/usr/bin:/bin"])
        }

        var cliCalls: [String] {
            ((try? String(contentsOf: root.appendingPathComponent("gh/calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        @MainActor
        func updater(current: String = "0.5.1", api: URL, cli: GitHubCLI? = nil, app: URL? = nil) -> Updater {
            Updater(
                current: UpdateVersion(current)!, bundleURL: app ?? applications.appendingPathComponent("Vibepost.app"),
                bundleIdentifier: "com.wuyoscar.mediacraft",
                source: GitHubReleases(repository: UpdaterTests.repository, api: api) { cli },
                staging: staging, trash: trash, defaults: defaults
            )
        }

        @discardableResult
        static func run(_ path: String, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
            return process.terminationStatus
        }
    }

    /// 本机的假 GitHub：/repos/<仓库>/releases/latest 回 json（或 status），/download/... 回附件
    private func server(_ fixture: Fixture, tag: String, status: Int = 200) throws -> LocalHTTPServer {
        let server = try LocalHTTPServer()
        let json = try fixture.releaseJSON(tag: tag, base: server.base)
        server.route("/repos/\(Self.repository)/releases/latest", .init(status: status, headers: ["Content-Type": "application/json"], body: status == 200 ? json : Data("{\"message\":\"Not Found\"}".utf8)))
        for name in try FileManager.default.contentsOfDirectory(atPath: fixture.assets.path) {
            server.route("/download/\(tag)/\(name)", .init(body: try Data(contentsOf: fixture.assets.appendingPathComponent(name))))
        }
        return server
    }

    private static func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
    }

    @Test("版本号按数字段比：0.6.0 > 0.5.10 > 0.5.1，0.6 与 0.6.0 一样，tag 的 v 前缀照认，别的写法不认")
    func versionsCompareByNumber() {
        let v = { UpdateVersion($0)! }
        #expect(v("0.6.0") > v("0.5.10"))
        #expect(v("0.5.10") > v("0.5.1"))
        #expect(v("0.6") == v("0.6.0"))
        #expect(v("v0.6.0") == v("0.6.0"))
        #expect(v("1.0") > v("0.99.99"))
        #expect(UpdateVersion("0.6.0-beta") == nil)
        #expect(UpdateVersion("") == nil)
        #expect(UpdateVersion("0..1") == nil)
    }

    @Test("公开仓库：直接问 GitHub，有新版就下载 DMG 与校验和，核对好拷到暂存目录（不用 gh）；一样新时说已是最新")
    func publicRepositoryDownloadsDirectly() async throws {
        let fixture = try Fixture()
        try fixture.makeRelease(version: "0.6.0")
        let server = try server(fixture, tag: "v0.6.0")
        defer { server.stop() }
        let updater = fixture.updater(api: URL(string: server.base)!)
        guard case .available(let release) = try await updater.check() else {
            Issue.record("应该有新版")
            return
        }
        let prepared = try await updater.prepare(release)
        let sameVersion = fixture.updater(current: "0.6.0", api: URL(string: server.base)!)
        let upToDate = try await sameVersion.check()

        #expect(release.version == UpdateVersion("0.6.0"))
        #expect(release.notes == "这一版的更新说明")
        #expect(Self.marker(prepared.app) == "new")
        #expect(server.requests.contains("/download/v0.6.0/Vibepost-0.6.0.dmg"))
        #expect(fixture.cliCalls.isEmpty)
        if case .upToDate(let version) = upToDate { #expect(version == UpdateVersion("0.6.0")) } else { Issue.record("应该已是最新") }
    }

    @Test("私有仓库（GitHub 回 404）：借本机的 gh 读 Release、下载附件；没有 gh 时说清楚要装好并登录 gh")
    func privateRepositoryUsesGitHubCLI() async throws {
        let fixture = try Fixture()
        try fixture.makeRelease(version: "0.6.0")
        let server = try server(fixture, tag: "v0.6.0", status: 404)
        defer { server.stop() }
        let cli = try fixture.fakeCLI(tag: "v0.6.0")
        let updater = fixture.updater(api: URL(string: server.base)!, cli: cli)
        guard case .available(let release) = try await updater.check() else {
            Issue.record("应该有新版")
            return
        }
        let prepared = try await updater.prepare(release)
        var missing: Error?
        do {
            _ = try await fixture.updater(api: URL(string: server.base)!).check()
        } catch {
            missing = error
        }

        #expect(Self.marker(prepared.app) == "new")
        let calls = fixture.cliCalls
        #expect(calls.first == "api repos/\(Self.repository)/releases/latest")
        #expect(calls.contains { $0.hasPrefix("release download v0.6.0 --repo \(Self.repository) --pattern Vibepost-0.6.0.dmg --dir ") })
        #expect(missing as? UpdateError == .needsCLI(Self.repository))
        #expect(missing?.localizedDescription.contains("gh auth login") == true)
    }

    @Test("下载的东西不对就不装：校验和对不上、包名不对、版本和 Release 不一致", arguments: ["checksum", "identifier", "version"])
    func rejectsWrongDownloads(_ problem: String) async throws {
        let fixture = try Fixture()
        switch problem {
        case "checksum": try fixture.makeRelease(version: "0.6.0", checksum: String(repeating: "0", count: 64))
        case "identifier": try fixture.makeRelease(version: "0.6.0", identifier: "com.example.other")
        default: try fixture.makeRelease(version: "0.6.0", appVersion: "0.9.9")
        }
        let server = try server(fixture, tag: "v0.6.0")
        defer { server.stop() }
        let updater = fixture.updater(api: URL(string: server.base)!)
        guard case .available(let release) = try await updater.check() else {
            Issue.record("应该有新版")
            return
        }
        var failure: UpdateError?
        do {
            _ = try await updater.prepare(release)
        } catch {
            failure = error as? UpdateError
        }

        switch problem {
        case "checksum": #expect(failure == .checksumMismatch)
        case "identifier": #expect(failure?.errorDescription?.contains("com.example.other") == true, "\(String(describing: failure))")
        default: #expect(failure?.errorDescription?.contains("0.9.9") == true, "\(String(describing: failure))")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("0.6.0/Vibepost.app").path))
    }

    @Test("交给 gh 的环境只有它用得到的（HOME、PATH、GH_*、代理……），终端里别的密钥不带过去")
    func cliEnvironmentIsMinimal() {
        for name in ["HOME", "PATH", "GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "XDG_CONFIG_HOME", "HTTPS_PROXY", "https_proxy", "SSH_AUTH_SOCK"] {
            #expect(GitHubCLI.passes(name), "\(name)")
        }
        for name in ["OPENAI_API_KEY", "OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "AWS_SECRET_ACCESS_KEY", "NOTION_API_KEY", "CLAUDECODE"] {
            #expect(!GitHubCLI.passes(name), "\(name)")
        }
    }

    @Test("跳过的版本记得住；自动检查一天最多一次")
    func skipsAndSchedules() async throws {
        let fixture = try Fixture()
        let updater = fixture.updater(api: URL(string: "http://127.0.0.1:9")!)
        let fresh = updater.dueForAutomaticCheck()
        updater.skip(UpdateVersion("0.6.0")!)
        fixture.defaults.set(Date(), forKey: Updater.lastCheckKey)
        let soon = updater.dueForAutomaticCheck(now: Date().addingTimeInterval(3600))
        let tomorrow = updater.dueForAutomaticCheck(now: Date().addingTimeInterval(25 * 3600))

        #expect(fresh)
        #expect(updater.isSkipped(UpdateVersion("0.6.0")!))
        #expect(!updater.isSkipped(UpdateVersion("0.6.1")!))
        #expect(!soon)
        #expect(tomorrow)
    }

    @Test("替换脚本等 App 退出后把旧版挪进废纸篓、新版放到原处；新版挪不过去时旧版放回原处")
    func installSwapsAfterExitAndRollsBack() async throws {
        let fixture = try Fixture()
        let current = fixture.applications.appendingPathComponent("Vibepost.app")
        try fixture.makeApp(at: current, version: "0.5.1", marker: "old")
        let staged = fixture.staging.appendingPathComponent("0.6.0/Vibepost.app")
        try fixture.makeApp(at: staged, version: "0.6.0", marker: "new")
        let release = try UpdateRelease.parse(fixture.releaseJSON(tag: "v0.6.0", base: "http://127.0.0.1:9"), via: .web)
        let updater = fixture.updater(api: URL(string: "http://127.0.0.1:9")!, app: current)

        // 一个还在跑的「旧 App」：脚本要等它退出才动手
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["1"]
        try running.run()
        try updater.install(Updater.Prepared(release: release, app: staged, dmg: staged), relaunch: false, waitingFor: running.processIdentifier)
        let untouched = Self.marker(current)
        let backup = fixture.trash.appendingPathComponent("Vibepost 0.5.1.app")
        let deadline = ContinuousClock.now + .seconds(15)
        while Self.marker(current) != "new" || !FileManager.default.fileExists(atPath: backup.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let swapped = (Self.marker(current), Self.marker(backup))

        // 新版不见了（挪不过去）：旧版回到原处
        try FileManager.default.removeItem(at: fixture.trash)
        try updater.install(Updater.Prepared(release: release, app: fixture.staging.appendingPathComponent("gone/Vibepost.app"), dmg: staged), relaunch: false, waitingFor: 999_999)
        try await Task.sleep(for: .seconds(2))
        let rolledBack = Self.marker(current)
        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: fixture.trash.path)) ?? []

        #expect(untouched == "old", "旧 App 还在跑时不动")
        #expect(swapped.0 == "new" && swapped.1 == "old", "\(swapped)")
        #expect(rolledBack == "new", "挪不过去时原处的那份还在")
        #expect(trashed.isEmpty, "\(trashed)")
    }
}
