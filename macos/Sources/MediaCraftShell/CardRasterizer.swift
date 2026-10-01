import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

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
    struct Request: Decodable {
        /// 每页 `<article class="mc-page">…</article>` 的外层 HTML（已经净化过）
        let pages: [String]
        /// 这一套卡片的样式：主题令牌 + 稿子的自定义样式（已经净化、限定在卡片里）
        let style: String
        /// 卡片的 CSS 尺寸与出图倍数：PNG 是 `width × scale` 乘 `height × scale`
        let width: Double
        let height: Double
        let scale: Double
        let method: String?
        /// 图片编号 → data URL；页面里写 `src="media:编号"`
        let media: [String: String]?

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

        var errorDescription: String? {
            switch self {
            case .badRequest(let what): "出图请求不对：\(what)"
            case .hostNotReady: "出图页面没有载入"
            case .snapshotFailed(let page): "第 \(page) 页没能出图"
            }
        }
    }

    struct Page {
        let png: Data
        let milliseconds: Double
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

    /// 桥请求：body 是 `Request` 的 JSON；回复是 `FramedBody`，头部 `{ ok, totalMs, files: [{ size, ms }] }`，后面依次是各页 PNG。
    func handle(body: Data) async -> NativeBridge.Reply {
        do {
            let request = try JSONDecoder().decode(Request.self, from: body)
            try request.validate()
            let started = ContinuousClock.now
            let pages = try await render(request)
            let header: [String: Any] = [
                "ok": true,
                "totalMs": Self.milliseconds(since: started),
                "files": pages.map { ["size": $0.png.count, "ms": $0.milliseconds] },
            ]
            let json = try JSONSerialization.data(withJSONObject: header)
            return .binary(FramedBody.join(header: json, parts: pages.map(\.png)))
        } catch let error as DecodingError {
            return .failure(400, "出图请求读不出来：\(error)")
        } catch {
            return .failure(500, error.localizedDescription)
        }
    }

    /// 排队执行，一套一套来。
    func render(_ request: Request) async throws -> [Page] {
        let previous = queue
        let work = Task { () -> Result<[Page], Error> in
            await previous?.value
            do { return .success(try await self.renderNow(request)) } catch { return .failure(error) }
        }
        queue = Task { _ = await work.value }
        return try await work.value.get()
    }

    private func renderNow(_ request: Request) async throws -> [Page] {
        let webView = try await host(width: request.width, height: request.height)
        _ = try await webView.callAsyncJavaScript(
            "return await window.mcRaster.setup(style, media, width, height)",
            arguments: ["style": request.style, "media": request.media ?? [:], "width": request.width, "height": request.height],
            contentWorld: .page
        )
        var pages: [Page] = []
        for (index, html) in request.pages.enumerated() {
            let started = ContinuousClock.now
            _ = try await webView.callAsyncJavaScript(
                "return await window.mcRaster.show(html)", arguments: ["html": html], contentWorld: .page
            )
            let png: Data
            if request.method == "pdf" {
                png = try await pdf(webView, request: request, page: index + 1)
            } else {
                png = try await snapshot(webView, request: request, page: index + 1)
            }
            pages.append(Page(png: png, milliseconds: Self.milliseconds(since: started)))
        }
        return pages
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

    /// 宿主页出错（比如被重新载入）时下次重建
    func reset() {
        webView?.navigationDelegate = nil
        window?.orderOut(nil)
        webView = nil
        window = nil
    }

    // MARK: 出图

    private func snapshot(_ webView: WKWebView, request: Request, page: Int) async throws -> Data {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: request.width, height: request.height)
        config.afterScreenUpdates = true
        // snapshotWidth 以点计；给到目标像素宽，WebKit 按 deviceScaleFactor 光栅化后再缩放，下面统一重采样到准确像素。
        config.snapshotWidth = NSNumber(value: request.width * request.scale / max(1, backingScale))
        let image = try await webView.takeSnapshot(configuration: config)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure.snapshotFailed(page: page)
        }
        return try Self.png(cgImage, width: Int((request.width * request.scale).rounded()), height: Int((request.height * request.scale).rounded()), page: page)
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
