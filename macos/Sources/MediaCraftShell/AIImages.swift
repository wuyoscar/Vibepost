import Foundation

/// 生图接口的地址：默认是 OpenAI 的正式接口，测试时换成本机的假接口。
public struct ImageAPI: Sendable {
    public var openAI: URL

    public init(openAI: URL) {
        self.openAI = openAI
    }

    public static let standard = ImageAPI(openAI: URL(string: "https://api.openai.com")!)
}

/// App 的工具 generate_image（用 Claude Code 时；Codex 用它自带的生图）：原生壳直接调 OpenAI 的生图接口（不经 Bash、不用确认），
/// 密钥取登录 shell 环境里的 `OPENAI_API_KEY`（没有时再找 `~/.env`），不写进日志、错误与页面。生成的图交给调用方存成配图候选。
/// 每篇稿子同时最多一个生图任务，可以停止（取消网络请求）。
final class AIImages: @unchecked Sendable {
    static let keyName = "OPENAI_API_KEY"

    /// 一次生图的要求（页面发来的，已检查）
    struct Request {
        let model: String
        let prompt: String
        let count: Int
        let width: Int
        let height: Int

        static let countRange = 1...4
        static let edgeRange = 256...3840
        static let promptLimit = 4000

        init(_ fields: [String: Any]) throws {
            guard let model = fields["model"] as? String, AISessions.TurnRequest.isModel(model) else {
                throw AISessions.Failure("生图模型 ID 不对")
            }
            let prompt = (fields["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty, prompt.count <= Self.promptLimit else { throw AISessions.Failure("提示词要有内容，最多 \(Self.promptLimit) 字") }
            guard let count = fields["count"] as? Int, Self.countRange.contains(count) else { throw AISessions.Failure("张数要在 1–4 之间") }
            let size = (fields["size"] as? String ?? "").split(separator: "x").compactMap { Int($0) }
            guard size.count == 2, size.allSatisfy(Self.edgeRange.contains) else {
                throw AISessions.Failure("尺寸写成「宽x高」，每边 \(Self.edgeRange.lowerBound)–\(Self.edgeRange.upperBound) 像素")
            }
            self.model = model
            self.prompt = prompt
            self.count = count
            width = size[0]
            height = size[1]
        }
    }

    /// 生成一张图最多等这么久（高质量的图常要一两分钟）
    private static let requestTimeout: TimeInterval = 300
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        return URLSession(configuration: configuration)
    }()
    private let api: ImageAPI
    private let lock = NSLock()
    private var jobs: [String: Task<[Data], Error>] = [:]

    init(api: ImageAPI) {
        self.api = api
    }

    /// 生成 count 张图（每张的原始字节）。keys 是能找到的密钥（登录 shell 的环境与 ~/.env）；这篇已经在生图时报错。
    func generate(draftId: String, request: Request, keys: [String: String]) async throws -> [Data] {
        let name = Self.keyName
        guard let key = keys[name], !key.isEmpty else {
            throw AISessions.Failure(
                "没有找到 \(name)：在终端的 shell 配置（如 ~/.zshrc）里 export \(name)=你的密钥，或写进 ~/.env（一行 \(name)=你的密钥），下次生图时 App 会重新读"
            )
        }
        let task = Task { try await self.openAI(request, key: key) }
        try lock.withLock {
            guard jobs[draftId] == nil else {
                task.cancel()
                throw AISessions.Failure("这篇稿子正在生图，等它生成完或先停止")
            }
            jobs[draftId] = task
        }
        defer { lock.withLock { jobs[draftId] = nil } }
        do {
            return try await task.value
        } catch where task.isCancelled {
            throw AISessions.Failure("已停止生图")
        }
    }

    /// 停止这篇正在生成的图；没有在生成时为 false
    @discardableResult
    func cancel(draftId: String) -> Bool {
        guard let task = lock.withLock({ jobs[draftId] }) else { return false }
        task.cancel()
        return true
    }

    /// OpenAI Images API：和作者自用的 gpt-image 技能一样，`POST /v1/images/generations`，quality 为 high，取 data[].b64_json
    private func openAI(_ request: Request, key: String) async throws -> [Data] {
        let body: [String: Any] = [
            "model": request.model, "prompt": request.prompt, "size": "\(request.width)x\(request.height)",
            "n": request.count, "quality": "high",
        ]
        let reply = try await post(api.openAI.appendingPathComponent("v1/images/generations"), body: body,
                                   headers: ["Authorization": "Bearer \(key)"], key: key)
        let images = (reply["data"] as? [[String: Any]] ?? []).compactMap { ($0["b64_json"] as? String).flatMap { Data(base64Encoded: $0) } }
        guard !images.isEmpty else { throw AISessions.Failure("OpenAI 没有返回图片") }
        return images
    }

    /// dotenv 文件里的变量：`KEY=值` 或 `export KEY=值`，值可以带引号；# 开头的是注释。读不到时为空
    static func dotenv(_ file: URL) -> [String: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var variables: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, ["\"", "'"].contains(quote), value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            variables[line[..<equals].trimmingCharacters(in: .whitespaces)] = value
        }
        return variables
    }

    /// 发 JSON、收 JSON；不是 2xx 时带上接口给的原因（去掉密钥，最多 300 字）
    private func post(_ url: URL, body: [String: Any], headers: [String: String], key: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AISessions.Failure("OpenAI 生图接口连不上：\(error.localizedDescription)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let reason = ((json["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self))
                .replacingOccurrences(of: key, with: "…")
            throw AISessions.Failure("OpenAI 生图失败（\(status)）：\(reason.prefix(300))")
        }
        return json
    }
}
