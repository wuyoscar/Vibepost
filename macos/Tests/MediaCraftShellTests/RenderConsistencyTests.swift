import Testing

@MainActor
struct RenderConsistencyTests {
    @Test("连续触发渲染时，先等的那一次也拿到最新画面，不会读到旧卡片")
    func awaitingSupersededRenderYieldsLatestCanvases() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create({ markdown: "# 短稿\\n\\n一段" });
            const before = (await mc.render.pages()).length;
            // 先出一次图，没画完就改稿（改稿会再出一次图，取代前一次）
            const first = mc.render.refresh();
            const second = mc.drafts.update({
              markdown: "# 长稿\\n\\n" + Array.from({ length: 40 }, (_, i) => `第${i + 1}段：写给测试的一段足够长的正文，用来撑出好几页卡片。`).join("\\n\\n"),
            });
            const afterFirst = (await first).length;
            await second;
            const afterSecond = (await mc.render.pages()).length;
            return { before, afterFirst, afterSecond };
        """) as? [String: Int]
        await harness.tearDown()

        #expect(result?["before"] == 1)
        #expect((result?["afterSecond"] ?? 0) > 1)
        #expect(result?["afterFirst"] == result?["afterSecond"], "被取代的渲染应等最新一次完成再返回")
        #expect(harness.pageErrors == [])
    }

    /// 备忘录（sage）的头像居中在署名前面，位置随名字在英文字体里的宽度变，常落在非整数像素上。
    /// 同样的稿子与设置，不管之前画过什么（头像在别的位置、别的主题），画出来都得一模一样。
    /// 出错时（在卡片画布上直接缩放 <img>）不是每个页面都会抖，所以连开几个新页面各来回换一阵。
    @Test("同一篇、同样的设置，出图像素与之前画过什么无关：来回换主题与英文字体，头像挪来挪去，每种设置每次都一样")
    func samePixelsRegardlessOfWhatWasDrawnBefore() async throws {
        try BundledFontsTests.requireBundledFonts()
        for page in 1...3 {
            let harness = ShellHarness()
            try await harness.load()
            let result = try await harness.evaluate(BundledFontsTests.helpers + """
                const mc = window.mediacraft;
                await mc.drafts.create({ markdown: "# 头像\\n\\n署名居中的卡片：名字变宽，头像跟着挪。" });
                const seen = {};
                const record = async (key) => {
                  seen[key] = [...new Set([...(seen[key] || []), await cardHashes()])];
                };
                for (let round = 0; round < 25; round += 1) {
                  for (const theme of ["editorial", "notes"]) {
                    await mc.themes.apply(theme);
                    await record(`${theme} 跟随主题`);
                    await mc.drafts.update({ fonts: { en: "ibm-plex-sans" } });
                    await record(`${theme} IBM Plex Sans`);
                    await mc.drafts.update({ fonts: { en: "theme" } });
                    await record(`${theme} 跟随主题`);
                  }
                }
                return Object.fromEntries(Object.entries(seen).map(([key, hashes]) => [key, hashes.length]));
            """) as? [String: Int]
            await harness.tearDown()

            #expect(result?.count == 4)
            for (key, count) in result ?? [:] {
                #expect(count == 1, "第 \(page) 个页面 \(key)：同样的稿子与设置画出了 \(count) 种像素")
            }
            #expect(harness.pageErrors == [])
        }
    }
}
