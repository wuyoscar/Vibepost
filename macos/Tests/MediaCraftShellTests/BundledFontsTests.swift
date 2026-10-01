import Foundation
import Testing

/// 打包字体：`scripts/fetch-fonts.py` 下载到仓库根目录的 `fonts/`（不进 git），页面从那里加载。
@MainActor
struct BundledFontsTests {
    static let helpers = """
        window.cardHashes = async () => (await window.mediacraft.render.canvases()).map((canvas) => {
          const data = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
          let hash = 2166136261;
          for (let i = 0; i < data.length; i += 4) {
            hash ^= data[i] | (data[i + 1] << 8) | (data[i + 2] << 16);
            hash = Math.imul(hash, 16777619);
          }
          return (hash >>> 0).toString(16);
        }).join(",");
        window.manifestFonts = async () => (await (await fetch("fonts/manifest.json")).json()).fonts;
        // 检查器「样式」标签里的字体选单：按钮的可访问名称是「中文字体 / 英文字体 / 代码字体 + 当前字体」
        window.openSettings = () => ui.click("样式");
        window.fontButton = (label) => {
          openSettings();
          return ui.find(label);
        };
        window.fontList = (button) => document.getElementById(button.getAttribute("aria-controls"));
        window.optionLabel = (option) => ui.name(option).replace(/未下载$/, "");
        window.pickFont = (button, label) => {
          button.click();
          ui.click(label, { within: fontList(button) });
        };
        // 等下一次出图画完（字体选单选完后排版是异步触发的）
        window.nextRender = () => new Promise((resolve) => {
          const off = window.mediacraft.on("rendered", () => {
            off();
            resolve();
          });
        });
        window.pressKey = (target, key) => target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    """

    /// 需要打包字体的测试：fonts/ 没生成时给出明确提示。
    static func requireBundledFonts() throws {
        let manifest = ShellHarness.repoRoot.appendingPathComponent("fonts/manifest.json")
        try #require(
            FileManager.default.fileExists(atPath: manifest.path),
            "fonts/ 不存在：先运行 python3 scripts/fetch-fonts.py 下载打包字体"
        )
    }

    /// 与 Release 包相同的网页目录，但不含 fonts/。
    static func webRootWithoutFonts() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-nofonts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        for item in ["index.html", "src", "brand", "docs/guide-assets"] {
            try FileManager.default.copyItem(
                at: ShellHarness.repoRoot.appendingPathComponent(item), to: root.appendingPathComponent(item)
            )
        }
        return root
    }

    @Test("选打包字体：卡片改用该字体，分页前等字体加载完，换字体后的第一次出图就是最终画面")
    func bundledFontIsLoadedBeforePagination() async throws {
        try Self.requireBundledFonts()
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const mc = window.mediacraft;
            await mc.drafts.create({
              markdown: "# Heading Font\\n\\n" + "The quick brown fox **jumps over** the lazy dog 敏捷的狐狸。".repeat(30),
            });
            const before = await cardHashes();
            const rendered = nextRender();
            pickFont(fontButton("英文字体"), "Source Serif 4");
            await rendered;
            const first = await cardHashes();
            await document.fonts.ready;
            await mc.render.refresh();
            const family = (await manifestFonts()).find((font) => font.id === "source-serif-4").family;
            return {
              value: (await mc.drafts.current()).fonts.en,
              changed: first !== before,
              stable: first === await cardHashes(),
              loaded: [400, 600, 700].every((weight) => document.fonts.check(`${weight} 34px "${family}"`, "The quick brown fox")),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["value"] as? String == "source-serif-4")
        #expect(result?["changed"] as? Bool == true)
        #expect(result?["stable"] as? Bool == true, "第一次出图用的是回退字体，分页与最终画面不一致")
        #expect(result?["loaded"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("字体选单：跟随主题在最前，每项用自己的字体写名字，键盘可以打开、选择、关闭")
    func fontPickerShowsEntriesInTheirOwnFont() async throws {
        try Self.requireBundledFonts()
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const mc = window.mediacraft;
            await mc.drafts.create({ markdown: "字体选单测试" });
            const { zh: choices } = await mc.fonts.list();
            const idOf = (option) => choices.find((font) => font.label === optionLabel(option))?.id;
            const button = fontButton("中文字体");
            const styleTab = ui.find("样式");
            const list = fontList(button);
            const active = () => optionLabel(document.getElementById(list.getAttribute("aria-activedescendant")));
            button.focus();
            pressKey(button, "ArrowDown");
            const opened = !list.hidden && document.activeElement === list && button.getAttribute("aria-expanded") === "true";
            const options = [...list.querySelectorAll('[role="option"]')];
            list.getBoundingClientRect();
            await document.fonts.ready;
            const fonts = await manifestFonts();
            const notOwnFont = options.filter((option) => {
              const bundled = fonts.find((font) => font.id === idOf(option));
              const family = getComputedStyle(option).fontFamily;
              if (!bundled) return !option.style.fontFamily;
              return !family.includes(bundled.family) || !document.fonts.check(`16px "${bundled.family}"`, option.textContent);
            }).map(idOf);
            const startKey = active();
            pressKey(list, "ArrowDown");
            const nextKey = active();
            const rendered = nextRender();
            pressKey(list, "Enter");
            const closed = list.hidden;
            const focusBack = document.activeElement === button;
            const chosen = { value: (await mc.drafts.current()).fonts.zh, closed, focusBack };
            await rendered;
            const family = fonts.find((font) => font.id === "noto-sans-sc").family;
            const cardUsesFont = document.fonts.check(`400 34px "${family}"`, "字体选单测试");
            button.click();
            pressKey(list, "Escape");
            return {
              opened, labels: options.map(optionLabel), ids: choices.map((font) => font.id), notOwnFont, startKey, nextKey, chosen, cardUsesFont,
              escapeClosesOnlyList: list.hidden && styleTab.getAttribute("aria-selected") === "true" && ui.find("中文字体") === button,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["opened"] as? Bool == true)
        #expect(result?["labels"] as? [String] == ["跟随主题", "思源黑体", "思源宋体", "霞鹜文楷", "得意黑", "苹方", "宋体"])
        #expect(result?["ids"] as? [String] == [
            "theme", "noto-sans-sc", "noto-serif-sc", "lxgw-wenkai", "smiley-sans", "zh-pingfang", "zh-song",
        ])
        #expect(result?["notOwnFont"] as? [String] == [])
        #expect(result?["startKey"] as? String == "跟随主题")
        #expect(result?["nextKey"] as? String == "思源黑体")
        let chosen = result?["chosen"] as? [String: Any]
        #expect(chosen?["value"] as? String == "noto-sans-sc")
        #expect(chosen?["closed"] as? Bool == true)
        #expect(chosen?["focusBack"] as? Bool == true)
        #expect(result?["cardUsesFont"] as? Bool == true)
        #expect(result?["escapeClosesOnlyList"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("没有 fonts/：页面照常启动、无报错；打包字体标为未下载，已选的保留并回退系统字体")
    func missingFontsFolderFallsBackQuietly() async throws {
        let root = try Self.webRootWithoutFonts()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = ShellHarness(webRoot: root)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const mc = window.mediacraft;
            await mc.drafts.create({ markdown: "# 回退\\n\\n系统字体 Fallback text **粗体**" });
            const fallback = await cardHashes();
            await mc.drafts.update({ fonts: { zh: "noto-serif-sc", en: "inter" } });
            const same = await cardHashes() === fallback;
            const { fonts: kept } = await mc.drafts.update({ fonts: { zh: "lxgw-wenkai", en: "fira-code" } });
            const { zh: choices } = await mc.fonts.list();
            const button = fontButton("中文字体");
            button.click();
            return {
              same,
              kept: [kept.zh, kept.en],
              unavailable: [...fontList(button).querySelectorAll('[aria-disabled="true"]')]
                .map((option) => choices.find((font) => font.label === optionLabel(option))?.id),
              notAvailable: choices.filter((font) => !font.available).map((font) => font.id),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["same"] as? Bool == true)
        #expect(result?["kept"] as? [String] == ["lxgw-wenkai", "fira-code"])
        #expect(result?["unavailable"] as? [String] == ["noto-sans-sc", "noto-serif-sc", "lxgw-wenkai", "smiley-sans"])
        #expect(result?["notAvailable"] as? [String] == ["noto-sans-sc", "noto-serif-sc", "lxgw-wenkai", "smiley-sans"])
        #expect(harness.pageErrors == [])
    }

    @Test("跟随主题：用这篇主题自带的中文、英文、代码字体（没有另带标题字体的主题各一组）；没有 fonts/ 时回退系统字体")
    func followThemeUsesThemeFonts() async throws {
        try Self.requireBundledFonts()
        let root = try Self.webRootWithoutFonts()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = Self.helpers + """
            const mc = window.mediacraft;
            const draft = await mc.drafts.create({
              markdown: "# 标题 Title\\n\\n正文 **粗体 bold** *斜体 italic* `code()` 2026\\n\\n- 列表 item\\n\\n> 引用 quote",
            });
            const result = { defaults: { fonts: [draft.fonts.zh, draft.fonts.en, draft.fonts.code] } };
            for (const [theme, fonts] of Object.entries(explicit)) {
              await mc.themes.apply(theme);
              await mc.drafts.update({ fonts: { zh: "theme", en: "theme", code: "theme" } });
              const follow = await cardHashes();
              await mc.drafts.update({ fonts: { zh: fonts[0], en: fonts[1], code: fonts[2] } });
              result[theme] = { follow, same: follow === await cardHashes() };
            }
            return result;
        """
        let bundled = ShellHarness()
        try await bundled.load()
        let withFonts = try await bundled.evaluate(script, arguments: ["explicit": [
            "plain": ["noto-sans-sc", "inter", "jetbrains-mono"],
            "ink": ["noto-sans-sc", "inter", "jetbrains-mono"],
            "editorial": ["noto-serif-sc", "source-serif-4", "ibm-plex-mono"],
            "notes": ["noto-sans-sc", "inter", "jetbrains-mono"],
            "glow": ["noto-sans-sc", "inter", "jetbrains-mono"],
        ]]) as? [String: [String: Any]]
        await bundled.tearDown()
        let missing = ShellHarness(webRoot: root)
        try await missing.load()
        let withoutFonts = try await missing.evaluate(script, arguments: ["explicit": [
            "notes": ["zh-pingfang", "en-sf", "code-menlo"], "editorial": ["zh-pingfang", "en-sf", "code-menlo"],
        ]]) as? [String: [String: Any]]
        await missing.tearDown()

        #expect(withFonts?["defaults"]?["fonts"] as? [String] == ["theme", "theme", "theme"], "新稿子的字体默认跟随主题")
        // 带标题字体的主题（陶土、手帐、撞色）自己选了字体时标题也换，不在这里比
        for theme in ["plain", "ink", "editorial", "notes", "glow"] {
            #expect(withFonts?[theme]?["same"] as? Bool == true, "\(theme)：跟随主题 = 这个主题的中文、英文、代码字体")
        }
        #expect(withoutFonts?["notes"]?["same"] as? Bool == true, "没有 fonts/ 时回退系统字体（苹方 / SF / Menlo）")
        #expect(withoutFonts?["editorial"]?["same"] as? Bool == true, "没有 fonts/ 时回退系统字体（苹方 / SF / Menlo）")
        #expect(withFonts?["notes"]?["follow"] as? String != withoutFonts?["notes"]?["follow"] as? String, "有 fonts/ 时备忘用的是打包字体")
        #expect(bundled.pageErrors == [])
        #expect(missing.pageErrors == [])
    }

    @Test("去掉不生效的字体：旧稿子的楷体、黑体、Rounded 与旧默认值改为跟随主题；列出的系统字体都真正解析得到")
    func removedFontsMigrateAndListedSystemFontsResolve() async throws {
        let harness = ShellHarness()
        // 存一批用着已去掉的字体的稿子，打开后逐篇看字体
        try await harness.prepareStorage(StorageScripts.seed + """
            const pairs = [["zh-kai", "en-rounded"], ["zh-hei", "en-system"], ["zh-system", "en-serif"], ["zh-song", "en-mono"]];
            await seedStore({
              drafts: pairs.map(([zh, en], index) => ({
                id: `project_font_${index}`, title: `旧字体 ${index}`, markdown: `旧字体稿 ${index}`, mode: "cards", theme: "notes",
                colors: {}, fonts: { zh, en, code: "theme" }, images: {}, createdAt: index + 1, updatedAt: index + 1,
              })),
            });
        """)
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            const migrated = [];
            for (let index = 0; index < 4; index += 1) {
              const { fonts } = await mc.drafts.open(`project_font_${index}`);
              migrated.push([fonts.zh, fonts.en]);
            }
            // 去掉末尾的通用族，再分别接 serif / sans-serif / monospace：三种画出来一样，说明前面的具名字体真的解析到了。
            const canvas = document.createElement("canvas");
            canvas.width = 480;
            canvas.height = 80;
            const context = canvas.getContext("2d");
            const draw = (font, text) => {
              context.clearRect(0, 0, canvas.width, canvas.height);
              context.font = font;
              context.fillText(text, 4, 56);
              return context.getImageData(0, 0, canvas.width, canvas.height).data.join();
            };
            const choices = await mc.fonts.list();
            const unresolved = ["zh", "en"].flatMap((script) => choices[script]
              .filter((font) => !font.bundled && font.id !== "theme")
              .filter((font) => {
                const named = font.family.replace(/,\\s*(serif|sans-serif|monospace)\\s*$/, "");
                const [serif, sans, mono] = ["serif", "sans-serif", "monospace"].map((generic) => draw(`400 40px ${named}, ${generic}`, font.label));
                return serif !== sans || sans !== mono;
              })
              .map((font) => font.id));
            return { migrated, unresolved };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["migrated"] as? [[String]] == [["theme", "theme"], ["theme", "theme"], ["theme", "en-serif"], ["zh-song", "en-mono"]])
        #expect(result?["unresolved"] as? [String] == [])
        #expect(harness.pageErrors == [])
    }
}
