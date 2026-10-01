import Foundation
import Testing

/// 发布助手（src/publish/）：页脚「检查」的面板与正文标注、标题按显示宽度计字、发送前的确认、发完分别复制、字体许可。
@MainActor
struct PublishAssistantTests {
    static let helpers = """
        const mc = window.mediacraft;
        window.mc = mc;
        // 这组测别的提醒：先填上署名，「署名还没填」不混进条数（它在 IdentityTests 里测）。
        // 新环境打开着说明书，说明书里不能改署名，先新建一篇
        if ((await mc.drafts.current()).readOnly) await mc.drafts.create();
        await mc.profile.update({ name: "测试作者" });
        window.wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        window.until = async (condition, timeout = 15000) => {
          const deadline = Date.now() + timeout;
          while (Date.now() < deadline) {
            const value = await condition();
            if (value) return value;
            await wait(50);
          }
          throw new Error(`等不到：${condition}`);
        };
        window.badge = () => ui.find("检查");
        window.checkPanel = () => document.querySelector('[role="dialog"][aria-labelledby="publishCheckTitle"]');
        // 面板里的每一条：[分组, 警告 / 提示, 名字]
        window.rows = () => [...checkPanel().querySelectorAll(".check-item")].map((row) => [
          row.closest(".check-group").querySelector("h3").firstChild.textContent,
          row.querySelector(".check-level").textContent,
          row.querySelector(".check-label").textContent,
        ]);
        window.labels = () => rows().map((row) => row[2]);
        window.typeTitle = (text) => {
          const input = ui.find("标题");
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        };
        // 正文里标出来的字：[字, 是不是警告]
        window.marks = () => [...document.querySelectorAll("#markdownEditor .cm-hint")].map((mark) => [mark.textContent, mark.classList.contains("is-warn")]);
    """

    static let markdown = "这是最佳的选择，第一次用。\n\n加微信 abc 或打 138-1234-5678，vxworks 不算。\n\n`最佳` 在代码里，看 https://example.com/最佳 就行。"

    @Test("发布检查：极限词、引流词按分组列出、正文里标出；代码、网址里的词与「第一次」不算；跳过去、替换（⌘Z 撤回）、忽略（重新打开还在，可恢复）")
    func panelListsHitsAndFixesThem() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let found = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "最强续航测评", markdown, caption: "续航实测 #测评" });
            await until(() => badge()?.textContent === "检查 · 5");
            ui.click("检查");
            const opened = { visible: !checkPanel().hidden, expanded: badge().getAttribute("aria-expanded"), focused: document.activeElement === checkPanel() };
            return { rows: rows(), marks: marks(), badge: badge().textContent, level: badge().dataset.level, opened };
        """, arguments: ["markdown": Self.markdown]) as? [String: Any]

        let actions = try await harness.evaluate(Self.helpers + """
            ui.click("跳到「手机号」");
            await until(async () => (await mc.editor.selection()).text === "138-1234-5678");
            ui.click("跳到标题里的「最强」");
            const title = ui.find("标题");
            await until(() => document.activeElement === title);
            const titleSelected = title.value.slice(title.selectionStart, title.selectionEnd) === "最强";
            ui.click("改成「很好」", { within: checkPanel() });
            await until(async () => (await mc.drafts.current()).markdown.startsWith("这是很好的选择") && badge().textContent === "检查 · 4");
            const replaced = labels();
            await mc.drafts.undo();
            await until(() => badge().textContent === "检查 · 5");
            const undone = (await mc.drafts.current()).markdown === markdown;
            ui.click("忽略「加微信」");
            await until(() => badge().textContent === "检查 · 4");
            return { titleSelected, replaced, undone, ignored: labels(), status: document.querySelector("#statusText").textContent };
        """, arguments: ["markdown": Self.markdown]) as? [String: Any]

        try await harness.load()
        let reopened = try await harness.evaluate(Self.helpers + """
            await until(() => badge()?.textContent === "检查 · 4");
            ui.click("检查");
            const before = { labels: labels(), restore: ui.find("恢复忽略的 1 处") !== null };
            ui.click("恢复忽略的 1 处");
            await until(() => badge().textContent === "检查 · 5");
            checkPanel().dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
            return { before, after: labels(), closed: checkPanel().hidden && document.activeElement === badge() };
        """) as? [String: Any]
        await harness.tearDown()

        let rows = found?["rows"] as? [[String]]
        #expect(rows == [
            ["极限词", "警告", "最强"], ["极限词", "警告", "最佳"],
            ["引流", "警告", "加微信"], ["引流", "警告", "手机号"], ["引流", "警告", "网址"],
        ], "标题里的词排在正文前面；代码里的「最佳」、网址里的「最佳」、「第一次」、vxworks 都不算")
        #expect(found?["marks"] as? [[AnyHashable]] == [
            ["最佳", true], ["加微信", true], ["138-1234-5678", true], ["https://example.com/最佳", true],
        ] as [[AnyHashable]])
        #expect(found?["badge"] as? String == "检查 · 5")
        #expect(found?["level"] as? String == "warn")
        #expect(found?["opened"] as? [String: AnyHashable] == ["visible": true, "expanded": "true", "focused": true])
        #expect(actions?["titleSelected"] as? Bool == true, "标题里的命中跳到标题框并选中")
        #expect(actions?["replaced"] as? [String] == ["最强", "加微信", "手机号", "网址"])
        #expect(actions?["undone"] as? Bool == true, "替换是撤销历史里的一步")
        #expect(actions?["ignored"] as? [String] == ["最强", "最佳", "手机号", "网址"])
        #expect((actions?["status"] as? String)?.contains("已把「最佳」改成「很好」") == true)
        #expect(reopened?["before"] as? [String: AnyHashable] == ["labels": ["最强", "最佳", "手机号", "网址"], "restore": true], "忽略的记在本机")
        #expect(reopened?["after"] as? [String] == ["最强", "最佳", "加微信", "手机号", "网址"])
        #expect(reopened?["closed"] as? Bool == true, "Esc 收起面板，焦点回到「检查」")
        #expect(harness.pageErrors == [])
    }

    @Test("标题按小红书的显示宽度计字（中文、emoji 1 个，英文、数字半个）；正文栏的话题超 10 个、图片超 18 张、标题超 20 字时提醒；长文不查数量")
    func titleWidthAndLimits() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const count = () => document.querySelector("#titleCount");
            await mc.drafts.create({ markdown: "正文" });
            const widths = [];
            for (const title of ["Hello World 你好世界", "😀👍🏽🇨🇳", "a".repeat(40), "a".repeat(41)]) {
              typeTitle(title);
              widths.push([count().textContent, count().classList.contains("is-over")]);
            }
            const topics = Array.from({ length: 12 }, (_, index) => `#话题${index + 1}`).join(" ");
            await mc.drafts.update({ caption: `去了好多地方\\n${topics}`, markdown: "#卡片上的话题不算 " + Array.from({ length: 19 }, (_, index) => `第 ${index + 1} 页`).join("\\n\\n[[分页]]\\n\\n") });
            await until(() => badge().textContent === "检查 · 3");
            ui.click("检查");
            const limits = rows();
            ui.click("跳到正文栏里的「话题 12 个」");
            const caption = document.querySelector("#captionInput");
            const extraTopic = await until(() => document.activeElement === caption && caption.value.slice(caption.selectionStart, caption.selectionEnd));
            await mc.drafts.update({ mode: "article" });
            await until(() => badge().textContent === "检查");
            return { widths, limits, extraTopic, empty: checkPanel().textContent.includes("没有要改的地方") };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["widths"] as? [[AnyHashable]] == [["10/20", false], ["3/20", false], ["20/20", false], ["21/20", true]] as [[AnyHashable]])
        #expect(result?["limits"] as? [[String]] == [["数量上限", "警告", "标题 21/20"], ["数量上限", "警告", "话题 12 个"], ["数量上限", "警告", "19 张图片"]])
        #expect(result?["extraTopic"] as? String == "#话题11", "跳到正文栏里第一个发不出去的话题")
        #expect(result?["empty"] as? Bool == true, "长文不查标题、话题与图片数")
        #expect(harness.pageErrors == [])
    }

    @Test("发送前自动检查：还有提醒时问一句（去看看 / 仍然发送 / 不再提醒）；用过 AI 提醒声明；发完分别复制标题、正文栏、话题（正文栏的 + AI 建议的）")
    func sendAsksFirstThenCopiesPieces() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["可以带上这几个话题：#周末去哪儿 #城市漫步 #旅行"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let asked = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "周末的城市漫步", markdown: "# 老城区路线\\n\\n#卡片上的话题", caption: "周末去了老城区。\\n\\n#旅行 #散步" });
            await mc.ai.send("为这篇稿子想 5 个话题", { kind: "command", label: "加话题标签" });
            await until(() => badge().textContent === "检查 · 1");
            ui.click("发送到 iPhone");
            const sheet = await until(() => ui.alert());
            const shown = { title: ui.name(sheet), list: sheet.querySelector("ul").textContent, focused: document.activeElement === ui.find("去看看") };
            ui.click("去看看");
            return { shown, closed: ui.alert() === null, panel: !checkPanel().hidden, rows: rows() };
        """) as? [String: Any]
        #expect(harness.sender.batches.isEmpty, "「去看看」不发送")

        _ = try await harness.evaluate(Self.helpers + """
            ui.click("发送到 iPhone");
            await until(() => ui.alert());
            ui.click("仍然发送");
        """)
        try await waitUntil(timeout: .seconds(20)) { harness.sender.batches.count == 1 }
        let bodyOnClipboard = harness.clipboard.text
        var copied: [String] = []
        for name in ["复制标题", "复制话题", "复制正文"] {
            let detail = try await harness.evaluate(Self.helpers + """
                const detail = () => document.querySelector("#outputActivity .activity-detail").textContent;
                const button = await until(() => ui.find(name, { within: "导出进度" }));
                const before = detail();
                button.click();
                await until(() => detail() !== before);
                return detail();
            """, arguments: ["name": name]) as? String ?? ""
            copied.append("\(detail)|\(harness.clipboard.text ?? "")")
        }

        _ = try await harness.evaluate(Self.helpers + """
            ui.click("发送到 iPhone");
            await until(() => ui.alert());
            ui.find("不再提醒（在「检查」里可以重新打开）").click();
            ui.click("仍然发送");
            await until(() => ui.alert() === null);
        """)
        try await waitUntil(timeout: .seconds(20)) { harness.sender.batches.count == 2 }
        _ = try await harness.waitForPage("!ui.find('发送到 iPhone').disabled")
        _ = try await harness.evaluate("ui.click('发送到 iPhone')")
        try await waitUntil(timeout: .seconds(20)) { harness.sender.batches.count == 3 }
        try await harness.load()
        let remembered = try await harness.evaluate(Self.helpers + """
            await until(() => badge());
            ui.click("检查");
            return ui.find("发送前自动检查").checked;
        """) as? Bool
        await harness.tearDown()

        let shown = asked?["shown"] as? [String: AnyHashable]
        #expect(shown?["title"] as? String == "还有 1 处提醒，仍然发送？")
        #expect(shown?["list"] as? String == "AI 声明用过 AI 助手")
        #expect(shown?["focused"] as? Bool == true, "焦点先落在不发送的那个按钮上")
        #expect(asked?["closed"] as? Bool == true)
        #expect(asked?["panel"] as? Bool == true, "「去看看」打开检查面板")
        #expect(asked?["rows"] as? [[String]] == [["AI 声明", "提示", "用过 AI 助手"]])
        #expect(bodyOnClipboard == "周末去了老城区。\n\n#旅行 #散步", "正文栏默认已复制")
        #expect(copied == [
            "已复制标题，粘贴到小红书的标题栏|周末的城市漫步",
            "已复制 4 个话题：#旅行 #散步 #周末去哪儿 #城市漫步|#旅行 #散步 #周末去哪儿 #城市漫步",
            "已复制正文|周末去了老城区。\n\n#旅行 #散步",
        ], "话题：正文栏里的在前（卡片上的不算），AI 建议的去重后接在后面")
        #expect(remembered == false, "「不再提醒」记在本机，检查面板里的开关跟着关上")
        #expect(harness.pageErrors == [])
    }

    @Test("字体选单每项标出许可（打包字体 OFL 可商用，系统字体仅限个人）；用了系统字体导出时提醒一次，可以不再提醒")
    func fontLicenses() async throws {
        try BundledFontsTests.requireBundledFonts()
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let badges = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "字体许可" });
            const button = ui.find("中文字体");
            button.click();
            const list = document.getElementById(button.getAttribute("aria-controls"));
            const options = [...list.querySelectorAll('[role="option"]')].map((option) => [
              ui.name(option).replace(/未下载$/, ""),
              getComputedStyle(option, "::after").content.replace(/^"|"$/g, ""),
            ]);
            button.click();
            const { zh } = await mc.fonts.list();
            return { options, api: zh.map((font) => [font.id, font.license ?? "none"]) };
        """) as? [String: Any]

        let idle = "!ui.find('批量下载').disabled"
        let note = "(() => { const note = document.querySelector('#outputActivity .activity-note'); return note.hidden ? '' : note.textContent.replace(/\\s+/g, ' ').trim(); })()"
        var notes: [String] = []
        for fonts in [
            "{}",
            "{ zh: 'zh-pingfang' }",
            "{ zh: 'zh-pingfang' }",
            "{ en: 'en-sf' }",
        ] {
            _ = try await harness.evaluate("await window.mediacraft.drafts.update({ fonts: \(fonts) }); ui.click('批量下载');")
            _ = try await harness.waitForPage("document.querySelector('#outputActivity').dataset.state === 'success'", timeout: .seconds(30))
            notes.append(try await harness.evaluate("return \(note)") as? String ?? "")
            _ = try await harness.waitForPage(idle)
        }
        _ = try await harness.evaluate("ui.click('不再提醒', { within: '导出进度' })")
        let dismissed = try await harness.evaluate("return \(note)") as? String
        _ = try await harness.evaluate("await window.mediacraft.drafts.update({ fonts: { code: 'code-menlo' }, markdown: '用 `code` 写' }); ui.click('批量下载');")
        _ = try await harness.waitForPage("document.querySelector('#outputActivity').dataset.state === 'success'", timeout: .seconds(30))
        let afterDismiss = try await harness.evaluate("return \(note)") as? String
        await harness.tearDown()

        #expect(badges?["options"] as? [[String]] == [
            ["跟随主题", "none"], ["思源黑体", "OFL 可商用"], ["思源宋体", "OFL 可商用"], ["霞鹜文楷", "OFL 可商用"], ["得意黑", "OFL 可商用"],
            ["苹方", "系统字体 · 仅限个人"], ["宋体", "系统字体 · 仅限个人"],
        ])
        #expect(badges?["api"] as? [[String]] == [
            ["theme", "none"], ["noto-sans-sc", "ofl"], ["noto-serif-sc", "ofl"], ["lxgw-wenkai", "ofl"], ["smiley-sans", "ofl"],
            ["zh-pingfang", "system"], ["zh-song", "system"],
        ])
        #expect(notes == [
            "",
            "用了系统字体「苹方」，只限个人使用；商用请换成打包的开源字体 不再提醒",
            "",
            "用了系统字体「苹方」「SF」，只限个人使用；商用请换成打包的开源字体 不再提醒",
        ], "打包字体不提醒；同一篇同样的字体只提醒一次，换了字体再提醒")
        #expect(dismissed == "")
        #expect(afterDismiss == "", "点了「不再提醒」以后都不提醒")
        #expect(harness.pageErrors == [])
    }
}
