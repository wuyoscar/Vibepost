import Foundation
import Testing

@MainActor
struct PublishHelpersTests {
    /// 像用户一样在标题框里输入（改值后派发 input 事件）；正文通过 App API 写入。
    static let typing = """
        window.titleInput = () => ui.find("标题");
        window.typeTitle = (text) => {
          const input = titleInput();
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        };
        window.typeBody = (text) => window.mediacraft.drafts.update({ markdown: text });
        window.typeCaption = (text) => {
          const input = ui.find("图片下面的正文");
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        };
    """

    /// [标题计数, 标题是否标红, 正文计数, 正文是否标红]
    static let readCounts = """
        const title = document.querySelector("#titleCount");
        const body = document.querySelector("#bodyCount");
        return [
          title.textContent, String(title.classList.contains("is-over")),
          body.textContent, String(body.classList.contains("is-over")),
        ];
    """

    @Test("每篇稿子有自己的标题：切换稿子、重新打开后仍在，稿件列表也显示它")
    func titleIsSavedWithEachDraft() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let switched = try await harness.evaluate(Self.typing + """
            const mc = window.mediacraft;
            await mc.drafts.create();
            await typeBody("第一篇的正文");
            typeTitle("第一篇的标题");
            const { id: firstId } = await mc.drafts.current();
            await mc.drafts.create();
            const secondTitle = titleInput().value;
            await mc.drafts.open(firstId);
            return { secondTitle, firstTitle: titleInput().value };
        """) as? [String: String]
        _ = try await harness.evaluate(Self.typing + StorageScripts.read + """
            typeTitle('改过的标题');
            window.storedTitle = async () => (await readStore("drafts", (await window.mediacraft.drafts.current()).id))?.title;
        """)
        let saved = try await harness.waitForPage("(await storedTitle()) === '改过的标题'", timeout: .seconds(5))
        try await harness.load()
        let reopened = try await harness.evaluate("""
            ui.expand("稿件列表");
            return {
              title: ui.find("标题").value,
              history: (await window.mediacraft.drafts.list()).find((draft) => draft.current)?.title ?? "",
              historyShown: String(Boolean(ui.find("改过的标题", { within: "稿件" }))),
            };
        """) as? [String: String]
        await harness.tearDown()

        #expect(switched?["secondTitle"] == "")
        #expect(switched?["firstTitle"] == "第一篇的标题")
        #expect(saved, "只改标题也要自动保存")
        #expect(reopened?["title"] == "改过的标题")
        #expect(reopened?["history"] == "改过的标题")
        #expect(reopened?["historyShown"] == "true", "稿件列表里显示这个标题")
        #expect(harness.pageErrors == [])
    }

    @Test("标题与正文实时计数：正文数的是正文栏（不是卡片上的字），超出 20 / 1000 字时标红")
    func countsFollowXiaohongshuLimits() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(Self.typing + """
            await window.mediacraft.drafts.create();
            typeTitle("一二三四五六七八九十一二三四五六七八九十");
            await typeBody("字".repeat(1200));
            typeCaption("去了 公园\\n\\n#散步 👍");
        """)
        let within = try await harness.evaluate(Self.readCounts) as? [String]
        _ = try await harness.evaluate(Self.typing + """
            typeTitle(titleInput().value + "多");
            typeCaption("字".repeat(1001));
        """)
        let over = try await harness.evaluate(Self.readCounts) as? [String]
        await harness.tearDown()

        // 空白不计，emoji 这类增补平面字符算 2 个字；卡片上的 1200 字不算。
        #expect(within == ["20/20", "false", "9/1000", "false"])
        #expect(over == ["21/20", "true", "1001/1000", "true"])
        #expect(harness.pageErrors == [])
    }

    @Test("批量、单张、长图下载的文件名都带标题，文件名里不能用的字符被替换")
    func downloadsAreNamedAfterTheTitle() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(Self.typing + """
            await window.mediacraft.drafts.create({ markdown });
            typeTitle("发布/测试:第1篇?");
            ui.click("批量下载");
        """, arguments: ["markdown": SendToIPhoneTests.markdown])
        // 导出进行中下载按钮是禁用的，等它恢复再点下一个
        let idle = "ui.find('下载第 1 张') && !ui.find('下载第 1 张').disabled"
        let zip = harness.downloadsDirectory.appendingPathComponent("发布-测试-第1篇.zip")
        try await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: zip.path) }
        _ = try await harness.waitForPage(idle)

        _ = try await harness.evaluate("ui.click('下载第 1 张')")
        let page = harness.downloadsDirectory.appendingPathComponent("发布-测试-第1篇-01.png")
        try await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: page.path) }
        _ = try await harness.waitForPage(idle)

        _ = try await harness.evaluate("ui.click('长文', { within: '排版模式' })")
        _ = try await harness.waitForPage("ui.find('下载长图') && !ui.find('下载长图').disabled && (await window.mediacraft.drafts.current()).mode === 'article'")
        _ = try await harness.evaluate("ui.click('下载长图')")
        let article = harness.downloadsDirectory.appendingPathComponent("发布-测试-第1篇.png")
        try await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: article.path) }

        let saved = try FileManager.default.contentsOfDirectory(atPath: harness.downloadsDirectory.path).sorted()
        let zipText = String(decoding: (try? Data(contentsOf: zip)) ?? Data(), as: UTF8.self)
        await harness.tearDown()

        #expect(saved == ["发布-测试-第1篇-01.png", "发布-测试-第1篇.png", "发布-测试-第1篇.zip"])
        #expect(zipText.contains("发布-测试-第1篇-01.png"), "压缩包里的每一页也带标题")
        #expect(harness.pageErrors == [])
    }

    @Test("有标题时，发送到 iPhone 仍按 01.png 页序命名，剪贴板仍只放正文栏里的正文")
    func sendToIPhoneKeepsPageOrderNames() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let pageCount = try await harness.evaluate(Self.typing + """
            await window.mediacraft.drafts.create({ markdown, caption });
            typeTitle("发布/测试:第1篇?");
            const pages = await window.mediacraft.render.pages();
            ui.click("发送到 iPhone");
            return pages.length;
        """, arguments: ["markdown": SendToIPhoneTests.markdown, "caption": SendToIPhoneTests.caption]) as? Int ?? 0
        try await waitUntil(timeout: .seconds(20)) { !harness.sender.batches.isEmpty }
        let names = harness.sender.batches.first?.map(\.lastPathComponent) ?? []
        await harness.tearDown()

        #expect(pageCount >= 2)
        #expect(names == (1...max(pageCount, 1)).map { String(format: "%02d.png", $0) })
        #expect(harness.clipboard.text == SendToIPhoneTests.caption)
        #expect(harness.pageErrors == [])
    }
}
