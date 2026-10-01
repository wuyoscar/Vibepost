import Testing

/// 卡片把 Markdown 结构画对：有序编号、列表悬挂缩进、分割线、连续引用竖线。
@MainActor
struct MarkdownStructureTests {
    /// 固定配色与字号出图，并提供按逻辑坐标读像素的小工具。
    /// renderDraft 返回每页的摘要（mediacraft.render.pages()），page.canvas 是这一页的预览画布（2 倍图）。
    static let setup = """
        const mc = window.mediacraft;
        await mc.drafts.create({
          mode: "cards",
          colors: { bg: "#ffffff", text: "#202938", accent: "#2563eb" },
          fontSize: 34,
          lineHeight: 1.85,
          fonts: { zh: "theme", en: "theme" },
        });
        window.renderDraft = async (text) => {
          await mc.drafts.update({ markdown: text });
          const pages = await mc.render.pages();
          const canvases = await mc.render.canvases();
          return pages.map((page, index) => ({ ...page, canvas: canvases[index] }));
        };
        window.textItems = (page) => page.items.filter((item) => item.kind === "text");
        // 逻辑坐标矩形里与背景不同的像素数（画布是 2 倍图）
        window.inkIn = (page, x, y, width, height) => {
          const data = page.canvas.getContext("2d").getImageData(Math.round(x * 2), Math.round(y * 2), Math.round(width * 2), Math.round(height * 2)).data;
          let ink = 0;
          for (let i = 0; i < data.length; i += 4) {
            if (Math.abs(data[i] - 255) + Math.abs(data[i + 1] - 255) + Math.abs(data[i + 2] - 255) > 24) ink += 1;
          }
          return ink;
        };
        window.pixelsHash = async (page, x, y, width, height) => {
          const data = page.canvas.getContext("2d").getImageData(Math.round(x * 2), Math.round(y * 2), Math.round(width * 2), Math.round(height * 2)).data;
          return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", data)), (byte) => byte.toString(16).padStart(2, "0")).join("");
        };
    """

    @Test("有序列表显示原编号：编号画在正文左侧，不同编号画出来不同，正文位置一致")
    func orderedListKeepsNumbers() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const [page] = await renderDraft("1. 同一句话\\n2. 同一句话\\n7. 同一句话\\n- 同一句话");
            const lines = textItems(page);
            const left = page.contentBounds.left;
            const gutters = await Promise.all(lines.map((item) => pixelsHash(page, left, item.y, item.x - left, item.height)));
            const texts = await Promise.all(lines.map((item) => pixelsHash(page, item.x, item.y, 200, item.height)));
            return {
              markers: lines.map((item) => item.marker ?? ""),
              gutterInk: lines.map((item) => inkIn(page, left, item.y, item.x - left, item.height) > 0),
              distinctGutters: new Set(gutters).size,
              distinctTexts: new Set(texts).size,
              indented: lines.every((item) => item.x > left),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["markers"] as? [String] == ["1.", "2.", "7.", "-"])
        #expect(result?["gutterInk"] as? [Bool] == [true, true, true, true], "每一项左侧都画了编号或圆点")
        #expect(result?["distinctGutters"] as? Int == 4, "1. 2. 7. 与圆点各不相同")
        #expect(result?["distinctTexts"] as? Int == 1, "正文起点一致")
        #expect(result?["indented"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("编号比悬挂区宽（如 2024.）时整个列表一起右移，编号不越过正文左边界")
    func wideNumbersWidenTheGutter() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const [page] = await renderDraft("5. 五\\n2024. 回顾这一年\\n- 圆点项");
            const left = page.contentBounds.left;
            const lines = textItems(page);
            return {
              sameX: new Set(lines.map((item) => item.x)).size === 1,
              spill: lines.map((item) => inkIn(page, 0, item.y, left - 1, item.height)),
              markerInk: lines.map((item) => inkIn(page, left - 1, item.y, item.x - left, item.height) > 0),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["sameX"] as? Bool == true, "同一个列表的正文起点一致")
        #expect(result?["spill"] as? [Int] == [0, 0, 0], "编号没有画到左边距里")
        #expect(result?["markerInk"] as? [Bool] == [true, true, true])
        #expect(harness.pageErrors == [])
    }

    @Test("列表项折行时续行与首行文字对齐，编号所在的左侧区域只在首行有内容")
    func wrappedListItemsHangIndent() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const long = "这一项写得很长很长，长到一定要折成好几行，检验续行是不是和第一行的文字对齐，而不是顶到最左边，English words wrap too.";
            const [page] = await renderDraft(`- ${long}\\n10. ${long}`);
            const left = page.contentBounds.left;
            const lines = textItems(page);
            const firstLines = lines.filter((item) => item.marker);
            const continuations = lines.filter((item) => !item.marker);
            return {
              lineCount: lines.length,
              firstLineCount: firstLines.length,
              sameX: new Set(lines.map((item) => item.x)).size === 1 && lines[0].x > left,
              markerInk: firstLines.map((item) => inkIn(page, left, item.y, item.x - left - 2, item.height) > 0),
              continuationGutterInk: continuations.map((item) => inkIn(page, left, item.y, item.x - left - 2, item.height)),
              continuationTextInk: continuations.map((item) => inkIn(page, item.x, item.y, 60, item.height) > 0),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect((result?["lineCount"] as? Int ?? 0) >= 6, "两项都应折成多行")
        #expect(result?["firstLineCount"] as? Int == 2)
        #expect(result?["sameX"] as? Bool == true, "首行与续行的正文起点相同，且比段落右移")
        #expect(result?["markerInk"] as? [Bool] == [true, true])
        #expect((result?["continuationGutterInk"] as? [Int] ?? [1]).allSatisfy { $0 == 0 }, "续行左侧悬挂区是空的")
        #expect((result?["continuationTextInk"] as? [Bool] ?? [false]).allSatisfy { $0 })
        #expect(harness.pageErrors == [])
    }

    @Test("--- 与 - - - 画成一条横贯正文区的细线")
    func thematicBreakDrawsRule() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const rules = [];
            for (const marker of ["---", "- - -", "***"]) {
              const [page] = await renderDraft(`上一段\\n\\n${marker}\\n\\n下一段`);
              const { left, right } = page.contentBounds;
              const [above, below] = textItems(page);
              const rows = [];
              for (let y = above.y + above.height; y < below.y; y += 0.5) {
                if (inkIn(page, left, y, right - left, 0.5) > (right - left) * 2 * 0.9) rows.push(y);
              }
              rows.push(inkIn(page, left - 20, rows[0] ?? 0, 16, 1) === 0 && inkIn(page, right + 4, rows[0] ?? 0, 16, 1) === 0);
              rules.push({ marker, rows, texts: textItems(page).length });
            }
            return rules;
        """) as? [[String: Any]]
        await harness.tearDown()

        for rule in result ?? [] {
            let rows = rule["rows"] as? [Any] ?? []
            let lineRows = rows.dropLast().compactMap { $0 as? Double }
            #expect(!lineRows.isEmpty && lineRows.count <= 6, "\(rule["marker"] ?? "")：应有一条不超过 3px 的横线，实际 \(lineRows.count) 行")
            #expect(rows.last as? Bool == true, "\(rule["marker"] ?? "")：线只画在正文区内")
            #expect(rule["texts"] as? Int == 2, "\(rule["marker"] ?? "")：分割线不是文字")
        }
        #expect(result?.count == 3)
        #expect(harness.pageErrors == [])
    }

    /// 把一页上的引用行按是否首尾相接分成几段，并数出每段竖线从首行到末行之间断开的像素行数。
    static let quoteRuns = """
        window.quoteRuns = (page) => {
          const barX = page.contentBounds.left + 2;
          const runs = [];
          for (const item of textItems(page).filter((line) => line.blockType === "quote")) {
            const run = runs[runs.length - 1];
            const previous = run?.[run.length - 1];
            if (previous && item.y === previous.y + previous.height) run.push(item);
            else runs.push([item]);
          }
          return runs.map((run) => {
            const first = run[0];
            const last = run[run.length - 1];
            let missing = 0;
            for (let y = first.y + 8; y < last.y + last.height - 8; y += 1) {
              if (inkIn(page, barX, y, 3, 1) === 0) missing += 1;
            }
            return { page: page.index + 1, lines: run.length, missing, top: first.y, bottom: last.y + last.height };
          });
        };
    """

    @Test("连续多行引用是一条连续竖线，跨页时每页各自连续")
    func consecutiveQuoteLinesShareOneBar() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let runs = try await harness.evaluate(Self.setup + Self.quoteRuns + """
            const filler = Array.from({ length: 6 }, (_, index) => `第${index + 1}段填充文字，把后面的引用推到页底附近。`).join("\\n\\n");
            const quote = Array.from({ length: 14 }, (_, index) => `> 引用第${index + 1}行，写得稍微长一点，让它折成两行，竖线应该一直连着不断开。`).join("\\n");
            return (await renderDraft(`${filler}\\n\\n${quote}`)).flatMap(quoteRuns);
        """) as? [[String: Any]]
        await harness.tearDown()

        let pages = (runs ?? []).compactMap { $0["page"] as? Int }
        #expect(Set(pages).count >= 2, "长引用应跨页")
        #expect(pages.count == Set(pages).count, "同一段引用在每一页上是连在一起的一段")
        for run in runs ?? [] {
            #expect(run["missing"] as? Int == 0, "第 \(run["page"] ?? 0) 页 \(run["lines"] ?? 0) 行的引用竖线有断开")
        }
        #expect(harness.pageErrors == [])
    }

    @Test("空行隔开的两段引用各有各的竖线，中间不连线")
    func separateQuotesKeepSeparateBars() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + Self.quoteRuns + """
            const [page] = await renderDraft("> 甲一\\n> 甲二\\n\\n> 乙");
            const runs = quoteRuns(page);
            // 两段之间（竖线跟着引用的内边距多走一点）要有一截空白
            let gapBlank = -1;
            if (runs.length === 2) {
              gapBlank = 0;
              for (let y = runs[0].bottom; y < runs[1].top; y += 1) {
                if (inkIn(page, page.contentBounds.left + 2, y, 3, 1) === 0) gapBlank += 1;
              }
            }
            return { runs, gapBlank };
        """) as? [String: Any]
        await harness.tearDown()

        let runs = result?["runs"] as? [[String: Any]] ?? []
        #expect(runs.map { $0["lines"] as? Int ?? 0 } == [2, 1])
        #expect(runs.allSatisfy { $0["missing"] as? Int == 0 })
        #expect((result?["gapBlank"] as? Int ?? 0) >= 4, "两段引用的竖线中间断开：\(result?["gapBlank"] ?? -1)")
        #expect(harness.pageErrors == [])
    }

    @Test("每行的源码范围对得上：列表、引用拖入图片后结构不被破坏")
    func sourceRangesStayCorrect() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const [imageId] = await mc.media.import([new File([await new Promise((resolve) => {
              const canvas = document.createElement("canvas");
              canvas.width = canvas.height = 8;
              canvas.getContext("2d").fillRect(0, 0, 8, 8);
              canvas.toBlob(resolve, "image/png");
            })], "dot.png", { type: "image/png" })]);
            await mc.media.update(imageId, { layout: { widthPercent: 25, align: "center" } });
            const tag = `[[image:${imageId}]]`;
            const content = `${tag}\\n\\n1. 第一项\\n2. 第二项写得长一些，让它折成两行，看每一行的源码范围\\n\\n> 引用一\\n> 引用二`;
            const [page] = await renderDraft(content);
            const mismatched = textItems(page).filter((item) => !content.slice(item.source[0], item.source[1]).includes(item.text)).length;
            // 在预览里把图片拖到某一行之前松手
            const moveBefore = async (text) => {
              const [fresh] = await renderDraft(content);
              const target = fresh.dropTargets.findIndex((candidate) => content.slice(candidate.source[0], candidate.source[1]).includes(text));
              await mc.media.move(imageId, { page: 0, target, after: false });
              return (await mc.drafts.current()).markdown;
            };
            return {
              mismatched,
              beforeListItem: await moveBefore("第二项"),
              beforeQuoteLine: await moveBefore("引用二"),
              tag,
            };
        """) as? [String: Any]
        await harness.tearDown()

        let tag = result?["tag"] as? String ?? "?"
        #expect(result?["mismatched"] as? Int == 0, "每行的源码范围都包含这一行画出的文字")
        #expect(result?["beforeListItem"] as? String == "1. 第一项\n\(tag)\n2. 第二项写得长一些，让它折成两行，看每一行的源码范围\n\n> 引用一\n> 引用二",
                "图片插在列表项整行之前，编号仍在行首")
        #expect(result?["beforeQuoteLine"] as? String == "1. 第一项\n2. 第二项写得长一些，让它折成两行，看每一行的源码范围\n\n> 引用一\n\(tag)\n> 引用二")
        #expect(harness.pageErrors == [])
    }
}
