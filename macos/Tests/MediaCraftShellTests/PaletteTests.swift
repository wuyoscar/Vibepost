import Testing

/// 配色：五个颜色角色、配色库、我的配色、色轮的配色规则与对比度保护、粘贴色值（docs/app-api.md 的 palettes）。
@MainActor
@Suite(.serialized)
struct PaletteTests {
    /// 测试自己的颜色计算（不用页面里的）：WCAG 对比度、OKLCH 色相、色相差；等待与找配色格子。
    static let helpers = """
        const mc = window.mediacraft;
        const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        const until = async (condition, label, timeout = 10000) => {
          const deadline = Date.now() + timeout;
          while (!(await condition())) {
            if (Date.now() > deadline) throw new Error(`等不到：${label}`);
            await wait(50);
          }
        };
        const rgb = (hex) => [1, 3, 5].map((index) => parseInt(hex.slice(index, index + 2), 16) / 255);
        const linear = (value) => (value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
        const luminance = (hex) => {
          const [r, g, b] = rgb(hex).map(linear);
          return 0.2126 * r + 0.7152 * g + 0.0722 * b;
        };
        const ratio = (a, b) => {
          const [high, low] = [luminance(a), luminance(b)].sort((x, y) => y - x);
          return (high + 0.05) / (low + 0.05);
        };
        const hue = (hex) => {
          const [r, g, b] = rgb(hex).map(linear);
          const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
          const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
          const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
          const a = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
          const bb = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
          return ((Math.atan2(bb, a) * 180) / Math.PI + 360) % 360;
        };
        // 从 from 转到 to 要多少度（0–360）
        const turn = (from, to) => (((to - from) % 360) + 360) % 360;
        const same = (a, b) => ["bg", "text", "accent", "secondary", "surface"].every((role) => a[role] === b[role]);
        const visible = (element) => element.getClientRects().length > 0;
        const tiles = () => [...document.querySelectorAll("[aria-label='配色库面板'] [data-palette-id]")].filter(visible);
        const openLibrary = async () => {
          ui.expand("配色库");
          await until(() => tiles().length > 0, "配色库的格子");
        };
        const cornerPixel = async () => {
          const [canvas] = await mc.render.canvases();
          const [r, g, b] = canvas.getContext("2d").getImageData(2, 2, 1, 1).data;
          return `#${[r, g, b].map((value) => value.toString(16).padStart(2, "0")).join("")}`;
        };
    """

    static let five = ["bg": "#f5eeec", "text": "#3e2f2e", "accent": "#955660", "secondary": "#6e4a4d", "surface": "#ebdcd9"]

    @Test("五个颜色随稿子保存，输出总有五个；只给三色时辅助、衬底按三色规则推；没单独调过的辅助、衬底跟着底色与正文色走")
    func fiveRolesRoundTrip() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let draftId = try await harness.evaluate(Self.helpers + """
            const { id } = await mc.drafts.create({ markdown: "# 标题\\n\\n> 引用" });
            await mc.drafts.update({ colors: five });
            return id;
        """, arguments: ["five": Self.five]) as? String ?? ""
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.open(draftId);
            const reloaded = (await mc.drafts.current()).colors;
            const three = (await mc.drafts.update({ colors: { bg: "#ffffff", text: "#202938", accent: "#2563eb" } })).colors;
            const one = (await mc.drafts.update({ colors: { accent: "#d9480f" } })).colors;
            const followed = (await mc.drafts.update({ colors: { bg: "#111111", text: "#f5f5f5" } })).colors;
            await mc.drafts.update({ colors: { secondary: "#ffcc00" } });
            const kept = (await mc.drafts.update({ colors: { text: "#dddddd" } })).colors;
            // 检查器里改色块：一样跟着走
            const input = document.getElementById("textColorInput");
            input.value = "#eeeeee";
            input.dispatchEvent(new Event("input", { bubbles: true }));
            await mc.render.pages();
            const swatch = (await mc.drafts.current()).colors;
            const invalid = await mc.drafts.update({ colors: { tint: "#ffffff" } }).then(() => "resolved", (error) => error.name);
            return { reloaded, three, one, followed, kept, swatch, invalid };
        """, arguments: ["draftId": draftId]) as? [String: Any]
        await harness.tearDown()

        #expect(result?["reloaded"] as? [String: String] == Self.five, "重新载入后五个颜色都在")
        #expect(result?["three"] as? [String: String] == [
            "bg": "#ffffff", "text": "#202938", "accent": "#2563eb", "secondary": "#202938", "surface": "#e9eaeb",
        ], "辅助 = 正文色，衬底 = 正文色 10% 叠在底色上")
        #expect(result?["one"] as? [String: String] == [
            "bg": "#ffffff", "text": "#202938", "accent": "#d9480f", "secondary": "#202938", "surface": "#e9eaeb",
        ])
        #expect(result?["followed"] as? [String: String] == [
            "bg": "#111111", "text": "#f5f5f5", "accent": "#d9480f", "secondary": "#f5f5f5", "surface": "#282828",
        ], "辅助、衬底没单独调过：跟着新的底色、正文色重新推")
        #expect(result?["kept"] as? [String: String] == [
            "bg": "#111111", "text": "#dddddd", "accent": "#d9480f", "secondary": "#ffcc00", "surface": "#252525",
        ], "单独调过的辅助色不动，衬底照样跟着走")
        #expect(result?["swatch"] as? [String: String] == [
            "bg": "#111111", "text": "#eeeeee", "accent": "#d9480f", "secondary": "#ffcc00", "surface": "#272727",
        ])
        #expect(result?["invalid"] as? String == "TypeError")
        #expect(harness.pageErrors == [])
    }

    @Test("只存了三色的旧稿子照常打开：与主题的五色一致（主题的辅助、衬底就是三色规则的值）；自己调过的三色按规则补齐")
    func threeColorDraftsLoadUnchanged() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let ids = try await harness.evaluate(StorageScripts.read + Self.helpers + """
            const ids = {};
            for (const theme of await mc.themes.list()) {
              ids[theme.id] = (await mc.drafts.create({ theme: theme.id, markdown: `# ${theme.name}\\n\\n> 引用\\n\\n正文` })).id;
            }
            ids.custom = (await mc.drafts.create({ markdown: "自己调过的三色" })).id;
            // 改成这版之前的样子：记录里只有三色
            const records = await readStore("drafts");
            const old = records.filter((record) => Object.values(ids).includes(record.id)).map((record) => {
              const [bg, text, accent] = record.id === ids.custom ? ["#ffffff", "#202938", "#2563eb"] : [record.colors.bg, record.colors.text, record.colors.accent];
              return { ...record, colors: { bg, text, accent } };
            });
            await writeStore("drafts", old);
            return ids;
        """) as? [String: String] ?? [:]
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const themes = await mc.themes.list();
            const loaded = {};
            for (const theme of themes) {
              const draft = await mc.drafts.open(ids[theme.id]);
              await mc.render.pages();
              loaded[theme.id] = { same: same(draft.colors, theme.colors), secondary: theme.colors.secondary === theme.colors.text };
            }
            const custom = (await mc.drafts.open(ids.custom)).colors;
            return { loaded, custom, themes: themes.map((theme) => Object.keys(theme.colors).join(",")) };
        """, arguments: ["ids": ids]) as? [String: Any]
        await harness.tearDown()

        let loaded = result?["loaded"] as? [String: [String: Bool]] ?? [:]
        #expect(loaded.count == ThemeTests.ids.count)
        for (theme, entry) in loaded {
            #expect(entry["same"] == true, "\(theme)：三色的旧稿子与主题配色一致")
            #expect(entry["secondary"] == true, "\(theme)：主题的辅助色就是正文色")
        }
        #expect(result?["custom"] as? [String: String] == [
            "bg": "#ffffff", "text": "#202938", "accent": "#2563eb", "secondary": "#202938", "surface": "#e9eaeb",
        ])
        #expect(result?["themes"] as? [String] == Array(repeating: "bg,text,accent,secondary,surface", count: ThemeTests.ids.count))
        #expect(harness.pageErrors == [])
    }

    @Test("卡片用上两个新角色：标题是辅助色，表头、代码块画在衬底上；引用竖线还是强调色（默认的备忘，引用只画竖线不画底）")
    func cardsPaintNewRoles() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({
              mode: "cards",
              markdown: "# 标题\\n\\n> 引用\\n\\n| 表头 | 二 |\\n| --- | --- |\\n| 一 | 二 |\\n\\n```\\ncode\\n```",
              colors: { bg: "#ffffff", text: "#222222", accent: "#1a56db", secondary: "#8a1c1c", surface: "#e3f0e3" },
            });
            const [page] = await mc.render.pages();
            const [canvas] = await mc.render.canvases();
            const at = (x, y) => {
              const [r, g, b] = canvas.getContext("2d").getImageData(Math.round(x * 2), Math.round(y * 2), 1, 1).data;
              return `#${[r, g, b].map((value) => value.toString(16).padStart(2, "0")).join("")}`;
            };
            const item = (kind) => page.items.find((entry) => entry.kind === kind);
            const heading = page.items.find((entry) => entry.blockType === "h1");
            // 标题的字：这一行里离底色最远的像素
            const context = canvas.getContext("2d");
            const { data } = context.getImageData(heading.x * 2, heading.y * 2, 200, heading.height * 2);
            let darkest = "#ffffff";
            for (let index = 0; index < data.length; index += 4) {
              const hex = `#${[data[index], data[index + 1], data[index + 2]].map((value) => value.toString(16).padStart(2, "0")).join("")}`;
              if (luminance(hex) < luminance(darkest)) darkest = hex;
            }
            const quote = item("quote");
            const table = item("table");
            const code = item("code");
            return {
              heading: darkest,
              quoteBar: at(quote.x + 3, quote.y + quote.height / 2),
              quoteBlock: at(quote.x + quote.width - 8, quote.y + quote.height / 2),
              tableHeader: at(table.x + table.cellWidth - 6, table.y + 4),
              codeBlock: at(code.x + code.width - 8, code.y + code.height / 2),
            };
        """) as? [String: String]
        await harness.tearDown()

        #expect(result?["heading"] == "#8a1c1c")
        #expect(result?["quoteBar"] == "#1a56db")
        #expect(result?["quoteBlock"] == "#ffffff", "备忘的引用不画衬底")
        #expect(result?["tableHeader"] == "#e3f0e3")
        #expect(result?["codeBlock"] == "#e3f0e3")
        #expect(harness.pageErrors == [])
    }

    @Test("配色库：48 组、6 类各 8 组；点一格套用到这篇，⌘Z 撤回；深色主题先列深色，「适合当前主题」只列深浅一致的")
    func libraryApplyUndoAndFilter() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# 标题\\n\\n> 引用" });
            await mc.themes.apply("notes");
            const before = (await mc.drafts.current()).colors;
            const list = await mc.palettes.list();
            const sakura = list.find((palette) => palette.name === "桜");
            await openLibrary();
            ui.click("桜");
            await until(async () => same((await mc.drafts.current()).colors, sakura.colors), "套用桜");
            await until(() => ui.find("桜").getAttribute("aria-current") === "true", "桜标为当前");
            const corner = await cornerPixel();
            document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "z", metaKey: true, bubbles: true, cancelable: true }));
            await until(async () => same((await mc.drafts.current()).colors, before), "⌘Z 撤回");
            await mc.drafts.redo();
            const redone = same((await mc.drafts.current()).colors, sakura.colors);

            await mc.themes.apply("ink");
            await until(() => tiles()[0] && list.find((palette) => palette.id === tiles()[0].dataset.paletteId).tone === "dark", "深色配色在前");
            const firstTones = [...document.querySelectorAll("[aria-label='配色库面板'] .palette-grid")]
              .map((grid) => list.find((palette) => palette.id === grid.querySelector("[data-palette-id]").dataset.paletteId).tone);
            ui.click("适合当前主题");
            const shown = tiles().map((tile) => list.find((palette) => palette.id === tile.dataset.paletteId));
            ui.click("霓虹赛博");
            const neon = tiles().map((tile) => tile.dataset.paletteId);
            return {
              count: list.filter((palette) => palette.builtIn).length,
              categories: [...new Set(list.map((palette) => palette.category))],
              perCategory: [...new Set(list.map((palette) => palette.category))].map((category) => list.filter((palette) => palette.category === category).length),
              tonesMatch: list.every((palette) => palette.tone === (luminance(palette.colors.bg) < 0.4 ? "dark" : "light")),
              corner, sakuraBg: sakura.colors.bg, redone, firstTones,
              filtered: shown.every((palette) => palette.tone === "dark"),
              filteredCount: shown.length,
              darkCount: list.filter((palette) => palette.tone === "dark").length,
              neon,
              darkNeon: list.filter((palette) => palette.category === "neon" && palette.tone === "dark").map((palette) => palette.id),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["count"] as? Int == 48)
        #expect(result?["categories"] as? [String] == ["morandi", "japanese", "film", "nature", "neon", "mono"])
        #expect(result?["perCategory"] as? [Int] == [8, 8, 8, 8, 8, 8])
        #expect(result?["tonesMatch"] as? Bool == true, "浅 / 深的标记与底色一致")
        #expect(result?["corner"] as? String == result?["sakuraBg"] as? String, "舞台换成了桜的底色")
        #expect(result?["redone"] as? Bool == true)
        #expect(result?["firstTones"] as? [String] == Array(repeating: "dark", count: 6), "纯黑主题：每一类都是深色配色在前")
        #expect(result?["filtered"] as? Bool == true)
        #expect(result?["filteredCount"] as? Int == result?["darkCount"] as? Int)
        #expect(result?["neon"] as? [String] == result?["darkNeon"] as? [String])
        #expect(harness.pageErrors == [])
    }

    @Test("我的配色：存（界面与 API）、删，重新载入后还在；内置的不能删")
    func myPalettesPersist() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let saved = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await mc.palettes.apply("neon-01");
            await openLibrary();
            ui.find("配色名字").value = "夜里的霓虹";
            ui.click("存到我的配色");
            await until(() => ui.find("夜里的霓虹"), "界面上存好的一格");
            const unnamed = await mc.palettes.save();
            const builtIn = await mc.palettes.remove("neon-01").then(() => "resolved", (error) => error.message);
            const missing = await mc.palettes.remove("mine-nothing").then(() => "resolved", (error) => error.message);
            return { unnamed: unnamed.name, builtIn, missing };
        """) as? [String: String]
        try await harness.load()
        let reloaded = try await harness.evaluate(Self.helpers + """
            const mine = (await mc.palettes.list()).filter((palette) => !palette.builtIn);
            const neon = (await mc.palettes.list()).find((palette) => palette.id === "neon-01");
            await openLibrary();
            ui.click("我的配色", { within: "配色分类" });
            await until(() => ui.find("删除「夜里的霓虹」"), "删除按钮");
            ui.click("删除「夜里的霓虹」");
            await until(async () => (await mc.palettes.list()).filter((palette) => !palette.builtIn).length === 1, "删掉一组");
            return {
              names: mine.map((palette) => palette.name),
              categories: mine.map((palette) => palette.category),
              sameColors: mine.every((palette) => same(palette.colors, neon.colors)),
              tones: mine.map((palette) => palette.tone),
            };
        """) as? [String: Any]
        try await harness.load()
        let afterRemove = try await harness.evaluate(Self.helpers + """
            return (await mc.palettes.list()).filter((palette) => !palette.builtIn).map((palette) => palette.name);
        """) as? [String]
        await harness.tearDown()

        #expect(saved?["unnamed"] == "我的配色 2", "没起名字时按个数编号")
        #expect(saved?["builtIn"] == "内置的配色不能删")
        #expect(saved?["missing"]?.hasPrefix("我的配色里没有这一组") == true)
        #expect(reloaded?["names"] as? [String] == ["夜里的霓虹", "我的配色 2"])
        #expect(reloaded?["categories"] as? [String] == ["mine", "mine"])
        #expect(reloaded?["sameColors"] as? Bool == true)
        #expect(reloaded?["tones"] as? [String] == ["dark", "dark"])
        #expect(afterRemove == ["我的配色 2"])
        #expect(harness.pageErrors == [])
    }

    @Test("配色规则：把手与辅助色的色相关系；不认识的规则是 TypeError")
    func harmonyRulesKeepHueRelations() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const rules = { analogous: [0, 30, 330], complementary: [0, 180], split: [0, 150, 210], triadic: [0, 120, 240], square: [0, 90, 180, 270], monochrome: [0] };
            const secondary = { analogous: 30, complementary: 180, split: 150, triadic: 120, square: 90, monochrome: 0 };
            const off = (value, target) => Math.min(turn(value, target), turn(target, value));
            const problems = [];
            for (const base of ["#2f7df6", "#d9480f", "#2f9e44"]) {
              for (const [rule, offsets] of Object.entries(rules)) {
                for (const tone of ["light", "dark"]) {
                  const result = await mc.palettes.harmony({ base, rule, tone });
                  const label = `${base} ${rule} ${tone}`;
                  const handles = result.hues.map((value) => Math.round(turn(result.hues[0], value)) % 360);
                  if (JSON.stringify(handles) !== JSON.stringify(offsets)) problems.push(`${label} 把手 ${handles}`);
                  if (off(result.hues[0], hue(base)) > 1) problems.push(`${label} 基准色相`);
                  if (off(hue(result.colors.accent), result.hues[0]) > 4) problems.push(`${label} 强调色相 ${hue(result.colors.accent)}`);
                  const expected = (result.hues[0] + secondary[rule]) % 360;
                  if (off(hue(result.colors.secondary), expected) > 5) problems.push(`${label} 辅助色相 ${hue(result.colors.secondary)} ≠ ${expected}`);
                  if ((tone === "dark") !== (luminance(result.colors.bg) < 0.4)) problems.push(`${label} 深浅`);
                }
              }
            }
            const badRule = await mc.palettes.harmony({ base: "#2f7df6", rule: "rainbow" }).then(() => "resolved", (error) => error.name);
            const badBase = await mc.palettes.harmony({ base: "blue", rule: "triadic" }).then(() => "resolved", (error) => error.name);
            return { problems, badRule, badBase };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["problems"] as? [String] == [])
        #expect(result?["badRule"] as? String == "TypeError")
        #expect(result?["badBase"] as? String == "TypeError")
        #expect(harness.pageErrors == [])
    }

    @Test("对比度保护：配色规则推出的、粘贴分配的、内置的配色，文字与强调对底色 ≥ 4.5:1，辅助 ≥ 3:1，衬底上的正文 ≥ 4.5:1，报告与实测一致")
    func contrastGuard() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let problems = try await harness.evaluate(Self.helpers + """
            const problems = [];
            const check = (label, colors, contrast) => {
              const measured = {
                text: ratio(colors.text, colors.bg), accent: ratio(colors.accent, colors.bg),
                secondary: ratio(colors.secondary, colors.bg), surface: ratio(colors.text, colors.surface),
              };
              const minimum = { text: 4.5, accent: 4.5, secondary: 3, surface: 4.5 };
              for (const [role, value] of Object.entries(measured)) {
                if (value < minimum[role]) problems.push(`${label} ${role} ${value.toFixed(2)}`);
                if (contrast && Math.abs(contrast[role].ratio - value) > 0.01) problems.push(`${label} ${role} 报告 ${contrast[role].ratio} 实测 ${value.toFixed(2)}`);
              }
            };
            const adjusted = [];
            for (const base of ["#ffe600", "#7fffd4", "#808080", "#ff00ff", "#00ff00", "#0000ff"]) {
              for (const rule of ["analogous", "complementary", "split", "triadic", "square", "monochrome"]) {
                for (const tone of ["light", "dark"]) {
                  const result = await mc.palettes.harmony({ base, rule, tone });
                  check(`${base} ${rule} ${tone}`, result.colors, result.contrast);
                  adjusted.push(...result.adjusted);
                }
              }
            }
            await mc.drafts.create({ markdown: "正文" });
            for (const list of [["#ffe066", "#fff3b0", "#f4d35e", "#ee964b"], ["#0b132b", "#1c2541", "#3a506b", "#5bc0be", "#6fffe9"]]) {
              check(list.join(" "), (await mc.palettes.apply(list)).colors);
            }
            for (const palette of (await mc.palettes.list()).filter((item) => item.builtIn)) check(palette.name, palette.colors);
            if (!adjusted.length) problems.push("这些基准色里总该有要调的");
            return problems;
        """) as? [String]
        await harness.tearDown()

        #expect(problems == [])
        #expect(harness.pageErrors == [])
    }

    @Test("粘贴色值：按明暗分给五个角色并做对比度保护；界面里粘贴、分配、应用，与 API 一样，⌘Z 撤回；只认 # 开头的写法，没有 # 的数字不算")
    func pastedHexMapping() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const list = ["#264653", "#2a9d8f", "#e9c46a", "#f4a261", "#e76f51"];
            await mc.drafts.create({ markdown: "# 标题\\n\\n正文" });
            await mc.themes.apply("notes");
            const before = (await mc.drafts.current()).colors;
            const api = (await mc.palettes.apply(list)).colors;
            await mc.drafts.undo();
            const undone = same((await mc.drafts.current()).colors, before);
            ui.expand("色轮");
            await until(() => document.querySelector("[aria-label='五个角色'] code").textContent === before.bg, "色轮面板");
            const codes = () => [...document.querySelectorAll("[aria-label='五个角色'] code")].map((code) => code.textContent);
            // 没有 # 的一串数字、十六进制（电话、年份、Coolors 网址里的写法）都不算色值
            ui.find("粘贴色值").value = "电话 123456，2026 年，https://coolors.co/264653-2a9d8f-e9c46a";
            ui.click("分配");
            const bareRejected = { note: document.querySelector(".wheel-note").textContent, codes: codes() };
            ui.find("粘贴色值").value = "#264653, #2a9d8f\\n#e9c46a #f4a261 123456 #e76f51";
            ui.click("分配");
            const shown = codes();
            ui.click("应用");
            await until(async () => same((await mc.drafts.current()).colors, api), "界面里应用");
            const tooFew = await mc.palettes.apply(["#ffffff", "#000000"]).then(() => "resolved", (error) => error.name);
            return {
              api, undone, shown, tooFew, bareRejected, before: ["bg", "text", "accent", "secondary", "surface"].map((role) => before[role]),
              accentHue: Math.abs(hue(api.accent) - hue("#e76f51")),
              secondaryHue: Math.abs(hue(api.secondary) - hue("#2a9d8f")),
              // 配色先落进稿子，面板随后收起：等它收起（收不起来就是 true）
              wheelOpen: await until(() => !document.querySelector("#colorWheel").open, "面板收起", 3000).then(() => false, () => true),
            };
        """) as? [String: Any]
        await harness.tearDown()

        let api = result?["api"] as? [String: String] ?? [:]
        #expect(api["bg"] == "#e9c46a", "最亮的当背景")
        #expect(api["text"] == "#264653", "最暗的当文字")
        #expect(api["surface"] == "#f4a261", "和背景明度最接近的当衬底")
        #expect((result?["accentHue"] as? Double ?? 99) < 4, "彩度最高的当强调（保护后色相不变）")
        #expect((result?["secondaryHue"] as? Double ?? 99) < 4, "其次的当辅助")
        #expect(result?["undone"] as? Bool == true)
        #expect(result?["shown"] as? [String] == ["bg", "text", "accent", "secondary", "surface"].map { api[$0] ?? "" })
        let bare = result?["bareRejected"] as? [String: Any]
        let bareNote = bare?["note"] as? String ?? ""
        #expect(bareNote.contains("至少要三个颜色"), "没有 # 的都不算：一个色值也没有")
        #expect(bare?["codes"] as? [String] == result?["before"] as? [String], "没分配成，色块还是原来的配色")
        #expect(result?["tooFew"] as? String == "TypeError")
        #expect(result?["wheelOpen"] as? Bool == false, "应用后面板收起")
        #expect(harness.pageErrors == [])
    }

    @Test("色轮：选规则、方向键转把手时舞台实时预览，稿子不变；取消回到原来的配色；应用是撤销历史里的一步")
    func wheelPreviewCancelApply() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# 标题\\n\\n正文" });
            await mc.themes.apply("notes");
            const before = (await mc.drafts.current()).colors;
            const code = () => [...document.querySelectorAll("[aria-label='五个角色'] code")].map((item) => item.textContent);
            const current = ["bg", "text", "accent", "secondary", "surface"].map((role) => before[role]).join();
            ui.expand("色轮");
            await until(() => code().join() === current, "色轮面板显示现在的配色");
            const initial = code();
            ui.click("互补", { within: "配色规则" });
            const complementary = code();
            await until(async () => (await cornerPixel()) === complementary[0], "舞台预览互补配色");
            const draftDuringPreview = same((await mc.drafts.current()).colors, before);
            const handle = ui.find("基准色");
            handle.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
            const turned = code();
            ui.click("取消");
            await until(async () => (await cornerPixel()) === before.bg, "取消后回到原来的底色");
            const afterCancel = same((await mc.drafts.current()).colors, before);

            ui.expand("色轮");
            await until(() => code().join() === current, "再打开色轮");
            ui.click("三角", { within: "配色规则" });
            const triadic = code();
            ui.click("应用");
            await until(async () => (await mc.drafts.current()).colors.bg === triadic[0], "应用三角配色");
            const applied = (await mc.drafts.current()).colors;
            await mc.drafts.undo();
            const undone = same((await mc.drafts.current()).colors, before);
            return {
              initial, before: ["bg", "text", "accent", "secondary", "surface"].map((role) => before[role]),
              changed: complementary.join() !== initial.join(), turned: turned.join() !== complementary.join(),
              draftDuringPreview, afterCancel, applied: ["bg", "text", "accent", "secondary", "surface"].map((role) => applied[role]),
              triadic, undone,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["initial"] as? [String] == result?["before"] as? [String], "打开时显示这篇现在的配色")
        #expect(result?["changed"] as? Bool == true)
        #expect(result?["turned"] as? Bool == true, "方向键转动基准色")
        #expect(result?["draftDuringPreview"] as? Bool == true, "预览不改稿子")
        #expect(result?["afterCancel"] as? Bool == true)
        #expect(result?["applied"] as? [String] == result?["triadic"] as? [String])
        #expect(result?["undone"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("色轮：拖基准色改色相（按住拖动一路跟着变）；拖别的把手整组一起转，规则的色相关系不变")
    func wheelHandlesDrag() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# 标题\\n\\n正文" });
            await mc.themes.apply("notes");
            const code = () => [...document.querySelectorAll("[aria-label='五个角色'] code")].map((item) => item.textContent);
            ui.expand("色轮");
            await until(() => code()[0] === "#ffffff", "色轮面板");
            ui.click("类比", { within: "配色规则" });
            const stage = ui.find("基准色").parentElement;
            const box = stage.getBoundingClientRect();
            // 色轮直径 200，圆心在 (100, 100)；色相 0° 在右边、逆时针转
            const fire = (target, type, x, y) => target.dispatchEvent(new PointerEvent(type, {
              pointerId: 1, pointerType: "mouse", isPrimary: true, button: 0, buttons: type === "pointerup" ? 0 : 1,
              clientX: box.left + x, clientY: box.top + y, bubbles: true, cancelable: true,
            }));
            const base = ui.find("基准色");
            fire(base, "pointerdown", 100, 20);
            const up = hue(code()[2]);
            fire(stage, "pointermove", 180, 100);
            const right = hue(code()[2]);
            fire(stage, "pointerup", 180, 100);
            const second = ui.find("配色点 2");
            const rect = second.getBoundingClientRect();
            fire(second, "pointerdown", rect.left + rect.width / 2 - box.left, rect.top + rect.height / 2 - box.top);
            fire(stage, "pointermove", 100, 180);
            fire(stage, "pointerup", 100, 180);
            const turned = code();
            await until(async () => (await cornerPixel()) === turned[0], "舞台跟着预览");
            return {
              up, right, turnedAccent: hue(turned[2]), turnedSecondary: hue(turned[3]),
              draftUnchanged: (await mc.drafts.current()).colors.bg === "#ffffff",
            };
        """) as? [String: Any]
        await harness.tearDown()

        let off = { (value: Double, target: Double) -> Double in
            let delta = abs(value - target).truncatingRemainder(dividingBy: 360)
            return min(delta, 360 - delta)
        }
        #expect(off(result?["up"] as? Double ?? -99, 90) < 4, "拖到正上方：色相 90°")
        #expect(off(result?["right"] as? Double ?? -99, 0) < 4, "拖到右边：色相 0°")
        #expect(off(result?["turnedAccent"] as? Double ?? -99, 240) < 4, "类比的第二个把手（+30°）拖到正下方 270°，基准色转到 240°")
        #expect(off(result?["turnedSecondary"] as? Double ?? -99, 270) < 5, "辅助色跟着第二个把手")
        #expect(result?["draftUnchanged"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("换主题重置这篇的配色；「恢复主题配色」还原，⌘Z 撤回")
    func themeChangeResetsPalette() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await mc.themes.apply("notes");
            const themes = await mc.themes.list();
            const theme = (id) => themes.find((item) => item.id === id).colors;
            await mc.palettes.apply("film-06");
            const night = same((await mc.themes.apply("ink")).colors, theme("ink"));
            await mc.palettes.apply("japanese-03");
            ui.click("恢复主题配色");
            await until(async () => same((await mc.drafts.current()).colors, theme("ink")), "恢复主题配色");
            await until(() => ui.find("恢复主题配色").disabled, "按钮停用");
            const disabled = ui.find("恢复主题配色").disabled;
            await mc.drafts.undo();
            const undone = (await mc.drafts.current()).colors;
            const sakura = (await mc.palettes.list()).find((palette) => palette.id === "japanese-03").colors;
            return { night, undone: same(undone, sakura), disabled };
        """) as? [String: Bool]
        await harness.tearDown()

        #expect(result?["night"] == true)
        #expect(result?["undone"] == true)
        #expect(result?["disabled"] == true, "已经是主题配色时按钮停用")
        #expect(harness.pageErrors == [])
    }
}
