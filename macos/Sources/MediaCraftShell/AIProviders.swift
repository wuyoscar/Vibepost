import Foundation

/// 在 App 里填的接口（AI 设置 ›「接别家的模型」›「接口」）：一家服务商的密钥，或一个 OpenAI 兼容的接口地址加模型名。
/// 它们经 OpenCode 使用：起 `opencode acp` 时，壳把这几家写成一段内联配置（环境变量 `OPENCODE_CONFIG_CONTENT`，
/// OpenCode 把它和用户自己的配置合并），密钥各放进一个只给这个进程的环境变量，配置里只写 `{env:…}`。
/// 用户自己的 OpenCode 配置与凭据一个字不动。
///
/// 存在 `<AI 根目录>/providers.json`（只有本人可读写，0600）。密钥只进不出：页面存的时候给，之后只知道「填了没有」；
/// 换了服务商或接口地址的那一项不沿用旧密钥（要重新填），免得一把密钥被改了地址的配置带去别处。
actor AIProviders {
    struct Entry: Equatable {
        /// OpenCode 里的服务商 id：它目录里有的（deepseek、zhipuai-coding-plan……），或自定义接口的（my-…）
        var provider: String
        var name: String
        /// 有接口地址的是自定义接口（OpenAI 兼容）：要自己写模型名；没有的是 OpenCode 目录里的服务商，模型由它列
        var baseURL: String?
        var models: [String]
        var key: String

        var fields: [String: Any] {
            ["provider": provider, "name": name, "baseURL": baseURL ?? NSNull(), "models": models, "hasKey": !key.isEmpty]
        }
    }

    struct Invalid: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static let limit = 20
    static let modelLimit = 50
    /// 放密钥的环境变量：`VIBEPOST_API_KEY_1`、`_2`……（按存的顺序）
    static let keyPrefix = "VIBEPOST_API_KEY_"
    static let configVariable = "OPENCODE_CONFIG_CONTENT"

    private let file: URL

    init(root: URL) {
        file = root.appendingPathComponent("providers.json")
    }

    /// 给页面的列表：没有密钥，只有 hasKey
    func list() -> [[String: Any]] {
        read().map(\.fields)
    }

    /// 存整份列表。每一项 `{ provider, name, baseURL?, models?, key? }`：没带 key 的沿用已存的那把（服务商和接口地址都没变时）
    func save(_ incoming: [[String: Any]]) throws -> [[String: Any]] {
        guard incoming.count <= Self.limit else { throw Invalid("接口最多 \(Self.limit) 个") }
        let stored = Dictionary(read().map { ($0.provider, $0) }) { first, _ in first }
        var entries: [Entry] = []
        for item in incoming {
            var entry = try Self.entry(item)
            guard !entries.contains(where: { $0.provider == entry.provider }) else {
                throw Invalid("「\(entry.name)」已经有一个了")
            }
            if entry.key.isEmpty, let old = stored[entry.provider], old.baseURL == entry.baseURL { entry.key = old.key }
            entries.append(entry)
        }
        try write(entries)
        return entries.map(\.fields)
    }

    /// 起 OpenCode 时另加的环境变量（内联配置与各家的密钥）和这些密钥本身（出错信息里要打码）。
    /// existing：用户环境里原有的 `OPENCODE_CONFIG_CONTENT`（有的话把我们的服务商并进去，别的原样留着）
    func launch(existing: String?) -> (environment: [String: String], secrets: [String]) {
        let entries = read().filter { !$0.key.isEmpty }
        guard !entries.isEmpty else { return ([:], []) }
        var environment: [String: String] = [:]
        var providers: [String: Any] = [:]
        for (index, entry) in entries.enumerated() {
            let variable = "\(Self.keyPrefix)\(index + 1)"
            environment[variable] = entry.key
            providers[entry.provider] = Self.block(entry, key: "{env:\(variable)}")
        }
        var config = existing.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        config["provider"] = (config["provider"] as? [String: Any] ?? [:]).merging(providers) { $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else { return ([:], []) }
        environment[Self.configVariable] = String(decoding: data, as: UTF8.self)
        return (environment, entries.map(\.key))
    }

    /// 这一家在 OpenCode 配置里的样子
    static func block(_ entry: Entry, key: String) -> [String: Any] {
        guard let baseURL = entry.baseURL else { return ["options": ["apiKey": key]] }
        return [
            "npm": "@ai-sdk/openai-compatible",
            "name": entry.name,
            "options": ["baseURL": baseURL, "apiKey": key],
            "models": Dictionary(uniqueKeysWithValues: entry.models.map { ($0, ["name": $0]) }),
        ]
    }

    /// 文字里的密钥换成省略号（Agent 的出错信息给页面看之前）
    static func redact(_ text: String, secrets: [String]) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "…") }
    }

    // MARK: - 校验

    private static let providerPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9._-]{0,63}$")
    private static let modelPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9._:@/\[\]-]{0,99}$"#)

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func entry(_ item: [String: Any]) throws -> Entry {
        let trimmed = { (value: Any?) in (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let provider = trimmed(item["provider"])
        guard matches(providerPattern, provider) else { throw Invalid("服务商不对：「\(provider)」") }
        let name = trimmed(item["name"])
        guard !name.isEmpty, name.count <= 60, !name.contains(where: \.isNewline) else { throw Invalid("接口要有个名字（最多 60 个字）") }
        let key = trimmed(item["key"])
        guard key.count <= 500, !key.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F }) else {
            throw Invalid("「\(name)」的密钥不对：不能有空格或换行")
        }
        let address = trimmed(item["baseURL"])
        guard !address.isEmpty else { return Entry(provider: provider, name: name, baseURL: nil, models: [], key: key) }
        guard address.count <= 500, let url = URLComponents(string: address), ["http", "https"].contains(url.scheme ?? ""),
              !(url.host ?? "").isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw Invalid("「\(name)」的接口地址不对：要像 https://api.example.com/v1 这样") }
        let models = (item["models"] as? [Any] ?? []).map(trimmed).filter { !$0.isEmpty }
        guard !models.isEmpty else { throw Invalid("「\(name)」要写上至少一个模型名") }
        guard models.count <= modelLimit, Set(models).count == models.count else { throw Invalid("「\(name)」的模型名重复了，或多于 \(modelLimit) 个") }
        if let bad = models.first(where: { !matches(modelPattern, $0) }) { throw Invalid("模型名不对：「\(bad)」（不能有空格，最多 100 个字符）") }
        return Entry(provider: provider, name: name, baseURL: address, models: models, key: key)
    }

    // MARK: - 文件

    private func read() -> [Entry] {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["providers"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let provider = item["provider"] as? String, let name = item["name"] as? String else { return nil }
            return Entry(
                provider: provider, name: name, baseURL: item["baseURL"] as? String, models: item["models"] as? [String] ?? [],
                key: item["key"] as? String ?? ""
            )
        }
    }

    /// 先写进一个一开始就只有本人可读的临时文件，再换上去：密钥不会有一刻躺在别人读得到的文件里
    private func write(_ entries: [Entry]) throws {
        let items = entries.map { entry -> [String: Any] in
            var item: [String: Any] = ["provider": entry.provider, "name": entry.name, "models": entry.models, "key": entry.key]
            item["baseURL"] = entry.baseURL
            return item
        }
        let data = try JSONSerialization.data(withJSONObject: ["providers": items], options: [.prettyPrinted, .sortedKeys])
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".providers-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Invalid("接口没能保存：写不进 \(file.deletingLastPathComponent().path)")
        }
        guard rename(temporary.path, file.path) == 0 else {
            try? manager.removeItem(at: temporary)
            throw Invalid("接口没能保存：\(String(cString: strerror(errno)))")
        }
    }
}
