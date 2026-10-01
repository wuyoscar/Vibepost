import Testing

/// 新分页排版的行为：折行规则、图片版式、拼图比例、代码块、标题带图换页、速度。
@MainActor
struct CardLayoutTests {
    static let setup = PaginationTests.setup + """
        window.importPng = async (name, width, height) => (await mc.media.import([await pngFile(name, width, height)]))[0];
    """

    @Test("折行：行首没有逗号句号等标点、行尾没有开引号开括号，英文单词不从中间断开")
    func lineBreakingRules() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const sentence = "他说：「先问再读，再动手。」（这一步很关键）然后呢？“好的”——就这样……English words should never be broken in the middle, 2026。";
            const cards = await renderDraft(Array.from({ length: 6 }, () => sentence).join(""));
            const items = cards.flatMap(textItems);
            const lines = items.map((item) => item.text);
            const noStart = new Set([..."，。、；：？！）」』》”…—"]);
            const noEnd = new Set([..."（「『《“"]);
            const isLetter = (char) => /[A-Za-z]/.test(char ?? "");
            // 前一行的最后一个字母和后一行的第一个字母在原文里紧挨着，就是把一个词断开了
            const splitWords = items.slice(1).filter((item, index) => {
              const previous = items[index];
              return isLetter(item.text[0]) && isLetter(previous.text[previous.text.length - 1]) && previous.source[1] === item.source[0];
            });
            return {
              count: lines.length,
              badStart: lines.filter((line) => noStart.has(line[0])),
              badEnd: lines.filter((line) => noEnd.has(line[line.length - 1])),
              splitWords: splitWords.map((item) => item.text),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect((result?["count"] as? Int ?? 0) >= 6, "长段应折成多行")
        #expect(result?["badStart"] as? [String] == [], "有行以避头标点开头")
        #expect(result?["badEnd"] as? [String] == [], "有行以开引号、开括号结尾")
        #expect(result?["splitWords"] as? [String] == [], "英文单词被从中间断开")
        #expect(harness.pageErrors == [])
    }

    @Test("图片按各自的版式排：宽度百分比与对齐、固定框、图片最大高；点选框带缩放上限")
    func imagesFollowTheirLayout() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const wide = await importPng("wide.png", 400, 200);
            const tall = await importPng("tall.png", 200, 800);
            const hitFor = async (layout, id = wide, extra = {}) => {
              await mc.media.update(id, { layout });
              await mc.drafts.update({ imageMaxHeight: 1048, ...extra });
              const [page] = await renderDraft(`[[image:${id}]]`);
              const [hit] = page.imageHits;
              return { ...hit, left: page.contentBounds.left, right: page.contentBounds.right };
            };
            return {
              full: await hitFor(null),
              left: await hitFor({ widthPercent: 50, align: "left" }),
              right: await hitFor({ widthPercent: 50, align: "right" }),
              center: await hitFor({ widthPercent: 50, align: "center" }),
              fixed: await hitFor({ fixedWidth: 300, fixedHeight: 200 }),
              capped: await hitFor(null, tall, { imageMaxHeight: 400 }),
            };
        """) as? [String: [String: Any]]
        await harness.tearDown()

        func number(_ key: String, _ field: String) -> Double { result?[key]?[field] as? Double ?? -1 }
        let left = number("full", "left")
        let right = number("full", "right")
        #expect(number("full", "x") == left && number("full", "width") == right - left, "默认铺满正文宽")
        #expect(number("full", "height") == (right - left) / 2, "按原图比例")
        #expect(number("full", "baseWidth") == right - left && number("full", "resizeMaxWidth") == right - left)
        #expect(number("left", "x") == left && number("left", "width") == (right - left) / 2)
        #expect(number("right", "x") + number("right", "width") == right)
        #expect(abs(number("center", "x") + number("center", "width") / 2 - (left + right) / 2) <= 0.5)
        #expect(number("fixed", "width") == 300 && number("fixed", "height") == 200, "固定框")
        #expect(number("capped", "height") == 400 && number("capped", "width") == 100, "高图按图片最大高缩小")
        #expect(number("capped", "baseWidth") == 100, "缩放上限跟着最大高")
        #expect(harness.pageErrors == [])
    }

    @Test("拼图按整组比例排：1x1、4x3、3x2、16x9，不写或写别的按 16x9；两张并排、中间留缝")
    func imagePairsFollowRatio() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const a = await importPng("a.png", 300, 300);
            const b = await importPng("b.png", 200, 300);
            const ratios = {};
            for (const ratio of ["1x1", "4x3", "3x2", "16x9", "", "2x1"]) {
              const [page] = await renderDraft(`[[image:${a}|${b}${ratio ? `|${ratio}` : ""}]]`);
              const pair = page.items.find((item) => item.kind === "imagePair");
              ratios[ratio || "none"] = pair ? Math.round((pair.width / pair.height) * 100) / 100 : 0;
            }
            const [page] = await renderDraft(`[[image:${a}|${b}|1x1]]`);
            const pair = page.items.find((item) => item.kind === "imagePair");
            const canvas = page.canvas.getContext("2d");
            const pixel = (x) => Array.from(canvas.getImageData(Math.round(x * 2), Math.round((pair.y + pair.height / 2) * 2), 1, 1).data.slice(0, 3));
            return { ratios, ids: pair.imageIds.length, left: pixel(pair.x + 10), gap: pixel(pair.x + pair.width / 2), right: pixel(pair.x + pair.width - 10) };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["ratios"] as? [String: Double] == ["1x1": 1, "4x3": 1.33, "3x2": 1.5, "16x9": 1.78, "none": 1.78, "2x1": 1.78])
        #expect(result?["ids"] as? Int == 2)
        #expect(result?["left"] as? [Int] == [25, 113, 194], "左边是甲图")
        #expect(result?["right"] as? [Int] == [25, 113, 194], "右边是乙图")
        #expect(result?["gap"] as? [Int] == [255, 255, 255], "中间留缝")
        #expect(harness.pageErrors == [])
    }

    @Test("代码块：等宽字按原文逐行画在一块底框里，不解析行内格式；跨页时每页一个框")
    func codeBlocksKeepSourceLines() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const [page] = await renderDraft("代码前一段\\n\\n```js\\nconst a = **1**;\\n\\n  return a;\\n```\\n\\n代码后一段");
            const box = page.items.find((item) => item.kind === "code");
            const lines = page.items.filter((item) => item.blockType === "code");
            const long = await renderDraft("```\\n" + Array.from({ length: 40 }, (_, index) => `line ${index + 1}`).join("\\n") + "\\n```");
            return {
              texts: lines.map((item) => item.text),
              inside: lines.every((item) => item.y >= box.y && item.y + item.height <= box.y + box.height && item.x > box.x),
              plain: lines.every((item) => item.runs.every((run) => !run.bold && !run.code)),
              boxes: long.map((card) => card.items.filter((item) => item.kind === "code").length),
              lineCount: long.flatMap((card) => card.items.filter((item) => item.blockType === "code")).length,
              order: textItems(page).map((item) => item.blockType),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["texts"] as? [String] == ["const a = **1**;", "", "  return a;"])
        #expect(result?["inside"] as? Bool == true)
        #expect(result?["plain"] as? Bool == true)
        let boxes = result?["boxes"] as? [Int] ?? []
        #expect(boxes.count >= 2 && boxes.allSatisfy { $0 == 1 }, "长代码块跨页，每页一个框：\(boxes)")
        #expect(result?["lineCount"] as? Int == 40)
        #expect(result?["order"] as? [String] == ["p", "code", "code", "code", "p"])
        #expect(harness.pageErrors == [])
    }

    @Test("标题后面紧跟一张放不下的大图：图在标题下缩小一些，标题不落单；空行 > 在一段引用里")
    func headingKeepsItsImage() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + MarkdownStructureTests.quoteRuns + """
            const tall = await importPng("tall.png", 300, 1000);
            const cards = await renderDraft(`第一段\\n\\n## 大图\\n\\n[[image:${tall}]]\\n\\n> 甲\\n>\\n> 乙`);
            const headingPage = cards.findIndex((page) => textItems(page).some((item) => item.blockType === "h2"));
            const imagePage = cards.findIndex((page) => page.imageHits.length);
            return {
              together: headingPage === imagePage,
              endsWithHeading: cards.slice(0, -1).filter((page) => isHeading(page.items[page.items.length - 1])).length,
              overflow: cards.filter((page) => page.items.some((item) => item.y + item.height > page.contentBounds.bottom)).length,
              quote: cards.flatMap(quoteRuns).map((run) => run.lines),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["together"] as? Bool == true)
        #expect(result?["endsWithHeading"] as? Int == 0)
        #expect(result?["overflow"] as? Int == 0)
        #expect(result?["quote"] as? [Int] == [3], "单独一个 > 是引用里的空行，竖线连着")
        #expect(harness.pageErrors == [])
    }

    @Test("两万字的稿子：整篇解析、分页、出图足够快，可以每次按键都重排")
    func largeDraftRendersFast() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const parts = [];
            for (let index = 1, length = 0; length < 20000; index += 1) {
              const part = index % 5 === 0 ? `## 第${index}节` : index % 5 === 1 ? `> 第${index}段引用，写得长一点，看看折行。` : `第${index}段：把写好的内容排成卡片，**再一键**发到手机上发布，English words 与 \\`code\\` 混排，2026。`.repeat(2);
              parts.push(part);
              length += part.length;
            }
            await mc.drafts.update({ markdown: parts.join("\\n\\n") });
            // 主题面板闲下来时会在后台给别的主题按整篇出缩略图（打字时它就停下）：量之前切到 AI 助手，让它停着
            ui.click("AI 助手");
            const times = [];
            let pages = 0;
            for (let run = 0; run < 3; run += 1) {
              const start = performance.now();
              pages = (await mc.render.refresh()).length;
              times.push(performance.now() - start);
            }
            return { pages, median: times.sort((a, b) => a - b)[1] };
        """) as? [String: Any]
        await harness.tearDown()

        #expect((result?["pages"] as? Int ?? 0) > 30)
        #expect((result?["median"] as? Double ?? 9999) < 500, "两万字出一次图用了 \(result?["median"] ?? 0) 毫秒")
        #expect(harness.pageErrors == [])
    }
}
