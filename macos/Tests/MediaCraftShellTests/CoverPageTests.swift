import Foundation
import Testing

/// 封面、结尾页与分页质量（v4/06）：首页做封面的开关、标题自适应、底图上的字看得清、[[结尾]]、胶片上的字数与填满、末页回填。
@MainActor
struct CoverPageTests {
    static let structures = CardStructureTests.structures

    /// MarkdownStructureTests 的出图小工具，外加：纯色 PNG 文件、按图片编号取图、读一行字的对比度。
    static let setup = MarkdownStructureTests.setup + """
        window.mc = mc; // 后面分开执行的脚本也能用
        window.pngFile = (name, color, width = 400, height = 300) => new Promise((resolve) => {
          const canvas = Object.assign(document.createElement("canvas"), { width, height });
          const context = canvas.getContext("2d");
          context.fillStyle = color;
          context.fillRect(0, 0, width, height);
          canvas.toBlob((blob) => resolve(new File([blob], name, { type: "image/png" })), "image/png");
        });
        window.until = async (check, timeout = 10000) => {
          const deadline = Date.now() + timeout;
          while (!(await check())) {
            if (Date.now() > deadline) throw new Error(`等不到：${check}`);
            await new Promise((resolve) => setTimeout(resolve, 50));
          }
        };
        window.renderPages = async () => {
          const pages = await mc.render.pages();
          const canvases = await mc.render.canvases();
          return pages.map((page, index) => ({ ...page, canvas: canvases[index] }));
        };
        window.hashOf = async (canvas) => {
          const data = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
          return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", data)), (byte) => byte.toString(16).padStart(2, "0")).join("");
        };
        const channel = (value) => {
          const s = value / 255;
          return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
        };
        window.luminance = ([r, g, b]) => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
        window.contrast = (a, b) => {
          const [high, low] = [luminance(a), luminance(b)].sort((x, y) => y - x);
          return (high + 0.05) / (low + 0.05);
        };
        // 一行字所在框里：出现最多的颜色当底，和它反差最大的颜色当字，返回两者的对比度
        window.lineContrast = (canvas, item) => {
          const box = [item.x, item.y, Math.min(item.width, 380), item.height].map((value) => Math.round(value * 2));
          const data = canvas.getContext("2d").getImageData(...box).data;
          const counts = new Map();
          for (let i = 0; i < data.length; i += 4) {
            const key = `${data[i]},${data[i + 1]},${data[i + 2]}`;
            counts.set(key, (counts.get(key) || 0) + 1);
          }
          const colors = [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([key]) => key.split(",").map(Number));
          return Math.max(...colors.map((color) => contrast(colors[0], color)));
        };
    """

    static let body = (1...14).map { "第 \($0) 段：把写好的内容排成卡片，读起来一张一张往后翻。" }.joined(separator: "\n\n")

    @Test("首页做封面：默认关、旧稿不变；开了之后第 1 张是封面（标题取标题框、署名），正文从第 2 张起按内页排；关掉回到原来的像素")
    func coverToggleAddsCoverPage() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            await mc.drafts.update({ markdown: body, title: "把卡片排好的三个办法" });
            const before = await renderPages();
            const defaults = (await mc.drafts.current()).cover;
            await mc.drafts.update({ cover: { enabled: true, subtitle: "从写到发只要一分钟" } });
            const on = await renderPages();
            const titleOnly = on[0].items.filter((item) => item.blockType === "title").map((item) => item.text).join("");
            const subtitle = on[0].items.filter((item) => item.blockType === "subtitle").map((item) => item.text).join("");
            await mc.drafts.update({ title: "" });
            const fallback = (await renderPages())[0].items.filter((item) => item.blockType === "title").map((item) => item.text).join("");
            await mc.drafts.update({ title: "把卡片排好的三个办法", cover: { enabled: false } });
            const off = await renderPages();
            const same = [];
            for (const [index, page] of before.entries()) same.push((await hashOf(page.canvas)) === (await hashOf(off[index].canvas)));
            return {
              defaults, titleOnly, subtitle, fallback,
              beforeRoles: before.map((page) => page.role), onRoles: on.map((page) => page.role),
              onHeaders: on.map((page) => page.header), beforeFirstTop: before[0].contentBounds.top,
              bodyTops: on.slice(1).map((page) => page.contentBounds.top), innerTop: before[1].contentBounds.top,
              firstBodyText: on[1].items.find((item) => item.kind === "text")?.text ?? "",
              beforeFirstText: before[0].items.find((item) => item.kind === "text")?.text ?? "",
              offCount: off.length, beforeCount: before.length, same,
              coverSources: on[0].items.map((item) => item.source),
            };
        """, arguments: ["body": Self.body]) as? [String: Any]
        await harness.tearDown()

        #expect(result?["defaults"] as? [String: AnyHashable] == ["enabled": false, "subtitle": "", "image": NSNull()])
        let beforeRoles = result?["beforeRoles"] as? [String] ?? []
        let onRoles = result?["onRoles"] as? [String] ?? []
        #expect(beforeRoles.allSatisfy { $0 == "body" })
        #expect(onRoles.first == "cover" && onRoles.dropFirst().allSatisfy { $0 == "body" })
        #expect(result?["titleOnly"] as? String == "把卡片排好的三个办法")
        #expect(result?["subtitle"] as? String == "从写到发只要一分钟")
        #expect(result?["fallback"] as? String == "第 1 段：把写好的内容排成卡片，读起来一张一张往后翻。", "标题框空着时取正文第一行")
        #expect((result?["onHeaders"] as? [Bool])?.first == true, "封面有署名")
        #expect((result?["onHeaders"] as? [Bool])?.dropFirst().allSatisfy { !$0 } == true, "正文页都按内页排，不再有首页页眉")
        let innerTop = result?["innerTop"] as? Double ?? -1
        #expect((result?["bodyTops"] as? [Double])?.allSatisfy { $0 == innerTop } == true)
        #expect(result?["firstBodyText"] as? String == result?["beforeFirstText"] as? String, "正文从第 2 张开始")
        #expect((result?["coverSources"] as? [Any])?.allSatisfy { $0 is NSNull } == true, "封面上的字不在正文里")
        #expect(result?["offCount"] as? Int == result?["beforeCount"] as? Int)
        #expect((result?["same"] as? [Bool])?.allSatisfy { $0 } == true, "关掉封面后每一张都和原来的像素一样")
        #expect(harness.pageErrors == [])
    }

    @Test("封面标题按实测宽度缩放：短标题用大字一行，长标题不超过结构给的行数（三到四行）、不小于下限、末行截断；英文单词不拆开；字不出版心")
    func coverTitleFitsBounds() async throws {
        let harness = ShellHarness()
        try await harness.load()
        var results: [String: [String: Any]] = [:]
        _ = try await harness.evaluate(Self.setup + "await mc.drafts.update({ markdown: '正文', cover: { enabled: true } });")
        for structure in Self.structures {
            results[structure] = try await harness.evaluate("""
                const titleOf = async (title) => {
                  await mc.drafts.update({ title });
                  const { pages, canvases } = await mc.render.offscreen({ structure });
                  const page = pages[0];
                  const lines = page.items.filter((item) => item.blockType === "title");
                  // 标题几行之外的地方（版心左右）有没有字的颜色；底色取这一行最左边的像素（撞色的封面是满版强调色）
                  const data = canvases[0].getContext("2d").getImageData(0, 0, canvases[0].width, canvases[0].height).data;
                  let outside = 0;
                  for (const line of lines) {
                    const row = Math.round((line.y + line.height / 2) * 2);
                    const paper = Array.from(data.slice(row * canvases[0].width * 4 + 8, row * canvases[0].width * 4 + 11));
                    for (let y = Math.round(line.y * 2); y < Math.round((line.y + line.height) * 2); y += 2) {
                      for (const x of [Math.round(page.contentBounds.left * 2) - 6, Math.round(page.contentBounds.right * 2) + 4]) {
                        const at = (y * canvases[0].width + x) * 4;
                        if (Math.abs(data[at] - paper[0]) + Math.abs(data[at + 1] - paper[1]) + Math.abs(data[at + 2] - paper[2]) > 60) outside += 1;
                      }
                    }
                  }
                  return { sizes: lines.map((line) => line.fontSize), texts: lines.map((line) => line.text), outside, maxLines: MediaCraftEngine.cardStructures[structure].cover.title.maxLines };
                };
                return {
                  short: await titleOf("读书"),
                  long: await titleOf("一个非常非常长的标题：用来检验封面标题在放不下的时候会自动缩小字号，最多排三行，再放不下就在最后截断加上省略号"),
                  word: await titleOf("Superintelligence 读书法"),
                };
            """, arguments: ["structure": structure]) as? [String: Any]
        }
        await harness.tearDown()

        for structure in Self.structures {
            let result = results[structure] ?? [:]
            let short = result["short"] as? [String: Any] ?? [:]
            let long = result["long"] as? [String: Any] ?? [:]
            let word = result["word"] as? [String: Any] ?? [:]
            #expect((short["texts"] as? [String]) == ["读书"], "\(structure)：短标题一行")
            #expect(((short["sizes"] as? [Double])?.first ?? 0) >= 96, "\(structure)：短标题用大字")
            let longTexts = long["texts"] as? [String] ?? []
            #expect((1...(long["maxLines"] as? Int ?? 3)).contains(longTexts.count), "\(structure)：长标题最多 \(long["maxLines"] ?? 3) 行")
            #expect((long["sizes"] as? [Double])?.allSatisfy { $0 >= 56 } == true, "\(structure)：字号不小于下限")
            #expect(longTexts.last?.hasSuffix("…") == true, "\(structure)：放不下的在末行截断")
            #expect((word["texts"] as? [String])?.contains { $0.contains("Superintelligence") } == true, "\(structure)：英文单词不从中间拆开")
            for case let item as [String: Any] in [short, long, word] {
                #expect(item["outside"] as? Int == 0, "\(structure)：标题的字出了版心")
            }
        }
        #expect(harness.pageErrors == [])
    }

    @Test("封面底图：图放在结构给的位置（实况也行），最坏的纯黑、纯白、中灰底图上，标题与副标题的对比度都够")
    func coverImageKeepsTextReadable() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            await mc.drafts.update({ markdown: "正文", title: "封面上的字要看得清", cover: { enabled: true, subtitle: "副标题也一样" } });
            const ids = await mc.media.import([await pngFile("black.png", "#000000"), await pngFile("white.png", "#ffffff"), await pngFile("gray.png", "#808080")]);
            const report = [];
            for (const theme of await mc.themes.list()) {
              for (const id of ids) {
                await mc.drafts.update({ theme: theme.id, cover: { image: id } });
                const [cover] = await renderPages();
                const image = cover.items.find((item) => item.kind === "image");
                const hit = cover.imageHits[0];
                const texts = cover.items.filter((item) => item.kind === "text");
                report.push({
                  theme: theme.id, image: (await mc.media.get(id)).name,
                  drawn: Boolean(image && hit && hit.cover && hit.source === null && image.imageId === id),
                  contrasts: texts.map((item) => ({ kind: item.blockType, ratio: lineContrast(cover.canvas, item) })),
                });
              }
            }
            return report;
        """) as? [[String: Any]]
        await harness.tearDown()

        #expect(result?.count == ThemeTests.ids.count * 3)
        for entry in result ?? [] {
            let label = "\(entry["theme"] ?? "")・\(entry["image"] ?? "")"
            #expect(entry["drawn"] as? Bool == true, "\(label)：底图画上了，点选框标着 cover")
            let contrasts = entry["contrasts"] as? [[String: Any]] ?? []
            #expect(Set(contrasts.compactMap { $0["kind"] as? String }) == ["title", "subtitle"], "\(label)")
            for item in contrasts {
                #expect((item["ratio"] as? Double ?? 0) >= 3, "\(label) 的\(item["kind"] ?? "")对比度不够：\(item["ratio"] ?? 0)")
            }
        }
        #expect(harness.pageErrors == [])
    }

    @Test("[[结尾]]：单独一行才算，之后的内容排成结尾页（居中、上下居中、最后是署名）；不进纯文本与长文；只认第一个")
    func endPageCollectsTrailingContent() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const parse = async (text) => (await mc.engine.parse(text)).blocks.map((block) => block.type);
            const draft = "正文第一段。\\n\\n  [[结尾]]  \\n\\n关注我，下期讲封面\\n\\n**第 3 期**";
            const pages = await renderDraft(draft);
            const end = pages[pages.length - 1];
            const texts = textItems(end);
            // 每行字的墨迹左右留白应差不多（居中）
            const inkEdges = (item) => {
              const data = end.canvas.getContext("2d").getImageData(0, Math.round(item.y * 2), end.canvas.width, Math.round(item.height * 2)).data;
              let first = Infinity;
              let last = -1;
              for (let i = 0; i < data.length; i += 4) {
                if (Math.abs(data[i] - 255) + Math.abs(data[i + 1] - 255) + Math.abs(data[i + 2] - 255) < 60) continue;
                const x = (i / 4) % end.canvas.width;
                first = Math.min(first, x);
                last = Math.max(last, x);
              }
              return [first / 2, 864 - last / 2];
            };
            const top = Math.min(...end.items.map((item) => item.y));
            const onlySignature = await renderDraft("正文。\\n\\n[[结尾]]");
            const twice = await renderDraft("正文。\\n\\n[[结尾]]\\n\\n谢谢\\n\\n[[结尾]]\\n\\n再见");
            return {
              blocks: await parse(draft),
              literal: [await parse("前 [[结尾]] 后"), await parse("[[ 结尾 ]]"), await parse("［［结尾］］")],
              plain: await mc.render.plainText(draft),
              article: await mc.render.articleHtml(draft),
              roles: pages.map((page) => page.role),
              header: end.header,
              texts: texts.map((item) => item.text),
              margins: texts.map(inkEdges),
              topGap: top - end.contentBounds.top,
              bodyTexts: textItems(pages[0]).map((item) => item.text),
              signatureOnly: { roles: onlySignature.map((page) => page.role), items: onlySignature.at(-1).items.length, header: onlySignature.at(-1).header },
              twice: twice.flatMap((page) => textItems(page).map((item) => item.text)),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["blocks"] as? [String] == ["paragraph", "endPage", "paragraph", "paragraph"])
        #expect(result?["literal"] as? [[String]] == [["paragraph"], ["paragraph"], ["paragraph"]], "写在文字中间、带空格、全角方括号都不算")
        #expect(result?["plain"] as? String == "正文第一段。\n\n关注我，下期讲封面\n\n第 3 期")
        #expect(result?["article"] as? String == "<p>正文第一段。</p><p>关注我，下期讲封面</p><p><strong>第 3 期</strong></p>")
        #expect(result?["roles"] as? [String] == ["body", "end"])
        #expect(result?["header"] as? Bool == true, "结尾页有署名")
        #expect(result?["texts"] as? [String] == ["关注我，下期讲封面", "第 3 期"])
        #expect(result?["bodyTexts"] as? [String] == ["正文第一段。"])
        for case let margins as [Double] in result?["margins"] as? [Any] ?? [] {
            #expect(abs(margins[0] - margins[1]) <= 6, "结尾页的字居中：左右留白 \(margins)")
        }
        #expect((result?["topGap"] as? Double ?? 0) > 200, "内容整体上下居中，上面留出大片空白")
        let signatureOnly = result?["signatureOnly"] as? [String: Any]
        #expect(signatureOnly?["roles"] as? [String] == ["body", "end"])
        #expect(signatureOnly?["items"] as? Int == 0, "[[结尾]] 后面没写东西时，结尾页只有署名")
        #expect(signatureOnly?["header"] as? Bool == true)
        #expect(result?["twice"] as? [String] == ["正文。", "谢谢", "再见"], "第二个 [[结尾]] 不画，也不另起结尾页")
        #expect(harness.pageErrors == [])
    }

    @Test("「插入」菜单与「/」菜单都能插入 [[结尾]]，单独占一行")
    func menusInsertEndPage() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(LivePreviewEditorTests.helpers + """
            await mc.drafts.create({ markdown: "第一段" });
            await mc.editor.select(3);
            ui.expand("插入", { within: "文字样式" });
            ui.click("结尾页", { within: "文字样式" });
            const fromMenu = await markdown();
            await setBody("第一段\\n");
            await mc.editor.select("第一段\\n".length);
            await type("/");
            await type("jw");
            const menu = document.querySelector('[role="listbox"][aria-label="快速插入"]');
            const filtered = [...menu.querySelectorAll('[role="option"]')].map(ui.name);
            press("Enter");
            await until(() => !visible(menu));
            return { fromMenu, filtered, fromSlash: await markdown() };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["fromMenu"] as? String == "第一段\n[[结尾]]\n")
        #expect(result?["filtered"] as? [String] == ["结尾页", "结尾引导"], "拼音缩写 jw 筛出「结尾页」（片段「结尾引导」也匹配，排在后面）")
        #expect(result?["fromSlash"] as? String == "第一段\n[[结尾]]\n")
        #expect(harness.pageErrors == [])
    }

    @Test("胶片上每张标字数与填满多少：偏空（不到四分之一）、偏挤（超过 300 字）换色并在悬停说明里写明；封面、结尾页只写名字")
    func filmstripShowsCharsAndFill() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let dense = String(repeating: "密密麻麻地写满一整张卡片的字。", count: 30)
        let ready = try await harness.evaluate(Self.setup + """
            await mc.drafts.update({
              fontSize: 24, lineHeight: 1.4, title: "胶片",
              markdown: `第一张只有一行。\\n\\n[[分页]]\\n\\n${dense}\\n\\n[[分页]]\\n\\n最后一张也只有一行。\\n\\n[[结尾]]\\n\\n谢谢`,
              cover: { enabled: true },
            });
            return (await mc.render.pages()).length;
        """, arguments: ["dense": dense]) as? Int ?? 0
        let shown = try await harness.waitForPage("document.querySelectorAll('#filmstrip .film-meter').length === \(ready)")
        let result = try await harness.evaluate("""
            const pages = await mc.render.pages();
            return [...document.querySelectorAll("#filmstrip .film-thumb")].map((thumb, index) => {
              const meter = thumb.querySelector(".film-meter");
              return {
                label: thumb.getAttribute("aria-label"), note: thumb.title, density: meter.dataset.density,
                count: meter.querySelector(".film-meter-count").textContent, chars: pages[index].chars, fill: pages[index].fill,
                bar: getComputedStyle(meter.querySelector(".film-meter-bar")).transform,
              };
            });
        """) as? [[String: Any]]
        await harness.tearDown()

        #expect(shown, "胶片上每张都有字数与填满")
        let thumbs = result ?? []
        #expect(thumbs.map { $0["density"] as? String ?? "" } == ["cover", "sparse", "dense", "sparse", "end"])
        #expect(thumbs.first?["count"] as? String == "封面")
        #expect(thumbs.last?["count"] as? String == "结尾")
        #expect(thumbs.map { $0["label"] as? String ?? "" } == (1...5).map { "第 \($0) 张" }, "可访问名称还是「第 N 张」")
        for thumb in thumbs.dropFirst().dropLast() {
            #expect(thumb["count"] as? String == "\(thumb["chars"] as? Int ?? -1)")
            #expect((thumb["note"] as? String)?.contains("\(thumb["chars"] as? Int ?? -1) 字 · 填满") == true)
        }
        #expect((thumbs[1]["note"] as? String)?.contains("偏空") == true)
        #expect((thumbs[2]["note"] as? String)?.contains("偏挤") == true)
        #expect((thumbs[2]["chars"] as? Int ?? 0) > 300)
        #expect((thumbs[1]["fill"] as? Double ?? 1) < 0.25)
        #expect(harness.pageErrors == [])
    }

    @Test("末页太短时从前一页回填：整块挪、不把标题留在页底；挪不了整块时从一行的开头断；[[分页]] 换出来的末页不动")
    func shortLastPageBackfills() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const paragraph = (index) => `第 ${index} 段：这一段写得不长不短，大约占三行，用来检验末页太短时能不能从前一页整段挪下来。`;
            const cases = [];
            for (let count = 8; count <= 26; count += 1) {
              const blocks = Array.from({ length: count }, (_, index) => (index % 5 === 4 ? `## 第 ${index} 节\\n\\n${paragraph(index + 1)}` : paragraph(index + 1)));
              const markdown = blocks.join("\\n\\n");
              const pages = await renderDraft(markdown);
              if (pages.length < 2) continue;
              const last = pages[pages.length - 1];
              const previous = pages[pages.length - 2];
              const firstLine = textItems(last)[0];
              // 前一页页底空着的高度：正常换页时放不下下一行才换，空不出一行半；空得多就是回填挪走了内容
              const free = previous.contentBounds.bottom - Math.max(...previous.items.map((item) => item.y + item.height));
              // 一块的开头：标题从井号后的文字算，段落从第一行的文字算
              const starts = (await mc.engine.parse(markdown)).blocks.map((block) => (block.contentSource ?? block.lines?.[0].contentSource ?? block.source)[0]);
              cases.push({
                count, fill: last.fill, previousFill: previous.fill,
                moved: free > firstLine.height * 1.5,
                startsBlock: starts.includes(firstLine.source[0]),
                endsWithHeading: pages.slice(0, -1).some((page) => ["h1", "h2", "h3"].includes(page.items[page.items.length - 1]?.blockType)),
              });
            }
            const lines = Array.from({ length: 30 }, (_, index) => `第 ${index + 1} 行字。`).join("\\n");
            const single = await renderDraft(lines);
            const singleFirst = textItems(single.at(-1))[0];
            const forced = await renderDraft(`${paragraph(1)}\\n\\n${paragraph(2)}\\n\\n[[分页]]\\n\\n最后一行。`);
            return {
              cases,
              single: { fill: single.at(-1).fill, pages: single.length, lineStart: lines[singleFirst.source[0] - 1] === "\\n" },
              forced: { pages: forced.length, fill: forced.at(-1).fill, text: textItems(forced.at(-1)).map((item) => item.text) },
            };
        """) as? [String: Any]
        await harness.tearDown()

        let cases = result?["cases"] as? [[String: Any]] ?? []
        #expect(cases.count >= 10)
        #expect(cases.filter { $0["moved"] as? Bool == true }.count >= 3, "这组稿子里应有几篇是回填过的")
        for entry in cases {
            let label = "\(entry["count"] ?? 0) 段"
            #expect((entry["fill"] as? Double ?? 0) >= 0.25, "\(label)：末页只用了 \(entry["fill"] ?? 0)")
            #expect((entry["previousFill"] as? Double ?? 0) >= 0.25, "\(label)：前一页被挪得太空")
            if entry["moved"] as? Bool == true {
                #expect(entry["startsBlock"] as? Bool == true, "\(label)：回填整块挪，末页从一块的开头起")
            }
            #expect(entry["endsWithHeading"] as? Bool == false, "\(label)：有一页以标题结尾")
        }
        let single = result?["single"] as? [String: Any]
        #expect((single?["pages"] as? Int ?? 0) >= 2)
        #expect((single?["fill"] as? Double ?? 0) >= 0.25, "只有一段时按行回填")
        #expect(single?["lineStart"] as? Bool == true, "从原文一行的开头断开")
        let forced = result?["forced"] as? [String: Any]
        #expect(forced?["text"] as? [String] == ["最后一行。"], "[[分页]] 换出来的末页不回填")
        #expect((forced?["fill"] as? Double ?? 1) < 0.25)
        #expect(harness.pageErrors == [])
    }

    @Test("App API：cover 字段的默认值、只改给了的几项、校验；换稿子再回来还在；pages() 带 role / fill / chars；舞台上不能拖封面的底图")
    func appApiCoverFields() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const errors = [];
            const attempt = async (patch) => {
              try {
                await mc.drafts.update(patch);
                errors.push("");
              } catch (error) {
                errors.push(`${error.name}:${error.message}`);
              }
            };
            await attempt({ cover: { enabled: "yes" } });
            await attempt({ cover: { subtitle: 3 } });
            await attempt({ cover: { image: "nope" } });
            await attempt({ cover: { color: "#fff" } });
            let created = "";
            const count = (await mc.drafts.list()).length;
            try {
              await mc.drafts.create({ cover: { image: "nope" } });
            } catch (error) {
              created = `${error.message}|${(await mc.drafts.list()).length === count}`;
            }
            const [photo] = await mc.media.import([await pngFile("photo.png", "#1971c2")]);
            const merged = (await mc.drafts.update({ markdown: `正文第一段。\\n\\n[[image:${photo}]]\\n\\n第二段。`, cover: { enabled: true } })).cover;
            const subtitled = (await mc.drafts.update({ cover: { subtitle: "副标题", image: photo } })).cover;
            const pages = await mc.render.pages();
            const draftId = (await mc.drafts.current()).id;
            await mc.drafts.create();
            await mc.drafts.open(draftId);
            const reopened = (await mc.drafts.current()).cover;
            // 正文里的那张图照样能挪；封面上同一张图的点选框不接拖动
            const bodyPage = pages.findIndex((page) => page.imageHits.some((hit) => !hit.cover));
            const moved = await mc.media.move(photo, { page: bodyPage, target: 0 });
            const coverBoxes = document.querySelectorAll(".stage-card:first-child .stage-media").length;
            const bodyBoxes = document.querySelectorAll(".stage-media").length;
            return {
              errors, created, merged, subtitled, reopened, moved, coverBoxes, bodyBoxes,
              summaries: pages.map(({ role, header, fill, chars, imageHits }) => ({ role, header, fill, chars, covers: imageHits.map((hit) => hit.cover) })),
            };
        """) as? [String: Any]
        await harness.tearDown()

        let errors = result?["errors"] as? [String] ?? []
        #expect(errors.count == 4)
        #expect(errors[0].hasPrefix("TypeError:"))
        #expect(errors[1].hasPrefix("TypeError:"))
        #expect(errors[2] == "Error:这篇稿子里没有这张图：nope")
        #expect(errors[3].hasPrefix("TypeError:") && errors[3].contains("color"))
        #expect(result?["created"] as? String == "这篇稿子里没有这张图：nope|true", "create 先校验，不留下半截的新稿")
        let merged = result?["merged"] as? [String: AnyHashable]
        #expect(merged == ["enabled": true, "subtitle": "", "image": NSNull()])
        let subtitled = result?["subtitled"] as? [String: AnyHashable]
        #expect(subtitled?["enabled"] as? Bool == true, "只改给了的几项")
        #expect(subtitled?["subtitle"] as? String == "副标题")
        #expect(result?["reopened"] as? [String: AnyHashable] == subtitled, "封面设置随稿子存")
        let summaries = result?["summaries"] as? [[String: Any]] ?? []
        #expect(summaries.first?["role"] as? String == "cover")
        #expect(summaries.first?["header"] as? Bool == true)
        #expect(summaries.first?["fill"] is NSNull, "封面没有填满多少")
        #expect(summaries.first?["covers"] as? [Bool] == [true])
        #expect((summaries.first?["chars"] as? Int ?? 0) > 0)
        #expect(summaries.dropFirst().allSatisfy { ($0["fill"] as? Double).map { (0...1).contains($0) } == true && $0["role"] as? String == "body" })
        #expect(summaries.dropFirst().flatMap { $0["covers"] as? [Bool] ?? [] }.allSatisfy { !$0 })
        #expect(result?["moved"] as? Bool == true)
        #expect(result?["coverBoxes"] as? Int == 0, "封面的底图在舞台上不能点选拖动")
        #expect((result?["bodyBoxes"] as? Int ?? 0) >= 1)
        #expect(harness.pageErrors == [])
    }

    @Test("检查器「封面」：开关、副标题、从这篇的图里挑底图、另传一张只给封面用的图（不插进正文）")
    func inspectorControlsCover() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            const [photo] = await mc.media.import([await pngFile("风景.png", "#2f9e44")]);
            await mc.drafts.update({ title: "检查器" });
            const hiddenBefore = document.querySelector("[data-cover-fields]").hidden;
            ui.click("首页做封面");
            const subtitle = document.querySelector("#coverSubtitleInput");
            subtitle.value = "从检查器改的副标题";
            subtitle.dispatchEvent(new Event("input", { bubbles: true }));
            ui.click("封面底图：图片 风景.png");
            const picked = (await mc.render.pages())[0];
            const afterPick = (await mc.drafts.current()).cover;
            const input = ui.find("上传封面底图");
            const transfer = new DataTransfer();
            transfer.items.add(await pngFile("只给封面.png", "#e8590c"));
            input.files = transfer.files;
            input.dispatchEvent(new Event("change", { bubbles: true }));
            await until(async () => (await mc.drafts.current()).cover.image !== photo);
            const uploaded = (await mc.drafts.current());
            const uploadedName = (await mc.media.get(uploaded.cover.image))?.name;
            ui.click("封面不用底图");
            const none = (await mc.drafts.current()).cover.image;
            ui.click("首页做封面");
            return {
              hiddenBefore, hiddenAfter: document.querySelector("[data-cover-fields]").hidden,
              afterPick, pickedRole: picked.role, pickedImage: picked.imageHits[0]?.imageId === photo,
              uploadedName, inText: uploaded.markdown.includes(uploaded.cover.image), none,
              pressed: document.querySelector('#coverImages [aria-pressed="true"]')?.getAttribute("aria-label"),
              final: (await mc.drafts.current()).cover.enabled,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["hiddenBefore"] as? Bool == true, "没开封面时只显示开关")
        let afterPick = result?["afterPick"] as? [String: Any]
        #expect(afterPick?["enabled"] as? Bool == true)
        #expect(afterPick?["subtitle"] as? String == "从检查器改的副标题")
        #expect(result?["pickedRole"] as? String == "cover")
        #expect(result?["pickedImage"] as? Bool == true)
        #expect(result?["uploadedName"] as? String == "只给封面.png")
        #expect(result?["inText"] as? Bool == false, "上传的底图不插进正文")
        #expect(result?["none"] is NSNull)
        #expect(result?["pressed"] as? String == "封面不用底图")
        #expect(result?["final"] as? Bool == false)
        #expect(result?["hiddenAfter"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("导出与发送带上封面和结尾页：按页序 01 是封面、最后一张是结尾页")
    func sendIncludesCoverAndEndPages() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let roles = try await harness.evaluate("""
            await window.mediacraft.drafts.create({ markdown, title: "发送封面", caption: "封面与结尾页一起发", cover: { enabled: true } });
            return (await window.mediacraft.render.pages()).map((page) => page.role);
        """, arguments: ["markdown": SendToIPhoneTests.markdown + "\n\n[[结尾]]\n\n关注我"]) as? [String] ?? []
        _ = try await harness.evaluate("ui.click('发送到 iPhone')")
        try await waitUntil(timeout: .seconds(20)) { !harness.sender.batches.isEmpty }
        let files = harness.sender.batches.first ?? []
        // 发送这件事收完尾（提示卡出来）再导出：一次只做一件
        _ = try await harness.waitForPage("document.querySelector('#outputActivity').dataset.state === 'success'")
        let single = try await harness.evaluate("return (await window.mediacraft.output.exportPng(0)).filename") as? String
        await harness.tearDown()

        #expect(roles.first == "cover" && roles.last == "end")
        #expect(files.map(\.lastPathComponent) == (1...roles.count).map { String(format: "%02d.png", $0) })
        #expect(files.map(SendToIPhoneTests.pixelSize).allSatisfy { $0 == "1728x2304" })
        #expect(single == "发送封面-01.png", "单独导出封面")
        #expect(harness.pageErrors == [])
    }
}

/// 实况用例都挂在已串行的 SendLivePhotoTests 下：两个 WKWebView 同时解码视频会互相卡住。
@MainActor
extension SendLivePhotoTests {
    @Test("实况做封面底图：图框只到文字区上沿（视频盖不住字），舞台上播放，发送时第 1 张是 .pvt")
    func liveCoverSendsAsLivePhoto() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let prepared = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文第一段。", title: "实况封面", theme: "ink" });
            const id = await mc.media.insertLivePhoto(await liveFile(video), { at: 0, duration: 3 });
            await mc.drafts.update({ markdown: "正文第一段。", cover: { enabled: true, subtitle: "副标题", image: id } });
            const [cover] = await mc.render.pages();
            const hit = cover.imageHits[0];
            const textTop = Math.min(...cover.items.filter((item) => item.kind === "text").map((item) => item.y));
            await until(() => document.querySelector(".stage-card .stage-live"));
            return { live: hit?.live === true && hit.cover === true, wellBottom: hit.y + hit.height, textTop, pages: (await mc.render.pages()).length };
        """, arguments: ["video": Self.h264]) as? [String: Any]
        _ = try await harness.evaluate("""
            window.sendOutcome = "发送中";
            window.mediacraft.output.sendToIPhone().then(() => { sendOutcome = "ok"; }, (error) => { sendOutcome = error.message; });
        """)
        try await waitUntil(timeout: .seconds(90)) { !harness.sender.batches.isEmpty }
        let files = harness.sender.batches.first ?? []
        await harness.tearDown()

        #expect(prepared?["live"] as? Bool == true)
        #expect((prepared?["wellBottom"] as? Double ?? 9999) < (prepared?["textTop"] as? Double ?? 0), "视频的框在字的上面")
        #expect(files.map(\.lastPathComponent) == ["01.pvt", "02.png"])
        #expect(harness.pageErrors == [])
    }
}
