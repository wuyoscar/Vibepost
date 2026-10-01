import Testing

/// 作者能控制每张卡放什么：手动分页符、标题不落单、长表格跨页、一页一段实况。
@MainActor
struct PaginationTests {
    static let setup = MarkdownStructureTests.setup + """
        window.lineTexts = (page) => textItems(page).map((item) => item.text);
        window.isHeading = (item) => item?.kind === "text" && ["h1", "h2", "h3"].includes(item.blockType);
        window.pngFile = (name, width, height) => new Promise((resolve) => {
          const canvas = document.createElement("canvas");
          canvas.width = width;
          canvas.height = height;
          const context = canvas.getContext("2d");
          context.fillStyle = "#1971c2";
          context.fillRect(0, 0, width, height);
          canvas.toBlob((blob) => resolve(new File([blob], name, { type: "image/png" })), "image/png");
        });
    """

    @Test("单独一行 [[分页]]：后面的内容从新的一张卡开始，标记本身不画；连用或放在末尾不产生空白卡")
    func pageBreakMarkerStartsNewCard() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const cards = await renderDraft("第一段\\n\\n[[分页]]\\n\\n第二段\\n[[分页]]\\n[[分页]]\\n第三段\\n\\n[[分页]]");
            const inline = await renderDraft("前文 [[分页]] 后文");
            const cover = await renderDraft("# 封面标题\\n\\n[[分页]]\\n\\n正文");
            return {
              pages: cards.map(lineTexts),
              topGaps: cards.map((page) => page.items[0].y - page.contentBounds.top),
              inline: inline.map(lineTexts),
              cover: cover.map(lineTexts),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["pages"] as? [[String]] == [["第一段"], ["第二段"], ["第三段"]])
        #expect(result?["topGaps"] as? [Int] == [0, 0, 0], "分页后的空行不在新卡顶上留白")
        #expect(result?["inline"] as? [[String]] == [["前文 [[分页]] 后文"]], "行内的 [[分页]] 不算分页符")
        #expect(result?["cover"] as? [[String]] == [["封面标题"], ["正文"]], "作者手动分页优先：标题可以单独成卡")
        #expect(harness.pageErrors == [])
    }

    @Test("「插入」菜单的分页把 [[分页]] 插在光标处，单独占一行，光标停在下一行开头")
    func toolbarInsertsPageBreak() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let hasIcon = try await harness.evaluate(
            "ui.expand('插入', { within: '文字样式' }); return Boolean(ui.find('分页', { within: '文字样式' })?.querySelector('svg'))"
        ) as? Bool
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create();
            const insertAt = async (text, caret) => {
              await mc.drafts.update({ markdown: text });
              await mc.editor.select(caret);
              ui.expand("插入", { within: "文字样式" });
              ui.click("分页", { within: "文字样式" });
              return [(await mc.drafts.current()).markdown, (await mc.editor.selection()).start];
            };
            return [
              await insertAt("第一段第二段", 3),
              await insertAt("第一段\\n第二段", 3),
              await insertAt("第一段\\n第二段", 4),
              await insertAt("第一段", 3),
            ];
        """) as? [[Any]]
        await harness.tearDown()

        #expect(hasIcon == true, "按钮有图标")
        let expected: [(String, Int)] = [
            ("第一段\n[[分页]]\n第二段", 11),
            ("第一段\n[[分页]]\n第二段", 11),
            ("第一段\n[[分页]]\n第二段", 11),
            ("第一段\n[[分页]]\n", 11),
        ]
        #expect(result?.count == expected.count)
        for (actual, (text, caret)) in zip(result ?? [], expected) {
            #expect(actual.first as? String == text)
            #expect(actual.last as? Int == caret)
        }
        #expect(harness.pageErrors == [])
    }

    @Test("[[分页]] 不进复制的纯文本，也不出现在长文里")
    func pageBreakMarkerStaysOutOfTextAndArticle() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create();
            const draft = "第一段\\n\\n[[分页]]\\n\\n第二段";
            return { plain: await mc.render.plainText(draft), article: await mc.render.articleHtml(draft) };
        """) as? [String: String]
        await harness.tearDown()

        #expect(result?["plain"] == "第一段\n\n第二段")
        #expect(result?["article"] == "<p>第一段</p><p>第二段</p>")
        #expect(harness.pageErrors == [])
    }

    @Test("标题不做一页的最后一块：放不下后面第一段时和它一起换页（连着的几级标题一起走）")
    func headingsMoveWithFollowingBlock() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const cases = [];
            for (const heading of ["## 小标题", "# 大标题\\n## 小标题"]) {
              for (let lines = 0; lines <= 16; lines += 1) {
                const filler = Array.from({ length: lines }, (_, index) => `填充第${index + 1}行`).join("\\n");
                const cards = await renderDraft(`${filler}\\n\\n${heading}\\n\\n标题后面的第一段正文。\\n\\n第二段正文。`);
                const endsWithHeading = cards.slice(0, -1).filter((page) => isHeading(page.items[page.items.length - 1])).length;
                const headingPage = cards.findIndex((page) => textItems(page).some((item) => item.blockType === "h2"));
                const bodyPage = cards.findIndex((page) => lineTexts(page).includes("标题后面的第一段正文。"));
                const overflow = cards.filter((page) => page.items.some((item) => item.y + item.height > page.contentBounds.bottom)).length;
                cases.push({ heading, lines, endsWithHeading, together: headingPage === bodyPage, overflow });
              }
            }
            return cases;
        """) as? [[String: Any]]
        await harness.tearDown()

        #expect(result?.count == 34)
        for item in result ?? [] {
            let label = "\(item["heading"] ?? "") 前面 \(item["lines"] ?? 0) 行"
            #expect(item["endsWithHeading"] as? Int == 0, "\(label)：有一页以标题结尾")
            #expect(item["together"] as? Bool == true, "\(label)：标题和后面第一段不在同一页")
            #expect(item["overflow"] as? Int == 0, "\(label)：内容超出页底")
        }
        #expect(harness.pageErrors == [])
    }

    @Test("放不下的表格按行拆到后面的页，每页重复表头，不超出页底，行序不乱")
    func longTablesSplitByRows() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const rows = Array.from({ length: 40 }, (_, index) => `| ${index + 1} | 第${index + 1}行 | 说明 |`).join("\\n");
            const cards = await renderDraft(`开头一段。\\n\\n| 序号 | 项目 | 说明 |\\n| --- | --- | --- |\\n${rows}\\n\\n结尾一段。`);
            const parts = cards.flatMap((page) => page.items.filter((item) => item.kind === "table").map((item) => {
              const context = page.canvas.getContext("2d");
              const fill = context.getImageData((item.x + 6) * 2, (item.y + 6) * 2, 1, 1).data;
              const paper = context.getImageData(8, 8, 1, 1).data;
              return {
                header: item.rows[0].cells.slice(0, 3),
                headerRow: item.rows[0].header,
                numbers: item.rows.slice(1).map((row) => Number(row.cells[0])),
                inside: item.y + item.height <= page.contentBounds.bottom,
                headerFill: [0, 1, 2].some((channel) => Math.abs(fill[channel] - paper[channel]) > 8),
              };
            }));
            return parts;
        """) as? [[String: Any]]
        await harness.tearDown()

        let parts = result ?? []
        #expect(parts.count >= 2, "40 行的表格应拆到多页")
        #expect(parts.allSatisfy { $0["header"] as? [String] == ["序号", "项目", "说明"] && $0["headerRow"] as? Bool == true }, "每页都重复表头")
        #expect(parts.allSatisfy { $0["headerFill"] as? Bool == true }, "每页表头都画了表头底色（衬底）")
        #expect(parts.allSatisfy { $0["inside"] as? Bool == true }, "表格不超出页底")
        #expect(parts.allSatisfy { !($0["numbers"] as? [Int] ?? []).isEmpty }, "每页至少带一行")
        #expect(parts.flatMap { $0["numbers"] as? [Int] ?? [] } == Array(1...40))
        #expect(harness.pageErrors == [])
    }
}

/// 实况用例都挂在已串行的 SendLivePhotoTests 下：两个 WKWebView 同时解码视频会互相卡住。
@MainActor
extension SendLivePhotoTests {
    @Test("一页已有实况时下一段实况换到新页（标题跟着走），导出不再因一页多段实况报错；普通图片不受影响")
    func onlyOneLivePhotoPerPage() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(PaginationTests.setup + """
            const video = await (await fetch("/macos/Tests/Fixtures/live-h264.mp4")).blob();
            const insertLive = (name) => mc.media.insertLivePhoto(new File([video], name, { type: "video/mp4" }), { duration: 3 });
            const liveA = await insertLive("a.mp4");
            const liveB = await insertLive("b.mp4");
            const [stillA, stillB] = await mc.media.import([await pngFile("c.png", 300, 400), await pngFile("d.png", 300, 400)]);
            for (const id of [liveA, liveB, stillA, stillB]) await mc.media.update(id, { layout: { widthPercent: 30, align: "center" } });
            const livePages = await renderDraft(`[[image:${liveA}]]\\n\\n## 第二段实况\\n\\n[[image:${liveB}]]`);
            return {
              livePerPage: livePages.map((page) => page.imageHits.filter((hit) => hit.live).length),
              headingWithSecond: textItems(livePages[1] ?? livePages[0]).some((item) => item.blockType === "h2"),
              stillPages: (await renderDraft(`[[image:${stillA}]]\\n\\n[[image:${stillB}]]`)).length,
            };
        """) as? [String: Any]
        await harness.tearDown()

        // 实况按页合成，一页只能有一段；每页至多一段，导出时就不会因「一页多段实况」被拒。
        #expect(result?["livePerPage"] as? [Int] == [1, 1])
        #expect(result?["headingWithSecond"] as? Bool == true, "第二段实况前的标题跟着换页")
        #expect(result?["stillPages"] as? Int == 1, "普通图片照常排在同一页")
        #expect(harness.pageErrors == [])
    }
}
