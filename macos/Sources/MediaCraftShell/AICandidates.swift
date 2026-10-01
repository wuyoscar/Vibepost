import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 配图候选：Claude 生成或找到的图片（本机路径或网址）。先复制进 `<AI 根目录>/.candidates/<稿子 id>/<id>.<扩展名>`
/// （不在 claude 的工作目录里），页面只拿到缩略图；用户点了才取原图插进稿子。只收真能解码、不太大的图片。
/// 网上的图片与这篇稿子工作目录以外的文件要用户先同意，和终端里 claude 打开网页、读目录外的文件要问一样；
/// 同意由壳记账（`CandidateApprovals`），没同意时连读都不读。
struct AICandidates: Sendable {
    private static let byteLimit = 20 * 1024 * 1024
    /// 解码后的像素上限：20 MB 以内的高压缩图也可能解出几十亿像素
    private static let pixelLimit = 64_000_000
    private static let thumbnailPixels = 360
    /// 原样保留的格式；其余（HEIC、TIFF……）转成 PNG，网页里一定画得出来
    private static let keptTypes: [UTType: String] = [.png: "png", .jpeg: "jpg", .webP: "webp", .gif: "gif"]
    /// 下载：连接 15 秒没动静、整个下载 30 秒还没完都算失败
    private static let downloads: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    let root: URL

    /// 这篇稿子的配图候选放在哪（删稿子时整个删掉）
    func folder(_ draftId: String) -> URL {
        root.appendingPathComponent(".candidates", isDirectory: true).appendingPathComponent(draftId, isDirectory: true)
    }

    /// 图片从哪来：网上（网址与它所在的站点），或本机（在不在这篇稿子的工作目录里）
    enum Origin: Sendable {
        case remote(URL, site: CandidateScope)
        case local(URL, inWorkingDirectory: Bool)

        var needsApproval: Bool {
            if case .local(_, true) = self { return false }
            return true
        }

        /// 一次同意认的是哪张图：网址，或解开符号链接后的路径
        var key: String {
            switch self {
            case .remote(let url, _): return url.absoluteString
            case .local(let file, _): return file.path
            }
        }

        /// 这次同意放行的范围：网上的是同一站点（只管这一张图下载途中的重定向），本机的是同一目录（不含子目录）。
        /// 只有本机目录能「本次会话都允许」，见 `CandidateApprovals`
        var scope: CandidateScope {
            switch self {
            case .remote(_, let site): return site
            case .local(let file, _): return .directory(file.deletingLastPathComponent().path)
            }
        }
    }

    /// source 是本机路径（相对路径按工作副本目录算，`~` 可用）、file:// 或 http(s) 网址
    func origin(of source: String, draftId: String) throws -> Origin {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw AISessions.Failure("没有给图片的路径或网址") }
        return try Self.origin(of: source, workingDirectory: root.appendingPathComponent(draftId, isDirectory: true))
    }

    /// 登记好的一张候选：thumb 是 JPEG 缩略图的 data URL
    struct Candidate: Sendable {
        let id: String
        let name: String
        let width: Int
        let height: Int
        let thumb: String

        var fields: [String: Any] { ["id": id, "name": name, "width": width, "height": height, "thumb": thumb] }
    }

    /// 登记一张候选（要不要先问用户由调用方按 `origin.needsApproval` 决定）。网上的图片只跟着重定向走到 `allowed` 里的站点，
    /// 越界时抛 `CandidateRedirect`。所在的任务被取消（删稿子）时不再往 `.candidates` 里写。
    func add(draftId: String, origin: Origin, source: String, allowed: Set<CandidateScope>) async throws -> Candidate {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let (data, name) = try await load(origin, source: source, allowed: allowed)
        return try store(draftId: draftId, data: data, name: name)
    }

    /// 登记一张已经拿到手的图（生图工具生成的）：检查、存进 `.candidates/`、做缩略图，返回同 `add`
    func store(draftId: String, data: Data, name: String) throws -> Candidate {
        let image = try Self.prepare(data, name: name)
        let thumb = try Self.thumbnail(image.source, name: name)
        let id = UUID().uuidString.lowercased()
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder(draftId), withIntermediateDirectories: true)
        try image.bytes.write(to: folder(draftId).appendingPathComponent("\(id).\(image.ext)"), options: .atomic)
        return Candidate(id: id, name: name, width: image.width, height: image.height, thumb: thumb)
    }

    /// 登记一张后端自己生成、存在本机的图（Codex 自带的生图）：同样检查、存一份进 `.candidates/`，原图不动
    func store(draftId: String, generated file: URL, name: String) throws -> Candidate {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.byteLimit else { throw AISessions.Failure("生成的图超过 20 MB：\(file.lastPathComponent)") }
        guard let data = try? Data(contentsOf: file) else { throw AISessions.Failure("读不到生成的图：\(file.path)") }
        return try store(draftId: draftId, data: data, name: name)
    }

    /// 检查过、网页里一定画得出来的一张图
    struct PreparedImage {
        let bytes: Data
        let ext: String
        let width: Int
        let height: Int
        let source: CGImageSource

        var mimeType: String { UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/png" }
    }

    /// 真能解码、不超过 6400 万像素才收；PNG / JPEG / WebP / GIF 原样，别的转成 PNG（配图候选与外部 Agent 插图共用）
    static func prepare(_ data: Data, name: String) throws -> PreparedImage {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw AISessions.Failure("「\(name)」不是能打开的图片") }
        guard width * height <= pixelLimit else { throw AISessions.Failure("「\(name)」太大了（\(width) × \(height)）") }
        let type = (CGImageSourceGetType(image) as String?).flatMap { UTType($0) }
        let (bytes, ext) = try type.flatMap { keptTypes[$0] }.map { (data, $0) } ?? (png(image, name: name), "png")
        return PreparedImage(bytes: bytes, ext: ext, width: width, height: height, source: image)
    }

    /// 候选的原图：`{ type, data }`（MIME 类型与 base64）
    func file(draftId: String, id: String) throws -> [String: Any] {
        guard UUID(uuidString: id) != nil,
              let url = try? FileManager.default.contentsOfDirectory(at: folder(draftId), includingPropertiesForKeys: nil)
                .first(where: { $0.deletingPathExtension().lastPathComponent == id.lowercased() }),
              let data = try? Data(contentsOf: url)
        else { throw AISessions.Failure("这张候选图已经不在了") }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        return ["type": type, "data": data.base64EncodedString()]
    }

    // MARK: - 读取

    /// 网上配图的网址最长这么多字
    static let remoteSourceLimit = 2048

    /// 本机路径解开符号链接后再判断在不在工作目录里
    private static func origin(of source: String, workingDirectory: URL) throws -> Origin {
        if let url = URL(string: source), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            guard let site = CandidateScope.site(of: url) else { throw AISessions.Failure("网址不对：\(source)") }
            // 正常的图片地址用不到这么长；太长的多半是把别的内容塞进了网址
            guard source.count <= Self.remoteSourceLimit else {
                throw AISessions.Failure("网址太长（超过 \(Self.remoteSourceLimit) 个字），没有载入")
            }
            return .remote(url, site: site)
        }
        let path: String
        if let url = URL(string: source), url.isFileURL {
            path = url.path
        } else {
            let expanded = (source as NSString).expandingTildeInPath
            path = expanded.hasPrefix("/") ? expanded : workingDirectory.appendingPathComponent(expanded).path
        }
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let base = workingDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return .local(file, inWorkingDirectory: file.path.hasPrefix(base))
    }

    private func load(_ origin: Origin, source: String, allowed: Set<CandidateScope>) async throws -> (Data, String) {
        switch origin {
        case .remote(let url, _):
            return (try await Self.download(url, allowed: allowed), Self.displayName(url.lastPathComponent))
        case .local(let file, _):
            return try Self.readLocal(file, source: source)
        }
    }

    /// 本机的一个图片文件：只读常规文件，20 MB 以内。返回内容与显示名（配图候选与外部 Agent 插图共用）
    static func readLocal(_ file: URL, source: String) throws -> (Data, String) {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw AISessions.Failure("找不到图片文件：\(source)") }
        guard (values?.fileSize ?? 0) <= byteLimit else { throw AISessions.Failure("图片超过 20 MB：\(source)") }
        return (try Data(contentsOf: file), displayName(file.lastPathComponent))
    }

    /// 边下边数，超过 20 MB 就停，不先整个读进内存。重定向逐跳检查（`RedirectGuard`），本机 / 局域网地址先挡掉（`LocalAddresses`）。
    private static func download(_ url: URL, allowed: Set<CandidateScope>) async throws -> Data {
        try await LocalAddresses.check(url)
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let redirects = RedirectGuard(allowed: allowed)
        let (bytes, response) = try await downloads.bytes(for: request, delegate: redirects)
        let tooLarge = AISessions.Failure("图片超过 20 MB：\(url.absoluteString)")
        if let stop = redirects.stop {
            bytes.task.cancel()
            throw stop
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            bytes.task.cancel()
            throw AISessions.Failure("下载图片失败：\(url.absoluteString)")
        }
        guard http.expectedContentLength <= byteLimit else {
            bytes.task.cancel()
            throw tooLarge
        }
        // 删稿子时取消：马上停下这次下载，别等下完
        let data = try await withTaskCancellationHandler {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > byteLimit {
                    bytes.task.cancel()
                    throw tooLarge
                }
            }
            return data
        } onCancel: {
            bytes.task.cancel()
        }
        try Task.checkCancellation()
        return data
    }

    private static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "/" ? "配图" : String(trimmed.prefix(80))
    }

    // MARK: - 编码

    private static func png(_ image: CGImageSource, name: String) throws -> Data {
        guard let frame = CGImageSourceCreateImageAtIndex(image, 0, nil) else { throw AISessions.Failure("「\(name)」解码失败") }
        return try encode(frame, type: .png, name: name)
    }

    /// 最长边 360 像素的 JPEG（透明处垫白底），按图片自带的方向转正
    private static func thumbnail(_ image: CGImageSource, name: String) throws -> String {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        guard let small = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary),
              let context = CGContext(
                data: nil, width: small.width, height: small.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw AISessions.Failure("「\(name)」做不出缩略图") }
        let bounds = CGRect(x: 0, y: 0, width: small.width, height: small.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(small, in: bounds)
        guard let flattened = context.makeImage() else { throw AISessions.Failure("「\(name)」做不出缩略图") }
        return "data:image/jpeg;base64,\(try encode(flattened, type: .jpeg, name: name).base64EncodedString())"
    }

    private static func encode(_ image: CGImage, type: UTType, name: String) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw AISessions.Failure("「\(name)」编码失败")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AISessions.Failure("「\(name)」编码失败") }
        return data as Data
    }
}

/// 载入网上、工作目录以外的配图要用户同意：同意记在壳里，不凭页面一句「同意了」就读。
/// 要问时壳发一张一次性的凭据（绑定这篇稿子、这一轮、这张图与要放行的范围），页面问过用户、带着凭据再来才读；
/// 「本次会话都允许」只记本机目录（这篇稿子之后同一目录的不再问）。网上的图每批都问、每张都给用户看网址：
/// 放行整个网站的话，被提示词注入的模型能把读到的内容拼进那个网站的网址里带出去（防提示词注入，见 docs/app-api.md）。
/// 下载途中重定向到别的站点时，同一张图再发一张凭据，范围是那个站点。
/// 这一轮结束时没用掉的凭据作废；页面重新载入、App 退出后放行的范围都忘掉（和 claude 的「本次会话都允许」一样）。
final class CandidateApprovals: @unchecked Sendable {
    private struct Ticket {
        let draftId: String
        let turnId: String
        let key: String
        let scope: CandidateScope
    }

    private let lock = NSLock()
    private var tickets: [String: Ticket] = [:]
    private var scopes: [String: Set<CandidateScope>] = [:]

    /// 这篇稿子的会话里放行过的范围
    func sessionScopes(_ draftId: String) -> Set<CandidateScope> {
        lock.withLock { scopes[draftId] ?? [] }
    }

    /// 发一张凭据：页面问过用户后带着它再来
    func issue(draftId: String, turnId: String, key: String, scope: CandidateScope) -> String {
        let token = UUID().uuidString.lowercased()
        lock.withLock { tickets[token] = Ticket(draftId: draftId, turnId: turnId, key: key, scope: scope) }
        return token
    }

    /// 用掉一张凭据：是壳发的、对得上这篇稿子、这一轮与这张图才算数，返回它放行的范围（不算数为 nil）；
    /// session 为 true、范围是本机目录时，这个目录在这篇的会话里一直放行（网上的站点不记）
    func redeem(_ token: String, draftId: String, turnId: String, key: String, session: Bool) -> CandidateScope? {
        lock.withLock {
            guard let ticket = tickets[token], ticket.draftId == draftId, ticket.turnId == turnId, ticket.key == key else {
                return nil
            }
            tickets[token] = nil
            if session, case .directory = ticket.scope { scopes[draftId, default: []].insert(ticket.scope) }
            return ticket.scope
        }
    }

    func endTurn(_ turnId: String) {
        lock.withLock { tickets = tickets.filter { $0.value.turnId != turnId } }
    }

    func forget(draftId: String) {
        lock.withLock {
            tickets = tickets.filter { $0.value.draftId != draftId }
            scopes[draftId] = nil
        }
    }

    func reset() {
        lock.withLock {
            tickets = [:]
            scopes = [:]
        }
    }
}
