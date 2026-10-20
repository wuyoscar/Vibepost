import Foundation
import MediaCraftMCP
import Testing
@testable import MediaCraftShell

/// 写作手册：用户自己的，补充题材的口味，每份一个 .md（开头 name / description，后面是正文），放在支持目录的「写作手册」文件夹
/// （测试里是 aiRoot/写作手册）。App 不自带手册（内置的写作技能在 src/skills/，见 SkillsTests）：第一次用时只建空文件夹，里面的文件从不删、不补；
/// AI 设置里列出，「打开」「在 Finder 中显示」「打开文件夹」交给系统（harness 只记下来）；App 里的 AI 每轮在工作副本里拿到拷贝与
/// AGENTS.md 末尾的目录；save_writing_manual 弹确认框，用户同意才存；外部 Agent 经 MCP 列出、读取、提议保存。
/// 测试用的手册是这里自己放进去的（`seed`）。
@MainActor
struct WritingManualsTests {
    /// 测试自己放进文件夹的手册：文件名 → 内容
    static let fixtures: [String: String] = [
        "菜谱.md": "---\nname: 菜谱\ndescription: 家常菜谱：用料、步骤、火候\n---\n\n# 菜谱\n\n先写用料，再写步骤。\n",
        "露营.md": "---\nname: 露营\ndescription: 露营清单：装备、营地、天气写清楚\n---\n\n# 露营\n\n先列装备，再写营地。\n",
        "标题打磨.md": "---\nname: 标题打磨\ndescription: 起标题：力度可以变，事实不能变\n---\n\n# 标题打磨\n\n力度可以变，事实不能变。\n",
    ]
    static let names = ["菜谱", "露营", "标题打磨"].sorted(by: WritingManuals.ordered)

    /// 把测试用的手册放进文件夹（没有时先建）
    static func seed(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in fixtures {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    static func example(_ name: String) throws -> WritingManuals.Parsed {
        WritingManuals.parse(try fixtures["\(name).md"] ?? "", fallbackName: name)
    }

    static func files(in folder: URL) -> [String: String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".md") }
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)).map { (name, $0) }
        })
    }

    /// 等 harness 记下来的东西到齐（页面经原生桥要的，主线程上记）
    static func waitFor(_ condition: () -> Bool, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static let listScript = """
        const mc = window.mediacraft;
        const until = async (condition, timeout = 10000) => {
          const deadline = Date.now() + timeout;
          while (Date.now() < deadline) {
            const value = await condition();
            if (value) return value;
            await new Promise((resolve) => setTimeout(resolve, 50));
          }
          throw new Error(`等不到：${condition}`);
        };
        const rows = () => [...document.querySelectorAll("#writingManualList > li")]
          .map((row) => [row.querySelector(".ai-manual-name")?.textContent ?? "", row.querySelector(".ai-manual-description")?.textContent ?? row.textContent]);
    """

    @Test("第一次用时只建空文件夹（App 不自带写作手册）；AI 设置里先列两个内置技能（只读，「查看」展开全文），再列用户的写作手册（名字与说明），每次打开设置重新读；「打开」「在 Finder 中显示」「打开文件夹」交给系统")
    func settingsListManuals() async throws {
        let harness = ShellHarness(onboarding: false)
        let folder = harness.aiRoot.appendingPathComponent("写作手册")
        try await harness.load()
        let createdBeforeUse = FileManager.default.fileExists(atPath: folder.path)
        let empty = try await harness.evaluate(Self.listScript + """
            await mc.drafts.create();
            ui.click("AI 助手");
            ui.expand("AI 设置");
            await until(() => rows().length === 1 && document.querySelector("#writingManualList .ai-manual-empty"));
            const builtIn = [...document.querySelectorAll("#builtInSkillList > li")]
              .map((row) => [row.querySelector(".ai-manual-name").textContent, row.querySelector(".ai-manual-description").textContent]);
            ui.click("查看", { within: "写作" });
            const shown = document.querySelector('[aria-label="「写作」全文"]');
            const text = shown.hidden ? null : shown.textContent;
            ui.click("收起", { within: "写作" });
            return {
              builtIn, text, expected: window.MediaCraftSkills.document("写作"), hiddenAgain: shown.hidden,
              buttons: [...document.querySelectorAll("#builtInSkillList button")].map((button) => button.textContent),
              note: document.querySelector("#writingManualList .ai-manual-empty").textContent,
            };
        """) as? [String: Any]
        let createdAfterUse = Self.files(in: folder)
        let folderExists = FileManager.default.fileExists(atPath: folder.path)

        // 用户放进几份手册：再打开设置时列出来
        try Self.seed(folder)
        let first = try await harness.evaluate(Self.listScript + """
            ui.click("AI 设置");
            await until(() => !document.getElementById("aiSettings").open);
            ui.expand("AI 设置");
            await until(() => rows().length === 3);
            const shown = { rows: rows(), visible: !document.getElementById("writingManuals").hidden };
            ui.click("打开", { within: "菜谱" });
            ui.click("在 Finder 中显示", { within: "标题打磨" });
            ui.click("打开文件夹");
            return shown;
        """) as? [String: Any]
        try await Self.waitFor { harness.openedFiles.count == 1 && harness.revealedFiles.count == 2 }
        _ = try await harness.evaluate("document.getElementById('builtInSkills').scrollIntoView({ block: 'nearest' })")
        try await harness.screenshot("writing-manuals-settings", of: ".ai-settings-popover")

        // 用户删掉一份、自己放一份没写开头的：再打开设置时照文件夹里现在的列
        try FileManager.default.removeItem(at: folder.appendingPathComponent("露营.md"))
        try "# 我的手册\n\n随便写写\n".write(to: folder.appendingPathComponent("我的手册.md"), atomically: true, encoding: .utf8)
        let second = try await harness.evaluate(Self.listScript + """
            ui.click("AI 设置");
            await until(() => !document.getElementById("aiSettings").open);
            ui.expand("AI 设置");
            await until(() => rows().some(([name]) => name === "我的手册"));
            return rows();
        """) as? [[String]]
        // 临时目录在 /private/var 下（/var 是链接）：收尾删掉之前比较解开链接后的路径
        let path = { (url: URL) in url.resolvingSymlinksInPath().path }
        let opened = harness.openedFiles.map(path)
        let revealed = harness.revealedFiles.map(path)
        let expectedOpened = [path(folder.appendingPathComponent("菜谱.md"))]
        let expectedRevealed = [path(folder.appendingPathComponent("标题打磨.md")), path(folder)]
        await harness.tearDown()

        #expect(!createdBeforeUse, "用到之前不建")
        #expect(folderExists && createdAfterUse.isEmpty, "第一次用时建一个空文件夹，App 不往里放手册：\(createdAfterUse.keys.sorted())")
        let builtIn = empty?["builtIn"] as? [[String]] ?? []
        #expect(builtIn.map { $0.first ?? "" } == ["使用 Vibepost", "写作"], "内置技能先列操作手册、再列写作：\(builtIn)")
        #expect(builtIn.first?.last?.hasPrefix("Vibepost 的操作手册") == true && builtIn.last?.last?.hasPrefix("Vibepost 内置的写作技能") == true)
        #expect(empty?["text"] as? String == empty?["expected"] as? String && (empty?["text"] as? String)?.hasPrefix("# 写作") == true, "「查看」展开的是写作技能全文")
        #expect(empty?["hiddenAgain"] as? Bool == true, "「收起」收回去")
        #expect(empty?["buttons"] as? [String] == ["查看", "查看"], "内置技能只读：只有「查看」")
        #expect((empty?["note"] as? String)?.contains("还没有写作手册") == true)
        #expect(first?["visible"] as? Bool == true)
        let listed = first?["rows"] as? [[String]] ?? []
        #expect(listed.map { $0.first ?? "" } == Self.names, "按名字排：\(listed)")
        #expect(listed.first(where: { $0.first == "菜谱" })?.last == (try Self.example("菜谱")).description, "说明取自开头的 description")
        #expect(opened == expectedOpened, "「打开」用默认的 App 打开那份")
        #expect(revealed.sorted() == expectedRevealed.sorted(), "「在 Finder 中显示」那份，「打开文件夹」打开文件夹（两个请求各自回来，先后不一定）")
        let expectedSecond = try (Self.names.filter { $0 != "露营" } + ["我的手册"]).sorted(by: WritingManuals.ordered).map { name in
            [name, name == "我的手册" ? "（没有说明）" : try Self.example(name).description]
        }
        #expect(second == expectedSecond, "\(second ?? [])")
        #expect(harness.pageErrors == [])
    }

    @Test("App 里的 AI：每轮把写作手册拷进工作副本的「写作手册/」，AGENTS.md 是两份内置技能的全文、后面列出写作手册的目录；每轮重写（Agent 改了不留，用户改了下一轮就用新的），说明书里讲清楚")
    func workCopyGetsManuals() async throws {
        let fake = try FakeClaude(script: [AIReviewTests.write("写作手册/菜谱.md", "被 Agent 改坏了\n")] + StreamJSON.reply(["好的。"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        let folder = harness.aiRoot.appendingPathComponent("写作手册")
        try Self.seed(folder)
        try await harness.load()
        let first = try await harness.evaluate(AIReviewTests.helpers + """
            const draft = await mc.drafts.create({ markdown: "原来的一段" });
            await openAI();
            ask("写一篇");
            await until(() => finished(1));
            return { id: draft.id, manual: window.MediaCraftManual.document(), writing: window.MediaCraftSkills.document("写作") };
        """) as? [String: Any]
        let id = first?["id"] as? String ?? ""
        let work = harness.aiRoot.appendingPathComponent(id)
        let copiesAfterFirst = Self.files(in: work.appendingPathComponent("写作手册"))
        let agentsAfterFirst = (try? String(contentsOf: work.appendingPathComponent("AGENTS.md"), encoding: .utf8)) ?? ""

        // 用户在两轮之间改了文件夹：删掉一份、加一份
        try FileManager.default.removeItem(at: folder.appendingPathComponent("露营.md"))
        try "---\nname: 周报\ndescription: 一周要闻：每条一句事实小标题\n---\n\n每条写来源和日期。\n".write(
            to: folder.appendingPathComponent("周报.md"), atomically: true, encoding: .utf8
        )
        try fake.script(StreamJSON.reply(["好的。"]))
        _ = try await harness.evaluate(AIReviewTests.helpers + """
            ask("再写一篇");
            await until(() => finished(2));
        """)
        let copiesAfterSecond = Self.files(in: work.appendingPathComponent("写作手册"))
        let agentsAfterSecond = (try? String(contentsOf: work.appendingPathComponent("AGENTS.md"), encoding: .utf8)) ?? ""
        let userFolder = Self.files(in: folder)
        let systemPrompt = FakeClaude.option("--append-system-prompt", in: fake.calls().first ?? [:]) ?? ""
        await harness.tearDown()

        let manual = first?["manual"] as? String ?? "(没有)"
        let writing = first?["writing"] as? String ?? "(没有)"
        #expect(copiesAfterFirst["菜谱.md"] == "被 Agent 改坏了\n", "这一轮里 Agent 改的是工作副本里的拷贝")
        #expect(copiesAfterFirst["露营.md"] == Self.fixtures["露营.md"] && copiesAfterFirst.count == Self.names.count)
        #expect(userFolder["菜谱.md"] == Self.fixtures["菜谱.md"], "用户的写作手册没被 Agent 改到")
        #expect(agentsAfterFirst.hasPrefix(manual), "AGENTS.md 先是操作手册全文")
        #expect(agentsAfterFirst.contains("\n\n" + writing.trimmingCharacters(in: .newlines) + "\n\n## 写作手册"), "操作手册后面是写作技能全文，再后面是写作手册的目录")
        #expect(agentsAfterFirst.contains("- 菜谱：家常菜谱：用料、步骤、火候（写作手册/菜谱.md）"), "\(agentsAfterFirst.suffix(600))")
        #expect(agentsAfterFirst.contains("- 露营：") && agentsAfterFirst.contains("- 标题打磨："))
        #expect(agentsAfterFirst.contains("save_writing_manual") && agentsAfterFirst.contains("照写作技能"))

        #expect(copiesAfterSecond["菜谱.md"] == Self.fixtures["菜谱.md"], "下一轮开始时拷贝重写，Agent 改的不留")
        #expect(copiesAfterSecond["周报.md"] != nil && copiesAfterSecond["露营.md"] == nil, "用户改了文件夹，下一轮就用新的：\(copiesAfterSecond.keys.sorted())")
        #expect(agentsAfterSecond.hasPrefix(manual) && agentsAfterSecond.contains(writing.trimmingCharacters(in: .newlines)))
        #expect(agentsAfterSecond.contains("- 周报：一周要闻：每条一句事实小标题（写作手册/周报.md）") && !agentsAfterSecond.contains("露营"))
        #expect(systemPrompt.contains("写作手册/") && systemPrompt.contains("save_writing_manual"), "说明书里讲清楚写作手册在哪、怎么记经验")
        #expect(systemPrompt.contains("内置的写作技能") && systemPrompt.contains("素材不够先问，不编"), "说明书带写作技能的短版")
        #expect(harness.pageErrors == [])
    }

    @Test("save_writing_manual：名字不合规矩直接回错误；新建、修改都弹确认框给用户看改动，拒绝时不存、Agent 收到原因；同意才存进文件夹")
    func saveNeedsConfirmation() async throws {
        let trip = try Self.example("露营")
        let edited = trip.body + "- 新加的一条经验：开头先给结论。\n"
        let weekly: [String: Any] = ["name": "周报", "description": "一周要闻：每条一句事实小标题", "content": "# 周报\n\n每条写来源和日期。\n"]
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(),
            StreamJSON.toolCall("w0", "save_writing_manual", ["name": "a/b", "description": "说明", "content": "正文"]),
            StreamJSON.toolCall("w1", "save_writing_manual", weekly),
            StreamJSON.toolCall("w2", "save_writing_manual", weekly),
            StreamJSON.toolCall("w3", "save_writing_manual", ["name": "露营", "description": trip.description, "content": edited]),
            StreamJSON.textStart(), StreamJSON.textDelta("记好了"), StreamJSON.assistantText("记好了"), StreamJSON.result("记好了"),
        ])
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        let folder = harness.aiRoot.appendingPathComponent("写作手册")
        try Self.seed(folder)
        try await harness.load()
        let result = try await harness.evaluate(AIReviewTests.helpers + """
            const dialog = () => ({ title: document.getElementById("confirmTitle").textContent, message: document.getElementById("confirmMessage").textContent });
            const names = async () => (await window.MediaCraftNative.manuals.list()).manuals.map((manual) => manual.name);
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            ask("把这次的经验记进写作手册");
            await until(() => ui.alert());
            const declined = dialog();
            ui.click("取消", { within: ui.alert() });
            await until(() => ui.alert());
            const afterDecline = await names();
            const created = dialog();
            ui.click("保存", { within: ui.alert() });
            await until(() => ui.alert());
            const changed = dialog();
            ui.click("保存", { within: ui.alert() });
            await until(() => finished(1));
            return { declined, afterDecline, created, changed, lines: shown().map(([, text]) => text) };
        """) as? [String: Any]
        let saved = Self.files(in: folder)
        await harness.tearDown()

        func text(_ requestId: String) -> (String, Bool) {
            let result = ((fake.response(0, requestId)?["response"] as? [String: Any])?["mcp_response"] as? [String: Any])?["result"] as? [String: Any]
            let content = (result?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
            return (content, result?["isError"] as? Bool ?? false)
        }
        #expect(text("w0").1 && text("w0").0.contains("手册名里不能有"), "名字不合规矩：不弹框，直接回错误：\(text("w0"))")
        let declined = result?["declined"] as? [String: String]
        #expect(declined?["title"] == "新建写作手册「周报」")
        #expect(declined?["message"]?.contains("说明：一周要闻：每条一句事实小标题") == true && declined?["message"]?.contains("每条写来源和日期。") == true, "\(declined ?? [:])")
        #expect(text("w1") == ("用户没有同意保存这份写作手册", true))
        #expect((result?["afterDecline"] as? [String])?.contains("周报") == false, "拒绝时不存")
        #expect(text("w2") == ("已新建写作手册「周报」并保存，下一轮起生效。", false))
        let changed = result?["changed"] as? [String: String]
        #expect(changed?["title"] == "修改写作手册「露营」")
        #expect(changed?["message"]?.contains("正文 +1 / −0 行") == true && changed?["message"]?.contains("+ - 新加的一条经验：开头先给结论。") == true, "\(changed ?? [:])")
        #expect(text("w3") == ("已修改写作手册「露营」并保存，下一轮起生效。", false))
        #expect(saved["周报.md"] == "---\nname: 周报\ndescription: 一周要闻：每条一句事实小标题\n---\n\n# 周报\n\n每条写来源和日期。\n", "\(saved["周报.md"] ?? "(没有)")")
        #expect(saved["露营.md"] == WritingManuals.compose(name: "露营", description: trip.description, body: edited), "修改的写回原来的文件")
        #expect(saved.count == Self.names.count + 1)
        let lines = result?["lines"] as? [String] ?? []
        #expect(lines.contains("新建写作手册「周报」") && lines.contains("修改写作手册「露营」"), "会话里记一行：\(lines)")
        #expect(harness.pageErrors == [])
    }

    @Test("外部 Agent：list_writing_manuals 列出名字与说明，read_writing_manual 读全文（没有的回错误）；save_writing_manual 同样弹确认框，同意才存")
    func externalAgentReadsManuals() async throws {
        let config = MCPConfiguration.temporary()
        let harness = ShellHarness(onboarding: false, mcp: config)
        let folder = harness.aiRoot.appendingPathComponent("写作手册")
        try Self.seed(folder)
        try await harness.load()
        let client = MCPTestClient(socketPath: config.socketPath)
        _ = try await client.initialize()
        let list = try await client.call("list_writing_manuals")
        let read = try await client.call("read_writing_manual", ["name": "标题打磨"])
        let missing = try await client.call("read_writing_manual", ["name": "没有这份"])
        async let saving = client.call("save_writing_manual", ["name": "周报", "description": "一周要闻", "content": "每条写来源和日期。\n"])
        let asked = try await harness.waitForPage("ui.alert() !== null")
        let title = try await harness.evaluate("return document.getElementById('confirmTitle').textContent") as? String
        _ = try await harness.evaluate("ui.click('保存', { within: ui.alert() })")
        let saved = try await saving
        let log = try await harness.evaluate("return (await mediacraft.mcp.log()).map((entry) => entry.text)") as? [String]
        let file = try? String(contentsOf: folder.appendingPathComponent("周报.md"), encoding: .utf8)
        client.close()
        await harness.tearDown()
        try? FileManager.default.removeItem(at: config.directory)

        let titles = try Self.example("标题打磨")
        let recipe = try Self.example("菜谱")
        #expect(!list.isError && list.text.hasPrefix("共 \(Self.names.count) 份写作手册"), "\(list.text)")
        #expect(list.text.contains("- 标题打磨：\(titles.description)") && list.text.contains("- 菜谱：\(recipe.description)") && list.text.contains("- 露营：") && list.text.contains("get_writing_skill"))
        #expect(!read.isError && read.text == "---\nname: 标题打磨\ndescription: \(titles.description)\n---\n\n\(titles.body)", "\(read.text.prefix(120))")
        #expect(missing.isError && missing.text.contains("没有这份写作手册"), "\(missing.text)")
        #expect(asked && title == "新建写作手册「周报」")
        #expect(!saved.isError && saved.text.contains("已新建写作手册「周报」"), "\(saved.text)")
        #expect(file == "---\nname: 周报\ndescription: 一周要闻\n---\n\n每条写来源和日期。\n")
        #expect(log == ["新建写作手册「周报」"], "列进「外部 Agent 的操作」：\(log ?? [])")
        #expect(harness.pageErrors == [])
    }

    @Test("老用户的写作手册（包括老版本放进去的示例）照旧列出、一个字不改；App 不补回删掉的，也不往里加新的")
    func existingLibraryIsLeftAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.seed(folder)
        let custom = "---\nname: 标题打磨\ndescription: 我的写法\n---\n用户改过的正文"
        try custom.write(to: folder.appendingPathComponent("标题打磨.md"), atomically: true, encoding: .utf8)
        // 老版本记下装过哪些示例的文件：留着，不当手册
        try #"["标题打磨.md","国际新闻.md"]"#.write(to: folder.appendingPathComponent(".bundled-writing-manuals.json"), atomically: true, encoding: .utf8)
        let manuals = WritingManuals(folder: folder)
        #expect(try manuals.list().map(\.name) == Self.names)
        #expect(try String(contentsOf: folder.appendingPathComponent("标题打磨.md"), encoding: .utf8) == custom)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("露营.md"))
        #expect(try manuals.list().map(\.name) == Self.names.filter { $0 != "露营" }, "删掉的不补回")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == [".bundled-writing-manuals.json", "标题打磨.md", "菜谱.md"].sorted(), "App 不往里加、不删：\(left)")

        // 新装：文件夹不在时建一个空的
        let fresh = folder.appendingPathComponent("新的写作手册")
        #expect(try WritingManuals(folder: fresh).list().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fresh.path).isEmpty)
    }

    @Test("输入框的「写作手册」：斜杠打开、多选不发送，正文随下一条注入且历史留标签，之后不继承")
    func selectedSkillsReachNextTurn() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["收到。"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try Self.seed(harness.aiRoot.appendingPathComponent("写作手册"))
        try await harness.load()
        _ = try await harness.evaluate(AISessionTests.helpers + """
            await mc.drafts.create({ markdown: "测试稿件。" });
            await openAI();
            const input = document.getElementById('aiInput');
            input.dispatchEvent(new KeyboardEvent('keydown', { key: '/', bubbles: true, cancelable: true }));
            await until(() => document.querySelectorAll('#aiSkillsList input').length === 3);
            for (const name of ['标题打磨', '菜谱']) {
              [...document.querySelectorAll('#aiSkillsList input')].find(node => node.value === name).click();
            }
            if ((await mc.ai.history()).messages.length) throw new Error('选择技能不应发送消息');
        """)
        try await harness.screenshot("writing-skills-picker", of: "#aiPanel")
        let result = try await harness.evaluate(AISessionTests.helpers + """
            document.getElementById('aiSkillsDone').click();
            ask('给我五个标题');
            await until(() => finished(1));
            const first = (await mc.ai.history()).messages.find(m => m.role === 'user');
            const tags = [...document.querySelectorAll('.ai-message-skills .ai-skill-tag')].map(n => n.textContent);
            const selected = document.querySelectorAll('#aiSelectedSkills button').length;
            ask('解释一下');
            await until(() => finished(2));
            document.getElementById('aiInput').dispatchEvent(new KeyboardEvent('keydown', { key: 'K', metaKey: true, shiftKey: true, bubbles: true, cancelable: true }));
            await until(() => !document.getElementById('aiSkillsPicker').hidden && document.querySelectorAll('#aiSkillsList input').length === 3);
            [...document.querySelectorAll('#aiSkillsList input')].find(n => n.value === '标题打磨').click();
            document.getElementById('aiSkillsDone').click();
            preset('封面标题 5 选 1');
            await until(() => finished(3));
            return { skills: first.skills.map(s => s.name), tags, selected, text: first.text };
        """) as? [String: Any]
        let prompt = fake.prompt(0)
        await harness.tearDown()
        #expect((result?["skills"] as? [String]) == ["标题打磨", "菜谱"])
        #expect((result?["tags"] as? [String]) == ["标题打磨", "菜谱"])
        #expect(result?["selected"] as? Int == 0)
        #expect(result?["text"] as? String == "给我五个标题")
        #expect(prompt.contains("【写作手册：标题打磨】") && prompt.contains("【写作手册：菜谱】"))
        #expect(prompt.contains("力度可以变，事实不能变") && !prompt.contains("# 露营"))
        #expect(prompt.hasSuffix("给我五个标题"))
        #expect(fake.prompt(1) == "解释一下", "后一轮不携带前一轮技能正文")
        #expect(fake.prompt(2).contains("【写作手册：标题打磨】"), "快捷命令同样携带下一条消息的写作手册")
        #expect(harness.pageErrors == [])
    }

    @Test("选中的写作手册被删除后发送失败，恢复输入与所选手册，未启动 agent")
    func missingSelectedSkillRestoresComposer() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["不应启动"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try Self.seed(harness.aiRoot.appendingPathComponent("写作手册"))
        try await harness.load()
        _ = try await harness.evaluate(AISessionTests.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            document.getElementById('aiSkillsToggle').click();
            await until(() => document.querySelectorAll('#aiSkillsList input').length === 3);
            [...document.querySelectorAll('#aiSkillsList input')].find(n => n.value === '标题打磨').click();
            document.getElementById('aiSkillsDone').click();
        """)
        try FileManager.default.removeItem(at: harness.aiRoot.appendingPathComponent("写作手册/标题打磨.md"))
        let result = try await harness.evaluate(AISessionTests.helpers + """
            ask('重新起标题');
            await until(() => finished(1));
            await until(() => document.getElementById('aiInput').value === '重新起标题');
            return { text: document.getElementById('aiInput').value,
              tags: [...document.querySelectorAll('#aiSelectedSkills button')].map(n => n.textContent),
              state: (await ends((await mc.drafts.current()).id))[0].state };
        """) as? [String: Any]
        let subsequent = try await harness.evaluate(AISessionTests.helpers + """
            ask('再试一次');
            const input = document.getElementById('aiInput');
            input.value = '我正在准备另一条消息';
            input.dispatchEvent(new Event('input', { bubbles: true }));
            await until(() => finished(2));
            await wait(50);
            return input.value;
        """) as? String
        await harness.tearDown()
        #expect(result?["text"] as? String == "重新起标题")
        #expect(result?["state"] as? String == "error")
        #expect((result?["tags"] as? [String]) == ["标题打磨 ×"])
        #expect(fake.calls().isEmpty)
        #expect(subsequent == "我正在准备另一条消息", "迟到的失败不能覆盖新输入")
        #expect(harness.pageErrors == [])
    }

    @Test("开头的 name / description：引号、折行的说明、没有开头时用文件名；写回时要加引号的加上，读回来一样")
    func frontMatterRoundTrip() {
        let quoted = WritingManuals.parse("---\nname: \"#话题\"\ndescription: >\n  第一行\n  第二行\nother: x\n---\n\n\n正文\n", fallbackName: "文件名")
        #expect(quoted == WritingManuals.Parsed(name: "#话题", description: "第一行 第二行", body: "正文\n"))
        let plain = WritingManuals.parse("# 没有开头\n\n正文", fallbackName: "文件名")
        #expect(plain == WritingManuals.Parsed(name: "文件名", description: "", body: "# 没有开头\n\n正文"))
        let crlf = WritingManuals.parse("\u{FEFF}---\r\nname: 菜谱\r\ndescription: 'it''s: 好吃'\r\n---\r\n正文\r\n", fallbackName: "x")
        #expect(crlf == WritingManuals.Parsed(name: "菜谱", description: "it's: 好吃", body: "正文\n"))
        let composed = WritingManuals.compose(name: "[草稿]", description: "要点: 一个 #标签", body: "\n正文")
        #expect(composed == "---\nname: \"[草稿]\"\ndescription: \"要点: 一个 #标签\"\n---\n\n正文\n")
        #expect(WritingManuals.parse(composed, fallbackName: "x") == WritingManuals.Parsed(name: "[草稿]", description: "要点: 一个 #标签", body: "正文\n"))
        #expect(WritingManuals.problem(withName: "..") != nil && WritingManuals.problem(withName: "a\tb") != nil && WritingManuals.problem(withName: "好名字") == nil)
    }
}
