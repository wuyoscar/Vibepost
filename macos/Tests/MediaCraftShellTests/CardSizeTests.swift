import Foundation
import Testing

@MainActor
struct CardSizeTests {
    @Test("尺寸随稿保存；文档排版比默认容纳更多文字，长页预览与原生 PNG 一致")
    func documentAndTallCards() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create();
            const paragraph = '写作时需要先讲清问题，再提供具体的事实和例子。读者可以沿着段落理解事情的经过，也能看出作者为什么得出这个判断。';
            const markdown = '# 一页里的完整说明\\n\\n' + Array.from({length: 8}, () => paragraph).join('\\n\\n');
            await mc.drafts.update({markdown, fontSize: 34, lineHeight: 1.85});
            await mc.render.pages();
            const before = (await mc.render.pages()).length;
            await mc.drafts.update({cardHeight: 1222, fontSize: 22, lineHeight: 1.55});
            await mc.render.pages();
            const dense = await mc.render.pages();
            const densePng = (await mc.render.canvases())[0].toDataURL("image/png").split(",")[1];
            const id = (await mc.drafts.current()).id;
            await mc.drafts.create();
            await mc.drafts.open(id);
            const restored = await mc.drafts.current();
            await mc.drafts.update({cardHeight: 1728});
            await mc.render.pages();
            const pages = await mc.render.pages();
            const canvases = await mc.render.canvases();
            const frame = document.querySelector('.card-frame');
            const page = frame.querySelector('.mc-card-host').shadowRoot.querySelector('.mc-page');
            return {densePng, before, dense: dense.length, noOverflow: [...dense,...pages].every(p => !p.overflow),
              restored: [restored.cardHeight,restored.fontSize], height: pages[0].height,
              png: [canvases[0].width,canvases[0].height], cssHeight: page.offsetHeight,
              ratio: frame.clientHeight/frame.clientWidth,
              text: pages.flatMap(p => p.items.filter(i => i.kind === 'text').map(i => i.text)).join('')};
        """) as? [String: Any]
        try await harness.screenshot("card-size-controls", of: "[aria-labelledby=layoutLabel]")
        CardRasterTests.keep(result?["densePng"] as? String ?? "", as: "document-layout.png")
        print("Card density: default=\(result?["before"] ?? "?"), document=\(result?["dense"] ?? "?")")
        await harness.tearDown()
        #expect((result?["dense"] as? Int ?? 100) < (result?["before"] as? Int ?? 0))
        #expect(result?["noOverflow"] as? Bool == true)
        #expect(result?["restored"] as? [Int] == [1222,22])
        #expect(result?["height"] as? Int == 1728)
        #expect(result?["png"] as? [Int] == [1728,3456])
        #expect(result?["cssHeight"] as? Int == 1728)
        #expect(abs((result?["ratio"] as? Double ?? 0) - 2) < 0.02)
        let text = result?["text"] as? String ?? ""
        #expect(text.components(separatedBy: "这个判断").count - 1 == 8)
        #expect(harness.pageErrors == [])
    }

    @Test("四种尺寸的原生导出、图片点选框和分页符；密度按钮与模板保留设置")
    func sizeControlsAndImages() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(PaginationTests.setup + """
            const id = (await mc.media.import([await pngFile('photo.png', 400, 200)]))[0];
            await mc.drafts.update({markdown: `第一段\\n\\n[[image:${id}]]\\n\\n[[分页]]\\n\\n第二段`});
            document.querySelector('[data-density="document"]').click();
            await new Promise(resolve => setTimeout(resolve, 100));
            const density = await mc.drafts.current();
            const sizes = [];
            for (const height of [1152,1222,1536,1728]) {
              const select = document.querySelector('#cardHeightInput');
              select.value = String(height);
              select.dispatchEvent(new Event('input', {bubbles: true}));
              const pages = await mc.render.pages();
              const canvas = (await mc.render.canvases())[0];
              const frame = document.querySelector('.card-frame');
              const box = frame.querySelector('.stage-media-layer button');
              const hit = pages[0].imageHits[0];
              const parent = frame.getBoundingClientRect(), rect = box.getBoundingClientRect();
              sizes.push({height: pages[0].height, png: canvas.height, count: pages.length,
                aligned: Math.abs((rect.top-parent.top)/parent.height - hit.y/height) < 0.005,
                complete: !pages.some(p => p.overflow)});
            }
            const format = window.MediaCraftTemplateFormat;
            const current = await mc.drafts.current();
            const parsed = format.entry('尺寸测试.md', format.compose({...current,name:'尺寸测试'}));
            return {sizes, density:[density.fontSize,density.lineHeight], templateHeight:parsed.cardHeight};
        """) as? [String: Any]
        await harness.tearDown()
        #expect(result?["density"] as? [Double] == [22,1.55])
        #expect(result?["templateHeight"] as? Int == 1728)
        let sizes = result?["sizes"] as? [[String: Any]] ?? []
        #expect(sizes.count == 4)
        for size in sizes {
            #expect(size["png"] as? Int == (size["height"] as? Int ?? 0) * 2)
            #expect(size["count"] as? Int == 2)
            #expect(size["aligned"] as? Bool == true)
            #expect(size["complete"] as? Bool == true)
        }
        #expect(harness.pageErrors == [])
    }
}
