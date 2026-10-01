import Foundation

/// 配图候选的放行范围：同一站点（协议、主机、端口都相同）或同一目录（不含子目录）。
/// 放行记账按这个结构比较；给人看的文字（确认框按钮上的「网站 https://example.com」）另外生成。
enum CandidateScope: Hashable, Sendable {
    case site(scheme: String, host: String, port: Int)
    case directory(String)

    /// 网址所在的站点；不是 http(s)、没有主机时为 nil。没写端口时按协议的默认端口算，写不写 :443 是同一个站点。
    static func site(of url: URL) -> CandidateScope? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        return .site(scheme: scheme, host: host, port: url.port ?? defaultPort(scheme))
    }

    private static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }

    var label: String {
        switch self {
        case let .site(scheme, host, port):
            let shownHost = host.contains(":") ? "[\(host)]" : host
            let shownPort = port == Self.defaultPort(scheme) ? "" : ":\(port)"
            return "网站 \(scheme)://\(shownHost)\(shownPort)"
        case let .directory(path):
            return "目录 \(path)"
        }
    }
}

/// 下载停在一次越界的重定向上（跳到了放行范围以外的站点）：调用方当作「要问用户」，问过再来。
struct CandidateRedirect: LocalizedError {
    let target: URL
    let scope: CandidateScope
    var errorDescription: String? { "图片的网址重定向到了别的站点：\(target.absoluteString)" }
}

/// 网上的图片不从本机、局域网、链路本地地址读，除非网址里写的就是那个地址（确认框里用户看得到、明确同意的）：
/// 主机名解析出来落在这些地址上时拒绝——换个名字指向本机或局域网，用户在确认框里看不出来。
enum LocalAddresses {
    /// 网址里直接写的就是本机或局域网：IP 地址、localhost、.local
    static func isExplicit(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
            || host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
    }

    /// 主机名解析出来是本机、局域网、链路本地地址时抛错；解析不出来的交给下载本身去失败。
    static func check(_ url: URL) async throws {
        guard let host = url.host?.lowercased(), !host.isEmpty, !isExplicit(host) else { return }
        let hits = await privateAddresses(of: host)
        guard hits.isEmpty else {
            throw AISessions.Failure("「\(host)」指向本机或局域网地址（\(hits.joined(separator: "、"))），不载入；确实要载入请直接写那个地址")
        }
    }

    /// 解析主机名（getaddrinfo 会阻塞，放在别的线程上），留下落在本机 / 局域网里的那些地址
    private static func privateAddresses(of host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: resolve(host).filter { isPrivate($0.bytes) }.map(\.text))
            }
        }
    }

    private static func resolve(_ host: String) -> [(bytes: [UInt8], text: String)] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0 else { return [] }
        defer { freeaddrinfo(list) }
        var found: [(bytes: [UInt8], text: String)] = []
        var cursor = list
        while let entry = cursor?.pointee {
            cursor = entry.ai_next
            guard let address = entry.ai_addr else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, entry.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: text)
            if entry.ai_family == AF_INET {
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                found.append((bytes, name))
            } else if entry.ai_family == AF_INET6 {
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                found.append((bytes, name))
            }
        }
        return found
    }

    /// 本机（127/8、::1）、未指定（0/8、::）、局域网（10/8、172.16/12、192.168/16、100.64/10、fc00::/7）、
    /// 链路本地（169.254/16、fe80::/10）；IPv6 里嵌着 IPv4 的按那个 IPv4 算
    static func isPrivate(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            let (a, b) = (bytes[0], bytes[1])
            return a == 0 || a == 10 || a == 127 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b))
        }
        guard bytes.count == 16 else { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff { return isPrivate(Array(bytes[12...])) }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) { return true } // :: 与 ::1
        return (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
    }
}

/// 下载时逐跳检查重定向：只跟到放行范围里的站点（这张图原来的站点、这一次同意的、这篇会话里放行过的），
/// 解析到本机 / 局域网的主机名也不跟。不跟时下载停在这一跳（拿到的是 3xx 回复），记下原因由下载方报出来。
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowed: Set<CandidateScope>
    private let lock = NSLock()
    private var stopped: Error?

    init(allowed: Set<CandidateScope>) {
        self.allowed = allowed
    }

    /// 停在了哪一跳、为什么（没停为 nil）
    var stop: Error? { lock.withLock { stopped } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, let scope = CandidateScope.site(of: url) else {
            refuse(AISessions.Failure("图片的网址重定向到了不支持的地址：\(request.url?.absoluteString ?? "")"), completionHandler)
            return
        }
        guard allowed.contains(scope) else {
            refuse(CandidateRedirect(target: url, scope: scope), completionHandler)
            return
        }
        Task {
            do {
                try await LocalAddresses.check(url)
                completionHandler(request)
            } catch {
                refuse(error, completionHandler)
            }
        }
    }

    private func refuse(_ reason: Error, _ completionHandler: (URLRequest?) -> Void) {
        lock.withLock { stopped = reason }
        completionHandler(nil)
    }
}
