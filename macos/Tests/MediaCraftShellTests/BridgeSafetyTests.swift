import Foundation
import Testing

@MainActor
struct BridgeSafetyTests {
    @Test("暂存时拒绝不合规的文件名，而不是等到发送才失败")
    func stageRejectsInvalidNames() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let statuses = try await harness.evaluate("""
            const batch = crypto.randomUUID();
            const post = async (name) => (await fetch(`/__native/stage?batch=${batch}&name=${encodeURIComponent(name)}`, {
              method: "POST", headers: { "X-MediaCraft-Bridge": "1" }, body: new Uint8Array([1, 2, 3]),
            })).status;
            return [await post("01.png"), await post("02.pvt"), await post("../03.png"), await post("04.pvt/../../x"), await post("05.txt")];
        """) as? [Int]
        await harness.tearDown()
        #expect(statuses == [200, 500, 500, 500, 500])
    }

    @Test("网页根目录里指向外部的 symlink 读不到")
    func schemeHandlerDoesNotFollowSymlinksOutsideRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-root-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-secret-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "<!doctype html><title>t</title>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let harness = ShellHarness(webRoot: root)
        try await harness.load()
        let status = try await harness.evaluate("return (await fetch('/link.txt')).status") as? Int
        await harness.tearDown()
        #expect(status == 404)
    }

    @Test("正文为空时发送不改动剪贴板")
    func emptyTextLeavesClipboardUntouched() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate("""
            const png = await new Promise((resolve) => {
              const canvas = document.createElement("canvas");
              canvas.width = canvas.height = 4;
              canvas.toBlob(resolve, "image/png");
            });
            await window.MediaCraftNative.sendToIPhone([{ blob: png, name: "01.png" }], "");
        """)
        await harness.tearDown()
        #expect(harness.sender.batches.count == 1)
        #expect(harness.clipboard.text == nil)
    }

    @Test("原生桥只接页面自己发的调用：GET、不带请求头的 POST、卡片样式里换着法子写的地址都碰不到原生能力")
    func bridgeRejectsForeignRequests() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            const statuses = [
              (await fetch("/__native/window/open")).status,
              (await fetch("/__native/window/open", { method: "POST", body: new ArrayBuffer(0) })).status,
            ];
            const image = await new Promise((resolve) => {
              const img = new Image();
              img.onload = () => resolve("loaded");
              img.onerror = () => resolve("blocked");
              img.src = "/__native/window/open?img";
            });
            // 卡片样式里的地址：CSS 转义、自定义属性、image-set()、@font-face，过滤之后一个都不剩；颜色与 data: 图片照常
            const sneaky = [
              ".mc-page { background-image: u\\\\72l(/__native/window/open?css); }",
              ".mc-page { --x: \\\\75 rl(/__native/window/open?var); background-image: var(--x); }",
              ".mc-page { background-image: image-set(\\"/__native/window/open?set\\" 1x); }",
              "@font-face { font-family: x; src: url(/__native/window/open?font); }",
              ".mc-page { color: rgb(1, 2, 3); background-image: url(data:image/png;base64,AAAA); }",
            ];
            const cleaned = sneaky.map((css) => window.MediaCraftCards.cleanCss(css));
            await mc.drafts.create({ markdown: "一段正文", cardCss: sneaky.join("\\n") });
            await mc.render.pages();
            await new Promise((resolve) => setTimeout(resolve, 500));
            return { statuses, image, cleaned };
        """) as? [String: Any]
        // 真有窗口要开的话，这时也该开出来了
        try await Task.sleep(for: .milliseconds(500))
        let windows = harness.windows.count
        await harness.tearDown()

        #expect(result?["statuses"] as? [Int] == [403, 403])
        #expect(result?["image"] as? String == "blocked")
        let cleaned = result?["cleaned"] as? [String] ?? []
        #expect(cleaned.count == 5)
        for css in cleaned.prefix(4) {
            #expect(!css.contains("__native") && !css.contains("image-set"), "\(css)")
        }
        #expect(cleaned.last?.contains("rgb(1, 2, 3)") == true && cleaned.last?.contains("data:image/png") == true, "\(cleaned.last ?? "")")
        #expect(windows == 0, "没有因为这些请求开出新窗口")
        #expect(harness.pageErrors == [])
    }

    @Test("外链只交出去网页与邮件地址，而且要是点出来的：file:、别的 App 的地址、页面自己的跳转都不开")
    func onlyClickedWebLinksOpenExternally() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate("""
            const pause = () => new Promise((resolve) => setTimeout(resolve, 150));
            for (const href of ["https://example.com/a", "mailto:someone@example.com", "file:///tmp/x.command", "x-apple.systempreferences:com.apple.preference.security"]) {
              const link = document.createElement("a");
              link.href = href;
              document.body.append(link);
              link.click();
              link.remove();
              await pause();
            }
            location.href = "https://example.com/b";
            await pause();
        """)
        let opened = harness.openedExternally.map(\.absoluteString)
        let stayed = try await harness.evaluate("return location.protocol") as? String
        await harness.tearDown()

        #expect(opened == ["https://example.com/a", "mailto:someone@example.com"])
        #expect(stayed == "mediacraft:", "页面没有被带走")
        #expect(harness.pageErrors == [])
    }
}
