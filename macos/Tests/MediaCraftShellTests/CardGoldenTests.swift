import Foundation
import Testing

/// 卡片结构的像素基准：同一份写实的稿子，按主题注册表（`mediacraft.themes`）里的每个主题各出一套图，钉住第 1 页（署名页）
/// 与第 2 页（内页）的像素哈希、正文区、图片点选框与拖放落点，以及总页数。配色、字体、卡片结构都取主题自己的（打包字体），
/// 基准按主题 id 记（两个主题可以共用一种卡片结构，配色不同像素也不同）。
/// 版式有意改动后，先看过新图，再用 `RECORD_CARD_GOLDEN=1 macos/run-tests.sh --filter CardGolden` 重新录制，核对 fixture 的差异。
@MainActor
struct CardGoldenTests {
    static let fixture = ShellHarness.repoRoot.appendingPathComponent("macos/Tests/Fixtures/card-structures-golden.json")

    static let draft = """
        # 用 AI 读论文的三个习惯

        最近把读论文的流程换成了「先问再读」：让模型先讲清楚这篇论文要解决什么问题，再带着问题去读原文。三周下来，读得更快，也记得更牢。

        > 不要让模型替你读完，而是让它帮你决定先读哪一段。

        ## 习惯一：先问三个问题

        1. 它要解决什么问题？
        2. 用了哪些关键假设？
        - 证据够不够硬？

        把三个答案各写成一句话，再开始读正文。带着问题读，**每一段都知道自己在找什么**，也更容易发现 `baseline` 挑得太弱。

        [[image:single]]

        ## 习惯二：让模型找漏洞

        问它：「方法里最容易被忽略的假设是什么？」模型常能指出*实验设置里的问题*：{{bg:#fff3bf|基线够不够强}}，{{color:#d9480f|指标有没有挑过}}，{{underline:dashed|消融做没做}}。

        | 问题 | 看哪里 | 权重 |
        | --- | :---: | ---: |
        | 基线够强吗 | 实验表格 | 高 |
        | 指标挑过吗 | 附录与消融 | 中 |

        [[image:left|right|4x3]]

        ---

        ### 一个小提醒

        模型的总结再流畅，也只是二手信息。~~全信模型~~ 不可取，遇到关键结论一定回到原文核对 English words 和数字 2026。
        """

    /// 建稿、导入三张固定图片与头像，把稿子里的 single / left / right 换成导入后的图片编号。
    static let setup = """
        const mc = window.mediacraft;
        await mc.drafts.create();
        const png = (width, height, colors) => new Promise((resolve) => {
          const canvas = document.createElement("canvas");
          canvas.width = width;
          canvas.height = height;
          const context = canvas.getContext("2d");
          colors.forEach((color, index) => {
            context.fillStyle = color;
            context.fillRect((index % 2) * width / 2, Math.floor(index / 2) * height / 2, width / 2, height / 2);
          });
          canvas.toBlob(resolve, "image/png");
        });
        const file = async (name, width, height, colors) => new File([await png(width, height, colors)], name, { type: "image/png" });
        const imported = await mc.media.import([
          await file("single.png", 320, 240, ["#e03131", "#2f9e44", "#1971c2", "#f08c00"]),
          await file("left.png", 300, 300, ["#5f3dc4", "#0c8599", "#e8590c", "#495057"]),
          await file("right.png", 200, 300, ["#c2255c", "#66a80f", "#1864ab", "#fab005"]),
        ]);
        const idOf = {};
        for (const id of imported) idOf[(await mc.media.get(id)).name] = id;
        await mc.media.update(idOf["single.png"], { layout: { widthPercent: 80, align: "center" } });
        const avatar = await new Promise(async (resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.onerror = reject;
          reader.readAsDataURL(await file("avatar.png", 96, 96, ["#343a40", "#ced4da", "#ced4da", "#343a40"]));
        });
        await mc.profile.update({ name: "wuyoscar", handle: "", avatar });
        window.goldenMarkdown = draft
          .replace("[[image:single]]", `[[image:${idOf["single.png"]}]]`)
          .replace("[[image:left|right|4x3]]", `[[image:${idOf["left.png"]}|${idOf["right.png"]}|4x3]]`);
        window.imageNames = Object.fromEntries((await mc.media.list()).map((image) => [image.id, image.name]));
    """

    /// 主题注册表里的每个主题：id 与它的卡片结构
    static let themes = """
        return (await window.mediacraft.themes.list()).map(({ id, structure }) => ({ id, structure }));
    """

    /// 按这个主题出图：主题、它的配色与字体都经注册表取，不在测试里另抄一份。
    /// 主题的辅助色与衬底是三色规则推出来的（没单独调过，tunedColors 为空），和在主题面板里点选一样。
    static let script = """
        const mc = window.mediacraft;
        const theme = (await mc.themes.list()).find((item) => item.id === themeId);
        await mc.drafts.update({
          mode: "cards",
          theme: theme.id,
          colors: theme.colors,
          tunedColors: [],
          fonts: theme.fonts,
          fontSize: 34,
          lineHeight: 1.85,
          imageMaxHeight: 1048,
          markdown: goldenMarkdown,
        });
        const hex = (buffer) => Array.from(new Uint8Array(buffer), (byte) => byte.toString(16).padStart(2, "0")).join("");
        const round = (value) => Math.round(value * 100) / 100;
        const name = (id) => (id ? `${imageNames[id]} ` : "");
        const { pages: layout, canvases } = await mc.render.offscreen();
        const pages = [];
        for (const [index, page] of layout.slice(0, 2).entries()) {
          const canvas = canvases[index];
          const pixels = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
          const { left, top, right, bottom } = page.contentBounds;
          pages.push({
            sha256: hex(await crypto.subtle.digest("SHA-256", pixels)),
            bounds: [left, top, right, bottom],
            imageHits: page.imageHits.map((hit) => `${name(hit.imageId)}${round(hit.x)},${round(hit.y)} ${round(hit.width)}x${round(hit.height)} base ${round(hit.baseWidth)} max ${round(hit.maxWidth)} resize ${round(hit.resizeMaxWidth)} src ${hit.source[0]}-${hit.source[1]}`),
            dropTargets: page.dropTargets.map((target) => `${target.kind} ${name(target.imageId)}y ${round(target.y)} h ${round(target.height)} src ${target.source[0]}-${target.source[1]}`),
          });
        }
        return JSON.stringify({ pageCount: layout.length, structure: layout[0].structure, pages });
    """

    @Test("每个主题的卡片结构出图与基准一致：署名页与内页的像素、正文区、图片点选框、拖放落点与总页数")
    func structuresMatchGolden() async throws {
        try BundledFontsTests.requireBundledFonts()
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(Self.setup, arguments: ["draft": Self.draft])
        let themes = (try await harness.evaluate(Self.themes) as? [[String: String]] ?? []).compactMap { theme in
            theme["id"].flatMap { id in theme["structure"].map { (id: id, structure: $0) } }
        }
        #expect(themes.map(\.id) == ThemeTests.ids, "主题注册表里的主题")
        var actual: [String: StructureGolden] = [:]
        for theme in themes {
            let json = try await harness.evaluate(Self.script, arguments: ["themeId": theme.id]) as? String ?? ""
            actual[theme.id] = try JSONDecoder().decode(StructureGolden.self, from: Data(json.utf8))
        }
        await harness.tearDown()
        #expect(harness.pageErrors == [])

        if ProcessInfo.processInfo.environment["RECORD_CARD_GOLDEN"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(actual).write(to: Self.fixture)
            Issue.record("已重新录制 \(Self.fixture.lastPathComponent)，核对差异后去掉 RECORD_CARD_GOLDEN 再跑")
            return
        }

        let golden = try JSONDecoder().decode([String: StructureGolden].self, from: Data(contentsOf: Self.fixture))
        #expect(Set(golden.keys) == Set(themes.map(\.id)))
        for theme in themes {
            let structure = theme.id
            guard let page = actual[theme.id], let expected = golden[theme.id] else {
                Issue.record("\(theme.id)（\(theme.structure)）：没有出图或没有基准")
                continue
            }
            #expect(page.structure == theme.structure)
            #expect(page.pageCount == expected.pageCount, "\(structure)：页数变了")
            #expect(page.pages.count == 2, "\(structure)：稿子应排满两页以上")
            for (index, (actualPage, expectedPage)) in zip(page.pages, expected.pages).enumerated() {
                let label = "\(structure) 第 \(index + 1) 页"
                #expect(actualPage.sha256 == expectedPage.sha256, "\(label)像素变了")
                #expect(actualPage.bounds == expectedPage.bounds, "\(label)正文区变了")
                #expect(actualPage.imageHits == expectedPage.imageHits, "\(label)图片点选框变了")
                #expect(actualPage.dropTargets == expectedPage.dropTargets, "\(label)拖放落点变了")
            }
        }
    }
}

private struct StructureGolden: Codable {
    var pageCount: Int
    var structure: String
    var pages: [CardPage]
}

private struct CardPage: Codable {
    var sha256: String
    var bounds: [Double]
    var imageHits: [String]
    var dropTargets: [String]
}
