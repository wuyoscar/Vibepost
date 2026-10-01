import Testing

/// 行内 `代码` 与 ~~删除线~~ 在卡片上画对，代码字体可选。
@MainActor
struct InlineCodeStrikeTests {
    static let helpers = MarkdownStructureTests.setup + BundledFontsTests.helpers + """
        window.lineText = (item) => item.text;
        // 逻辑坐标一行里与背景不同的像素：返回最左、最右的 x（没有就是 null）
        window.inkExtent = (page, y, background) => {
          const { canvas } = page;
          const data = canvas.getContext("2d").getImageData(0, Math.round(y * 2), canvas.width, 1).data;
          let first = null;
          let last = null;
          for (let x = 0; x < canvas.width; x += 1) {
            const i = x * 4;
            if (Math.abs(data[i] - background[0]) + Math.abs(data[i + 1] - background[1]) + Math.abs(data[i + 2] - background[2]) > 12) {
              first ??= x / 2;
              last = x / 2;
            }
          }
          return first === null ? null : { first, last };
        };
        window.pixel = (page, x, y) => Array.from(page.canvas.getContext("2d").getImageData(Math.round(x * 2), Math.round(y * 2), 1, 1).data.slice(0, 3));
        // 一行文字里墨迹最宽的那一条像素行（行内代码的底块最宽）
        window.widestRow = (page, item, background) => {
          let best = null;
          for (let y = item.y; y < item.y + item.height; y += 0.5) {
            const extent = inkExtent(page, y, background);
            if (extent && (!best || extent.last - extent.first > best.last - best.first)) best = { ...extent, y };
          }
          return best;
        };
    """

    @Test("`代码` 不露反引号，用等宽的代码字体画在一块浅底上；深色卡片上浅底同样看得见")
    func inlineCodeUsesCodeFontOnChip() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const measure = async (bg, text) => {
              await mc.drafts.update({ colors: { bg, text } });
              const [page] = await renderDraft("`iiii`");
              const background = pixel(page, 4, 4);
              const [item] = textItems(page);
              const row = widestRow(page, item, background);
              return {
                texts: textItems(page).map(lineText),
                code: item.runs.every((run) => run.code),
                width: row.last - row.first,
                chip: pixel(page, row.first + 2, row.y),
                background,
              };
            };
            return [await measure("#ffffff", "#202938"), await measure("#111111", "#f5f5f5")];
        """) as? [[String: Any]]
        await harness.tearDown()

        let light = result?.first ?? [:]
        let dark = result?.last ?? [:]
        #expect(light["texts"] as? [String] == ["iiii"], "反引号不画出来")
        #expect(light["code"] as? Bool == true)
        #expect((light["width"] as? Double ?? 0) > 60, "等宽字体的 iiii 连同底块应比比例字体宽得多")
        for (label, sample) in [("浅色", light), ("深色", dark)] {
            let chip = sample["chip"] as? [Int] ?? []
            let background = sample["background"] as? [Int] ?? []
            let difference = zip(chip, background).map { abs($0 - $1) }.reduce(0, +)
            #expect(difference >= 12 && difference <= 90, "\(label)卡片：代码底块应是一块看得见的浅底，实际 \(chip) 对背景 \(background)")
        }
        #expect(harness.pageErrors == [])
    }

    @Test("比一整行还长的代码按字折行，不画出正文区")
    func longCodeWrapsInsideContent() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const [page] = await renderDraft("长代码：`const answer = computeTheAnswerToLifeTheUniverseAndEverything(input, options);`");
            const background = pixel(page, 4, 4);
            const { right } = page.contentBounds;
            return {
              lines: textItems(page).length,
              spill: textItems(page).map((item) => inkExtent(page, item.y + item.height / 2, background)?.last ?? 0).filter((last) => last > right + 1),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect((result?["lines"] as? Int ?? 0) >= 2)
        #expect(result?["spill"] as? [Double] == [], "有行画出了正文区右边界")
        #expect(harness.pageErrors == [])
    }

    @Test("~~删除线~~ 不露波浪号，画一条横穿文字的线；「好开心~~ 明天见~~」这类波浪号照常显示")
    func strikethroughDrawsLineThroughText() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const [page] = await renderDraft("~~删除 strike~~");
            const [item] = textItems(page);
            const background = pixel(page, 4, 4);
            const whole = widestRow(page, item, background);
            let throughRows = 0;
            for (let y = item.y; y < item.y + item.height; y += 0.5) {
              const data = page.canvas.getContext("2d").getImageData(Math.round(whole.first * 2), Math.round(y * 2), Math.round((whole.last - whole.first) * 2), 1).data;
              let ink = 0;
              for (let i = 0; i < data.length; i += 4) {
                if (Math.abs(data[i] - background[0]) + Math.abs(data[i + 1] - background[1]) + Math.abs(data[i + 2] - background[2]) > 60) ink += 1;
              }
              if (ink >= data.length / 4 * 0.97) throughRows += 1;
            }
            const [wave] = await renderDraft("好开心~~ 明天见~~");
            return {
              texts: textItems(page).map(lineText),
              struck: item.runs.every((run) => run.strike),
              throughRows,
              wave: textItems(wave).map(lineText),
              waveStruck: textItems(wave).some((line) => line.runs.some((run) => run.strike)),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["texts"] as? [String] == ["删除 strike"], "波浪号不画出来")
        #expect(result?["struck"] as? Bool == true)
        let rows = result?["throughRows"] as? Int ?? 0
        #expect(rows >= 2 && rows <= 8, "应有一条横穿全部文字的细线，实际 \(rows) 行")
        #expect(result?["wave"] as? [String] == ["好开心~~ 明天见~~"])
        #expect(result?["waveStruck"] as? Bool == false)
        #expect(harness.pageErrors == [])
    }

    @Test("设置里有代码字体选单：默认跟随主题（白是 JetBrains Mono），每项用自己的字体；选别的打包字体后第一次出图就是最终画面并随稿子保存")
    func codeFontPicker() async throws {
        try BundledFontsTests.requireBundledFonts()
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "代码 `const answer = 42;` 与正文混排。".repeat(8) });
            const button = fontButton("代码字体");
            const defaults = [button.textContent.trim(), (await mc.drafts.current()).fonts.code];
            const before = await cardHashes();
            const { code: choices } = await mc.fonts.list();
            const idOf = (option) => choices.find((font) => font.label === optionLabel(option))?.id;
            button.click();
            const options = [...fontList(button).querySelectorAll('[role="option"]')];
            await document.fonts.ready;
            const fonts = await manifestFonts();
            const notOwnFont = options.filter((option) => {
              const bundled = fonts.find((font) => font.id === idOf(option));
              if (!bundled) return !option.style.fontFamily;
              return !getComputedStyle(option).fontFamily.includes(bundled.family) || !document.fonts.check(`16px "${bundled.family}"`, option.textContent);
            }).map(idOf);
            button.click();
            const rendered = nextRender();
            pickFont(button, "Fira Code");
            await rendered;
            const first = await cardHashes();
            await document.fonts.ready;
            await mc.render.refresh();
            const family = fonts.find((font) => font.id === "fira-code").family;
            const saved = (await mc.drafts.current()).fonts.code;
            const unknown = (await mc.drafts.update({ fonts: { code: "no-such-font" } })).fonts.code;
            const restored = (await mc.drafts.update({ fonts: { code: saved } })).fonts.code;
            return {
              defaults,
              labels: options.map(optionLabel),
              ids: choices.map((font) => font.id),
              notOwnFont,
              changed: first !== before,
              stable: first === await cardHashes(),
              loaded: document.fonts.check(`400 31px "${family}"`, "const answer = 42;"),
              saved,
              unknown,
              restored,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["defaults"] as? [String] == ["跟随主题", "theme"])
        #expect(result?["labels"] as? [String] == ["跟随主题", "JetBrains Mono", "IBM Plex Mono", "Fira Code", "Menlo"])
        #expect(result?["ids"] as? [String] == ["theme", "jetbrains-mono", "ibm-plex-mono", "fira-code", "code-menlo"])
        #expect(result?["notOwnFont"] as? [String] == [])
        #expect(result?["changed"] as? Bool == true)
        #expect(result?["stable"] as? Bool == true, "第一次出图用的是回退字体，分页与最终画面不一致")
        #expect(result?["loaded"] as? Bool == true)
        #expect(result?["saved"] as? String == "fira-code")
        #expect(result?["unknown"] as? String == "theme")
        #expect(result?["restored"] as? String == "fira-code")
        #expect(harness.pageErrors == [])
    }

    @Test("复制纯文本去掉反引号与删除线标记（代码里的字原样保留），长文里画成代码与删除线")
    func plainTextAndArticleDropMarkers() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create();
            return {
              plain: await mc.render.plainText("用`代码`和~~删除线~~，`a**b**` 与 **粗** 好开心~~ 明天见~~"),
              article: await mc.render.articleHtml("用`代码`和~~删除线~~"),
            };
        """) as? [String: String]
        await harness.tearDown()

        #expect(result?["plain"] == "用代码和删除线，a**b** 与 粗 好开心~~ 明天见~~")
        #expect(result?["article"] == "<p>用<code>代码</code>和<s>删除线</s></p>")
        #expect(harness.pageErrors == [])
    }
}
