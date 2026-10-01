import Foundation

/// 测试用的本机 HTTP 服务：127.0.0.1 上随机一个端口，按路径回固定的回复（可以是重定向、可以一点点慢慢给），
/// 记下收到的每个请求的路径。配图候选的下载、重定向、删稿子时取消下载都拿它来测，不上网。
final class LocalHTTPServer: @unchecked Sendable {
    struct Route {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// 正文分成几段、每段之间停多久（慢慢下载）；nil 是一次给完
        var trickle: (pieces: Int, pause: TimeInterval)?
    }

    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var received: [String] = []

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        self.listener = listener
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var base: String { "http://127.0.0.1:\(port)" }

    func route(_ path: String, _ route: Route) {
        lock.withLock { routes[path] = route }
    }

    /// 收到过的请求路径（按先后）
    var requests: [String] { lock.withLock { received } }

    func stop() {
        shutdown(listener, SHUT_RDWR) // 叫醒阻塞在 accept 里的线程
        close(listener)
    }

    private func acceptLoop() {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in serve(connection) }
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(contentsOf: buffer[0..<count])
        }
        let path = String(decoding: request, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let route = lock.withLock { () -> Route? in
            received.append(path)
            return routes[path]
        } ?? Route(status: 404)
        var head = "HTTP/1.1 \(route.status) X\r\nContent-Length: \(route.body.count)\r\nConnection: close\r\n"
        for (name, value) in route.headers { head += "\(name): \(value)\r\n" }
        guard write(Data((head + "\r\n").utf8), to: connection) else { return }
        let pieces = max(1, route.trickle?.pieces ?? 1)
        let size = (route.body.count + pieces - 1) / pieces
        for start in stride(from: 0, to: route.body.count, by: max(1, size)) {
            if start > 0, let pause = route.trickle?.pause { Thread.sleep(forTimeInterval: pause) }
            guard write(route.body.subdata(in: start..<min(route.body.count, start + size)), to: connection) else { return }
        }
    }

    private func write(_ data: Data, to connection: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(connection, bytes.baseAddress! + offset, bytes.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
