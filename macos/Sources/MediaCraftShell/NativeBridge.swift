import Foundation

/// 网页 → 壳的原生能力。页面通过 `POST mediacraft://app/__native/<action>?<参数>` 调用，
/// body 是文件的二进制内容（`ai/*`、`window/*`、`manuals/*`、`mcp/status`、`mcp/settings` 是 JSON，`live-photo` 是带文件的分段 body），
/// 返回 JSON（`live-photo` 成功时回分段 body）。文件读写与实况合成在后台执行，AirDrop 与剪贴板回到主线程。
/// 每个窗口一个：知道请求来自哪个窗口（AI 的一轮只推给发起它的窗口），服务是全 App 共用的。
final class NativeBridge: @unchecked Sendable {
    static let pathPrefix = "/__native/"

    struct Reply {
        let status: Int
        let body: Data
        var contentType = "application/json"

        static func ok(_ fields: [String: Any] = [:]) -> Reply {
            Reply(status: 200, body: (try? JSONSerialization.data(withJSONObject: fields.merging(["ok": true]) { $1 })) ?? Data())
        }

        static func failure(_ status: Int, _ message: String) -> Reply {
            Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message])) ?? Data())
        }

        /// 带文件的回复（`FramedBody`）
        static func binary(_ body: Data) -> Reply {
            Reply(status: 200, body: body, contentType: "application/octet-stream")
        }
    }

    /// 页面中止这个请求时（取消导出、重新载入）要不要停下正在做的事：只有实况合成要停。
    static func stopsWhenAbandoned(_ url: URL) -> Bool {
        url.path == pathPrefix + "live-photo"
    }

    private let downloadsDirectory: URL
    private let iPhoneSender: IPhoneSender
    private let clipboard: TextClipboard
    private let staging: SendStaging
    private let ai: AISessions
    private let livePhotos: LivePhotos
    private let externalAgents: ExternalAgents
    private let cards: CardRasterizer?
    /// 发来请求的窗口
    private let window: String
    /// 窗口的事（开新窗口、这个窗口占着哪些稿子……），由 ShellCore 接上（它知道是哪个窗口）；nil 时没有
    private let windows: (@Sendable (_ action: String, _ request: [String: Any]) async -> Reply)?
    /// 写作手册的事（列出、读、存、在 Finder 中显示、打开），由 ShellCore 接上；nil 时没有
    private let manuals: (@Sendable (_ action: String, _ request: [String: Any]) async -> Reply)?

    init(
        downloadsDirectory: URL, iPhoneSender: IPhoneSender, clipboard: TextClipboard, ai: AISessions,
        livePhotos: LivePhotos, externalAgents: ExternalAgents, cards: CardRasterizer? = nil, staging: SendStaging = SendStaging(),
        window: String = "main", windows: (@Sendable (_ action: String, _ request: [String: Any]) async -> Reply)? = nil,
        manuals: (@Sendable (_ action: String, _ request: [String: Any]) async -> Reply)? = nil
    ) {
        self.window = window
        self.windows = windows
        self.manuals = manuals
        self.cards = cards
        self.downloadsDirectory = downloadsDirectory
        self.iPhoneSender = iPhoneSender
        self.clipboard = clipboard
        self.ai = ai
        self.livePhotos = livePhotos
        self.externalAgents = externalAgents
        self.staging = staging
    }

    /// 收到请求那一刻这个窗口的页面是第几个（AppSchemeHandler 在主线程上同步取，早于这个页面之后的换页）
    func pageEpoch() -> Int {
        ai.epoch(window: window)
    }

    /// epoch：`pageEpoch()` 在收到请求时的值；不给时按处理时的算
    func handle(url: URL, body: Data, epoch: Int? = nil) async -> Reply {
        let action = String(url.path.dropFirst(Self.pathPrefix.count))
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { $1 }
        )
        switch action {
        case "save":
            return save(name: query["name"] ?? "", body: body)
        case "stage":
            return attempt { try staging.stage(batch: query["batch"] ?? "", name: query["name"] ?? "", data: body) }
        case "pdf-pages":
            return attempt { ["pages": try PDFPages.pngs(from: body).map { $0.base64EncodedString() }] }
        case "send-to-iphone":
            return await sendToIPhone(batch: query["batch"] ?? "", text: String(decoding: body, as: UTF8.self))
        case "copy-rich":
            return await copyRich(body)
        case "copy-text":
            return await copyText(String(decoding: body, as: UTF8.self))
        case "live-photo":
            return await livePhotos.handle(body: body)
        case "cards/raster":
            // HTML 卡片出图（ADR 0006 草案，默认不开）
            guard let cards else { return .failure(404, "没有 HTML 卡片出图") }
            return await cards.handle(body: body)
        case _ where action.hasPrefix("ai/"):
            return await ai.handle(action: String(action.dropFirst("ai/".count)), body: body, window: window, epoch: epoch)
        case _ where action.hasPrefix("window/"):
            guard let windows else { return .failure(404, "这里不能开窗口") }
            let request = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            return await windows(String(action.dropFirst("window/".count)), request)
        case _ where action.hasPrefix("manuals/"):
            guard let manuals else { return .failure(404, "这里没有写作手册") }
            let request = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            return await manuals(String(action.dropFirst("manuals/".count)), request)
        case _ where action.hasPrefix("mcp/"):
            return externalAgents.handle(action: String(action.dropFirst("mcp/".count)), query: query, body: body)
        default:
            return .failure(404, "unknown action: \(action)")
        }
    }

    /// 整组文件按页序交给 AirDrop；正文写进剪贴板，iPhone 上可直接粘贴。
    private func sendToIPhone(batch: String, text: String) async -> Reply {
        do {
            let files = try staging.finalize(batch: batch)
            try await MainActor.run {
                if !text.isEmpty { clipboard.write(text) }
                try iPhoneSender.send(files)
            }
            return .ok(["count": files.count])
        } catch {
            return .failure(500, error.localizedDescription)
        }
    }

    /// 纯文本复制（「复制全文」）：body 就是要复制的文字。
    private func copyText(_ text: String) async -> Reply {
        guard !text.isEmpty else { return .failure(400, "没有要复制的内容") }
        await MainActor.run { clipboard.write(text) }
        return .ok()
    }

    /// 带格式复制：body 是 `{ "html", "text" }`，两种格式一起写进剪贴板。
    private func copyRich(_ body: Data) async -> Reply {
        struct Payload: Decodable {
            let html: String
            let text: String
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body), !payload.html.isEmpty else {
            return .failure(400, "没有要复制的内容")
        }
        await MainActor.run { clipboard.writeRich(html: payload.html, text: payload.text) }
        return .ok()
    }

    private func attempt(_ work: () throws -> [String: Any]) -> Reply {
        do {
            return .ok(try work())
        } catch {
            return .failure(500, error.localizedDescription)
        }
    }

    private func attempt(_ work: () throws -> Void) -> Reply {
        attempt { try work(); return [:] }
    }

    /// 保存到下载文件夹；同名文件自动改为「名字 2.ext」。
    private func save(name: String, body: Data) -> Reply {
        let safeName = (name as NSString).lastPathComponent
        guard !safeName.isEmpty, safeName != "..", safeName != "." else { return .failure(400, "missing file name") }
        let destination = ShellWebView.uniqueURL(in: downloadsDirectory, name: safeName)
        do {
            try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
            try body.write(to: destination, options: .withoutOverwriting)
            return .ok(["path": destination.path, "name": destination.lastPathComponent])
        } catch {
            return .failure(500, error.localizedDescription)
        }
    }
}
