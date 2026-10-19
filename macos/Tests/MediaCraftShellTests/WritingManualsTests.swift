import Foundation
import MediaCraftMCP
import Testing
@testable import MediaCraftShell

/// 写作手册：只管写什么、什么口味，每份一个 .md（开头 name / description，后面是正文），放在支持目录的「写作手册」文件夹
/// （测试里是 aiRoot/写作手册）。第一次用时照 src/writing-manuals/ 建好；AI 设置里列出，「打开」「在 Finder 中显示」「打开文件夹」交给系统
/// （harness 只记下来）；App 里的 AI 每轮在工作副本里拿到拷贝与 AGENTS.md 末尾的目录；save_writing_manual 弹确认框，用户同意才存；
/// 外部 Agent 经 MCP 列出、读取、提议保存。
@MainActor
struct WritingManualsTests {
    static let examples = ShellHarness.repoRoot.appendingPathComponent("src/writing-manuals")
    static let names = ["保留原意去AI味", "标题打磨", "代码库解读", "观点长文", "国际新闻", "小红书图文", "英文简明表达"].sorted(by: WritingManuals.ordered)

    /// 自带的示例：文件名 → 内容
    static func exampleFiles() throws -> [String: String] {
        let files = try FileManager.default.contentsOfDirectory(atPath: examples.path).filter { $0.hasSuffix(".md") }
        return try Dictionary(uniqueKeysWithValues: files.map { ($0, try String(contentsOf: examples.appendingPathComponent($0), encoding: .utf8)) })
    }

    static func example(_ name: String) throws -> WritingManuals.Parsed {
        WritingManuals.parse(try String(contentsOf: examples.appendingPathComponent("\(name).md"), encoding: .utf8), fallbackName: name)
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

    @Test("第一次用时照自带的示例建好文件夹（之后不再补回删掉的示例）；AI 设置里列出名字与说明，每次打开设置重新读；「打开」「在 Finder 中显示」「打开文件夹」交给系统")
    func settingsListManuals() async throws {
        let harness = ShellHarness(onboarding: false)
        let folder = harness.aiRoot.appendingPathComponent("写作手册")
        try await harness.load()
        let createdBeforeUse = FileManager.default.fileExists(atPath: folder.path)
        let first = try await harness.evaluate(Self.listScript + """
            await mc.drafts.create();
            ui.click("AI 助手");
            ui.expand("AI 设置");
            await until(() => rows().length === 7);
            const shown = { rows: rows(), visible: !document.getElementById("writingManuals").hidden };
            ui.click("打开", { within: "小红书图文" });
            ui.click("在 Finder 中显示", { within: "代码库解读" });
            ui.click("打开文件夹");
            return shown;
        """) as? [String: Any]
        try await Self.waitFor { harness.openedFiles.count == 1 && harness.revealedFiles.count == 2 }
        _ = try await harness.evaluate("document.getElementById('writingManuals').scrollIntoView({ block: 'nearest' })")
        try await harness.screenshot("writing-manuals-settings", of: ".ai-settings-popover")
        let created = Self.files(in: folder)

        // 用户删掉一份示例、自己放一份没写开头的：再打开设置时照文件夹里现在的列，删掉的示例不会回来
        try FileManager.default.removeItem(at: folder.appendingPathComponent("国际新闻.md"))
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
        let expectedOpened = [path(folder.appendingPathComponent("小红书图文.md"))]
        let expectedRevealed = [path(folder.appendingPathComponent("代码库解读.md")), path(folder)]
        await harness.tearDown()

        let examples = try Self.exampleFiles()
        #expect(!createdBeforeUse, "用到之前不建")
        #expect(created == examples, "照自带的示例建好：\(created.keys.sorted())")
        #expect(first?["visible"] as? Bool == true)
        let listed = first?["rows"] as? [[String]] ?? []
        #expect(listed.map { $0.first ?? "" } == Self.names, "按名字排：\(listed)")
        #expect(listed.first(where: { $0.first == "小红书图文" })?.last == (try Self.example("小红书图文")).description, "说明取自开头的 description")
        #expect(opened == expectedOpened, "「打开」用默认的 App 打开那份")
        #expect(revealed.sorted() == expectedRevealed.sorted(), "「在 Finder 中显示」那份，「打开文件夹」打开文件夹（两个请求各自回来，先后不一定）")
        let expectedSecond = try (Self.names.filter { $0 != "国际新闻" } + ["我的手册"]).sorted(by: WritingManuals.ordered).map { name in
            [name, name == "我的手册" ? "（没有说明）" : try Self.example(name).description]
        }
        #expect(second == expectedSecond, "\(second ?? [])")
        #expect(harness.pageErrors == [])
    }

    @Test("App 里的 AI：每轮把写作手册拷进工作副本的「写作手册/」，AGENTS.md 在操作手册后面列出目录；每轮重写（Agent 改了不留，用户改了下一轮就用新的），说明书里讲清楚")
    func workCopyGetsManuals() async throws {
        let fake = try FakeClaude(script: [AIReviewTests.write("写作手册/小红书图文.md", "被 Agent 改坏了\n")] + StreamJSON.reply(["好的。"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        let folder = harness.aiRoot.appendingPathComponent("写作手册")
        try await harness.load()
        let first = try await harness.evaluate(AIReviewTests.helpers + """
            const draft = await mc.drafts.create({ markdown: "原来的一段" });
            await openAI();
            ask("写一篇");
            await until(() => finished(1));
            return { id: draft.id, manual: window.MediaCraftManual.document() };
        """) as? [String: Any]
        let id = first?["id"] as? String ?? ""
        let work = harness.aiRoot.appendingPathComponent(id)
        let copiesAfterFirst = Self.files(in: work.appendingPathComponent("写作手册"))
        let agentsAfterFirst = (try? String(contentsOf: work.appendingPathComponent("AGENTS.md"), encoding: .utf8)) ?? ""

        // 用户在两轮之间改了文件夹：删掉一份、加一份
        try FileManager.default.removeItem(at: folder.appendingPathComponent("国际新闻.md"))
        try "---\nname: 菜谱\ndescription: 家常菜谱：用料、步骤、火候\n---\n\n先写用料。\n".write(
            to: folder.appendingPathComponent("菜谱.md"), atomically: true, encoding: .utf8
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

        let examples = try Self.exampleFiles()
        let manual = first?["manual"] as? String ?? "(没有)"
        #expect(copiesAfterFirst["小红书图文.md"] == "被 Agent 改坏了\n", "这一轮里 Agent 改的是工作副本里的拷贝")
        #expect(copiesAfterFirst["代码库解读.md"] == examples["代码库解读.md"] && copiesAfterFirst.count == Self.names.count)
        #expect(userFolder["小红书图文.md"] == examples["小红书图文.md"], "用户的写作手册没被 Agent 改到")
        #expect(agentsAfterFirst.hasPrefix(manual), "AGENTS.md 先是操作手册全文")
        let xhs = try Self.example("小红书图文")
        #expect(agentsAfterFirst.contains("## 写作手册"))
        #expect(agentsAfterFirst.contains("- 小红书图文：\(xhs.description)（写作手册/小红书图文.md）"), "\(agentsAfterFirst.suffix(600))")
        #expect(agentsAfterFirst.contains("- 国际新闻：") && agentsAfterFirst.contains("- 代码库解读："))
        #expect(agentsAfterFirst.contains("save_writing_manual"))

        #expect(copiesAfterSecond["小红书图文.md"] == examples["小红书图文.md"], "下一轮开始时拷贝重写，Agent 改的不留")
        #expect(copiesAfterSecond["菜谱.md"] != nil && copiesAfterSecond["国际新闻.md"] == nil, "用户改了文件夹，下一轮就用新的：\(copiesAfterSecond.keys.sorted())")
        #expect(agentsAfterSecond.hasPrefix(manual))
        #expect(agentsAfterSecond.contains("- 菜谱：家常菜谱：用料、步骤、火候（写作手册/菜谱.md）") && !agentsAfterSecond.contains("国际新闻"))
        #expect(systemPrompt.contains("写作手册/") && systemPrompt.contains("save_writing_manual"), "说明书里讲清楚写作手册在哪、怎么记经验")
        #expect(harness.pageErrors == [])
    }

    @Test("save_writing_manual：名字不合规矩直接回错误；新建、修改都弹确认框给用户看改动，拒绝时不存、Agent 收到原因；同意才存进文件夹")
    func saveNeedsConfirmation() async throws {
        let xhs = try Self.example("小红书图文")
        let edited = xhs.body + "- 新加的一条经验：开头先给结论。\n"
        let recipe: [String: Any] = ["name": "菜谱", "description": "家常菜谱：用料、步骤、火候", "content": "# 菜谱\n\n先写用料，再写步骤。\n"]
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(),
            StreamJSON.toolCall("w0", "save_writing_manual", ["name": "a/b", "description": "说明", "content": "正文"]),
            StreamJSON.toolCall("w1", "save_writing_manual", recipe),
            StreamJSON.toolCall("w2", "save_writing_manual", recipe),
            StreamJSON.toolCall("w3", "save_writing_manual", ["name": "小红书图文", "description": xhs.description, "content": edited]),
            StreamJSON.textStart(), StreamJSON.textDelta("记好了"), StreamJSON.assistantText("记好了"), StreamJSON.result("记好了"),
        ])
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        let folder = harness.aiRoot.appendingPathComponent("写作手册")
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
        #expect(declined?["title"] == "新建写作手册「菜谱」")
        #expect(declined?["message"]?.contains("说明：家常菜谱：用料、步骤、火候") == true && declined?["message"]?.contains("先写用料，再写步骤。") == true, "\(declined ?? [:])")
        #expect(text("w1") == ("用户没有同意保存这份写作手册", true))
        #expect((result?["afterDecline"] as? [String])?.contains("菜谱") == false, "拒绝时不存")
        #expect(text("w2") == ("已新建写作手册「菜谱」并保存，下一轮起生效。", false))
        let changed = result?["changed"] as? [String: String]
        #expect(changed?["title"] == "修改写作手册「小红书图文」")
        #expect(changed?["message"]?.contains("正文 +1 / −0 行") == true && changed?["message"]?.contains("+ - 新加的一条经验：开头先给结论。") == true, "\(changed ?? [:])")
        #expect(text("w3") == ("已修改写作手册「小红书图文」并保存，下一轮起生效。", false))
        #expect(saved["菜谱.md"] == "---\nname: 菜谱\ndescription: 家常菜谱：用料、步骤、火候\n---\n\n# 菜谱\n\n先写用料，再写步骤。\n", "\(saved["菜谱.md"] ?? "(没有)")")
        #expect(saved["小红书图文.md"] == WritingManuals.compose(name: "小红书图文", description: xhs.description, body: edited), "修改的写回原来的文件")
        #expect(saved.count == Self.names.count + 1)
        let lines = result?["lines"] as? [String] ?? []
        #expect(lines.contains("新建写作手册「菜谱」") && lines.contains("修改写作手册「小红书图文」"), "会话里记一行：\(lines)")
        #expect(harness.pageErrors == [])
    }

    @Test("外部 Agent：list_writing_manuals 列出名字与说明，read_writing_manual 读全文（没有的回错误）；save_writing_manual 同样弹确认框，同意才存")
    func externalAgentReadsManuals() async throws {
        let config = MCPConfiguration.temporary()
        let harness = ShellHarness(onboarding: false, mcp: config)
        let folder = harness.aiRoot.appendingPathComponent("写作手册")
        try await harness.load()
        let client = MCPTestClient(socketPath: config.socketPath)
        _ = try await client.initialize()
        let list = try await client.call("list_writing_manuals")
        let read = try await client.call("read_writing_manual", ["name": "代码库解读"])
        let missing = try await client.call("read_writing_manual", ["name": "没有这份"])
        async let saving = client.call("save_writing_manual", ["name": "菜谱", "description": "家常菜谱", "content": "先写用料。\n"])
        let asked = try await harness.waitForPage("ui.alert() !== null")
        let title = try await harness.evaluate("return document.getElementById('confirmTitle').textContent") as? String
        _ = try await harness.evaluate("ui.click('保存', { within: ui.alert() })")
        let saved = try await saving
        let log = try await harness.evaluate("return (await mediacraft.mcp.log()).map((entry) => entry.text)") as? [String]
        let file = try? String(contentsOf: folder.appendingPathComponent("菜谱.md"), encoding: .utf8)
        client.close()
        await harness.tearDown()
        try? FileManager.default.removeItem(at: config.directory)

        let code = try Self.example("代码库解读")
        let xhs = try Self.example("小红书图文")
        #expect(!list.isError && list.text.hasPrefix("共 \(Self.names.count) 份写作手册"), "\(list.text)")
        #expect(list.text.contains("- 代码库解读：\(code.description)") && list.text.contains("- 小红书图文：\(xhs.description)") && list.text.contains("- 国际新闻："))
        #expect(!read.isError && read.text == "---\nname: 代码库解读\ndescription: \(code.description)\n---\n\n\(code.body)", "\(read.text.prefix(120))")
        #expect(missing.isError && missing.text.contains("没有这份写作手册"), "\(missing.text)")
        #expect(asked && title == "新建写作手册「菜谱」")
        #expect(!saved.isError && saved.text.contains("已新建写作手册「菜谱」"), "\(saved.text)")
        #expect(file == "---\nname: 菜谱\ndescription: 家常菜谱\n---\n\n先写用料。\n")
        #expect(log == ["新建写作手册「菜谱」"], "列进「外部 Agent 的操作」：\(log ?? [])")
        #expect(harness.pageErrors == [])
    }

    @Test("老用户补入新技能，不覆盖同名手册，不复活删除的旧示例或已安装新技能")
    func upgradePreservesUserLibrary() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let custom = "---\nname: 标题打磨\ndescription: 我的写法\n---\n用户改过的正文"
        try custom.write(to: folder.appendingPathComponent("标题打磨.md"), atomically: true, encoding: .utf8)
        let manuals = WritingManuals(folder: folder, examples: Self.examples)
        let installed = try manuals.list().map(\.name)
        #expect(installed.contains("保留原意去AI味") && installed.contains("英文简明表达"))
        #expect(!installed.contains("国际新闻"), "旧示例可能被用户删除，不能补回")
        #expect(try String(contentsOf: folder.appendingPathComponent("标题打磨.md"), encoding: .utf8) == custom)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("观点长文.md"))
        #expect(try !manuals.list().contains(where: { $0.name == "观点长文" }))
    }

    @Test("写作技能：斜杠打开、多选不发送，正文随下一条注入且历史留标签，之后不继承")
    func selectedSkillsReachNextTurn() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["收到。"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(AISessionTests.helpers + """
            await mc.drafts.create({ markdown: "测试稿件。" });
            await openAI();
            const input = document.getElementById('aiInput');
            input.dispatchEvent(new KeyboardEvent('keydown', { key: '/', bubbles: true, cancelable: true }));
            await until(() => document.querySelectorAll('#aiSkillsList input').length === 7);
            for (const name of ['标题打磨', '保留原意去AI味']) {
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
            await until(() => !document.getElementById('aiSkillsPicker').hidden && document.querySelectorAll('#aiSkillsList input').length === 7);
            [...document.querySelectorAll('#aiSkillsList input')].find(n => n.value === '标题打磨').click();
            document.getElementById('aiSkillsDone').click();
            preset('封面标题 5 选 1');
            await until(() => finished(3));
            return { skills: first.skills.map(s => s.name), tags, selected, text: first.text };
        """) as? [String: Any]
        let prompt = fake.prompt(0)
        await harness.tearDown()
        #expect((result?["skills"] as? [String]) == ["标题打磨", "保留原意去AI味"])
        #expect((result?["tags"] as? [String]) == ["标题打磨", "保留原意去AI味"])
        #expect(result?["selected"] as? Int == 0)
        #expect(result?["text"] as? String == "给我五个标题")
        #expect(prompt.contains("【技能：标题打磨】") && prompt.contains("【技能：保留原意去AI味】"))
        #expect(prompt.contains("力度可以变，事实不能变") && !prompt.contains("# 英文简明表达"))
        #expect(prompt.hasSuffix("给我五个标题"))
        #expect(fake.prompt(1) == "解释一下", "后一轮不携带前一轮技能正文")
        #expect(fake.prompt(2).contains("【技能：标题打磨】"), "快捷命令同样携带下一条消息的技能")
        #expect(harness.pageErrors == [])
    }

    @Test("选中的技能被删除后发送失败，恢复输入与技能，未启动 agent")
    func missingSelectedSkillRestoresComposer() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["不应启动"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(AISessionTests.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            document.getElementById('aiSkillsToggle').click();
            await until(() => document.querySelectorAll('#aiSkillsList input').length === 7);
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
