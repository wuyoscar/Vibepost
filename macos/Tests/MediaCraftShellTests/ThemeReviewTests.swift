import AppKit
import Foundation
import Testing
import WebKit

/// 看主题用的一套图（不是断言）：`THEME_REVIEW_DIR=目录 macos/run-tests.sh --filter ThemeReview` 时，
/// 用说明书素材里的三张照片排一篇旅行笔记，按每个主题（`THEME_REVIEW_THEMES=id,id` 可只出几个）存封面（有底图、没底图）、
/// 前两张正文页与结尾页的 PNG：`<主题>-<序号>-<页>.png`；README 的几张截图也在这里出，主题总览 `themes.png`
/// 是 12 个主题的封面按面板的三组拼成的 4×3（设 `MEDIACRAFT_SCREENSHOTS` 也出它）。没设目录时跳过。
@MainActor
struct ThemeReviewTests {
    static let markdown = """
        # 周末去山里看一次日出

        凌晨四点出发，山路上只有车灯。到观景台的时候天还没亮，风很大，但所有人都在等同一件事。

        > 日出只有十几分钟，却能让你记住整个周末。

        ## 出发前准备

        1. 前一晚查好日出时间，提前四十分钟到
        2. 带一件**防风外套**，山顶比山下冷 8 度
        - 手机和充电宝提前充满

        [[image:valley]]

        ## 拍照小技巧

        逆光时对着亮处测光，{{bg:#fff3bf|让天空保留层次}}，人会暗一点，回去再{{color:#d9480f|拉阴影}}。直接开 `HDR` 反而容易发灰。

        | 时间 | 光线 | 适合拍 |
        | --- | :---: | ---: |
        | 日出前 20 分钟 | 蓝调 | 剪影 |
        | 日出后 10 分钟 | 金光 | 人像 |

        [[image:lake|sunset|4x3]]

        ---

        ### 一点感受

        ~~赖床~~ 早起一次，看到的是 2026 年最好看的一片云。English words 也要排得好看。

        [[结尾]]

        ## 下次去哪

        关注我，下期写秋天的湖边露营。
        觉得有用就收藏一下。
        """

    static let script = """
        const mc = window.mediacraft;
        if (!window.reviewReady) {
          await mc.drafts.create();
          const photo = async (name) => {
            const blob = await fetch(`docs/guide-assets/${name}`).then((response) => response.blob());
            return new File([blob], name, { type: "image/jpeg" });
          };
          const ids = await mc.media.import([await photo("valley-morning.jpg"), await photo("night-lake.jpg"), await photo("sunset-live-cover.jpg")]);
          // 导入的顺序不一定是传进去的顺序：按文件名认
          const byName = {};
          for (const id of ids) byName[(await mc.media.get(id)).name] = id;
          window.reviewIds = { valley: byName["valley-morning.jpg"], lake: byName["night-lake.jpg"], sunset: byName["sunset-live-cover.jpg"] };
          await mc.profile.update({ name: "wuyoscar", handle: "@wuyoscar", avatar: "brand/avatar.png" });
          window.reviewReady = true;
        }
        const theme = (await mc.themes.list()).find((item) => item.id === themeId);
        const text = markdown
          .replace("[[image:valley]]", `[[image:${reviewIds.valley}]]`)
          .replace("[[image:lake|sunset|4x3]]", `[[image:${reviewIds.lake}|${reviewIds.sunset}|4x3]]`);
        await mc.drafts.update({
          mode: "cards", theme: theme.id, colors: theme.colors, tunedColors: [], fonts: { zh: "theme", en: "theme", code: "theme" },
          fontSize: 34, lineHeight: 1.85, imageMaxHeight: 1048,
          title: "周末去山里看一次日出", markdown: text,
          cover: { enabled: true, subtitle: "凌晨四点出发，值了", image: reviewIds.valley },
        });
        const pictured = await mc.render.offscreen();
        const last = pictured.pages.length - 1;
        await mc.drafts.update({ cover: { enabled: true, subtitle: "凌晨四点出发，值了", image: null } });
        const plain = await mc.render.offscreen();
        // 主题总览（exportThemesSheet）要拼每个主题带底图的封面：留在页面里
        (window.reviewCovers ??= {})[themeId] = pictured.canvases[0];
        const shots = [
          ["1-cover-photo", pictured.canvases[0]],
          ["2-cover", plain.canvases[0]],
          ["3-page", pictured.canvases[1]],
          ["4-page", pictured.canvases[2]],
          ["5-end", pictured.canvases[last]],
        ];
        return shots.map(([name, canvas]) => [name, canvas.toDataURL("image/png")]);
    """

    @Test(
        "主题审阅图：每个主题的封面、正文页与结尾页存成 PNG",
        .enabled(if: ProcessInfo.processInfo.environment["THEME_REVIEW_DIR"] != nil)
    )
    func exportReviewSheets() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: environment["THEME_REVIEW_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let harness = ShellHarness()
        try await harness.load()
        let all = try await harness.evaluate("return (await window.mediacraft.themes.list()).map((theme) => theme.id)") as? [String] ?? []
        let wanted = environment["THEME_REVIEW_THEMES"].map { $0.split(separator: ",").map(String.init) } ?? all
        for themeId in wanted where all.contains(themeId) {
            let shots = try await harness.evaluate(
                Self.script, arguments: ["themeId": themeId, "markdown": Self.markdown]
            ) as? [[String]] ?? []
            for shot in shots where shot.count == 2 {
                let data = Data(base64Encoded: String(shot[1].dropFirst("data:image/png;base64,".count))) ?? Data()
                try data.write(to: directory.appendingPathComponent("\(themeId)-\(shot[0]).png"))
            }
        }
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }

    /// 把每个主题带底图的封面拼成一张：面板的三组各一行（行首是组名），每行四张，每张下面是主题名；灰底，同舞台的底色
    static let sheetScript = """
        const mc = window.mediacraft;
        const themes = await mc.themes.list();
        const groups = await mc.themes.groups();
        const COLS = 4, GAP = 16, MARGIN = 20, CARD_W = 363, CARD_H = 484, GROUP_H = 28, NAME_H = 40;
        const ROW_H = GROUP_H + CARD_H + NAME_H;
        const sheet = document.createElement("canvas");
        sheet.width = MARGIN * 2 + COLS * CARD_W + (COLS - 1) * GAP;
        sheet.height = MARGIN * 2 + groups.length * ROW_H + (groups.length - 1) * GAP;
        const context = sheet.getContext("2d");
        context.imageSmoothingQuality = "high";
        context.fillStyle = "#e8e8e8";
        context.fillRect(0, 0, sheet.width, sheet.height);
        context.textBaseline = "middle";
        const font = (size, weight) => `${weight} ${size}px -apple-system, "PingFang SC", "Helvetica Neue", sans-serif`;
        groups.forEach((group, row) => {
          const top = MARGIN + row * (ROW_H + GAP);
          context.fillStyle = "#6e6e73";
          context.font = font(18, 600);
          context.textAlign = "left";
          context.fillText(group.name, MARGIN + 2, top + GROUP_H / 2);
          themes.filter((theme) => theme.group === group.id).forEach((theme, column) => {
            const left = MARGIN + column * (CARD_W + GAP);
            const card = reviewCovers[theme.id];
            if (!card) throw new Error(`没有 ${theme.id} 的封面`);
            context.save();
            context.beginPath();
            context.roundRect(left, top + GROUP_H, CARD_W, CARD_H, 10);
            context.clip();
            context.drawImage(card, left, top + GROUP_H, CARD_W, CARD_H);
            context.restore();
            context.fillStyle = "#1d1d1f";
            context.font = font(20, 600);
            context.textAlign = "center";
            context.fillText(theme.name, left + CARD_W / 2, top + GROUP_H + CARD_H + NAME_H / 2);
          });
        });
        return sheet.toDataURL("image/png");
    """

    @Test(
        "README 的主题总览：12 个主题下同一篇稿子带底图的封面，按面板的三组拼成 4×3、每张下面是主题名（themes.png）",
        .enabled(if: ProcessInfo.processInfo.environment["THEME_REVIEW_DIR"] != nil || ProcessInfo.processInfo.environment["MEDIACRAFT_SCREENSHOTS"] != nil)
    )
    func exportThemesSheet() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: environment["THEME_REVIEW_DIR"] ?? environment["MEDIACRAFT_SCREENSHOTS"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let all = try await harness.evaluate("return (await window.mediacraft.themes.list()).map((theme) => theme.id)") as? [String] ?? []
        #expect(all.count == ThemeTests.ids.count, "12 个主题都拼进去")
        for themeId in all {
            _ = try await harness.evaluate(Self.script, arguments: ["themeId": themeId, "markdown": Self.markdown])
        }
        let sheet = try await harness.evaluate(Self.sheetScript) as? String ?? ""
        let data = Data(base64Encoded: String(sheet.dropFirst("data:image/png;base64,".count))) ?? Data()
        #expect(data.count > 100_000, "拼出来的图不该是空的：\(data.count) 字节")
        try data.write(to: directory.appendingPathComponent("themes.png"))
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }

    @Test(
        "README 的整窗截图：深色界面里一篇手帐主题的旅行笔记（app.png）",
        .enabled(if: ProcessInfo.processInfo.environment["THEME_REVIEW_DIR"] != nil)
    )
    func exportAppScreenshot() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THEME_REVIEW_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        harness.setAppearance(dark: true)
        _ = try await harness.evaluate(Self.script, arguments: ["themeId": "journal", "markdown": Self.markdown])
        _ = try await harness.evaluate("""
            // 审阅脚本最后把封面底图去掉了：放回来
            await window.mediacraft.drafts.update({
              cover: { enabled: true, subtitle: "凌晨四点出发，值了", image: reviewIds.valley },
              caption: "凌晨四点出发，在山顶等了二十分钟。云和光都值得，下次还想再去一次。\\n\\n#日出 #周末去哪儿 #旅行攻略",
            });
            ui.click("样式");
            await window.mediacraft.render.pages();
            // 等主题面板把每个主题的缩略图都出好（最多 30 秒）
            const group = document.querySelector('[role="group"][aria-label="主题"]');
            for (let waited = 0; waited < 30000 && group.getAttribute("aria-busy") !== "false"; waited += 100) {
              await new Promise((resolve) => setTimeout(resolve, 100));
            }
            await new Promise((resolve) => setTimeout(resolve, 400));
            return true;
        """)
        let image = try await harness.webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: directory.appendingPathComponent("app.png"))
        }
        harness.setAppearance(dark: false)
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }

    @Test(
        "README 的另外三张截图：浅色整窗（app-light.png）、手机预览（phone-preview.png）、AI 的改动逐处确认（ai.png）",
        .enabled(if: ProcessInfo.processInfo.environment["THEME_REVIEW_DIR"] != nil)
    )
    func exportReadmeScreenshots() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THEME_REVIEW_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 假的 Claude 润色三处（只改字，不碰图片标记），停在逐处确认
        func edit(_ old: String, _ new: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: ["draft.md", old, new])) ?? Data()
            return "#edit " + String(decoding: data, as: UTF8.self)
        }
        let fake = try FakeClaude(script: [
            edit("凌晨四点出发，山路上只有车灯。", "凌晨四点出发，整条山路只有我们这一束车灯。"),
            edit("带一件**防风外套**，山顶比山下冷 8 度", "带一件**防风外套**：山顶比山下冷 8 度左右"),
            edit("关注我，下期写秋天的湖边露营。", "下期写秋天的湖边露营，想看的话点个关注。"),
        ] + StreamJSON.reply(["改好了三处：开头更有画面，准备清单更具体，结尾的关注提示更自然。"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        func save(_ name: String) async throws {
            let image = try await harness.webView.takeSnapshot(configuration: WKSnapshotConfiguration())
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
        let settle = """
            await window.mediacraft.render.pages();
            await new Promise((resolve) => setTimeout(resolve, 600));
            return true;
        """
        _ = try await harness.evaluate(Self.script, arguments: ["themeId": "notes", "markdown": Self.markdown])
        _ = try await harness.evaluate("""
            await window.mediacraft.drafts.update({
              cover: { enabled: true, subtitle: "凌晨四点出发，值了", image: reviewIds.valley },
              caption: "凌晨四点出发，在山顶等了二十分钟。云和光都值得，下次还想再去一次。\\n\\n#日出 #周末去哪儿 #旅行攻略",
            });
            ui.click("样式");
            await window.mediacraft.render.pages();
            const group = document.querySelector('[role="group"][aria-label="主题"]');
            for (let waited = 0; waited < 30000 && group.getAttribute("aria-busy") !== "false"; waited += 100) {
              await new Promise((resolve) => setTimeout(resolve, 100));
            }
        """ + settle)
        try await save("app-light")

        _ = try await harness.evaluate("ui.click(\"手机预览\");\n" + settle)
        try await save("phone-preview")
        _ = try await harness.evaluate("ui.click(\"手机预览\");\n" + settle)

        _ = try await harness.evaluate(AIReviewTests.helpers + """
            await openAI();
            ask("润色一下，开头更有画面，结尾的关注提示自然一点");
            await until(() => finished(1));
            await until(() => bars().length >= 3);
        """ + settle)
        try await save("ai")
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }
}
