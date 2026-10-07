import Foundation

/// 用户自己存的模板：支持目录的「模板」文件夹（`AIConfiguration.templates`）里每套一个文件夹 `<名字>/模板.md` + 同目录的图片。
/// 文件的格式（开头 front matter + 卡片内容，图片按 `编号: 文件名` 列在开头）由页面读写（src/templates/format.js、templates.js），
/// 壳只管文件：列出（名字与 模板.md 全文）、读（加上图片的 data URL）、存（页面给 md 与图片的 base64，整套换掉）、删、在 Finder 中显示。
/// 仓库自带的模板不在这里（随网页打包的登记表 src/templates/index.js）。文件夹不在时列出为空，第一次存时才建。
/// 用户用 Finder 整套拷给别人、或自己改 模板.md 都行，App 每次都读最新的；App 只删用户点了删除的那一套，从不删整个文件夹。
/// 几个窗口共用这一份，读写排在一把锁里。
final class TemplateLibrary: @unchecked Sendable {
    struct Template: Sendable, Equatable {
        /// 文件夹名就是模板名
        let name: String
        let folder: URL
        /// `模板.md` 的全文
        let content: String
    }

    /// 一张要写进文件夹的图片：文件名（只看最后一段）与内容
    struct Image: Sendable {
        let name: String
        let data: Data
    }

    typealias Failure = WritingManuals.Failure

    static let fileName = "模板.md"
    /// `模板.md` 最多这么多字节（UTF-8）
    static let contentLimit = 1_000_000
    /// 每张图最多这么多字节；一套最多这么多张
    static let imageLimit = 20_000_000
    static let imageCountLimit = 40
    /// 认得的图片格式：扩展名 → MIME 类型（读成 data URL 用）
    static let imageTypes: [String: String] = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp"]

    let folder: URL
    private let lock = NSLock()

    init(folder: URL) {
        self.folder = folder
    }

    /// 全部模板（按名字的拼音排）：文件夹里每个带 `模板.md` 的子文件夹一套；文件夹还不在时为空
    func list() throws -> [Template] {
        try lock.withLock { try templatesLocked() }
    }

    /// 这一套与它的图片（文件名 → data URL；`模板.md` 旁边认得的图片文件都读进来）
    func read(_ name: String) throws -> (template: Template, images: [String: String]) {
        try lock.withLock {
            let template = try templateLocked(name)
            var images: [String: String] = [:]
            let files = (try? FileManager.default.contentsOfDirectory(at: template.folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            // 文件夹里的图最多读 imageCountLimit 张（用户往里丢几百张也不会一次读成一个巨大的回复）
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard images.count < Self.imageCountLimit else { break }
                guard let mime = Self.imageTypes[file.pathExtension.lowercased()],
                      let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= Self.imageLimit
                else { continue }
                images[file.lastPathComponent] = "data:\(mime);base64,\(data.base64EncodedString())"
            }
            return (template, images)
        }
    }

    /// 新建或整套换掉一份：先在旁边的临时文件夹里写好 `模板.md` 与图片，再换到 `<名字>/`（中途出错不会留下半套）
    func save(name rawName: String, content: String, images: [Image]) throws -> Template {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = WritingManuals.problem(withName: name) { throw Failure(problem.replacingOccurrences(of: "手册名", with: "模板名")) }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("模板不能空着") }
        guard content.utf8.count <= Self.contentLimit else { throw Failure("模板太长了：最多 \(Self.contentLimit / 1000) KB") }
        guard images.count <= Self.imageCountLimit else { throw Failure("一套模板最多 \(Self.imageCountLimit) 张图") }
        var seen: Set<String> = []
        for image in images {
            let file = (image.name as NSString).lastPathComponent
            guard file == image.name, !file.hasPrefix("."), file.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  Self.imageTypes[(file as NSString).pathExtension.lowercased()] != nil else {
                throw Failure("图片文件名不对：\(image.name)（只能是 jpg / png / gif / webp）")
            }
            guard file.lowercased() != Self.fileName.lowercased(), seen.insert(file.lowercased()).inserted else { throw Failure("图片文件名重复：\(file)") }
            guard image.data.count <= Self.imageLimit else { throw Failure("图片太大了：\(file)（最多 \(Self.imageLimit / 1_000_000) MB）") }
        }
        return try lock.withLock {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(name, isDirectory: true)
            let staging = folder.appendingPathComponent(".\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try Data(content.utf8).write(to: staging.appendingPathComponent(Self.fileName))
            for image in images {
                try image.data.write(to: staging.appendingPathComponent(image.name))
            }
            // 同名的整套换掉：原子替换（换到一半出错时旧的那套还在）；文件夹名大小写不同也算同一套（APFS 默认不分大小写）
            if let existing = try? templateLocked(name) {
                _ = try FileManager.default.replaceItemAt(existing.folder, withItemAt: staging)
                if existing.folder.lastPathComponent != name { try? FileManager.default.moveItem(at: existing.folder, to: target) }
            } else {
                try FileManager.default.moveItem(at: staging, to: target)
            }
            return Template(name: name, folder: target, content: content)
        }
    }

    /// 删掉这一套（整个文件夹）
    func remove(_ name: String) throws {
        try lock.withLock {
            let template = try templateLocked(name)
            try FileManager.default.removeItem(at: template.folder)
        }
    }

    /// 要在 Finder 中显示的：这一套的文件夹，没给名字时是模板文件夹本身（不在时先建好）
    func location(of name: String?) throws -> URL {
        try lock.withLock {
            guard let name, !name.isEmpty else {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return folder
            }
            return try templateLocked(name).folder
        }
    }

    // MARK: - 文件夹

    private func templatesLocked() throws -> [Template] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { throw Failure("「\(folder.path)」不是文件夹", status: 500) }
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return entries.compactMap { entry -> Template? in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let file = entry.appendingPathComponent(Self.fileName)
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= Self.contentLimit,
                  let content = String(data: data, encoding: .utf8)
            else { return nil }
            return Template(name: entry.lastPathComponent, folder: entry, content: content)
        }
        .sorted { WritingManuals.ordered($0.name, $1.name) }
    }

    /// 按名字找（不分大小写：APFS 默认不分，`save("foo")` 换掉的 "Foo" 读回来也得认）
    private func templateLocked(_ name: String) throws -> Template {
        guard let template = try templatesLocked().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw Failure("没有这个模板：\(name)", status: 404)
        }
        return template
    }
}
