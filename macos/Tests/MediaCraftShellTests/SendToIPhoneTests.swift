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
        do {
            try await harness.load()
            let pageCount = try await harness.evaluate("""
                await window.mediacraft.drafts.create({ markdown, caption });
                return (await window.mediacraft.render.pages()).length;
            """, arguments: ["markdown": Self.markdown, "caption": Self.caption]) as? Int ?? 0

            let files = try await Self.receivedFiles(harness)
            let captureDates = files.map(Self.captureDate)
            let sizes = files.map(Self.pixelSize)

            #expect(pageCount >= 2, "正文应足够长，排成多页")
            #expect(files.map(\.lastPathComponent) == (1...max(pageCount, 1)).map { String(format: "%02d.png", $0) })
            #expect(captureDates.allSatisfy { $0 != nil }, "每张图都要写入拍摄时间")
            #expect(zip(captureDates, captureDates.dropFirst()).allSatisfy { ($0 ?? "") < ($1 ?? "") }, "拍摄时间按页序递增")
            #expect(sizes.allSatisfy { $0 == "1728x2304" })
            #expect(harness.clipboard.text == Self.caption, "剪贴板是正文栏，不是卡片上的字")
            #expect(harness.pageErrors == [])
        } catch {
            let diagnostic = await Self.failureDiagnostics(harness)
            print("卡片发送诊断：\(diagnostic)")
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("长文模式把一张长图发到 iPhone，全文的纯文本进剪贴板（长文没有正文栏）")
    func sendsArticleAsOneLongImage() async throws {
        let harness = ShellHarness()
        do {
            try await harness.load()
            _ = try await harness.evaluate("""
                await window.mediacraft.drafts.create({ markdown, mode: "article", caption: "长文里不用正文栏" });
            """, arguments: ["markdown": Self.markdown])
            let files = try await Self.receivedFiles(harness)
            let size = files.first.map(Self.pixelDimensions) ?? (width: 0, height: 0)
            let captureDate = files.first.flatMap(Self.captureDate)

            #expect(files.map(\.lastPathComponent) == ["01.png"])
            #expect(size.height > size.width * 2, "40 段正文的长文应是一张很长的竖图")
            #expect(captureDate != nil)
            #expect(harness.clipboard.text == Self.expectedClipboard)
            #expect(harness.pageErrors == [])
        } catch {
            let diagnostic = await Self.failureDiagnostics(harness)
            print("长文发送诊断：\(diagnostic)")
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    /// Keep the real UI send and its completion in the same awaited WK call,
    /// as the export and MCP tests do; a Swift-side receiver poll does not await the page's work.
    /// The existing 120-second budget includes layout, pixels, packaging and native send.
    private static func receivedFiles(_ harness: ShellHarness) async throws -> [URL] {
        let detail = try #require(try await harness.evaluate(outputDiagnosticsScript + """
            ui.click("发送到 iPhone");
            const deadline = Date.now() + 120000;
            while (!["success", "error", "cancelled"].includes(document.querySelector("#outputActivity").dataset.state)
              && Date.now() < deadline) {
              await new Promise((resolve) => setTimeout(resolve, 50));
            }
            window.sendDiagnostic = outputSnapshot();
            return JSON.stringify(window.sendDiagnostic);
        """) as? String)
        let status = try JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: Any]
        try #require(status?["state"] as? String == "success", "120 秒内发送没有成功：\(detail)，页面错误：\(harness.pageErrors)")
        return try #require(harness.sender.batches.first, "页面报告发送成功，但原生接收端没有批次：\(detail)")
    }

    /// Read the existing progress card and rendering counters on failure.
    static let outputDiagnosticsScript = """
        const outputSnapshot = () => {
          const panel = document.querySelector("#outputActivity");
          return {
            state: panel?.dataset.state ?? "idle",
            title: panel?.querySelector(".activity-title")?.textContent ?? "",
            detail: panel?.querySelector(".activity-detail")?.textContent ?? "",
            progress: panel?.querySelector(".activity-track")?.getAttribute("aria-valuenow") ?? null,
            visibility: document.visibilityState, fonts: document.fonts.status,
            cardStats: { ...window.MediaCraftCards?.stats },
            pages: document.querySelectorAll("#stageCards .stage-card").length,
          };
        };
    """

    static func failureDiagnostics(_ harness: ShellHarness) async -> String {
        let state = (try? await harness.evaluate(outputDiagnosticsScript + """
            const snapshot = { current: outputSnapshot(), send: window.sendDiagnostic ?? null };
            return JSON.stringify(snapshot);
        """)) as? String ?? "页面没有返回诊断"
        return "\(state)，页面错误：\(harness.pageErrors)"
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
