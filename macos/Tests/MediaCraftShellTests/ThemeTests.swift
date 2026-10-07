import Foundation
import Testing

/// 主题：一次选择决定卡片结构、卡片配色与跟随主题的字体（界面皮肤跟随系统，ADR 0007）；每篇稿子记住自己的主题。
@MainActor
struct ThemeTests {
    /// 主题注册表（src/themes/themes.js）的顺序：id 与名字（v5 定稿的八个，第 03 张票）
    static let ids = ["notes", "plain", "journal", "glow", "clay", "editorial", "poster", "ink", "neon"]
    static let names = ["备忘", "纯白", "手帐", "柔光", "陶土", "杂志", "撞色", "纯黑", "电光"]
    /// 主题 → 卡片结构（每个主题一种，id 相同）
    static let structures = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
    /// 几个主题的配色（背景、文字、强调）
    static let notes = ["#ffffff", "#1c1c1e", "#ffbd2e"]
    static let ink = ["#0c0c0c", "#e8e8e5", "#e8e8e5"]
    /// 写进页面脚本里的 id 数组
    static var idsJSON: String { "[" + ids.map { "\"\($0)\"" }.joined(separator: ", ") + "]" }

    /// 用户操作的入口：检查器「样式」标签里的主题区点一个主题；读界面皮肤、这篇的主题、卡片与颜色。
    static let helpers = """
        const mc = window.mediacraft;
        window.themeGroup = () => document.querySelector('[role="group"][aria-label="主题"]');
        window.themeOptions = () => [...themeGroup().querySelectorAll("[aria-pressed]")];
        window.pickTheme = async (id) => {
          const theme = (await mc.themes.list()).find((item) => item.id === id);
          ui.click("样式");
          ui.click(theme.name, { within: "主题" });
          await mc.render.pages();
          document.getAnimations().forEach((animation) => animation.finish()); // 按钮颜色有过渡动画，直接走到终点再读
        };
        window.cardColors = async () => {
          const { colors } = await mc.drafts.current();
          return [colors.bg, colors.text, colors.accent];
        };
        window.cardTemplate = async () => (await mc.render.pages())[0].structure;
        // 卡片左边正中的一点（逻辑坐标 4, 576）：避开页眉条、渐变与装饰，是这一页的底色
        window.cornerPixel = async () => [...(await mc.render.canvases())[0].getContext("2d").getImageData(8, 1152, 1, 1).data.slice(0, 3)];
        window.css = (element, property) => getComputedStyle(element).getPropertyValue(property).trim();
        window.region = (name) => document.querySelector(`[aria-label="${name}"]`);
        // 界面皮肤：内容区底色、正文色、顶栏玻璃、分隔线、预览舞台、分段控件底、主按钮、浮层
        window.skin = () => ({
          ui: document.documentElement.dataset.uiTheme,
          window: css(region("编辑器"), "background-color"),
          text: css(document.body, "color"),
          glass: css(document.querySelector("header"), "background-color"),
          line: css(region("编辑器"), "border-right-color"),
          stage: css(region("预览"), "background-color"),
          layer: css(region("排版模式"), "background-color"),
          primary: css(ui.find("发送到 iPhone"), "background-color"),
          popover: css(ui.find("插入").nextElementSibling, "background-color"),
          font: css(document.body, "font-family"),
        });
        window.snapshot = async () => ({ skin: skin(), card: document.documentElement.dataset.cardTheme, template: await cardTemplate(), colors: await cardColors(), corner: await cornerPixel() });
        window.longDraft = (count) => Array.from({ length: count }, (_, index) =>
          `第 ${index + 1} 段：写得足够长，才能把内容推到后面的页面，检验页眉、页脚与分页的位置。`).join("\\n\\n");
    """

    /// 出一次图，读出每页卡片上的字与图（CardDomProbe，逻辑坐标），按页码（从 1 起）归好。
    static let recordCalls = CardDomProbe.script + """
        window.recordRender = async () => {
          const pages = await mc.render.refresh();
          const canvases = await mc.render.canvases();
          const calls = stageCards().flatMap((host, index) => cardDom(host).map((call) => ({ ...call, page: index + 1 })));
          window.cardBg = (await mc.drafts.current()).colors.bg;
          return { calls, pages, canvases };
        };
        // 一块区域（逻辑坐标）里不是底色的像素：个数、左右边界、与底色的最大对比度。
        window.inkIn = (canvas, left, top, right, bottom) => {
          const scale = canvas.width / 864;
          const bg = [1, 3, 5].map((index) => Number.parseInt(cardBg.slice(index, index + 2), 16));
          const x0 = Math.round(left * scale);
          const y0 = Math.round(top * scale);
          const width = Math.round(right * scale) - x0;
          const { data } = canvas.getContext("2d").getImageData(x0, y0, width, Math.round(bottom * scale) - y0);
          const channel = (value) => {
            const s = value / 255;
            return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
          };
          const luminance = ([r, g, b]) => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
          const ratio = (a, b) => {
            const [high, low] = [luminance(a), luminance(b)].sort((x, y) => y - x);
            return (high + 0.05) / (low + 0.05);
          };
          let count = 0;
          let minX = Infinity;
          let maxX = -Infinity;
          let contrast = 1;
          for (let i = 0; i < data.length; i += 4) {
            const pixel = [data[i], data[i + 1], data[i + 2]];
            if (pixel.every((value, index) => value === bg[index])) continue;
            const x = (i / 4) % width;
            count += 1;
            minX = Math.min(minX, x);
            maxX = Math.max(maxX, x);
            contrast = Math.max(contrast, ratio(pixel, bg));
          }
          return { count, left: (x0 + minX) / scale, right: (x0 + maxX + 1) / scale, contrast };
        };
    """

    @Test("主题区按注册表的顺序列出所有主题（名字；说明与换过去的页数作描述），都能点；顶栏主题按钮显示当前主题，点它回到样式标签")
    func themeSectionAndToolbarButton() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            const themes = await mc.themes.list();
            const options = themeOptions().map((option) => ({
              id: option.dataset.theme,
              name: ui.name(option),
              description: option.getAttribute("aria-describedby").split(" ").map((id) => document.getElementById(id).textContent).join(" "),
              pressed: option.getAttribute("aria-pressed"),
              disabled: option.disabled,
            }));
            ui.click("AI 助手");
            const aiShown = ui.find("样式").getAttribute("aria-selected") === "false";
            const before = ui.find("主题：").getAttribute("aria-label");
            ui.click("主题：");
            const aiPanel = document.getElementById(ui.find("AI 助手").getAttribute("aria-controls"));
            const backToStyle = ui.find("样式").getAttribute("aria-selected") === "true" && aiPanel.hidden && ui.find("备忘", { within: "主题" }) !== null;
            await pickTheme("ink");
            return {
              ids: options.map((option) => option.id),
              apiIds: themes.map((theme) => theme.id),
              names: options.map((option) => option.name),
              descriptions: options.map((option) => option.description),
              labels: themes.map((theme) => theme.label),
              pressed: options.map((option) => option.pressed),
              disabled: options.some((option) => option.disabled),
              soon: themeGroup().closest("section").textContent.includes("即将推出"),
              aiShown, before, backToStyle,
              after: ui.find("主题：").getAttribute("aria-label"),
              oldToggle: document.querySelector("#themeToggleBtn") !== null,
              presets: document.querySelectorAll("#palettePresets, [data-palette]").length,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["ids"] as? [String] == Self.ids)
        #expect(result?["apiIds"] as? [String] == Self.ids)
        #expect(result?["names"] as? [String] == Self.names)
        let descriptions = result?["descriptions"] as? [String] ?? []
        let labels = result?["labels"] as? [String] ?? []
        #expect(labels.first == "干净的随手记 · 黄色小签" && labels.last == "深蓝底 · 一抹电蓝 · 等宽标签", "\(labels)")
        #expect(descriptions.count == Self.ids.count && zip(descriptions, labels).allSatisfy { $0.hasPrefix($1) }, "描述先说主题的说明：\(descriptions)")
        #expect(result?["pressed"] as? [String] == ["true"] + Array(repeating: "false", count: Self.ids.count - 1), "新环境默认是备忘")
        #expect(result?["disabled"] as? Bool == false, "所有主题都能点")
        #expect(result?["soon"] as? Bool == false, "没有「即将推出」的主题了")
        #expect(result?["aiShown"] as? Bool == true)
        #expect(result?["before"] as? String == "主题：备忘")
        #expect(result?["backToStyle"] as? Bool == true, "点顶栏主题按钮回到样式标签")
        #expect(result?["after"] as? String == "主题：纯黑")
        #expect(result?["oldToggle"] as? Bool == false, "黑白切换已被「主题」取代")
        #expect(result?["presets"] as? Int == 0, "8 组配色那一排已移除")
        #expect(harness.pageErrors == [])
    }

    @Test("每个主题都能切换：卡片结构、卡片配色与「跟随主题」的中文、英文、代码字体一起换，界面皮肤不变")
    func everyThemeSwitchesSkinStructurePaletteAndFonts() async throws {
        try BundledFontsTests.requireBundledFonts()
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + Self.recordCalls + """
            await mc.drafts.create({ markdown: "# 主题\\n\\n中文正文 English words `code42` 混排。" });
            await document.fonts.ready;
            // 这段字用的字体栈（去掉引号）
            const families = (call) => (call?.font.replace(/^\\S+\\s+\\S+\\s+/, "") ?? "").split(",").map((name) => name.trim().replace(/^"|"$/g, ""));
            const result = {};
            for (const theme of await mc.themes.list()) {
              await pickTheme(theme.id);
              const { calls } = await recordRender();
              const text = calls.filter((call) => call.kind === "text" && call.page === 1);
              result[theme.id] = {
                ...(await snapshot()),
                pressed: themeOptions().filter((option) => option.getAttribute("aria-pressed") === "true").map((option) => option.dataset.theme),
                body: families(text.find((call) => call.text.includes("中文") && call.text.includes("English"))),
                code: families(text.find((call) => call.text === "code42")),
              };
            }
            return result;
        """) as? [String: [String: Any]]
        await harness.tearDown()

        // 主题 → 卡片结构、卡片配色、跟随主题的字体；界面皮肤不跟主题变，一直是浅色（测试固定在系统浅色外观）
        let expected: [(id: String, template: String, colors: [String], fonts: [String])] = [
            ("notes", "notes", ["#ffffff", "#1c1c1e", "#ffbd2e"], ["MC Noto Sans SC", "MC Inter", "MC JetBrains Mono"]),
            ("plain", "plain", ["#ffffff", "#111111", "#111111"], ["MC Noto Sans SC", "MC Inter", "MC JetBrains Mono"]),
            ("journal", "journal", ["#fbf9f3", "#2a2825", "#4ca585"], ["MC LXGW WenKai", "MC Source Serif 4", "MC IBM Plex Mono"]),
            ("glow", "glow", ["#f5f3ff", "#25223d", "#7a68ee"], ["MC Noto Sans SC", "MC Inter", "MC JetBrains Mono"]),
            ("clay", "clay", ["#fff6f0", "#1d1b18", "#e5704f"], ["MC Noto Sans SC", "MC Inter", "MC IBM Plex Mono"]),
            ("editorial", "editorial", ["#f2f6fa", "#1b2430", "#2f67b1"], ["MC Noto Serif SC", "MC Source Serif 4", "MC IBM Plex Mono"]),
            ("poster", "poster", ["#fffdf5", "#111111", "#ffe047"], ["MC Noto Sans SC", "MC Inter", "MC JetBrains Mono"]),
            ("ink", "ink", ["#0c0c0c", "#e8e8e5", "#e8e8e5"], ["MC Noto Sans SC", "MC Inter", "MC JetBrains Mono"]),
            ("neon", "neon", ["#0f172a", "#e6edf7", "#4cc9ff"], ["MC Noto Sans SC", "MC Inter", "MC JetBrains Mono"]),
        ]
        #expect(expected.map(\.id) == Self.ids, "表里列全注册表的主题")
        for theme in expected {
            let actual = result?[theme.id] ?? [:]
            let skin = actual["skin"] as? [String: String] ?? [:]
            #expect(skin["ui"] == "light", "\(theme.id)：界面皮肤不跟主题变")
            #expect([skin["window"] ?? "", skin["stage"] ?? ""] == ["rgb(244, 244, 244)", "rgb(232, 232, 232)"], "\(theme.id)：内容区与舞台底色 \(skin)")
            #expect(actual["card"] as? String == theme.id, "\(theme.id)：<html data-card-theme>")
            #expect(actual["pressed"] as? [String] == [theme.id], "\(theme.id)：主题区标出当前主题")
            #expect(actual["template"] as? String == theme.template, "\(theme.id)：卡片结构")
            #expect(actual["colors"] as? [String] == theme.colors, "\(theme.id)：卡片配色")
            let hex = Array(theme.colors[0].dropFirst())
            let corner = stride(from: 0, to: 6, by: 2).map { Int(String(hex[$0...$0 + 1]), radix: 16) ?? -1 }
            #expect(actual["corner"] as? [Int] == corner, "\(theme.id)：卡片底色真正画在卡片上")
            // 正文的字体栈里英文字体在前、中文字体跟着（混排时西文走英文字体），代码用代码字体
            let body = actual["body"] as? [String] ?? []
            let english = body.firstIndex(of: theme.fonts[1]), chinese = body.firstIndex(of: theme.fonts[0])
            #expect(english != nil && chinese != nil && english! < chinese!, "\(theme.id)：正文字体 \(body)")
            #expect((actual["code"] as? [String])?.first == theme.fonts[2], "\(theme.id)：代码字体 \(actual["code"] ?? [])")
        }
        #expect(harness.pageErrors == [])
    }

    @Test("选主题换卡片结构与卡片配色，界面皮肤不变（跟随系统）；换回来也一样")
    func choosingThemeChangesStructureAndPaletteNotSkin() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# 主题\\n\\n正文段落。" });
            const notes = await snapshot();
            await pickTheme("ink");
            const ink = await snapshot();
            const pressed = themeOptions().map((option) => option.getAttribute("aria-pressed"));
            await pickTheme("notes");
            return { notes, ink, pressed, back: await snapshot() };
        """) as? [String: Any]
        await harness.tearDown()

        let light = result?["notes"] as? [String: Any]
        let dark = result?["ink"] as? [String: Any]
        let lightSkin = light?["skin"] as? [String: String] ?? [:]
        let darkSkin = dark?["skin"] as? [String: String] ?? [:]
        // 浅色界面（原来「灰」的令牌）：内容区 #f4f4f4、玻璃 rgba(234,234,234,.9)、分隔线 #d9d9d9、舞台 #e8e8e8、分段底 #ffffff、主色 #0f62fe
        #expect(lightSkin.filter { $0.key != "font" } == [
            "ui": "light", "window": "rgb(244, 244, 244)", "text": "rgb(22, 22, 22)",
            "glass": "rgba(234, 234, 234, 0.9)", "line": "rgb(217, 217, 217)", "stage": "rgb(232, 232, 232)",
            "layer": "rgb(255, 255, 255)", "primary": "rgb(15, 98, 254)", "popover": "rgb(255, 255, 255)",
        ])
        #expect(darkSkin == lightSkin, "换成纯黑，界面不变")
        #expect(lightSkin["font"]?.hasPrefix("-apple-system") == true, "界面用系统字体：\(lightSkin["font"] ?? "")")
        #expect(darkSkin["font"] == lightSkin["font"])
        #expect(light?["template"] as? String == "notes")
        #expect(dark?["template"] as? String == "ink")
        #expect(light?["colors"] as? [String] == Self.notes)
        #expect(dark?["colors"] as? [String] == Self.ink)
        #expect(light?["corner"] as? [Int] == [255, 255, 255])
        #expect(dark?["corner"] as? [Int] == [12, 12, 12])
        #expect(result?["pressed"] as? [String] == Self.ids.map { $0 == "ink" ? "true" : "false" }, "主题区标出纯黑")
        let back = result?["back"] as? [String: Any]
        #expect(back?["skin"] as? [String: String] == lightSkin)
        #expect(back?["template"] as? String == "notes")
        #expect(back?["colors"] as? [String] == Self.notes)
        #expect(harness.pageErrors == [])
    }

    @Test("每篇稿子记住自己的主题：切换稿子、重新载入都不变；新稿子沿用上一次选的主题")
    func eachDraftRemembersItsTheme() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let before = try await harness.evaluate(Self.helpers + """
            const { id: first } = await mc.drafts.create();
            await pickTheme("ink");
            const { id: second } = await mc.drafts.create();
            const newDraft = await snapshot();
            await pickTheme("notes");
            await mc.drafts.open(first);
            return { first, second, newDraft, reopened: await snapshot() };
        """) as? [String: Any]
        try await harness.load()
        let after = try await harness.evaluate(Self.helpers + """
            const reloaded = { id: (await mc.drafts.current()).id, ...(await snapshot()) };
            await mc.drafts.open(second);
            const other = await snapshot();
            await mc.drafts.create();
            return { reloaded, other, newest: await snapshot() };
        """, arguments: ["second": before?["second"] as? String ?? ""]) as? [String: Any]
        await harness.tearDown()

        let newDraft = before?["newDraft"] as? [String: Any]
        #expect(newDraft?["card"] as? String == "ink", "新稿子沿用上一次选的纯黑")
        #expect(newDraft?["template"] as? String == "ink")
        #expect(newDraft?["colors"] as? [String] == Self.ink)
        let reopened = before?["reopened"] as? [String: Any]
        #expect(reopened?["card"] as? String == "ink", "切回第一篇还是纯黑")
        #expect(reopened?["colors"] as? [String] == Self.ink)
        let reloaded = after?["reloaded"] as? [String: Any]
        #expect(reloaded?["id"] as? String == before?["first"] as? String)
        #expect(reloaded?["card"] as? String == "ink", "重新载入后还是纯黑")
        #expect(reloaded?["template"] as? String == "ink")
        #expect(reloaded?["colors"] as? [String] == Self.ink)
        let other = after?["other"] as? [String: Any]
        #expect(other?["card"] as? String == "notes")
        #expect(other?["template"] as? String == "notes")
        #expect(other?["colors"] as? [String] == Self.notes)
        let newest = after?["newest"] as? [String: Any]
        #expect(newest?["card"] as? String == "notes", "上一次选的是备忘，新稿子就是备忘")
        #expect(newest?["colors"] as? [String] == Self.notes)
        #expect(harness.pageErrors == [])
    }

    @Test("主题的标题字体：跟随主题时标题、封面标题用主题另带的标题字体，正文仍用正文字体；自己选了中文字体，标题的中文也用选的")
    func themeTitleFonts() async throws {
        try BundledFontsTests.requireBundledFonts()
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + CardDomProbe.script + """
            await mc.drafts.create({ markdown: "# 标题 Title\\n\\n正文 body text" });
            await mc.themes.apply("clay");
            // 这段字用的字体栈（去掉字重、字号与引号）
            const families = (call) => (call?.font.replace(/^\\S+\\s+\\S+\\s+/, "") ?? "").split(",").map((name) => name.trim().replace(/^"|"$/g, ""));
            const read = async () => {
              await mc.render.refresh();
              const calls = cardDom(stageCards()[0]);
              return {
                title: families(calls.find((call) => call.block === "h1")),
                body: families(calls.find((call) => call.block === "p")),
              };
            };
            const follow = await read();
            await mc.drafts.update({ fonts: { zh: "noto-sans-sc" } });
            const chosen = await read();
            return { follow, chosen };
        """) as? [String: [String: [String]]]
        await harness.tearDown()

        let follow = result?["follow"] ?? [:]
        #expect(Array((follow["title"] ?? []).prefix(2)) == ["MC Source Serif 4", "MC Noto Serif SC"], "陶土的标题：衬线 \(follow["title"] ?? [])")
        #expect(Array((follow["body"] ?? []).prefix(2)) == ["MC Inter", "MC Noto Sans SC"], "陶土的正文：无衬线 \(follow["body"] ?? [])")
        let chosen = result?["chosen"] ?? [:]
        #expect(Array((chosen["title"] ?? []).prefix(2)) == ["MC Source Serif 4", "MC Noto Sans SC"], "自己选了中文字体：标题的中文跟着换 \(chosen["title"] ?? [])")
        #expect(harness.pageErrors == [])
    }

    @Test("定稿之前的旧主题：稿子打开时换成接替它的新主题（暗夜 → 纯黑、纸 → 陶土、废土 → 手帐……），没调过的配色换成新主题的、调过的保留；每轮 AI 之前存的版本、上次选的主题也一样，换过的写回存储")
    func retiredThemesMigrate() async throws {
        let harness = ShellHarness(onboarding: false)
        let night = ["bg": "#161616", "text": "#f4f4f4", "accent": "#78a9ff"]
        let waste = ["bg": "#efe6d6", "text": "#3b2f24", "accent": "#a8522a"]
        let tuned = ["bg": "#fff4e6", "text": "#3a3226", "accent": "#b5562e"]
        func record(_ id: String, theme: String, colors: [String: String], versions: [[String: Any]] = []) -> [String: Any] {
            ["id": id, "title": id, "markdown": "\(id) 的正文", "mode": "cards", "theme": theme, "colors": colors,
             "fonts": ["zh": "theme", "en": "theme", "code": "theme"], "images": [:], "createdAt": 1, "updatedAt": 2, "versions": versions]
        }
        let version: [String: Any] = ["id": "turn-1", "at": 1, "label": "一", "draft": ["title": "旧", "markdown": "一轮之前", "mode": "cards", "theme": "waste", "colors": waste, "images": [:]]]
        let seed = ["drafts": [
            record("dark", theme: "night", colors: night),
            record("tuned", theme: "paper", colors: tuned),
            record("versioned", theme: "mist", colors: [:], versions: [version]),
        ]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: seed), as: UTF8.self)
        try await harness.prepareStorage(StorageScripts.seed + """
            await seedStore(\(json));
            localStorage.setItem("mediacraft.prefs.v1", JSON.stringify({ currentDraftId: "dark", lastTheme: "cyber" }));
        """)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + StorageScripts.read + """
            const pick = (draft) => ({ theme: draft.theme, colors: [draft.colors.bg, draft.colors.text, draft.colors.accent], tuned: draft.tunedColors });
            const dark = pick(await mc.drafts.current());
            const card = document.documentElement.dataset.cardTheme;
            const template = await cardTemplate();
            const tuned = pick(await mc.drafts.open("tuned"));
            const versioned = pick(await mc.drafts.open("versioned"));
            const version = (await mc.ai.versions.list())[0];
            await mc.ai.versions.revert(version.id);
            const reverted = pick(await mc.drafts.current());
            const stored = Object.fromEntries((await readStore("drafts")).map((record) => [record.id, [record.theme, record.versions?.[0]?.draft.theme ?? null]]));
            const fresh = pick(await mc.drafts.create());
            return { dark, card, template, tuned, versioned, reverted, stored, fresh };
        """) as? [String: Any]
        await harness.tearDown()

        func view(_ key: String) -> [String: Any] { result?[key] as? [String: Any] ?? [:] }
        #expect(view("dark")["theme"] as? String == "ink" && view("dark")["colors"] as? [String] == Self.ink, "暗夜没调过：换成纯黑的配色 \(view("dark"))")
        #expect(result?["card"] as? String == "ink" && result?["template"] as? String == "ink")
        #expect(view("tuned")["theme"] as? String == "clay", "纸 → 陶土")
        #expect(view("tuned")["colors"] as? [String] == ["#fff4e6", "#3a3226", "#b5562e"], "调过的配色保留")
        #expect(view("versioned")["theme"] as? String == "glow" && view("versioned")["colors"] as? [String] == ["#f5f3ff", "#25223d", "#7a68ee"], "雾 → 柔光，没存配色的用柔光的")
        #expect(view("reverted")["theme"] as? String == "journal" && view("reverted")["colors"] as? [String] == ["#fbf9f3", "#2a2825", "#4ca585"], "撤回到废土时的版本：手帐与它的配色")
        let stored = result?["stored"] as? [String: [Any]] ?? [:]
        #expect(stored["dark"]?.first as? String == "ink" && stored["tuned"]?.first as? String == "clay", "换过的写回存储：\(stored)")
        #expect(stored["versioned"]?.last as? String == "journal", "版本里的主题也写回")
        #expect(view("fresh")["theme"] as? String == "ink", "上次选的赛博 → 新稿子用纯黑")
        #expect(harness.pageErrors == [])
    }
}
