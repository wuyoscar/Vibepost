import Foundation

/// 写作手册：只管写什么、什么口味（题材、读者、语气、结构），和管排版写法的操作手册（src/engine/manual.js）分开。
/// 像技能一样每份一个 Markdown 文件：开头两行 `---` 之间是 `name:`（手册名）与 `description:`（一句话说明它管什么），后面是正文。
/// 放在支持目录的「写作手册」文件夹（`AIConfiguration.writingManuals`），用户用任何编辑器改，App 每次都读最新的；
/// 文件夹不在时用 App 自带的示例（网页根目录的 `src/writing-manuals/`）建好，已经在了就不动（删掉的示例不会回来），App 从不删它。
/// Agent 只看目录（名字 + 说明）自己挑：App 里的 AI 每轮在工作副本里拿到一份拷贝（`写作手册/`）与 AGENTS.md 末尾的目录，
/// 外部 Agent 经 MCP 列出、读取；新建、修改经原生桥 `manuals/save`（页面先弹确认框问过用户）。
/// 几个窗口、AI 的几轮、外部 Agent 共用这一份，读写排在一把锁里。
final class WritingManuals: @unchecked Sendable {
    struct Manual: Sendable, Equatable {
        let name: String
        /// 一行，最多 `descriptionLimit` 字（长了截断、末尾「…」）
        let description: String
        let file: URL
    }

    /// 出错的原因（中文）与原生桥回的状态码：名字、说明、正文不合规矩 400，没有这份 404
    struct Failure: LocalizedError {
        let message: String
        let status: Int
        init(_ message: String, status: Int = 400) {
            self.message = message
            self.status = status
        }
        var errorDescription: String? { message }
    }

    static let nameLimit = 40
    static let descriptionLimit = 200
    /// 保存的正文最多这么多字节（UTF-8）
    static let bodyLimit = 200_000
    /// 文件夹里比这还大的文件不算手册（用户放错了东西，不每轮整个读进来、拷进工作副本）
    static let fileLimit = 1_000_000

    let folder: URL
    private let examples: URL
    private let lock = NSLock()

    /// - folder: 写作手册的文件夹
    /// - examples: 自带的示例手册（文件夹不在时拷进去）
    init(folder: URL, examples: URL) {
        self.folder = folder
        self.examples = examples
    }

    /// 文件夹不在时建好并放进示例
    func ensure() throws {
        try lock.withLock { try ensureLocked() }
    }

    /// 全部手册，按名字的拼音排；同名的只认文件名排在前面的那份
    func list() throws -> [Manual] {
        try lock.withLock {
            try ensureLocked()
            return try manualsLocked()
        }
    }

    /// 这份手册与它的正文（不含开头的 name / description）
    func read(_ name: String) throws -> (manual: Manual, body: String) {
        try lock.withLock {
            try ensureLocked()
            guard let manual = try manualsLocked().first(where: { $0.name == name }), let text = Self.readText(manual.file) else {
                throw Failure("没有这份写作手册：\(name)", status: 404)
            }
            return (manual, Self.parse(text, fallbackName: manual.name).body)
        }
    }

    /// 新建或整份换掉一份手册：已有这个名字的写回它原来的文件，没有的写成 `<名字>.md`
    func save(name rawName: String, description rawDescription: String, body: String) throws -> Manual {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.problem(withName: name) { throw Failure(problem) }
        let description = Self.oneLine(rawDescription)
        guard !description.isEmpty else { throw Failure("说明（description）不能空着：一句话写清这份手册管什么") }
        guard description.count <= Self.descriptionLimit else { throw Failure("说明最多 \(Self.descriptionLimit) 字，现在 \(description.count) 字") }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("正文不能空着") }
        guard body.utf8.count <= Self.bodyLimit else { throw Failure("正文太长了：最多 \(Self.bodyLimit / 1000) KB") }
        return try lock.withLock {
            try ensureLocked()
            let manuals = try manualsLocked()
            let file: URL
            if let existing = manuals.first(where: { $0.name == name }) {
                file = existing.file
            } else {
                file = folder.appendingPathComponent("\(name).md")
                // 文件名撞上了别的（大小写、写法不同也算同一个文件）：不覆盖它
                if FileManager.default.fileExists(atPath: file.path) {
                    let other = manuals.first { $0.file.standardizedFileURL.path.lowercased() == file.standardizedFileURL.path.lowercased() }
                    throw Failure(other.map { "「\(name).md」已经是写作手册「\($0.name)」的文件，换个名字" } ?? "写作手册文件夹里已经有一个「\(name).md」，换个名字")
                }
            }
            try Data(Self.compose(name: name, description: description, body: body).utf8).write(to: file, options: .atomic)
            return Manual(name: name, description: description, file: file)
        }
    }

    /// 把全部手册拷进 directory（先清掉它原来的样子）：工作副本里的「写作手册/」，Agent 改了也不留。
    /// 拷的是文件内容（手册是符号链接时也不把链接拷过去，Agent 改不到原文件）。返回拷进去的手册（file 是拷贝）
    func copy(into directory: URL) throws -> [Manual] {
        try lock.withLock {
            try ensureLocked()
            let manuals = try manualsLocked()
            // 换成了符号链接也只删链接本身
            do {
                try FileManager.default.removeItem(at: directory)
            } catch CocoaError.fileNoSuchFile {}
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try manuals.compactMap { manual in
                guard let data = Self.readData(manual.file) else { return nil }
                let copy = directory.appendingPathComponent(manual.file.lastPathComponent)
                try data.write(to: copy)
                return Manual(name: manual.name, description: manual.description, file: copy)
            }
        }
    }

    // MARK: - 文件夹

    private func ensureLocked() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw Failure("「\(folder.path)」不是文件夹", status: 500) }
            return
        }
        // 先在旁边的临时文件夹里放好示例再整个挪过去：中途出错不会留下半个文件夹（下次还会再建）
        let parent = folder.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(folder.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let samples = (try? FileManager.default.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for sample in samples where sample.pathExtension.lowercased() == "md" {
            guard let data = Self.readData(sample) else { continue }
            try data.write(to: staging.appendingPathComponent(sample.lastPathComponent))
        }
        do {
            try FileManager.default.moveItem(at: staging, to: folder)
        } catch {
            // 同时开着的另一个 Vibepost 先建好了：用它的
            guard !FileManager.default.fileExists(atPath: folder.path) else { return }
            throw error
        }
    }

    private func manualsLocked() throws -> [Manual] {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { Self.ordered($0.lastPathComponent, $1.lastPathComponent) }
        var seen: Set<String> = []
        var manuals: [Manual] = []
        for file in files {
            guard let text = Self.readText(file) else { continue }
            let parsed = Self.parse(text, fallbackName: file.deletingPathExtension().lastPathComponent)
            guard seen.insert(parsed.name).inserted else { continue }
            manuals.append(Manual(name: parsed.name, description: parsed.description, file: file))
        }
        return manuals.sorted { Self.ordered($0.name, $1.name) }
    }

    /// 按中文（拼音）排、数字按大小：用固定的区域，不跟着这台 Mac 的语言设置变
    private static let collation = Locale(identifier: "zh_CN")
    static func ordered(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive], range: nil, locale: collation) == .orderedAscending
    }

    /// 文件的内容（跟着符号链接）；读不了、是文件夹、太大时为 nil
    private static func readData(_ file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= fileLimit else { return nil }
        return data
    }

    /// 文件的文字：不是 UTF-8 的不算手册
    private static func readText(_ file: URL) -> String? {
        readData(file).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - 名字与开头的 name / description

    /// 名字用作文件名：去掉首尾空白后 1–40 字，没有 / \ : 与控制字符，不以「.」开头；合规矩时为 nil
    static func problem(withName name: String) -> String? {
        if name.isEmpty { return "手册名不能空着" }
        if name.count > nameLimit { return "手册名最多 \(nameLimit) 字" }
        if name.contains(where: { "/\\:".contains($0) }) { return "手册名里不能有 / \\ :" }
        if name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return "手册名里不能有换行、制表这类控制字符" }
        if name.hasPrefix(".") { return "手册名不能以「.」开头" }
        return nil
    }

    /// 并成一行：换行与连着的空白换成一个空格
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    struct Parsed: Equatable {
        let name: String
        let description: String
        let body: String
    }

    /// 读开头 `---` 之间的 `name:` 与 `description:`（YAML 风格：值可以加引号，`>` / `|` 后面缩进的几行并成一行），其余的键不管。
    /// 没有这一段时名字是文件名、说明空着、全文都是正文；name 空着时也用文件名。正文去掉开头的空行
    static func parse(_ raw: String, fallbackName: String) -> Parsed {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.components(separatedBy: "\n")
        var fields: [String: String] = [:]
        var body = text
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) }) {
            var key: String?
            for line in lines[1..<end] {
                if let current = key, line.first?.isWhitespace == true {
                    // 接着上一个键的值（折行写的说明）
                    fields[current] = [fields[current] ?? "", line.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty }.joined(separator: " ")
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else {
                    key = nil
                    continue
                }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if [">", "|", ">-", "|-", ">+", "|+"].contains(value) { value = "" }
                key = name
                fields[name] = unquote(value)
            }
            body = lines[(end + 1)...].joined(separator: "\n")
        }
        while body.hasPrefix("\n") { body.removeFirst() }
        let name = oneLine(fields["name"] ?? "")
        var description = oneLine(fields["description"] ?? "")
        if description.count > descriptionLimit { description = String(description.prefix(descriptionLimit - 1)) + "…" }
        return Parsed(name: name.isEmpty ? fallbackName : name, description: description, body: body)
    }

    /// 写回文件的样子：开头 name / description（要加引号时加双引号），空一行，正文（末尾留一个换行）
    static func compose(name: String, description: String, body: String) -> String {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n")
        while text.hasPrefix("\n") { text.removeFirst() }
        if !text.hasSuffix("\n") { text += "\n" }
        return "---\nname: \(quoted(name))\ndescription: \(quoted(description))\n---\n\n\(text)"
    }

    /// YAML 里照字面读不出来的值（以引号、#、[、{、> 这类开头，或里面有「: 」「 #」）加上双引号
    private static func quoted(_ value: String) -> String {
        let special = value.first.map { "\"'#[]{}>|*&!%@`,?-:".contains($0) } ?? true
        guard special || value.contains(": ") || value.contains(" #") || value.hasSuffix(":") else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var result = ""
        var escaped = false
        for character in inner {
            if escaped {
                result.append(character == "n" ? " " : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
