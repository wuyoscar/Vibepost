import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 把一组文件交给 iPhone。生产环境是 AirDrop，测试里换成假接收端。
@MainActor
public protocol IPhoneSender {
    func send(_ files: [URL]) throws
}

/// 写入剪贴板。系统剪贴板会经「通用剪贴板」同步到 iPhone。
@MainActor
public protocol TextClipboard {
    /// 纯文本（发送到 iPhone 时的正文）
    func write(_ text: String)
    /// 带格式：HTML 与纯文本两种格式（复制长文进公众号编辑器）
    func writeRich(html: String, text: String)
}

public struct SystemClipboard: TextClipboard {
    nonisolated public init() {}

    public func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func writeRich(html: String, text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(html, forType: .html)
        NSPasteboard.general.setString(text, forType: .string)
    }
}

public struct AirDropSender: IPhoneSender {
    nonisolated public init() {}

    public func send(_ files: [URL]) throws {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else {
            throw SendError.airDropUnavailable
        }
        service.perform(withItems: files)
    }
}

enum SendError: LocalizedError {
    case airDropUnavailable
    case emptyBatch
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .airDropUnavailable: "隔空投送不可用，请确认 Wi-Fi 与蓝牙已打开"
        case .emptyBatch: "没有要发送的文件"
        case .invalidName(let name): "文件名无效：\(name)"
        }
    }
}

/// 发送前的暂存区：页面逐个上传文件，最后按文件名（页序）整组发出。
/// AirDrop 在后台读取文件，所以发送后不能立刻删除，下次发送时清理一天前的批次。
final class SendStaging {
    private let root: URL
    private let now: () -> Date

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("MediaCraft-Send"), now: @escaping () -> Date = Date.init) {
        self.root = root
        self.now = now
    }

    /// name 为 `NN.png` / `NN.jpg` 或实况目录包里的 `NN.pvt/<文件>`，不允许其他层级。
    func stage(batch: String, name: String, data: Data) throws {
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]
        let valid = UUID(uuidString: batch) != nil
            && components.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
            && (components.count == 1
                ? imageExtensions.contains((components[0] as NSString).pathExtension.lowercased())
                : components.count == 2 && components[0].hasSuffix(".pvt"))
        guard valid else { throw SendError.invalidName(name) }
        let file = components.reduce(root.appendingPathComponent(batch)) { $0.appendingPathComponent($1) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    /// 按文件名排序，拍摄时间从第一页起逐秒递增（最后一页 = 现在），iPhone 相册按拍摄时间排序时顺序不乱。
    func finalize(batch: String) throws -> [URL] {
        guard UUID(uuidString: batch) != nil else { throw SendError.invalidName(batch) }
        let directory = root.appendingPathComponent(batch)
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw SendError.emptyBatch }
        let latest = now()
        for (index, file) in files.enumerated() {
            let captureDate = latest.addingTimeInterval(TimeInterval(index - files.count + 1))
            try CaptureDate.stamp(file, date: captureDate)
        }
        removeBatches(olderThan: latest.addingTimeInterval(-86_400))
        return files
    }

    private func removeBatches(olderThan cutoff: Date) {
        let batches = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for batch in batches {
            let modified = (try? batch.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: batch) }
        }
    }
}

enum CaptureDate {
    /// 图片写入 EXIF 拍摄时间；实况 .pvt 写入其中的 JPG。文件与目录的创建 / 修改时间设成同一时刻。
    static func stamp(_ item: URL, date: Date) throws {
        let files = item.pathExtension == "pvt"
            ? try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
            : [item]
        for file in files {
            if let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image) {
                try writeExif(file, date: date, type: type)
            }
            try setFileDates(file, date)
        }
        if files != [item] { try setFileDates(item, date) }
    }

    private static func setFileDates(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    /// 只合并元数据、不重新编码像素：实况 JPG 的 Apple MakerNote（配对 ID）必须原样保留。
    private static func writeExif(_ file: URL, date: Date, type: UTType) throws {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let offset = DateFormatter()
        offset.locale = Locale(identifier: "en_US_POSIX")
        offset.dateFormat = "xxx"
        let metadata = CGImageMetadataCreateMutable()
        let values: [(CFString, String)] = [
            (kCGImagePropertyExifDateTimeOriginal, formatter.string(from: date)),
            (kCGImagePropertyExifDateTimeDigitized, formatter.string(from: date)),
            (kCGImagePropertyExifOffsetTimeOriginal, offset.string(from: date)),
        ]
        for (key, value) in values {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, key, value as CFString)
        }
        let output = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).tmp")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else { return }
        let options = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, nil) else {
            try? FileManager.default.removeItem(at: output)
            return
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: output)
    }
}
