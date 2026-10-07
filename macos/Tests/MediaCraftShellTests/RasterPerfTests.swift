import Foundation
import Testing

/// 大图稿子的出图代价（2026-10-08 用户现场：十来张 2000×1800 的截图，审阅时每次决定几秒、常驻几百 MB）：
/// 改一个字只重出变了的页；图片只过一次桥（出图的宿主页按编号留着）；缩略图不经整页画布；
/// 加减一页只重截各页的页码条（正文 PNG 按占位页码截，键不随页数变）。计数在 MediaCraftCards.stats。
@MainActor
struct RasterPerfTests {
    @Test("六张 2000×1800 的稿子：改一个字只重出那一页、图片不再过桥、不新建整页画布；加一页只重出新页、只重截各页的页码条")
    func editsOnlyRerenderChangedPages() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            const cards = window.MediaCraftCards;
            const png = (w, h, hue) => new Promise((resolve) => {
              const c = Object.assign(document.createElement("canvas"), { width: w, height: h });
              const g = c.getContext("2d");
              g.fillStyle = `hsl(${hue} 60% 40%)`;
              g.fillRect(0, 0, w, h);
              g.fillStyle = "#fff";
              g.font = "160px sans-serif";
              g.fillText(String(hue), 80, 300);
              c.toBlob(resolve, "image/png");
            });
            // 「样式」标签可见时主题面板会在停手后把 12 个主题的首页各出一遍（那是它自己的开销）：切到 AI 助手，只量舞台这条链
            ui.click("AI 助手");
            await mc.drafts.create({ markdown: "# 大图稿子\\n\\n开头一段。\\n\\n[[分页]]\\n\\n", theme: "press" });
            for (let i = 0; i < 6; i += 1) {
              const md = (await mc.drafts.current()).markdown;
              await mc.editor.select(md.length);
              await mc.media.import([new File([await png(2000, 1800, i * 50)], `shot-${i}.png`, { type: "image/png" })]);
              const after = (await mc.drafts.current()).markdown;
              await mc.drafts.update({ markdown: after.replace(/\\n*$/, "") + `\\n\\n**第 ${i + 1} 张**：这是一张截图的说明。\\n\\n[[分页]]\\n\\n` });
            }
            const pages = await mc.render.pages();
            await mc.render.thumbnails({ width: 120, height: 160 });
            await mc.drafts.saveNow();
            const stored = await window.MediaCraftDrafts.store.readDraft((await mc.drafts.current()).id);
            const sizesKnown = Object.values(stored.images).every((image) => image.width === 2000 && image.height === 1800);
            cards.resetStats();
            // 改第二页的一个字
            await mc.drafts.update({ markdown: (await mc.drafts.current()).markdown.replace("第 1 张**：这是", "第 1 张**：这是（改）") });
            const started = performance.now();
            await mc.render.pages();
            await mc.render.thumbnails({ width: 120, height: 160 });
            const editMs = performance.now() - started;
            const afterEdit = { ...cards.stats };
            cards.resetStats();
            // 末尾加一页：总页数变了，每页页脚的「共 N 页」都要重截，正文 PNG 不动
            await mc.drafts.update({ markdown: (await mc.drafts.current()).markdown.replace(/\\n*$/, "") + "\\n\\n新加的一页。" });
            await mc.render.pages();
            await mc.render.thumbnails({ width: 120, height: 160 });
            const afterAdd = { ...cards.stats };
            const pagesAfter = await mc.render.pages();
            return { pages: pages.length, pagesAfter: pagesAfter.length, sizesKnown, editMs, afterEdit, afterAdd };
        """) as? [String: Any]
        await harness.tearDown()

        let edit = result?["afterEdit"] as? [String: Any] ?? [:]
        let add = result?["afterAdd"] as? [String: Any] ?? [:]
        let pages = result?["pages"] as? Int ?? 0
        #expect(pages >= 7, "六张图各一页加开头一页：\(pages)")
        #expect(result?["sizesKnown"] as? Bool == true, "导入时记下了尺寸")
        #expect((edit["rasterized"] as? Int ?? 99) <= 1, "改一个字只重出那一页：\(edit)")
        #expect(edit["bridgedImageBytes"] as? Int == 0, "图片不再过桥：\(edit)")
        #expect(edit["fullPaints"] as? Int == 0, "缩略图不经整页画布：\(edit)")
        #expect((edit["thumbs"] as? Int ?? 99) <= 2, "只重做那一页的缩略图（胶片一份、这里要的一份）：\(edit)")
        #expect((result?["editMs"] as? Double ?? 99999) < 6000, "改一个字到缩略图更新：\(result?["editMs"] ?? 0) ms")
        #expect((add["rasterized"] as? Int ?? 99) <= 1, "加一页只重出新页：\(add)")
        #expect(add["bridgedImageBytes"] as? Int == 0, "加一页图片也不过桥：\(add)")
        let pagesAfter = result?["pagesAfter"] as? Int ?? 0
        #expect(pagesAfter == pages + 1 && (add["strips"] as? Int ?? 0) >= pagesAfter - 1, "页数变了：各页的页码条重截（\(add["strips"] ?? 0) / \(pagesAfter)）")
        #expect(harness.pageErrors == [], "\(harness.pageErrors)")
    }
}
