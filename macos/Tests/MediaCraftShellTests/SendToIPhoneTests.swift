import Foundation
import ImageIO
import Testing

@MainActor
struct SendToIPhoneTests {
    static let paragraphs = (1...40).map { "第\($0)段：把写好的内容排成卡片，再一键发到手机上发布。" }
    static let markdown = "# 发送测试\n\n" + paragraphs.map { $0.replacingOccurrences(of: "卡片", with: "**卡片**") }.joined(separator: "\n\n")
    /// 长文没有正文栏：剪贴板放全文的纯文本
    static let expectedClipboard = "发送测试\n\n" + paragraphs.joined(separator: "\n\n")
    /// 图文卡片的小红书正文（正文栏里单独写的那段）：剪贴板放它，不放卡片上的字
    static let caption = "周末把稿子排成卡片，一键发到手机。😀\n\n#排版 #效率"

    @Test("卡片整组按页序发到 iPhone，拍摄时间递增，正文栏里的小红书正文进剪贴板")
    func sendsCardsInPageOrder() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let pageCount = try await harness.evaluate("""
            await window.mediacraft.drafts.create({ markdown, caption });
            return (await window.mediacraft.render.pages()).length;
        """, arguments: ["markdown": Self.markdown, "caption": Self.caption]) as? Int ?? 0

        _ = try await harness.evaluate("ui.click('发送到 iPhone')")
        try await waitUntil(timeout: .seconds(20)) { !harness.sender.batches.isEmpty }
        let files = harness.sender.batches.first ?? []
        let captureDates = files.map(Self.captureDate)
        let sizes = files.map(Self.pixelSize)
        await harness.tearDown()

        #expect(pageCount >= 2, "正文应足够长，排成多页")
        #expect(files.map(\.lastPathComponent) == (1...max(pageCount, 1)).map { String(format: "%02d.png", $0) })
        #expect(captureDates.allSatisfy { $0 != nil }, "每张图都要写入拍摄时间")
        #expect(zip(captureDates, captureDates.dropFirst()).allSatisfy { ($0 ?? "") < ($1 ?? "") }, "拍摄时间按页序递增")
        #expect(sizes.allSatisfy { $0 == "1728x2304" })
        #expect(harness.clipboard.text == Self.caption, "剪贴板是正文栏，不是卡片上的字")
        #expect(harness.pageErrors == [])
    }

    @Test("长文模式把一张长图发到 iPhone，全文的纯文本进剪贴板（长文没有正文栏）")
    func sendsArticleAsOneLongImage() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate("""
            await window.mediacraft.drafts.create({ markdown, mode: "article", caption: "长文里不用正文栏" });
            ui.click("发送到 iPhone");
        """, arguments: ["markdown": Self.markdown])
        try await waitUntil(timeout: .seconds(30)) { !harness.sender.batches.isEmpty }
        let files = harness.sender.batches.first ?? []
        let size = files.first.map(Self.pixelDimensions) ?? (width: 0, height: 0)
        let captureDate = files.first.flatMap(Self.captureDate)
        await harness.tearDown()

        #expect(files.map(\.lastPathComponent) == ["01.png"])
        #expect(size.height > size.width * 2, "40 段正文的长文应是一张很长的竖图")
        #expect(captureDate != nil)
        #expect(harness.clipboard.text == Self.expectedClipboard)
        #expect(harness.pageErrors == [])
    }

    static func pixelDimensions(_ url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    static func captureDate(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        return exif[kCGImagePropertyExifDateTimeOriginal] as? String
    }

    static func pixelSize(_ url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return "unreadable" }
        return "\(properties[kCGImagePropertyPixelWidth] ?? 0)x\(properties[kCGImagePropertyPixelHeight] ?? 0)"
    }
}
