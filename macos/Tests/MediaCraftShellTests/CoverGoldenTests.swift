import Foundation
import Testing

/// 封面与结尾页的像素基准：卡片像素基准（CardGoldenTests）那篇稿子加上一段结尾，按每个主题各出三张——
/// 没有底图的封面、用 single.png 做底图的封面、结尾页，钉住像素哈希、标题各行的字与字号、结尾页的字与总页数。基准按主题 id 记。
/// 旧用例（没开封面、没写 [[结尾]]）的像素仍由 card-structures-golden.json 钉着，不在这里。
/// 版式有意改动后，先看过新图（`COVER_REVIEW_DIR=目录` 时把每张图存成 PNG），再用
/// `RECORD_COVER_GOLDEN=1 macos/run-tests.sh --filter CoverGolden` 重新录制，核对 fixture 的差异。
@MainActor
struct CoverGoldenTests {
    static let fixture = ShellHarness.repoRoot.appendingPathComponent("macos/Tests/Fixtures/cover-pages-golden.json")

    static let ending = """


        [[结尾]]

        ## 下期预告

        关注我，下期讲怎么用 AI 写综述。
        觉得有用就收藏一下。

        **第 3 期**
        """

    /// 按这个主题出三张：主题、配色与字体都经注册表取。
    /// 主题的辅助色与衬底是三色规则推出来的（没单独调过，tunedColors 为空），和在主题面板里点选一样。
    static let script = """
        const mc = window.mediacraft;
        const theme = (await mc.themes.list()).find((item) => item.id === themeId);
        const photo = (await mc.media.list()).find((image) => image.name === "single.png").id;
        await mc.drafts.update({
          mode: "cards", theme: theme.id, colors: theme.colors, tunedColors: [], fonts: theme.fonts,
          fontSize: 34, lineHeight: 1.85, imageMaxHeight: 1048,
          title: "用 AI 读论文的三个习惯", markdown: goldenMarkdown + ending,
          cover: { enabled: true, subtitle: "先问再读，三周读完二十篇", image: null },
        });
        const hex = (buffer) => Array.from(new Uint8Array(buffer), (byte) => byte.toString(16).padStart(2, "0")).join("");
        const shot = async (page, canvas) => ({
          sha256: hex(await crypto.subtle.digest("SHA-256", canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data)),
          lines: page.items.filter((item) => item.kind === "text").map((item) => `${item.blockType} ${item.fontSize} ${item.text}`),
          png: review ? canvas.toDataURL("image/png") : null,
        });
        const plain = await mc.render.offscreen();
        const last = plain.pages.length - 1;
        const cover = await shot(plain.pages[0], plain.canvases[0]);
        const end = await shot(plain.pages[last], plain.canvases[last]);
        await mc.drafts.update({ cover: { image: photo } });
        const pictured = await mc.render.offscreen();
        const coverImage = await shot(pictured.pages[0], pictured.canvases[0]);
        return JSON.stringify({
          structure: plain.pages[0].structure, pageCount: plain.pages.length,
          roles: [plain.pages[0].role, plain.pages[last].role, pictured.pages[0].role],
          shots: { cover, coverImage, end },
        });
    """

    @Test("每个主题的封面（有无底图）与结尾页出图与基准一致")
    func coversMatchGolden() async throws {
        try BundledFontsTests.requireBundledFonts()
        let environment = ProcessInfo.processInfo.environment
        let reviewDirectory = environment["COVER_REVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(CardGoldenTests.setup, arguments: ["draft": CardGoldenTests.draft])
        let themes = try await harness.evaluate("return (await window.mediacraft.themes.list()).map((theme) => theme.id)") as? [String] ?? []
        var actual: [String: CoverGolden] = [:]
        for theme in themes {
            let json = try await harness.evaluate(
                Self.script, arguments: ["themeId": theme, "ending": Self.ending, "review": reviewDirectory != nil]
            ) as? String ?? ""
            var golden = try JSONDecoder().decode(CoverGolden.self, from: Data(json.utf8))
            if let reviewDirectory {
                try FileManager.default.createDirectory(at: reviewDirectory, withIntermediateDirectories: true)
                for (name, shot) in golden.shots {
                    let data = Data(base64Encoded: String((shot.png ?? "").dropFirst("data:image/png;base64,".count))) ?? Data()
                    try data.write(to: reviewDirectory.appendingPathComponent("\(theme)-\(name).png"))
                }
            }
            golden.shots = golden.shots.mapValues { CoverShot(sha256: $0.sha256, lines: $0.lines, png: nil) }
            actual[theme] = golden
        }
        await harness.tearDown()
        #expect(harness.pageErrors == [])
        #expect(actual.count == ThemeTests.ids.count)

        if environment["RECORD_COVER_GOLDEN"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(actual).write(to: Self.fixture)
            Issue.record("已重新录制 \(Self.fixture.lastPathComponent)，核对差异后去掉 RECORD_COVER_GOLDEN 再跑")
            return
        }

        let expected = try JSONDecoder().decode([String: CoverGolden].self, from: Data(contentsOf: Self.fixture))
        #expect(Set(expected.keys) == Set(actual.keys))
        for (structure, golden) in actual {
            guard let reference = expected[structure] else { continue }
            #expect(golden.roles == ["cover", "end", "cover"], "\(structure)：第一张是封面、最后一张是结尾页")
            #expect(golden.pageCount == reference.pageCount, "\(structure)：页数变了")
            for (name, shot) in reference.shots {
                #expect(golden.shots[name]?.lines == shot.lines, "\(structure) \(name)：字或字号变了")
                #expect(golden.shots[name]?.sha256 == shot.sha256, "\(structure) \(name)：像素变了")
            }
        }
    }
}

private struct CoverGolden: Codable {
    var structure: String
    var pageCount: Int
    var roles: [String]
    var shots: [String: CoverShot]
}

private struct CoverShot: Codable {
    var sha256: String
    var lines: [String]
    /// 只在存评审图时有：这张的 PNG（data URL），不进基准
    var png: String?
}
