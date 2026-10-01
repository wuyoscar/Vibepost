import Testing

/// 深色配色下卡片依然清楚：直接从出图像素量对比度（WCAG 相对亮度）。
@MainActor
struct DarkCardLegibilityTests {
    static let darkPalettes = [
        ["#1c1f26", "#e8e6e3", "#e0b85a"], // 深夜
        ["#1f2d27", "#edeae0", "#c9a96e"], // 墨绿
        ["#161616", "#f4f4f4", "#78a9ff"], // Carbon Gray 100
    ]

    /// 在一块区域里取出现最多的颜色当底色，离它最远的像素当字色 / 线色，返回两者的对比度。
    static let measureHelpers = """
        const channel = (value) => {
          const s = value / 255;
          return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
        };
        const luminance = ([r, g, b]) => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
        const ratio = (a, b) => {
          const [high, low] = [luminance(a), luminance(b)].sort((x, y) => y - x);
          return (high + 0.05) / (low + 0.05);
        };
        const pixels = (canvas, left, top, right, bottom) => {
          const scale = canvas.width / 864;
          const x = Math.round(left * scale);
          const y = Math.round(top * scale);
          const { data } = canvas.getContext("2d").getImageData(x, y, Math.round(right * scale) - x, Math.round(bottom * scale) - y);
          const list = [];
          for (let i = 0; i < data.length; i += 4) list.push([data[i], data[i + 1], data[i + 2]]);
          return list;
        };
        const measure = (canvas, left, top, right, bottom) => {
          const list = pixels(canvas, left, top, right, bottom);
          const counts = new Map();
          list.forEach((pixel) => counts.set(pixel.join(), (counts.get(pixel.join()) || 0) + 1));
          const base = [...counts.entries()].sort((a, b) => b[1] - a[1])[0][0].split(",").map(Number);
          return Math.max(...list.map((pixel) => ratio(base, pixel)));
        };
        // 高亮底色块内部（避开圆角）：底色是出现最多的颜色，字的实心笔画离它最远。
        const measureHighlight = (canvas, item) => {
          const top = item.y + Math.round(item.height * 0.14);
          const bottom = top + Math.round(item.height * 0.72);
          return measure(canvas, item.x + 2, top + 8, item.x + 64, bottom - 8);
        };
        const mc = window.mediacraft;
        // 出图，每页摘要带上自己的预览画布
        const renderCards = async () => {
          const pages = await mc.render.pages();
          const canvases = await mc.render.canvases();
          return pages.map((page, index) => ({ ...page, canvas: canvases[index] }));
        };
        const textItems = (cards) => cards.flatMap((page) => page.items
          .filter((item) => item.kind === "text")
          .map((item) => ({ canvas: page.canvas, item })));
    """

    /// 深色配色下按指定卡片结构出图：量高亮、正文、表格，以及画在正文区以外的署名、页码、标签（次要文字）。
    static let darkScript = CardDomProbe.script + measureHelpers + """
        if (!window.darkDraftReady) {
          await mc.drafts.create();
          await mc.profile.update({ name: "wuyoscar", handle: "@wuyoscar" });
          window.darkDraftReady = true;
        }
        // 高亮色块跟着配色：先换上这组深色配色，再取它的高亮
        await mc.drafts.update({ colors: { bg: palette[0], text: palette[1], accent: palette[2] } });
        const { highlight } = await mc.themes.swatches();
        await mc.drafts.update({
          mode: "cards",
          fontSize: 34,
          lineHeight: 1.85,
          markdown: [
            "# 深色配色",
            "正文段落：量一量正文对卡片底色的对比度。",
            ...highlight.map((color) => `{{bg:${color}|高亮上的正文}}`),
            "| 项目 | 说明 |\\n| --- | --- |\\n| 字号 | 三十四 |",
          ].join("\\n\\n"),
        });
        const rendered = await mc.render.offscreen({ structure });
        const cards = rendered.pages.map((page, index) => ({ ...page, canvas: rendered.canvases[index], calls: cardDom(rendered.views[index]) }));

        const text = textItems(cards);
        const body = text.find(({ item }) => item.blockType === "p" && !item.runs.some((run) => run.bg));
        const tablePage = cards.find((page) => page.items.some((item) => item.kind === "table"));
        const table = tablePage.items.find((item) => item.kind === "table");
        const [head, row] = table.rows;
        // 表格最后一行下面的横线：一小条里出现最多的是底色，离它最远的是线
        const rowBottom = table.y + head.height + row.height;
        // 正文区以外的字：署名、账号、页码、结构的标签。夜读首页那个很淡的大引号是装饰，不算。
        const labels = cards.flatMap((page) => page.calls
          .filter((call) => call.kind === "text" && call.text !== "“" && (call.y < page.contentBounds.top || call.y > page.contentBounds.bottom))
          .map((call) => ({ text: call.text, ratio: measure(page.canvas, call.left, call.top, call.right, call.bottom) })));
        return {
          swatchCount: highlight.length,
          highlights: text.filter(({ item }) => item.runs[0]?.bg).map(({ canvas, item }) => measureHighlight(canvas, item)),
          body: measure(body.canvas, body.item.x, body.item.y, body.item.x + 300, body.item.y + body.item.height),
          labels,
          tableHeader: measure(tablePage.canvas, table.x + 4, table.y + 4, table.x + table.cellWidth - 4, table.y + head.height - 4),
          tableLine: measure(tablePage.canvas, table.x + 20, rowBottom - 3, table.x + 60, rowBottom + 3),
        };
    """

    static let structures = ThemeTests.ids

    @Test("深色配色、每种卡片结构：每个高亮色块上的字对高亮底 ≥ 4.5:1，正文对底色 ≥ 4.5:1，署名页码等次要文字 ≥ 3:1，表格线清楚")
    func darkPalettesStayLegible() async throws {
        let harness = ShellHarness()
        try await harness.load()
        for structure in Self.structures {
            for palette in Self.darkPalettes {
                let label = "\(structure) \(palette)"
                let result = try await harness.evaluate(Self.darkScript, arguments: ["palette": palette, "structure": structure]) as? [String: Any]
                let highlights = result?["highlights"] as? [Double] ?? []
                let swatchCount = result?["swatchCount"] as? Int ?? 0
                #expect(swatchCount >= 5 && highlights.count == swatchCount, "\(label)")
                for (index, value) in highlights.enumerated() {
                    #expect(value >= 4.5, "\(label) 第 \(index + 1) 个高亮上的字只有 \(value):1")
                }
                let body = result?["body"] as? Double ?? 0
                let tableHeader = result?["tableHeader"] as? Double ?? 0
                let tableLine = result?["tableLine"] as? Double ?? 0
                let labels = result?["labels"] as? [[String: Any]] ?? []
                #expect(body >= 4.5, "\(label) 正文对底色只有 \(body):1")
                #expect(!labels.isEmpty, "\(label) 没有署名或页码")
                for entry in labels {
                    let value = entry["ratio"] as? Double ?? 0
                    #expect(value >= 3, "\(label) 次要文字「\(entry["text"] ?? "")」只有 \(value):1")
                }
                #expect(tableHeader >= 4.5, "\(label) 表头文字对表头底色只有 \(tableHeader):1")
                #expect(tableLine >= 2.5, "\(label) 表格线对底色只有 \(tableLine):1")
            }
        }
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }

    @Test("高亮底色很深时，上面的正文自动换成看得清的颜色；本来就清楚的不动")
    func deepHighlightFlipsText() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.measureHelpers + """
            await mc.drafts.create({
              mode: "cards",
              colors: { bg: "#ffffff", text: "#202938", accent: "#2563eb" },
              markdown: "{{bg:#1e3a8a|深蓝高亮上的正文}}\\n\\n{{bg:#fff3bf|浅黄高亮上的正文}}",
            });
            const [deep, light] = textItems(await renderCards()).map(({ canvas, item }) => measureHighlight(canvas, item));
            return { deep, light };
        """) as? [String: Double]
        await harness.tearDown()

        #expect((result?["deep"] ?? 0) >= 4.5, "深色高亮上的字只有 \(result?["deep"] ?? 0):1")
        #expect((result?["light"] ?? 0) >= 4.5)
        #expect(harness.pageErrors == [])
    }
}
