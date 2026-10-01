import Foundation
import UniformTypeIdentifiers
import WebKit

/// 把 `mediacraft://app/<path>` 映射到网页根目录下的文件；支持 Range（视频播放需要）。
/// `POST /__native/*` 交给 `NativeBridge`：页面用 ArrayBuffer 作为 body（Blob body 传不进自定义 scheme）。
/// 只接带着 `X-MediaCraft-Bridge` 请求头的 POST（src/native-bridge.js 每次都带）：卡片样式里的 url()、图片地址这类
/// 浏览器自己发的 GET 带不上请求头，碰不到原生能力。
@MainActor
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    /// nil 时不接原生桥（出图用的宿主页只读文件，见 CardRasterizer）
    private let bridge: NativeBridge?
    /// 还在后台处理的桥请求；WebKit 取消（stop）后不能再往 task 里写响应，实况合成随之停下。
    private var pendingBridgeTasks: [ObjectIdentifier: (work: Task<Void, Never>, stops: Bool)] = [:]

    init(root: URL, bridge: NativeBridge?) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.bridge = bridge
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        if let url = task.request.url, url.path.hasPrefix(NativeBridge.pathPrefix) {
            guard let bridge else {
                respond(task, status: 404, headers: [:], body: Data())
                return
            }
            guard Self.isBridgeCall(task.request) else {
                respond(task, status: 403, headers: [:], body: Data())
                return
            }
            let id = ObjectIdentifier(task)
            let body = task.request.httpBody ?? Data()
            // 发请求的页面是这个窗口的第几个页面：现在就记下（页面的请求总是先于它被换掉的消息到这里），
            // 后台处理时它可能已经换掉了（重新载入），那时它要开始的 AI 回复不再起
            let epoch = bridge.pageEpoch()
            // 写文件、写 EXIF、合成实况放到后台，避免大视频或多页时卡住界面。
            let work = Task {
                let reply = await bridge.handle(url: url, body: body, epoch: epoch)
                guard pendingBridgeTasks.removeValue(forKey: id) != nil else { return }
                respond(task, status: reply.status, headers: ["Content-Type": reply.contentType], body: reply.body)
            }
            pendingBridgeTasks[id] = (work, NativeBridge.stopsWhenAbandoned(url))
            return
        }
        guard let url = task.request.url, let fileURL = resolve(url),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        else {
            respond(task, status: 404, headers: [:], body: Data())
            return
        }
        var headers = [
            "Content-Type": Self.mimeType(for: fileURL),
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]
        if let range = Self.byteRange(task.request.value(forHTTPHeaderField: "Range"), length: data.count) {
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
            respond(task, status: 206, headers: headers, body: data.subdata(in: range))
        } else {
            respond(task, status: 200, headers: headers, body: data)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        guard let pending = pendingBridgeTasks.removeValue(forKey: ObjectIdentifier(task)) else { return }
        if pending.stops { pending.work.cancel() }
    }

    static let bridgeHeader = "X-MediaCraft-Bridge"

    /// 页面自己发起的桥调用：POST，且带着桥的请求头。
    static func isBridgeCall(_ request: URLRequest) -> Bool {
        request.httpMethod == "POST" && request.value(forHTTPHeaderField: bridgeHeader) == "1"
    }

    /// 只允许访问根目录内部的文件：拒绝 `..` 越界，也不跟随指向根目录外的 symlink。
    func resolve(_ url: URL) -> URL? {
        let path = url.path.isEmpty || url.path == "/" ? "/index.html" : url.path
        let candidate = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }
        return candidate
    }

    private func respond(_ task: WKURLSchemeTask, status: Int, headers: [String: String], body: Data) {
        var headers = headers
        headers["Content-Length"] = String(body.count)
        let response = HTTPURLResponse(url: task.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript"
        default:
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    /// 解析 `bytes=start-end` / `bytes=start-`，返回半开区间。
    static func byteRange(_ header: String?, length: Int) -> Range<Int>? {
        guard let header, header.hasPrefix("bytes="), length > 0 else { return nil }
        let bounds = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int(bounds[0]), start < length else { return nil }
        let end = Int(bounds[1]).map { min($0, length - 1) } ?? (length - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }
}
