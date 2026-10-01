import Testing

/// 卡片配色属于每篇稿子：三个取色器是在主题配色上的单篇微调，重载、切换稿子都不能把它冲掉；
/// 只有换主题时才重置为该主题的配色。
@MainActor
struct ColorPersistenceTests {
    static let readColors = """
        const { colors } = await window.mediacraft.drafts.current();
        return [colors.bg, colors.text, colors.accent];
    """
    static let helpers = """
        const mc = window.mediacraft;
        window.cardColors = async () => {
          const { colors } = await mc.drafts.current();
          return [colors.bg, colors.text, colors.accent];
        };
        window.pickTheme = async (id) => {
          await mc.themes.apply(id);
          return cardColors();
        };
    """

    @Test("选过配色的稿子，重新载入后颜色不变")
    func colorsSurviveReload() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate("""
            await window.mediacraft.drafts.create();
            await window.mediacraft.drafts.update({ colors: { bg, text, accent } });
        """, arguments: ["bg": "#eef3f8", "text": "#1e2a3a", "accent": "#3b6ea8"])
        try await harness.load()
        let colors = try await harness.evaluate(Self.readColors) as? [String]
        await harness.tearDown()

        #expect(colors == ["#eef3f8", "#1e2a3a", "#3b6ea8"])
        #expect(harness.pageErrors == [])
    }

    @Test("切到别的稿子再切回来，颜色不变")
    func colorsSurviveProjectSwitch() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let colors = try await harness.evaluate("""
            const mc = window.mediacraft;
            const { id: first } = await mc.drafts.create();
            await mc.drafts.update({ colors: { bg, text, accent } });
            await mc.drafts.create();
            await mc.drafts.open(first);
        """ + Self.readColors, arguments: ["bg": "#fbf7ef", "text": "#3a3226", "accent": "#b5562e"]) as? [String]
        await harness.tearDown()

        #expect(colors == ["#fbf7ef", "#3a3226", "#b5562e"])
        #expect(harness.pageErrors == [])
    }

    @Test("微调过的颜色随稿子保存；换主题时三个颜色重置为该主题的配色")
    func fineTunedColorsResetOnThemeChange() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            await pickTheme("ink");
            await mc.drafts.update({ colors: { accent: "#ff8800" } });
        """)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const tuned = await cardColors();
            return { tuned, notes: await pickTheme("notes"), ink: await pickTheme("ink") };
        """) as? [String: [String]]
        await harness.tearDown()

        #expect(result?["tuned"] == ["#0c0c0c", "#e8e8e5", "#ff8800"], "微调的强调色重载后还在")
        #expect(result?["notes"] == ThemeTests.notes)
        #expect(result?["ink"] == ThemeTests.ink, "换回纯黑是纯黑的配色，不是之前微调的")
        #expect(harness.pageErrors == [])
    }

    @Test("新建稿子用上一次选的主题的配色，强调色真正画在卡片上")
    func newProjectUsesLastThemePalette() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            const fresh = await cardColors();
            await pickTheme("clay");
            await mc.drafts.create({ markdown: "> 引用的竖条用强调色" });
            const [page] = await mc.render.pages();
            const [canvas] = await mc.render.canvases();
            const quote = page.items.find((item) => item.blockType === "quote");
            // 竖条画在引用的缩进里，从正文区左边界开始
            const x = (page.contentBounds.left + 1) * page.pixelRatio;
            const [r, g, b] = canvas.getContext("2d").getImageData(x, (quote.y + quote.height / 2) * page.pixelRatio, 1, 1).data;
            const hex = (value) => value.toString(16).padStart(2, "0");
            return {
              fresh,
              afterClay: await cardColors(),
              quoteBar: `#${hex(r)}${hex(g)}${hex(b)}`,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["fresh"] as? [String] == ThemeTests.notes, "没选过主题时是备忘的配色")
        #expect(result?["afterClay"] as? [String] == ["#fff6f0", "#1d1b18", "#e5704f"])
        #expect(result?["quoteBar"] as? String == "#e5704f", "陶土引用左边的竖条是强调色")
        #expect(harness.pageErrors == [])
    }
}
