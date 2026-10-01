import Foundation
import Testing

/// HTML 卡片（ADR 0006）：舞台、render.pages() 的页面结果、导出都走 HTML 卡片。
@MainActor
@Suite(.serialized)
struct HtmlEngineTests {
    static func harness() async throws -> ShellHarness {
        let harness = ShellHarness()
        try await harness.load()
        return harness
    }

    @Test("说明书用 HTML 卡片排：页面结果带图片点选框、落点、逐行文字与字数，舞台上是这套卡片，导出 1728 × 2304")
    func guideRendersThroughHtmlCards() async throws {
        let harness = try await Self.harness()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            const guide = (await mc.drafts.list()).find((item) => item.builtIn && item.mode === "cards");
            await mc.drafts.open(guide.id);
            const pages = await mc.render.pages();
            const canvases = await mc.render.canvases();
            const stage = document.querySelectorAll("#stageCards .card-frame > .mc-card-host").length;
            const exported = (await mc.output.exportPng(0)).filename;
            const texts = pages.flatMap((page) => page.items).filter((item) => item.kind === "text");
            return {
              pages: pages.length,
              canvases: canvases.length,
              stage,
              structure: pages[0].structure,
              width: canvases[0].width,
              height: canvases[0].height,
              hits: pages.flatMap((page) => page.imageHits).length,
              drops: pages.every((page) => page.dropTargets.length > 0),
              chars: pages.map((page) => page.chars),
              fill: pages.every((page) => page.fill > 0 && page.fill <= 1),
              lines: texts.length,
              firstLine: texts[0]?.text,
              exported,
            };
        """) as? [String: Any]
        let saved = try FileManager.default.contentsOfDirectory(atPath: harness.downloadsDirectory.path)
        await harness.tearDown()

        let pages = result?["pages"] as? Int ?? 0
        #expect(pages >= 5)
        #expect(result?["canvases"] as? Int == pages && result?["stage"] as? Int == pages, "舞台上每页一张 HTML 卡片")
        #expect(result?["width"] as? Int == 1728 && result?["height"] as? Int == 2304)
        #expect(result?["structure"] as? String == "notes", "说明书用默认主题")
        #expect((result?["hits"] as? Int ?? 0) >= 1, "说明书里的图有点选框")
        #expect(result?["drops"] as? Bool == true)
        #expect((result?["chars"] as? [Int] ?? []).allSatisfy { $0 > 0 })
        #expect(result?["fill"] as? Bool == true)
        #expect((result?["lines"] as? Int ?? 0) > pages * 3, "文字逐行给")
        #expect(result?["firstLine"] as? String == "图文卡片说明书")
        #expect(saved.contains(result?["exported"] as? String ?? "-"))
        #expect(harness.pageErrors == [])
    }

    @Test("这一篇的卡片样式：用在卡片上（关在 Shadow DOM 里，不影响界面）、过滤 @import 与外部图片、可以撤销、换稿子不带过去；检查器里改了存进稿子")
    func cardCssAppliesToThisDraft() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create({ markdown: "一段正文" });
            const color = () => {
              const card = document.querySelector("#stageCards .mc-card-host");
              return card ? getComputedStyle(card.shadowRoot.querySelector(".mc-body p")).color : null;
            };
            const before = color();
            await mc.drafts.update({ cardCss: "@import url(https://example.invalid/x.css);\\n.mc-body p { color: rgb(200, 10, 20); background: url(https://example.invalid/a.png); }" }, { undoable: true });
            await mc.render.pages();
            const styled = color();
            const appColor = getComputedStyle(document.querySelector(".section-label")).color;
            const cleaned = window.MediaCraftCards.cleanCss((await mc.drafts.current()).cardCss);
            await mc.drafts.undo();
            await mc.render.pages();
            const undone = [(await mc.drafts.current()).cardCss, color()];
            await mc.drafts.update({ cardCss: ".mc-body p { color: rgb(1, 2, 3); }" });
            await mc.drafts.create({ markdown: "另一篇" });
            await mc.render.pages();
            const other = [(await mc.drafts.current()).cardCss, color()];
            ui.expand("高级 · 卡片样式");
            const input = document.querySelector("#cardCssInput");
            input.value = ".mc-body p { color: rgb(9, 9, 9); }";
            input.dispatchEvent(new Event("input"));
            await new Promise((resolve) => setTimeout(resolve, 700));
            await mc.render.pages();
            return { before, styled, appColor, cleaned, undone, other, typed: [(await mc.drafts.current()).cardCss, color()] };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["styled"] as? String == "rgb(200, 10, 20)")
        #expect(result?["appColor"] as? String != "rgb(200, 10, 20)", "关在卡片里，不影响界面")
        let cleaned = result?["cleaned"] as? String ?? ""
        #expect(!cleaned.contains("@import") && !cleaned.contains("example.invalid"), "去掉 @import 与外部地址：\(cleaned)")
        #expect((result?["undone"] as? [Any])?.first as? String == "")
        #expect((result?["undone"] as? [Any])?.last as? String == result?["before"] as? String, "撤销后回到原来的样子")
        #expect((result?["other"] as? [Any])?.first as? String == "", "新稿子没有上一篇的样式")
        #expect((result?["typed"] as? [Any])?.first as? String == ".mc-body p { color: rgb(9, 9, 9); }")
        #expect((result?["typed"] as? [Any])?.last as? String == "rgb(9, 9, 9)")
        #expect(harness.pageErrors == [])
    }
}
