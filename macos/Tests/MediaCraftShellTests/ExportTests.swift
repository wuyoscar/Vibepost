import Foundation
import Testing

/// 导出（存进「下载」）与发送：文件名、ZIP 里的页序、长图尺寸、进度与取消、空正文不动剪贴板。
@MainActor
@Suite(.serialized)
struct ExportTests {
    /// 页面里用 JSZip 读压缩包，按存进去的顺序列出文件（不含目录项）。
    static func zipEntries(_ harness: ShellHarness, _ url: URL) async throws -> [String] {
        let data = try Data(contentsOf: url)
        return try await harness.evaluate("""
            const zip = await JSZip.loadAsync(base64, { base64: true });
            return Object.values(zip.files).filter((file) => !file.dir).map((file) => file.name);
        """, arguments: ["base64": data.base64EncodedString()]) as? [String] ?? []
    }

    @Test("文件名以标题开头：不能用的字换成「-」；没填标题时用正文第一行")
    func filenamesFollowTheTitle() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create({ title: "  a/b\\\\c:d*e?f\\"g<h>i|j.  ", markdown: "正文" });
            const titled = (await mc.output.exportPng(0)).filename;
            await mc.drafts.create({ markdown: "# 第一行当名字\\n\\n正文" });
            const untitled = (await mc.output.exportZip()).filename;
            const again = (await mc.output.exportZip()).filename;
            return [titled, untitled, again];
        """) as? [String]
        let saved = try FileManager.default.contentsOfDirectory(atPath: harness.downloadsDirectory.path).sorted()
        await harness.tearDown()

        #expect(result == ["a-b-c-d-e-f-g-h-i-j-01.png", "第一行当名字.zip", "第一行当名字 2.zip"], "同名文件自动加序号，返回实际存下的名字")
        #expect(saved == ["a-b-c-d-e-f-g-h-i-j-01.png", "第一行当名字 2.zip", "第一行当名字.zip"])
        #expect(harness.pageErrors == [])
    }

    @Test("整组 ZIP：每页一张 PNG，按页序，文件名带标题")
    func zipKeepsPageOrder() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let pageCount = try await harness.evaluate("""
            await window.mediacraft.drafts.create({ title: "页序", markdown });
            const pages = await window.mediacraft.render.pages();
            await window.mediacraft.output.exportZip();
            return pages.length;
        """, arguments: ["markdown": SendToIPhoneTests.markdown]) as? Int ?? 0
        let entries = try await Self.zipEntries(harness, harness.downloadsDirectory.appendingPathComponent("页序.zip"))
        await harness.tearDown()

        #expect(pageCount >= 3)
        #expect(entries == (1...max(pageCount, 1)).map { String(format: "页序-%02d.png", $0) })
        #expect(harness.pageErrors == [])
    }

    @Test("含实况的整组 ZIP：实况页是完整的 .pvt（JPG、MOV、metadata.plist），其余页是 PNG，按页序")
    func zipPackagesLivePagesAsPvt() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let pageCount = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create({ title: "实况组", markdown });
            const video = await (await fetch("/macos/Tests/Fixtures/live-h264.mp4")).blob();
            await mc.media.insertLivePhoto(new File([video], "demo.mp4", { type: "video/mp4" }), { at: markdown.length, duration: 3 });
            const pages = await mc.render.pages();
            await mc.output.exportZip();
            return pages.length;
        """, arguments: ["markdown": SendToIPhoneTests.markdown]) as? Int ?? 0
        let entries = try await Self.zipEntries(harness, harness.downloadsDirectory.appendingPathComponent("实况组.zip"))
        await harness.tearDown()

        let last = String(format: "实况组-%02d", pageCount)
        #expect(pageCount >= 2)
        #expect(entries == (1..<max(pageCount, 1)).map { String(format: "实况组-%02d.png", $0) }
            + ["\(last).pvt/\(last).MOV", "\(last).pvt/\(last).JPG", "\(last).pvt/metadata.plist"])
        #expect(harness.pageErrors == [])
    }

    @Test("长图：宽 1080，正文越长图越高；单张 PNG 是 1728 × 2304")
    func longImageDimensions() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create({ title: "短", markdown: "# 短文\\n\\n一段话。" });
            await mc.output.exportLongImage();
            await mc.drafts.create({ title: "长", markdown });
            await mc.output.exportLongImage();
            await mc.drafts.update({ mode: "cards" });
            await mc.output.exportPng(0);
        """, arguments: ["markdown": SendToIPhoneTests.markdown])
        let short = SendToIPhoneTests.pixelDimensions(harness.downloadsDirectory.appendingPathComponent("短.png"))
        let long = SendToIPhoneTests.pixelDimensions(harness.downloadsDirectory.appendingPathComponent("长.png"))
        let card = SendToIPhoneTests.pixelSize(harness.downloadsDirectory.appendingPathComponent("长-01.png"))
        await harness.tearDown()

        #expect(short.width == 1080 && long.width == 1080)
        #expect(short.height > 200 && short.height < 1080, "两行字的长图不该很高：\(short.height)")
        #expect(long.height > long.width * 4, "40 段正文的长图应该很长：\(long.height)")
        #expect(card == "1728x2304")
        #expect(harness.pageErrors == [])
    }

    @Test("导出进度：进行中停用所有导出按钮、显示进度卡片，完成后提示存进「下载」并恢复按钮")
    func progressCardDuringExport() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let during = try await harness.evaluate("""
            await window.mediacraft.drafts.create({ title: "进度", markdown });
            await window.mediacraft.render.pages();
            ui.click("批量下载");
            const card = document.querySelector("#outputActivity");
            return {
              visible: String(!card.hidden),
              state: card.dataset.state,
              title: card.querySelector(".activity-title").textContent,
              zipDisabled: String(document.querySelector("#outputZipBtn").disabled),
              pageDisabled: String(document.querySelector("[data-page-export]").disabled),
              cancel: String(Boolean(ui.find("取消导出"))),
            };
        """, arguments: ["markdown": SendToIPhoneTests.markdown]) as? [String: String]
        _ = try await harness.waitForPage("document.querySelector('#outputActivity').dataset.state === 'success'")
        let after = try await harness.evaluate("""
            const card = document.querySelector("#outputActivity");
            return {
              title: card.querySelector(".activity-title").textContent,
              detail: card.querySelector(".activity-detail").textContent,
              zipDisabled: String(ui.find("批量下载").disabled),
              pageDisabled: String(ui.find("下载第 1 张").disabled),
              cancel: String(Boolean(ui.find("取消导出"))),
            };
        """) as? [String: String]
        await harness.tearDown()

        #expect(during == [
            "visible": "true", "state": "running", "title": "导出全部卡片",
            "zipDisabled": "true", "pageDisabled": "true", "cancel": "true",
        ])
        #expect(after == ["title": "已存进「下载」", "detail": "进度.zip", "zipDisabled": "false", "pageDisabled": "false", "cancel": "false"])
        #expect(harness.pageErrors == [])
    }

    @Test("取消导出：不存文件，提示已取消，接口 reject「已取消」")
    func cancelStopsExport() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create({ title: "取消", markdown });
            await mc.render.pages();
            const pending = mc.output.exportZip().then(() => "完成", (error) => error.message);
            ui.click("取消导出");
            const outcome = await pending;
            const card = document.querySelector("#outputActivity");
            return { outcome, state: card.dataset.state, title: card.querySelector(".activity-title").textContent };
        """, arguments: ["markdown": SendToIPhoneTests.markdown]) as? [String: String]
        #expect(try await harness.waitForPage("!ui.find('批量下载').disabled"), "导出彻底结束，按钮恢复")
        let saved = try FileManager.default.contentsOfDirectory(atPath: harness.downloadsDirectory.path)
        await harness.tearDown()

        #expect(result == ["outcome": "已取消", "state": "cancelled", "title": "已取消"])
        #expect(saved == [])
        #expect(harness.pageErrors == [])
    }

    @Test("正文栏空着时发送到 iPhone：不拦发送（没有别的提醒就不弹确认），照常发出，剪贴板不动，提示卡说明")
    func sendWithoutTextLeavesClipboard() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create();
            const canvas = document.createElement("canvas");
            canvas.width = 600;
            canvas.height = 400;
            canvas.getContext("2d").fillRect(0, 0, 600, 400);
            const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
            await mc.media.import([new File([blob], "only.png", { type: "image/png" })], { at: 0 });
            ui.click("发送到 iPhone");
        """)
        try await waitUntil(timeout: .seconds(20)) { !harness.sender.batches.isEmpty }
        let names = harness.sender.batches.first?.map(\.lastPathComponent) ?? []
        _ = try await harness.waitForPage("document.querySelector('#outputActivity').dataset.state === 'success'")
        let detail = try await harness.evaluate("return document.querySelector('#outputActivity .activity-detail').textContent") as? String
        let asked = try await harness.evaluate("return !document.querySelector('#sendCheckDialog').classList.contains('hidden')") as? Bool
        await harness.tearDown()

        #expect(asked == false, "只有「正文还没写」时不弹发送前的确认")
        #expect(names == ["01.png"])
        #expect(harness.clipboard.text == nil)
        #expect(detail == "正文栏还空着，剪贴板没动", "没有正文时不提示「正文已复制」")
        #expect(harness.pageErrors == [])
    }
}
