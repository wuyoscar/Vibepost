import AppKit
import Foundation
import Testing

@MainActor
struct DropFilesTests {
    static let setup = """
        const mc = window.mediacraft;
        await mc.drafts.create({ markdown: "# 标题\\n\\n第一段\\n\\n第二段" });
        const [firstPage] = await mc.render.canvases();
        window.makePng = (color) => new Promise((resolve) => {
          const canvas = document.createElement("canvas");
          canvas.width = canvas.height = 8;
          const context = canvas.getContext("2d");
          context.fillStyle = color;
          context.fillRect(0, 0, 8, 8);
          canvas.toBlob(resolve, "image/png");
        });
        // 从 Finder 拖到预览第一页的顶部或底部松手
        window.dropOnPreview = (files, edge) => {
          const transfer = new DataTransfer();
          files.forEach((file) => transfer.items.add(file));
          const rect = firstPage.getBoundingClientRect();
          const clientY = edge === "top" ? rect.top + 4 : rect.bottom - 4;
          firstPage.dispatchEvent(new DragEvent("drop", {
            bubbles: true, cancelable: true, dataTransfer: transfer, clientX: rect.left + rect.width / 2, clientY,
          }));
        };
        window.markdown = async () => (await window.mediacraft.drafts.current()).markdown;
        window.imageTagsInOrder = async () => [...(await markdown()).matchAll(/\\[\\[(?:图片|image)[:：]([^\\]|]+)\\]\\]/g)].map((match) => match[1]);
        window.imageNames = async () => Promise.all((await imageTagsInOrder()).map(async (id) => (await window.mediacraft.media.get(id)).name));
    """

    @Test("图片拖到预览底部：按文件名顺序插在最后一段之后")
    func dropImagesAtBottomOfPreview() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(Self.setup + """
            dropOnPreview([
              new File([await makePng("#ff0000")], "b.png", { type: "image/png" }),
              new File([await makePng("#0000ff")], "a.png", { type: "image/png" }),
            ], "bottom");
        """)
        let inserted = try await harness.waitForPage("(await imageTagsInOrder()).length === 2")
        let result = try await harness.evaluate("""
            const text = await markdown();
            return {
              names: await imageNames(),
              afterLastParagraph: text.indexOf("[[图片:") > text.indexOf("第二段"),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(inserted)
        #expect(result?["names"] as? [String] == ["a.png", "b.png"])
        #expect(result?["afterLastParagraph"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("图片拖到预览顶部：插在正文最前面")
    func dropImageAtTopOfPreview() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(Self.setup + """
            dropOnPreview([new File([await makePng("#ff0000")], "top.png", { type: "image/png" })], "top");
        """)
        let inserted = try await harness.waitForPage("(await imageTagsInOrder()).length === 1")
        let beforeText = try await harness.evaluate(
            "const text = await markdown(); return text.indexOf('[[图片:') < text.indexOf('第一段')"
        ) as? Bool
        await harness.tearDown()

        #expect(inserted)
        #expect(beforeText == true)
        #expect(harness.pageErrors == [])
    }

    @Test("图片拖进编辑区插在松手的那一行后面；粘贴图片插在光标处")
    func dropAndPasteImagesIntoEditor() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(Self.setup + """
            const body = document.querySelector('[role="textbox"][aria-label="正文"]');
            const line = [...body.children].find((element) => element.textContent === "第一段");
            const rect = line.getBoundingClientRect();
            const transfer = new DataTransfer();
            transfer.items.add(new File([await makePng("#ff0000")], "拖.png", { type: "image/png" }));
            body.dispatchEvent(new DragEvent("drop", {
              bubbles: true, cancelable: true, dataTransfer: transfer, clientX: rect.right - 2, clientY: rect.top + rect.height / 2,
            }));
        """)
        let dropped = try await harness.waitForPage("(await imageTagsInOrder()).length === 1")
        _ = try await harness.evaluate("""
            const text = await markdown();
            await window.mediacraft.editor.select(text.indexOf("第二段") + 3);
            const body = document.querySelector('[role="textbox"][aria-label="正文"]');
            const clipboard = new DataTransfer();
            clipboard.items.add(new File([await makePng("#0000ff")], "贴.png", { type: "image/png" }));
            body.dispatchEvent(new ClipboardEvent("paste", { clipboardData: clipboard, bubbles: true, cancelable: true }));
        """)
        let pasted = try await harness.waitForPage("(await imageTagsInOrder()).length === 2")
        let result = try await harness.evaluate("""
            return { names: await imageNames(), shape: (await markdown()).replace(/\\[\\[(?:图片|image):[^\\]]+\\]\\]/g, "[[图]]") };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(dropped && pasted)
        #expect(result?["names"] as? [String] == ["拖.png", "贴.png"])
        #expect(result?["shape"] as? String == "# 标题\n\n第一段\n[[图]]\n\n第二段\n[[图]]\n")
        #expect(harness.pageErrors == [])
    }

    @Test("PDF 拖进来：每页变成一张图，按页序插入")
    func dropPdfBecomesOneImagePerPage() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(Self.setup + """
            const bytes = Uint8Array.from(atob(pdf), (char) => char.charCodeAt(0));
            dropOnPreview([new File([bytes], "讲义.pdf", { type: "application/pdf" })], "bottom");
        """, arguments: ["pdf": Self.twoPagePdf(colors: [.red, .blue]).base64EncodedString()])
        let inserted = try await harness.waitForPage("(await imageTagsInOrder()).length === 2")
        let result = try await harness.evaluate("""
            const centerColor = (src) => new Promise((resolve) => {
              const image = new Image();
              image.onload = () => {
                const canvas = document.createElement("canvas");
                canvas.width = image.naturalWidth;
                canvas.height = image.naturalHeight;
                const context = canvas.getContext("2d");
                context.drawImage(image, 0, 0);
                const [r, g, b] = context.getImageData(canvas.width / 2, canvas.height / 2, 1, 1).data;
                resolve(r > 200 && b < 80 ? "red" : b > 200 && r < 80 ? "blue" : `${r},${g},${b}`);
              };
              image.src = src;
            });
            const ids = await imageTagsInOrder();
            return {
              names: await imageNames(),
              colors: await Promise.all(ids.map(async (id) => centerColor(await window.mediacraft.media.src(id)))),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(inserted)
        #expect(result?["names"] as? [String] == ["讲义-第1页.png", "讲义-第2页.png"])
        #expect(result?["colors"] as? [String] == ["red", "blue"])
        #expect(harness.pageErrors == [])
    }

    static func twoPagePdf(colors: [NSColor]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for color in colors {
            context.beginPDFPage(nil)
            context.setFillColor(color.cgColor)
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
