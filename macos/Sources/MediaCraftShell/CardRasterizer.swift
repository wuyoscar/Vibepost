import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// 出图器自己的错误（给页面的是一句中文）
struct RasterError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// HTML 卡片 → PNG（ADR 0006 草案，`docs/spikes/html-card-renderer.md`）。
///
/// 一个不上屏的 WKWebView 载入 `src/cards/raster-host.html`（和页面同一套打包字体与卡片样式，同一个 `mediacraft://app` 根目录），
/// 每一套卡片先换上样式与图片，再逐页换上这一页的 HTML，等字体、图片就绪后截图。WKWebView 只建一次、一直复用：
/// 载入宿主页与字体只付一次代价。
///
/// 两种出图方式：
/// - `snapshot`（默认）：`takeSnapshot`，WebKit 自己的光栅化，与舞台上看到的一致。视图放在屏幕外的无边框窗口里，
///   窗口的 backingScaleFactor 由主屏决定，所以截图按需要的像素重采样到 `width × scale`。
/// - `pdf`：`createPDF` 得到矢量页，再用 CoreGraphics 按目标像素画（与屏幕无关）。
@MainActor
final class CardRasterizer: NSObject {
    /// 一页：整页 HTML（页眉页脚里是占位页码），可选真实页码的页眉页脚（`chrome`：换上之后只截那两个区域），
    /// `full == false` 表示客户端已有这页的整页 PNG、只要页眉页脚的条
    struct PageRequest: Decodable {
        struct Chrome: Decodable {
            let head: String?
            let foot: String?
        }

        let html: String
        let chrome: Chrome?
        let full: Bool?
    }

    struct Request: Decodable {
        /// 每页的请求；也认旧写法（每页只是 `<article class="mc-page">…</article>` 的外层 HTML）
        let pages: [PageRequest]
        /// 这一套卡片的样式：主题令牌 + 稿子的自定义样式（已经净化、限定在卡片里）
        let style: String
        /// 卡片的 CSS 尺寸与出图倍数：PNG 是 `width × scale` 乘 `height × scale`
        let width: Double
        let height: Double
        let scale: Double
        let method: String?
        /// 图片编号 → data URL：只带宿主页还没有的；页面里写 `data-media="编号"`
        let media: [String: String]?
        /// 这一批用到的全部图片编号：宿主页缺哪张就回 409 让客户端补发
        let mediaIds: [String]?

        private enum CodingKeys: String, CodingKey { case pages, style, width, height, scale, method, media, mediaIds }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let htmls = try? container.decode([String].self, forKey: .pages) {
                pages = htmls.map { PageRequest(html: $0, chrome: nil, full: nil) }
            } else {
                pages = try container.decode([PageRequest].self, forKey: .pages)
            }
            style = try container.decode(String.self, forKey: .style)
            width = try container.decode(Double.self, forKey: .width)
            height = try container.decode(Double.self, forKey: .height)
            scale = try container.decode(Double.self, forKey: .scale)
            method = try container.decodeIfPresent(String.self, forKey: .method)
            media = try container.decodeIfPresent([String: String].self, forKey: .media)
            mediaIds = try container.decodeIfPresent([String].self, forKey: .mediaIds)
        }

        func validate() throws {
            guard !pages.isEmpty, pages.count <= 200 else { throw Failure.badRequest("页数") }
            guard (100...4000).contains(width), (100...6000).contains(height), (0.5...4).contains(scale) else {
                throw Failure.badRequest("尺寸")
            }
        }
    }

    enum Failure: LocalizedError {
        case badRequest(String)
        case hostNotReady
        case snapshotFailed(page: Int)
        /// 宿主页缺这几张图（重建过、或被挤掉了）：客户端补发一次
        case missingMedia([String], generation: String)

        var errorDescription: String? {
            switch self {
            case .badRequest(let what): "出图请求不对：\(what)"
            case .hostNotReady: "出图页面没有载入"
            case .snapshotFailed(let page): "第 \(page) 页没能出图"
            case .missingMedia(let ids, _): "出图的页面缺 \(ids.count) 张图"
            }
        }
    }

    /// 页眉或页脚按真实页码重截的一条：卡片坐标（CSS 像素）与 PNG
    struct Strip {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let png: Data
    }

    struct Page {
        /// 整页 PNG；客户端说已有时为 nil
        let png: Data?
        let strips: [Strip]
        let milliseconds: Double
    }

    struct Rendered {
        let pages: [Page]
        let generation: String
    }

    private let root: URL
    private var webView: WKWebView?
    private var window: NSWindow?
    private var loaded: CheckedContinuation<Void, Error>?
    /// 同一时间只排一套：多套交错时换样式会互相覆盖
    private var queue: Task<Void, Never>?

    /// 放 WKWebView 的方式（测量「窗口隐藏、被遮挡时还能不能出图」用）：
    /// offscreenWindow 屏幕外的无边框窗口（默认）；hiddenWindow 窗口 orderOut；noWindow 不放进窗口
    enum Hosting: String { case offscreenWindow, hiddenWindow, noWindow }
    var hosting: Hosting = .offscreenWindow

    init(root: URL) {
        self.root = root
    }

    /// 桥请求：body 是 `Request` 的 JSON；回复是 `FramedBody`，头部
    /// `{ ok, totalMs, generation, files: [{ size, ms }], pages: [{ ms, full, strips: [{ x, y, width, height }] }] }`，
    /// 后面的二进制段按页依次是：整页 PNG（full 时）、这页的各条。宿主页缺图时回 409 `{ ok: false, error, missing, generation }`。
    func handle(body: Data) async -> NativeBridge.Reply {
        do {
            let request = try JSONDecoder().decode(Request.self, from: body)
            try request.validate()
            let started = ContinuousClock.now
            let rendered = try await render(request)
            var files: [[String: Any]] = []
            var parts: [Data] = []
            let pages: [[String: Any]] = rendered.pages.map { page in
                if let png = page.png {
                    files.append(["size": png.count, "ms": page.milliseconds])
                    parts.append(png)
                }
                for strip in page.strips {
                    files.append(["size": strip.png.count, "ms": 0])
                    parts.append(strip.png)
                }
                return [
                    "ms": page.milliseconds, "full": page.png != nil,
                    "strips": page.strips.map { ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height] },
                ]
            }
            let header: [String: Any] = [
                "ok": true,
                "totalMs": Self.milliseconds(since: started),
                "generation": rendered.generation,
                "files": files,
                "pages": pages,
            ]
            let json = try JSONSerialization.data(withJSONObject: header)
            return .binary(FramedBody.join(header: json, parts: parts))
        } catch let error as DecodingError {
            return .failure(400, "出图请求读不出来：\(error)")
        } catch Failure.missingMedia(let ids, let generation) {
            let body = (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": "出图的页面缺 \(ids.count) 张图", "missing": ids, "generation": generation])) ?? Data()
            return NativeBridge.Reply(status: 409, body: body)
        } catch {
            return .failure(500, error.localizedDescription)
        }
    }

    /// 排队执行，一套一套来。
    func render(_ request: Request) async throws -> Rendered {
        let previous = queue
        let work = Task { () -> Result<Rendered, Error> in
            await previous?.value
            do { return .success(try await self.renderNow(request)) } catch { return .failure(error) }
        }
        queue = Task { _ = await work.value }
        return try await work.value.get()
    }

    /// 宿主页载入、布置样式与图片、每页出图的上限：出图进程卡住（不是崩溃）时不能让整条队列永远排死
    static let loadTimeout: Duration = .seconds(20)
    static let setupTimeout: Duration = .seconds(60)
    static let pageTimeout: Duration = .seconds(60)

    private func renderNow(_ request: Request) async throws -> Rendered {
        let webView = try await bounded(Self.loadTimeout, "载入出图的宿主页") { try await self.host(width: request.width, height: request.height) }
        let setup = try await bounded(Self.setupTimeout, "布置样式与图片") {
            try await webView.callAsyncJavaScript(
                "return await window.mcRaster.setup(style, media, mediaIds, width, height)",
                arguments: [
                    "style": request.style, "media": request.media ?? [:], "mediaIds": request.mediaIds ?? [],
                    "width": request.width, "height": request.height,
                ],
                contentWorld: .page
            )
        } as? [String: Any] ?? [:]
        let generation = setup["generation"] as? String ?? ""
        if let missing = setup["missing"] as? [String], !missing.isEmpty { throw Failure.missingMedia(missing, generation: generation) }
        var pages: [Page] = []
        for (index, page) in request.pages.enumerated() {
            let started = ContinuousClock.now
            let rendered: Page = try await bounded(Self.pageTimeout, "出第 \(index + 1) 页") {
                _ = try await webView.callAsyncJavaScript(
                    "return await window.mcRaster.show(html)", arguments: ["html": page.html], contentWorld: .page
                )
                var png: Data?
                if page.full != false {
                    png = request.method == "pdf"
                        ? try await self.pdf(webView, request: request, page: index + 1)
                        : try await self.snapshot(webView, request: request, page: index + 1)
                }
                var strips: [Strip] = []
                if let chrome = page.chrome {
                    let rects = try await webView.callAsyncJavaScript(
                        "return await window.mcRaster.chrome(head, foot)",
                        arguments: ["head": chrome.head ?? "", "foot": chrome.foot ?? ""], contentWorld: .page
                    ) as? [[String: Any]] ?? []
                    // PDF 路径没有区域截图：换上真实页码后整页再出一次，裁出各条
                    let whole = request.method == "pdf" && !rects.isEmpty ? try await self.pdf(webView, request: request, page: index + 1) : nil
                    for rect in rects {
                        guard let x = rect["x"] as? Double, let y = rect["y"] as? Double,
                              let width = rect["width"] as? Double, let height = rect["height"] as? Double, width > 0, height > 0
                        else { continue }
                        let box = CGRect(x: x, y: y, width: width, height: height)
                        let data: Data
                        if let whole {
                            data = try Self.crop(whole, rect: box, scale: request.scale, page: index + 1)
                        } else {
                            data = try await self.snapshot(webView, request: request, rect: box, page: index + 1)
                        }
                        strips.append(Strip(x: x, y: y, width: width, height: height, png: data))
                    }
                }
                return Page(png: png, strips: strips, milliseconds: Self.milliseconds(since: started))
            }
            pages.append(rendered)
        }
        return Rendered(pages: pages, generation: generation)
    }

    /// 一步出图最多等多久：到点了就当宿主页卡住，重建它（下次请求重新载入），这次报错
    private func bounded<T: Sendable>(_ timeout: Duration, _ what: String, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let outcome: Result<T, Error>? = await firstOf(timeout: timeout) {
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        guard let outcome else {
            reset()
            throw RasterError("\(what)超过 \(timeout) 没有回应：出图的页面可能卡住了，已重建，请再试一次")
        }
        return try outcome.get()
    }

    // MARK: 宿主页

    private func host(width: Double, height: Double) async throws -> WKWebView {
        if let webView {
            resize(webView, width: width, height: height)
            return webView
        }
        let config = WKWebViewConfiguration()
        // 不和页面共用存储：宿主页不读写稿子
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(AppSchemeHandler(root: root, bridge: nil), forURLScheme: ShellWebView.scheme)
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView
        switch hosting {
        case .noWindow:
            break
        case .offscreenWindow, .hiddenWindow:
            let window = NSWindow(
                contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = webView
            if hosting == .offscreenWindow { window.orderBack(nil) }
            self.window = window
        }
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            webView.load(URLRequest(url: URL(string: "\(ShellWebView.scheme)://\(ShellWebView.host)/src/cards/raster-host.html")!))
        }
        return webView
    }

    private func resize(_ webView: WKWebView, width: Double, height: Double) {
        guard webView.frame.width != width || webView.frame.height != height else { return }
        window?.setContentSize(NSSize(width: width, height: height))
        webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    /// 宿主页出错（比如被重新载入、卡住）时下次重建；还在等它载入的也放掉（进程在载入途中崩溃时两个回调的先后没有保证）
    func reset() {
        webView?.navigationDelegate = nil
        window?.orderOut(nil)
        webView = nil
        window = nil
        loaded?.resume(throwing: RasterError("出图的宿主页没有载入成功"))
        loaded = nil
    }

    // MARK: 出图

    private func snapshot(_ webView: WKWebView, request: Request, page: Int) async throws -> Data {
        try await snapshot(webView, request: request, rect: CGRect(x: 0, y: 0, width: request.width, height: request.height), page: page)
    }

    /// 截卡片上的一块（整页或页眉页脚的条）：rect 是卡片坐标（CSS 像素），PNG 是 rect × scale 的准确像素
    private func snapshot(_ webView: WKWebView, request: Request, rect: CGRect, page: Int) async throws -> Data {
        let config = WKSnapshotConfiguration()
        config.rect = rect
        config.afterScreenUpdates = true
        // snapshotWidth 以点计；给到目标像素宽，WebKit 按 deviceScaleFactor 光栅化后再缩放，下面统一重采样到准确像素。
        config.snapshotWidth = NSNumber(value: rect.width * request.scale / max(1, backingScale))
        let image = try await webView.takeSnapshot(configuration: config)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure.snapshotFailed(page: page)
        }
        return try Self.png(cgImage, width: Int((rect.width * request.scale).rounded()), height: Int((rect.height * request.scale).rounded()), page: page)
    }

    /// 从整页 PNG 里裁一块（PDF 路径的页眉页脚条）
    static func crop(_ png: Data, rect: CGRect, scale: Double, page: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cropped = image.cropping(to: CGRect(x: (rect.minX * scale).rounded(), y: (rect.minY * scale).rounded(), width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded()))
        else { throw Failure.snapshotFailed(page: page) }
        return try Self.png(cropped, width: Int((rect.width * scale).rounded()), height: Int((rect.height * scale).rounded()), page: page)
    }

    private func pdf(_ webView: WKWebView, request: Request, page: Int) async throws -> Data {
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: request.width, height: request.height)
        let data = try await webView.pdf(configuration: config)
        guard let png = try PDFPages.pngs(from: data, width: Int((request.width * request.scale).rounded())).first else {
            throw Failure.snapshotFailed(page: page)
        }
        return png
    }

    private var backingScale: Double {
        Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    /// 画进 sRGB 的准确像素画布再编码：截图的色彩空间跟着屏幕走，统一换成 sRGB，像素尺寸也和屏幕无关。
    static func png(_ image: CGImage, width: Int, height: Int, page: Int) throws -> Data {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.snapshotFailed(page: page) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw Failure.snapshotFailed(page: page) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.snapshotFailed(page: page)
        }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.snapshotFailed(page: page) }
        return data as Data
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
}

extension CardRasterizer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
        reset()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
        reset()
    }

    /// 宿主页不跳到别处
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(action.request.url?.scheme == ShellWebView.scheme ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reset()
    }
}
