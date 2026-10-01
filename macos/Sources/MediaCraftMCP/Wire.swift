import Foundation

/// MCP 服务与 App 共用的约定：套接字放在哪、App 的 bundle id。
public enum MCPPaths {
    public static let bundleIdentifier = "com.wuyoscar.mediacraft"
    /// 打包在 MediaCraft.app/Contents/MacOS/ 里的 MCP 服务
    public static let serverName = "mediacraft-mcp"
    public static let socketName = "mcp.sock"

    /// `~/Library/Application Support/MediaCraft`：套接字 `mcp.sock` 与设置 `mcp.json` 都在这里
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaCraft", isDirectory: true)
    }
}

/// 带中文原因的错误，原样交给 Agent 或页面。
public struct MCPFailure: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// 一条字节流（Unix 域套接字、stdin / stdout），按行收发 JSON：每行一条消息，消息里没有换行（JSONSerialization 不输出换行）。
/// 读只在一个线程里；写可以在任何线程，一条消息整条写完才写下一条。
/// 关掉之后描述符号可能分给别的文件：写与断开先看关没关（关的时候等正在写的写完），不会写进、断开别人的描述符。
public final class LineChannel: @unchecked Sendable {
    public let descriptor: Int32
    private var buffer = Data()
    /// buffer 里已经找过、没有换行的字节数：一行几十 MB（图片）时不用每读一块都从头找
    private var searched = 0
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false

    public init(descriptor: Int32) {
        self.descriptor = descriptor
        // 对方已经关了还写时只得到 EPIPE，不让整个进程收到 SIGPIPE（stdin / stdout 不是套接字，这一步不起作用也无妨）
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 下一行（不含换行）；对方关了、出错时为 nil。
    public func readLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let unsearched = buffer.index(buffer.startIndex, offsetBy: searched)
            if let newline = buffer[unsearched...].firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                searched = 0
                return line
            }
            searched = buffer.count
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// 读一行 JSON 对象；不是 JSON 对象的行跳过。
    public func readObject() -> [String: Any]? {
        while let line = readLine() {
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return object }
        }
        return nil
    }

    /// 写一条消息（JSON 对象）加换行。
    public func send(_ object: [String: Any]) throws {
        try write(JSONSerialization.data(withJSONObject: object) + Data("\n".utf8))
    }

    public func write(_ data: Data) throws {
        try writeLock.withLock {
            guard !stateLock.withLock({ closed }) else { throw MCPFailure("连接已经关了") }
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(descriptor, base + offset, raw.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw MCPFailure("写不进去（\(String(cString: strerror(errno)))）")
                    }
                    offset += count
                }
            }
        }
    }

    /// 空闲的连接上有没有动静：对方发来了什么（断开前的告别）、关了、出错都算。不阻塞。
    public func hasActivity() -> Bool {
        var probe = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&probe, 1, 0) > 0 || !buffer.isEmpty
    }

    /// 读最多等这么久（秒），到了 readLine 返回 nil；只对套接字有效。
    public func setReadTimeout(_ seconds: Int) {
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    /// 两个方向都断开：另一个线程里阻塞着的读、写随之返回。
    public func shutdown() {
        stateLock.withLock {
            if !closed { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        }
    }

    /// 先断开（叫醒阻塞着的写），等正在写的那条写完或失败，再关掉描述符
    public func close() {
        shutdown()
        writeLock.withLock {
            stateLock.withLock {
                guard !closed else { return }
                closed = true
                Darwin.close(descriptor)
            }
        }
    }
}

/// Unix 域套接字：App 监听，`mediacraft-mcp` 连过来。
public enum UnixSocket {
    /// 连到 path；没有人在听时抛错。
    public static func connect(to path: String) throws -> Int32 {
        var address = try address(of: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MCPFailure("建不了套接字（\(String(cString: strerror(errno)))）") }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw MCPFailure("连不上 \(path)（\(reason)）")
        }
        return descriptor
    }

    /// 在 path 上监听，文件权限 0600：只有自己能连。上次留下的套接字文件先删掉；还有人在上面听（另一个 MediaCraft 开着）时不抢，抛错。
    /// 返回非阻塞的监听描述符。
    public static func listen(at path: String) throws -> Int32 {
        var address = try address(of: path)
        if let other = try? connect(to: path) {
            Darwin.close(other)
            throw MCPFailure("另一个 Vibepost 已经在接外部 Agent（\(path)）")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MCPFailure("建不了套接字（\(String(cString: strerror(errno)))）") }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            unlink(path)
            throw MCPFailure("没能在 \(path) 上监听（\(reason)）")
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        return descriptor
    }

    /// 接一个连接（阻塞模式：BSD 上接进来的连接会继承监听套接字的 O_NONBLOCK）；没有等着的连接时为 nil。
    public static func accept(_ listener: Int32) -> Int32? {
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else { return nil }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        return descriptor
    }

    /// 路径上那个文件的 inode（没有时为 nil）：退出时只删自己建的套接字文件
    public static func inode(at path: String) -> ino_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_ino : nil
    }

    /// 连进来的是哪个用户（getpeereid）
    public static func peerUserID(_ descriptor: Int32) -> uid_t? {
        var user: uid_t = 0
        var group: gid_t = 0
        return getpeereid(descriptor, &user, &group) == 0 ? user : nil
    }

    private static func address(of path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw MCPFailure("套接字路径太长：\(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
}
