import Testing

/// 选中文字浮动条的字色、高亮色块由当前稿子的配色推出来（v4/04，docs/app-api.md 的 themes.swatches）。
@MainActor
struct InlineSwatchTests {
    /// 测试自己的对比度（WCAG 相对亮度）；打开浮动条的两个颜色菜单，读出看得见的色块。
    static let helpers = """
        const mc = window.mediacraft;
        window.mc = mc;
        window.markdown = async () => (await mc.drafts.current()).markdown;
        window.until = async (condition, timeout = 5000) => {
          const deadline = Date.now() + timeout;
          while (Date.now() < deadline) {
            const value = await condition();
            if (value) return value;
            await new Promise((resolve) => setTimeout(resolve, 10));
          }
          throw new Error(`等不到：${condition}`);
        };
        window.visible = (element) => Boolean(element) && element.getClientRects().length > 0 && !element.closest("[hidden]");
        window.bar = () => document.querySelector('[role="toolbar"][aria-label="选中的文字"]');
        const channel = (value) => (value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
        const luminance = (hex) => {
          const [r, g, b] = [1, 3, 5].map((index) => channel(parseInt(hex.slice(index, index + 2), 16) / 255));
          return 0.2126 * r + 0.7152 * g + 0.0722 * b;
        };
        window.ratio = (a, b) => {
          const [high, low] = [luminance(a), luminance(b)].sort((x, y) => y - x);
          return (high + 0.05) / (low + 0.05);
        };
        window.selectText = async (text) => {
          const at = (await markdown()).indexOf(text);
          await mc.editor.select(at, at + text.length);
          await until(() => visible(bar()));
        };
        // 点开「字色」或「高亮」，读出菜单里的色块（可访问名称「字色 强调 #0043ce」）与提示（「强调 #0043ce」）
        window.openSwatches = async (kind) => {
          ui.find(kind, { within: bar() }).click();
          const group = kind === "字色" ? "挑字色" : "挑高亮";
          await until(() => visible(document.querySelector(`[aria-label="${group}"]`)));
          return ui.all(`${kind} `, { within: group }).map((swatch) => ({ name: ui.name(swatch), title: swatch.title }));
        };
        // 当前稿子的色块：菜单里看得见的、App API 给的，以及每个色块对卡片颜色的对比度
        window.shownSwatches = async () => {
          await selectText("这段文字");
          const text = await openSwatches("字色");
          const highlight = await openSwatches("高亮");
          document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
          const { colors } = await mc.drafts.current();
          const hex = (swatch) => swatch.name.split(" ").pop();
          return {
            text: text.map(hex),
            highlight: highlight.map(hex),
            names: text.map((swatch) => swatch.name),
            titles: text.map((swatch) => swatch.title),
            api: await mc.themes.swatches(),
            textRatios: text.map((swatch) => ratio(hex(swatch), colors.bg)),
            highlightRatios: highlight.map((swatch) => ratio(hex(swatch), colors.text)),
          };
        };
    """

    @Test("字色、高亮色块跟着配色：杂志、手帐、套配色库、调强调色后各不相同；每个色块对卡片颜色 ≥ 4.5:1；与 themes.swatches() 一致")
    func swatchesFollowPalette() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "看看这段文字吧" });
            const shots = {};
            await mc.themes.apply("editorial");
            shots.editorial = await shownSwatches();
            await mc.themes.apply("journal");
            shots.journal = await shownSwatches();
            await mc.palettes.apply("neon-01");
            shots.library = await shownSwatches();
            // 检查器里调强调色（色块的 input 事件）：出图、存盘后色块跟着变
            const input = document.getElementById("accentColorInput");
            input.value = "#46e3ff";
            input.dispatchEvent(new Event("input", { bubbles: true }));
            await mc.render.pages();
            shots.tuned = await shownSwatches();
            return shots;
        """) as? [String: [String: Any]]
        await harness.tearDown()

        let scenarios = ["editorial", "journal", "library", "tuned"]
        let rows = scenarios.map { (result?[$0]?["text"] as? [String] ?? []) + (result?[$0]?["highlight"] as? [String] ?? []) }
        for (index, name) in scenarios.enumerated() {
            let shot = result?[name] ?? [:]
            let text = shot["text"] as? [String] ?? []
            let highlight = shot["highlight"] as? [String] ?? []
            let api = shot["api"] as? [String: [String]] ?? [:]
            #expect((5...6).contains(text.count) && (5...6).contains(highlight.count), "\(name)：字色 \(text)、高亮 \(highlight)")
            #expect(api["text"] == text && api["highlight"] == highlight, "\(name)：菜单与 themes.swatches() 一致")
            for value in shot["textRatios"] as? [Double] ?? [] {
                #expect(value >= 4.5, "\(name) 字色对卡片底色只有 \(value):1")
            }
            for value in shot["highlightRatios"] as? [Double] ?? [] {
                #expect(value >= 4.5, "\(name) 高亮底对正文色只有 \(value):1")
            }
            for earlier in rows[..<index] {
                #expect(rows[index] != earlier, "\(name) 的色块和前面的一样")
            }
        }
        #expect((result?["editorial"]?["names"] as? [String])?.first == "字色 强调 #2f67b1", "第一个是强调色")
        #expect((result?["editorial"]?["titles"] as? [String])?.first == "强调 #2f67b1", "提示是名字加色值")
        #expect((result?["tuned"]?["text"] as? [String])?.first == "#46e3ff", "调过的强调色")
        #expect(harness.pageErrors == [])
    }

    @Test("点色块写进 {{color:#色值|…}} / {{bg:#色值|…}}；换主题、套配色后已经写进正文的颜色不变")
    func writtenColorsStay() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "看看这段文字和那段文字吧" });
            await mc.themes.apply("editorial");
            const click = async (text, kind, index) => {
              await selectText(text);
              const before = await markdown();
              ui.find(kind, { within: bar() }).click();
              const group = kind === "字色" ? "挑字色" : "挑高亮";
              await until(() => visible(document.querySelector(`[aria-label="${group}"]`)));
              const swatch = ui.all(`${kind} `, { within: group })[index];
              swatch.click();
              await until(async () => (await markdown()) !== before);
              return ui.name(swatch).split(" ").pop();
            };
            const color = await click("这段文字", "字色", 2);
            const highlight = await click("那段文字", "高亮", 1);
            const written = await markdown();
            await mc.themes.apply("journal");
            const afterTheme = await markdown();
            const nightSwatches = await mc.themes.swatches();
            await mc.palettes.apply("japanese-01");
            return { color, highlight, written, afterTheme, afterPalette: await markdown(), nightSwatches };
        """) as? [String: Any]
        await harness.tearDown()

        let color = result?["color"] as? String ?? ""
        let highlight = result?["highlight"] as? String ?? ""
        let written = "看看{{color:\(color)|这段文字}}和{{bg:\(highlight)|那段文字}}吧"
        let night = result?["nightSwatches"] as? [String: [String]] ?? [:]
        #expect(color.hasPrefix("#") && highlight.hasPrefix("#"))
        #expect(result?["written"] as? String == written)
        #expect(result?["afterTheme"] as? String == written, "换主题后正文里的颜色不变")
        #expect(result?["afterPalette"] as? String == written, "套配色后正文里的颜色不变")
        #expect(!(night["text"] ?? []).contains(color) && !(night["highlight"] ?? []).contains(highlight), "手帐的色块换了")
        #expect(harness.pageErrors == [])
    }
}
