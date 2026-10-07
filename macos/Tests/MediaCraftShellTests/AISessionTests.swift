import Foundation
import Testing

/// AI 会话（本机 Claude Code）：找 claude、每篇稿子一个会话（先 --session-id 后 --resume）、流式回复、
/// 润色 / 命令 / 改写进同一个会话、改稿先逐处确认再作为一步可撤销的编辑、记录随稿子保存、停止与收尾时进程都结束。
/// 修改对比与版本的细节见 AIReviewTests。
/// claude 换成假的可执行文件（Fixtures/ai/fake-claude），它记下参数与 stdin、回放脚本里的 stream-json。
@MainActor
struct AISessionTests {
    static let helpers = """
        const mc = window.mediacraft;
        window.mc = mc;
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
        window.log = () => document.querySelector('[role="log"][aria-label="AI 对话"]');
        // 对话里看得见的每一条：[种类, 文字]（不含按钮上的字）
        window.shown = () => [...log().children].map((node) => [
          ["user", "assistant", "tool", "end", "typing"].find((kind) => node.classList.contains(`ai-${kind}`)),
          [...node.querySelectorAll("button")].reduce((text, button) => text.replace(button.innerText, ""), node.innerText)
            .replace(/\\s+/g, " ").trim(),
        ]);
        window.statusLine = () => document.querySelector("#aiPanel .ai-status").textContent;
        window.openAI = async () => {
          ui.click("AI 助手");
          await until(() => !ui.find("问 Claude").disabled);
        };
        // 像用户一样在输入框里打字、按回车
        window.ask = (text) => {
          const input = ui.find("问 Claude");
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
          input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
        };
        // 快捷命令：还没有对话时摊开在输入框上面，有了对话收在「快捷命令」里，要先点开
        window.presetButton = (name) => {
          if (!ui.find(name)) ui.click("快捷命令");
          return ui.find(name);
        };
        window.preset = (name) => presetButton(name).click();
        // 输入框旁的发送按钮（回复时换成停止）
        window.sendButton = () => ui.find("发送", { within: "对 Claude 说" });
        window.stopButton = () => ui.find("停止", { within: "对 Claude 说" });
        window.ends = async (draftId) => (await mc.ai.history(draftId)).messages.filter((message) => message.role === "end");
        // 第 count 轮说完，界面上又可以发送了
        window.finished = async (count) => {
          const { running, messages } = await mc.ai.history();
          return !running && messages.filter((message) => message.role === "end").length === count && sendButton();
        };
        window.selectText = async (text) => {
          const at = (await mc.drafts.current()).markdown.indexOf(text);
          return mc.editor.select(at, at + text.length);
        };
    """

    @Test("找不到 claude：AI 助手说明怎么安装、怎么指定路径，润色与输入框不可用")
    func notFoundShowsGuide() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            ui.click("AI 助手");
            await until(() => ui.find("重新查找"));
            const guide = document.querySelector('[aria-labelledby="aiGuideTitle"]');
            return {
              status: await mc.ai.status(),
              guide: guide.textContent.replace(/\\s+/g, " "),
              line: statusLine(),
              polish: ui.find("一键润色全文").disabled,
              command: ui.find("封面标题 5 选 1").disabled,
              input: ui.find("问 Claude").disabled,
            };
        """) as? [String: Any]
        await harness.tearDown()

        let status = result?["status"] as? [String: Any]
        #expect(status?["available"] as? Bool == false)
        let reason = status?["error"] as? String ?? ""
        #expect(reason.contains("PATH"))
        let guide = result?["guide"] as? String ?? ""
        #expect(guide.contains("没有找到本机 Claude Code"))
        #expect(guide.contains("npm install -g @anthropic-ai/claude-code"), "给出安装命令")
        #expect(guide.contains("which claude") && guide.contains("指定路径"), "说明怎么指定路径")
        #expect(result?["line"] as? String == "没有找到本机 Claude Code")
        #expect(result?["polish"] as? Bool == true)
        #expect(result?["command"] as? Bool == true)
        #expect(result?["input"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("在设置里指定 claude 的路径：错的路径说明原因，对的路径连上并记住（重新打开还在），「自动查找」恢复")
    func pathOverride() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            ui.click("AI 助手");
            await until(() => ui.find("指定路径"));
            ui.click("指定路径");
            const pathInput = ui.find("claude 的路径");
            const focused = document.activeElement === pathInput;
            pathInput.value = "/没有这个/claude";
            ui.click("保存", { within: "Claude Code" });
            const error = await until(() => document.querySelector('#aiSettings [role="alert"]:not([hidden])')?.textContent);
            pathInput.value = path;
            ui.click("保存", { within: "Claude Code" });
            await until(() => !ui.find("问 Claude").disabled);
            return { focused, error, line: statusLine(), status: await mc.ai.status(), guide: Boolean(ui.find("重新查找")) };
        """, arguments: ["path": fake.executable.path]) as? [String: Any]
        try await harness.load()
        let reopened = try await harness.evaluate(Self.helpers + """
            const kept = await mc.ai.status();
            const auto = await mc.ai.setPath(null);
            return { kept, auto };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["focused"] as? Bool == true, "「指定路径」打开设置并聚焦路径输入框")
        let error = result?["error"] as? String ?? ""
        #expect(error.contains("/没有这个/claude"), "错的路径说明原因")
        #expect(result?["line"] as? String == "本机 Claude Code 9.9.9 · 已连接")
        let status = result?["status"] as? [String: Any]
        #expect(status?["available"] as? Bool == true)
        #expect(status?["source"] as? String == "settings")
        #expect(status?["path"] as? String == fake.executable.path)
        #expect(result?["guide"] as? Bool == false, "连上后指引收起")
        let kept = reopened?["kept"] as? [String: Any]
        #expect(kept?["path"] as? String == fake.executable.path, "重新打开 App 还记得")
        #expect((reopened?["auto"] as? [String: Any])?["available"] as? Bool == false, "自动查找：终端 PATH 里没有")
        #expect(harness.pageErrors == [])
    }

    @Test("第一轮用 --session-id 开会话，下一轮 --resume 同一个；在这篇稿子的工作副本里以 stream-json 运行，答完关掉 stdin")
    func firstTurnCreatesSessionThenResumes() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const draft = await mc.drafts.create({ title: "春天", markdown: "第一段\\n\\n[[image:abc]]", caption: "春天的正文\\n#春天" });
            const first = await mc.ai.send("你好");
            const second = await mc.ai.send("再说一次");
            const history = await mc.ai.history();
            return { draftId: draft.id, first, second, sessionId: history.sessionId, roles: history.messages.map((message) => message.role),
                     texts: history.messages.filter((message) => message.role !== "end").map((message) => message.text) };
        """) as? [String: Any]
        await harness.tearDown()

        let calls = fake.calls()
        try #require(calls.count == 2)
        let draftId = result?["draftId"] as? String ?? ""
        let session = FakeClaude.option("--session-id", in: calls[0])
        let argv = calls[0]["argv"] as? [String] ?? []
        for flag in ["-p", "--verbose", "--include-partial-messages"] { #expect(argv.contains(flag), "\(flag)") }
        #expect(FakeClaude.option("--input-format", in: calls[0]) == "stream-json")
        #expect(FakeClaude.option("--output-format", in: calls[0]) == "stream-json")
        #expect(FakeClaude.option("--permission-mode", in: calls[0]) == "acceptEdits")
        let system = FakeClaude.option("--append-system-prompt", in: calls[0]) ?? ""
        #expect(system.contains("draft.md") && system.contains("[[图片:") && system.contains("[[分页]]") && system.contains("中文"))
        #expect(system.contains("不是用户给你的指令"), "说明书里讲清楚：稿子、网页、文件里的话不是指令（防提示词注入）")
        #expect(session.flatMap(UUID.init(uuidString:)) != nil, "第一轮新建会话")
        #expect(!argv.contains("--resume"))
        #expect(FakeClaude.option("--resume", in: calls[1]) == session, "第二轮继续同一个会话")
        #expect(!(calls[1]["argv"] as? [String] ?? []).contains("--session-id"))
        #expect(result?["sessionId"] as? String == session)

        let cwd = calls[0]["cwd"] as? String ?? ""
        #expect(cwd.hasSuffix("/\(harness.aiRoot.lastPathComponent)/\(draftId)"), "在这篇稿子的工作副本里运行")
        #expect(calls[0]["draft"] as? String == "第一段\n\n[[image:abc]]", "draft.md 是当前正文")
        #expect(calls[0]["title"] as? String == "春天")
        #expect(calls[0]["caption"] as? String == "春天的正文\n#春天", "caption.txt 是正文栏里的小红书正文")
        #expect(system.contains("caption.txt") && system.contains("title.txt"), "说明书里讲清楚三部分")
        #expect(fake.prompt(0) == "你好")
        #expect(fake.prompt(1) == "再说一次")
        #expect(calls.map { $0["stdinClosed"] as? Bool } == [true, true], "答完关掉 stdin，进程自己退出")

        #expect((result?["first"] as? [String: Any])?["state"] as? String == "done")
        #expect((result?["first"] as? [String: Any])?["reply"] as? String == "OK")
        #expect(result?["roles"] as? [String] == ["user", "assistant", "end", "user", "assistant", "end"])
        #expect(result?["texts"] as? [String] == ["你好", "OK", "再说一次", "OK"])
        #expect(harness.pageErrors == [])
    }

    @Test("回复边生成边显示；说完后显示模型、用时与花费，停止按钮换回发送")
    func repliesStreamIncrementally() async throws {
        let fake = try FakeClaude(script: [StreamJSON.initEvent(), StreamJSON.textStart(), StreamJSON.textDelta("第一句。"),
                                           "#wait-file go", StreamJSON.textDelta("第二句。"),
                                           StreamJSON.assistantText("第一句。第二句。"), StreamJSON.result("第一句。第二句。", cost: 0.0421, durationMs: 5230)])
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let partial = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            ask("写两句");
            await until(() => shown().some(([kind, text]) => kind === "assistant" && text === "第一句。"));
            return { shown: shown(), stop: Boolean(stopButton()), send: Boolean(sendButton()), line: statusLine(), input: ui.find("问 Claude").value };
        """) as? [String: Any]
        fake.release("go")
        let finished = try await harness.evaluate("""
            await until(() => sendButton() && shown().at(-1)?.[0] === "end");
            return { shown: shown(), line: statusLine() };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(partial?["shown"] as? [[String]] == [["user", "写两句"], ["assistant", "第一句。"]], "只出来了第一句")
        #expect(partial?["stop"] as? Bool == true)
        #expect(partial?["send"] as? Bool == false, "回复时发送按钮换成停止")
        #expect(partial?["line"] as? String == "Claude 正在回复…（claude-opus-4-6）", "回复时带上 claude 报的模型")
        #expect(partial?["input"] as? String == "", "发出去后输入框清空")
        #expect(finished?["shown"] as? [[String]] == [["user", "写两句"], ["assistant", "第一句。第二句。"], ["end", "claude-opus-4-6 · 5.2 秒 · $0.04"]])
        #expect(finished?["line"] as? String == "本机 Claude Code 9.9.9 · 已连接 · claude-opus-4-6")
        #expect(harness.pageErrors == [])
    }

    @Test("一键润色、快捷命令、选中「改写」与 ⌘J 都进同一个会话，选中的文字连同位置一起带上")
    func polishCommandsAndRewriteShareTheSession() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "今天天气很好。\\n\\n我们去公园散步。" });
            await openAI();
            ui.click("一键润色全文");
            await until(() => finished(1));
            preset("封面标题 5 选 1");
            await until(() => finished(2));

            ui.click("样式");
            await selectText("公园散步");
            await wait(300);
            ui.click("改写", { within: document.querySelector('[role="toolbar"][aria-label="选中的文字"]') });
            const rewrite = {
              tab: ui.find("AI 助手").getAttribute("aria-selected"),
              focus: ui.name(document.activeElement),
              chip: document.getElementById("aiContext").textContent.replace(/\\s+/g, " ").trim(),
            };
            ask("更口语一点");
            await until(() => finished(3));

            ui.click("样式");
            await selectText("天气很好");
            document.activeElement.dispatchEvent(new KeyboardEvent("keydown", { key: "j", metaKey: true, bubbles: true, cancelable: true }));
            await until(() => document.activeElement === ui.find("问 Claude"));
            const commandJ = {
              tab: ui.find("AI 助手").getAttribute("aria-selected"),
              chip: document.getElementById("aiContext").textContent.replace(/\\s+/g, " ").trim(),
            };
            ask("");
            await until(() => finished(4));
            const users = (await mc.ai.history()).messages.filter((message) => message.role === "user");
            return { rewrite, commandJ, users: users.map(({ kind, text, context }) => ({ kind, text, context: context ?? null })), shown: shown() };
        """) as? [String: Any]
        await harness.tearDown()

        let calls = fake.calls()
        try #require(calls.count == 4)
        let session = FakeClaude.option("--session-id", in: calls[0])
        #expect(session != nil)
        #expect(calls.dropFirst().map { FakeClaude.option("--resume", in: $0) } == [session, session, session], "都在同一个会话里")
        #expect(fake.prompt(0).contains("润色") && fake.prompt(0).contains("保留所有自定义标记"))
        #expect(fake.prompt(1).contains("5 个小红书封面标题"))
        #expect(fake.prompt(2).contains("第 13–16 个字符") && fake.prompt(2).contains("公园散步") && fake.prompt(2).hasSuffix("更口语一点"))
        #expect(fake.prompt(3).contains("第 3–6 个字符") && fake.prompt(3).contains("天气很好") && fake.prompt(3).contains("改写得更通顺"))

        let rewrite = result?["rewrite"] as? [String: String]
        #expect(rewrite?["tab"] == "true", "改写切到 AI 助手")
        #expect(rewrite?["focus"] == "问 Claude", "并聚焦输入框")
        #expect(rewrite?["chip"] == "选中的文字 · 第 13–16 字 公园散步")
        let commandJ = result?["commandJ"] as? [String: String]
        #expect(commandJ?["tab"] == "true")
        #expect(commandJ?["chip"] == "选中的文字 · 第 3–6 字 天气很好")
        let users = result?["users"] as? [[String: Any]] ?? []
        #expect(users.map { $0["kind"] as? String } == ["polish", "command", "rewrite", "rewrite"])
        #expect(users.map { $0["text"] as? String } == ["一键润色全文", "封面标题 5 选 1", "更口语一点", "改写这段"])
        #expect((users.last?["context"] as? [String: Any])?["text"] as? String == "天气很好")
        let shown = (result?["shown"] as? [[String]] ?? []).filter { $0.first == "user" }.map { $0.last ?? "" }
        #expect(shown == ["一键润色全文", "封面标题 5 选 1", "选中的文字 · 第 13–16 字 公园散步 更口语一点", "选中的文字 · 第 3–6 字 天气很好 改写这段"])
        #expect(harness.pageErrors == [])
    }

    @Test("AI 改了 draft.md / title.txt：先逐处确认，接受后是一步可以撤销的编辑，记录上标「已修改稿子」；没改就不标")
    func editsLandAsOneUndoableEdit() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        try fake.script(FakeClaude.fixture("edit-draft.jsonl"), call: 1)
        try fake.script(["#write [\"title.txt\", \"新标题\\n\"]"] + StreamJSON.reply(["标题改好了。"]), call: 2)
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "旧标题", markdown: "甲的故事\\n\\n第二段" });
            await openAI();
            ask("把甲改成乙");
            await until(() => finished(1));
            const waiting = { markdown: (await mc.drafts.current()).markdown, review: await mc.ai.review.get(), turn1: shown() };
            ui.click("全部接受");
            await until(async () => !(await mc.ai.review.get()).open);
            const edited = (await mc.drafts.current()).markdown;
            const turn1 = shown();
            const undone = (await mc.drafts.undo()).markdown;
            const redone = (await mc.drafts.redo()).markdown;
            ask("改个标题");
            await until(() => finished(2));
            await mc.ai.review.acceptAll();
            const title = (await mc.drafts.current()).title;
            ask("随便聊聊");
            await until(() => finished(3));
            return { waiting, edited, undone, redone, title, turn1, ends: (await ends()).map((end) => Boolean(end.edited)), shown: shown() };
        """) as? [String: Any]
        await harness.tearDown()

        let waiting = result?["waiting"] as? [String: Any]
        #expect(waiting?["markdown"] as? String == "甲的故事\n\n第二段", "确认之前不改正文")
        let hunks = (waiting?["review"] as? [String: Any])?["hunks"] as? [[String: Any]] ?? []
        #expect(hunks.map { "\($0["before"] ?? "")→\($0["after"] ?? "")" } == ["甲的故事→乙的故事"])
        #expect((waiting?["turn1"] as? [[String]])?.last == ["end", "1 处修改待确认 claude-opus-4-6 · 16 秒 · $0.72"])
        #expect(result?["edited"] as? String == "乙的故事\n\n第二段", "接受后落进编辑器")
        #expect(result?["undone"] as? String == "甲的故事\n\n第二段", "一次 ⌘Z 撤回整轮改动")
        #expect(result?["redone"] as? String == "乙的故事\n\n第二段")
        #expect(result?["title"] as? String == "新标题", "title.txt 改了就换标题")
        #expect(result?["turn1"] as? [[String]] == [
            ["user", "把甲改成乙"], ["tool", "读取 draft.md"], ["tool", "修改 draft.md"], ["assistant", "OK"],
            ["end", "已修改稿子 接受 1/1 处 · claude-opus-4-6 · 16 秒 · $0.72"],
        ])
        #expect(result?["ends"] as? [Bool] == [true, true, false], "没改稿子的一轮不标")
        #expect(harness.pageErrors == [])
    }

    @Test("会话记录随稿子保存：换一篇是那篇自己的会话，换回来、重新打开 App 都还在，接着同一个会话聊")
    func transcriptFollowsTheDraft() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let before = try await harness.evaluate(Self.helpers + """
            const a = await mc.drafts.create({ markdown: "甲稿" });
            await openAI();
            ask("你好");
            await until(() => finished(1));
            const withA = shown();
            await mc.drafts.create({ markdown: "乙稿" });
            await until(() => log().hidden);
            const onB = { messages: (await mc.ai.history()).messages.length, empty: ui.find("问 Claude") && !document.getElementById("aiEmpty").hidden };
            await mc.drafts.open(a.id);
            await until(() => shown().length === withA.length);
            return { a: a.id, withA, onB, back: shown() };
        """) as? [String: Any]
        try await harness.load()
        let after = try await harness.evaluate(Self.helpers + """
            await openAI();
            const reloaded = shown();
            const { sessionId } = await mc.ai.history();
            ask("接着聊");
            await until(() => finished(2));
            return { reloaded, sessionId, current: (await mc.drafts.current()).markdown };
        """) as? [String: Any]
        await harness.tearDown()

        let withA = before?["withA"] as? [[String]]
        #expect(withA?.map { $0.first ?? "" } == ["user", "assistant", "end"])
        let onB = before?["onB"] as? [String: Any]
        #expect(onB?["messages"] as? Int == 0, "另一篇是它自己的（空的）会话")
        #expect(onB?["empty"] as? Bool == true)
        #expect(before?["back"] as? [[String]] == withA, "换回来还在")
        #expect(after?["current"] as? String == "甲稿")
        #expect(after?["reloaded"] as? [[String]] == withA, "重新打开 App 还在")
        let calls = fake.calls()
        try #require(calls.count == 2)
        #expect(FakeClaude.option("--resume", in: calls[1]) == FakeClaude.option("--session-id", in: calls[0]), "接着同一个会话")
        #expect(after?["sessionId"] as? String == FakeClaude.option("--session-id", in: calls[0]))
        #expect(harness.pageErrors == [])
    }

    @Test("每篇稿子记下用的是哪个后端：跑过一轮记为 claude；没记后端的旧会话按 claude 读、照常续上；认不出的后端壳不起进程")
    func draftRemembersItsBackend() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let first = try await harness.evaluate(Self.helpers + StorageScripts.read + """
            const draft = await mc.drafts.create({ markdown: "甲稿" });
            await openAI();
            ask("你好");
            await until(() => finished(1));
            const stored = await until(async () => {
              const record = await readStore("drafts", draft.id);
              return record?.ai?.messages?.length >= 3 && record;
            });
            // 这版之前存下的会话没有 backend：去掉它再存回去
            const { backend, ...legacy } = stored.ai;
            await writeStore("drafts", [{ ...stored, ai: legacy }]);
            return { backend };
        """) as? [String: Any]
        try await harness.load()
        let second = try await harness.evaluate(Self.helpers + StorageScripts.read + """
            await openAI();
            ask("接着聊");
            await until(() => finished(2));
            const id = (await mc.drafts.current()).id;
            const stored = await until(async () => {
              const record = await readStore("drafts", id);
              return record?.ai?.backend && record;
            });
            const refused = await window.MediaCraftNative.ai.send({
              turnId: "t-unknown", draftId: id, backend: "nope", sessionId: crypto.randomUUID(), prompt: "你好", markdown: "甲稿",
            }).then(() => "起了进程", (error) => error.message);
            return { backend: stored.ai.backend, refused };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(first?["backend"] as? String == "claude")
        #expect(second?["backend"] as? String == "claude", "没记后端的旧会话按 claude 续上，之后记上")
        #expect((second?["refused"] as? String ?? "").contains("不认识的 AI 后端：nope"), "\(second?["refused"] ?? "")")
        let calls = fake.calls()
        try #require(calls.count == 2, "认不出的后端不起进程")
        #expect(FakeClaude.option("--resume", in: calls[1]) == FakeClaude.option("--session-id", in: calls[0]), "旧会话照常续上")
        #expect(harness.pageErrors == [])
    }

    @Test("换稿子时正在跑的一轮继续跑完；它的修改等打开那篇时再给你确认，接受后同样可以撤销")
    func runningTurnFinishesForItsOwnDraft() async throws {
        let fake = try FakeClaude(script: ["#wait-file go", "#edit [\"draft.md\", \"甲稿\", \"甲稿改好了\"]"] + StreamJSON.reply(["改好了。"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            window.a = await mc.drafts.create({ markdown: "甲稿" });
            await openAI();
            ask("改一下");
            await until(async () => (await mc.ai.history()).running);
            window.b = await mc.drafts.create({ markdown: "乙稿" });
        """)
        fake.release("go")
        let result = try await harness.evaluate("""
            await until(async () => !(await mc.ai.history(a.id)).running);
            const whileAway = {
              current: (await mc.drafts.current()).markdown,
              stored: (await mc.drafts.get(a.id)).markdown,
              end: (await ends(a.id)).at(-1),
            };
            await mc.drafts.open(a.id);
            await until(() => ui.find("全部接受", { within: document.getElementById("aiReview") }));
            const shownOnOpen = (await mc.ai.review.get()).hunks.map(({ before, after }) => [before, after]);
            ui.click("全部接受", { within: document.getElementById("aiReview") });
            await until(async () => (await mc.drafts.current()).markdown === "甲稿改好了");
            await until(() => shown().at(-1)?.[1].startsWith("已修改稿子"));
            const end = (await ends()).at(-1);
            const undone = (await mc.drafts.undo()).markdown;
            return { whileAway, shownOnOpen, end, undone };
        """) as? [String: Any]
        await harness.tearDown()

        let whileAway = result?["whileAway"] as? [String: Any]
        #expect(whileAway?["current"] as? String == "乙稿", "不会改到正在编辑的另一篇")
        #expect(whileAway?["stored"] as? String == "甲稿", "等打开时再确认")
        #expect((whileAway?["end"] as? [String: Any])?["review"] as? [String: Int] == ["count": 1], "记下有 1 处待确认")
        #expect(result?["shownOnOpen"] as? [[String]] == [["甲稿", "甲稿改好了"]], "打开那篇时显示待确认的修改")
        let end = result?["end"] as? [String: Any]
        #expect(end?["edited"] as? Bool == true)
        #expect(end?["review"] as? [String: Int] == ["count": 1, "accepted": 1])
        #expect(result?["undone"] as? String == "甲稿", "打开后接受的修改也能撤销")
        #expect(harness.pageErrors == [])
    }

    @Test("停止：先 SIGINT，不退出再 SIGTERM；进程确实没了，记录上是「已停止」，可以接着发下一轮")
    func stopKillsTheProcess() async throws {
        let fake = try FakeClaude(script: [StreamJSON.initEvent(), StreamJSON.textStart(), StreamJSON.textDelta("写到一半"), "#hang"])
        defer { fake.remove() }
        try fake.script(["#ignore-sigint", StreamJSON.initEvent(), StreamJSON.textStart(), StreamJSON.textDelta("不听话"), "#hang"], call: 2)
        try fake.script(StreamJSON.reply(["好的。"]), call: 3)
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            ask("写长一点");
            await until(() => shown().some(([kind, text]) => kind === "assistant" && text === "写到一半"));
            stopButton().click();
            await until(() => sendButton());
            const first = shown();
            ask("再试一次");
            await until(() => shown().some(([, text]) => text === "不听话"));
            stopButton().click();
            await until(() => sendButton());
            ask("第三次");
            await until(() => finished(3));
            return { first, states: (await ends()).map((end) => end.state) };
        """) as? [String: Any]
        let calls = fake.calls()
        let pids = calls.compactMap { ($0["pid"] as? NSNumber)?.int32Value }
        var gone: [Bool] = []
        for pid in pids { gone.append(await FakeClaude.waitUntilGone(pid)) }
        await harness.tearDown()

        #expect(result?["first"] as? [[String]] == [["user", "写长一点"], ["assistant", "写到一半"], ["end", "已停止 · claude-opus-4-6"]])
        #expect(result?["states"] as? [String] == ["cancelled", "cancelled", "done"])
        try #require(calls.count == 3)
        #expect(calls[0]["signals"] as? [String] == ["INT"])
        #expect(calls[1]["signals"] as? [String] == ["INT", "TERM"], "SIGINT 不管用时再 SIGTERM")
        #expect(gone == [true, true, true], "进程都没了")
        #expect(harness.pageErrors == [])
    }

    @Test("关窗口（harness 收尾）与重新载入页面时，还在跑的 claude 进程都被结束")
    func teardownAndReloadEndTheProcesses() async throws {
        let fake = try FakeClaude(script: [StreamJSON.initEvent(), "#hang"])
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            ask("一直等着");
            await until(async () => (await mc.ai.history()).running);
        """)
        try await Self.waitForCalls(fake, count: 1)
        try await harness.load()
        let afterReload = try await harness.evaluate(Self.helpers + """
            await openAI();
            const { running, messages } = await mc.ai.history();
            ask("再等一次");
            await until(async () => (await mc.ai.history()).running);
            return { running, last: messages.at(-1) };
        """) as? [String: Any]
        try await Self.waitForCalls(fake, count: 2)
        let pids = fake.calls().compactMap { ($0["pid"] as? NSNumber)?.int32Value }
        let reloadedGone = await FakeClaude.waitUntilGone(pids[0])
        await harness.tearDown()
        let teardownGone = await FakeClaude.waitUntilGone(pids[1])

        #expect(reloadedGone, "重新载入后旧页面的进程结束")
        #expect(afterReload?["running"] as? Bool == false)
        #expect((afterReload?["last"] as? [String: Any])?["state"] as? String == "interrupted", "被打断的一轮记为已中断")
        #expect(teardownGone, "收尾后进程结束")
    }

    @Test("Claude Code 那边的会话没了（--resume 找不到）：这一轮报错说明，下一轮开新会话")
    func lostSessionStartsOver() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await mc.ai.send("第一轮");
        """)
        try FileManager.default.removeItem(at: fake.directory.appendingPathComponent("sessions"))
        let result = try await harness.evaluate("""
            const lost = await mc.ai.send("第二轮");
            const fresh = await mc.ai.send("第三轮");
            return { lost, fresh };
        """) as? [String: Any]
        await harness.tearDown()

        let calls = fake.calls()
        try #require(calls.count == 3)
        #expect((result?["lost"] as? [String: Any])?["state"] as? String == "error")
        let lost = (result?["lost"] as? [String: Any])?["error"] as? String ?? ""
        #expect(lost.contains("开一个新会话"))
        #expect((result?["fresh"] as? [String: Any])?["state"] as? String == "done")
        let first = FakeClaude.option("--session-id", in: calls[0])
        #expect(FakeClaude.option("--resume", in: calls[1]) == first)
        let fresh = FakeClaude.option("--session-id", in: calls[2])
        #expect(fresh != nil && fresh != first, "开了新会话")
        #expect(harness.pageErrors == [])
    }

    private static func waitForCalls(_ fake: FakeClaude, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while fake.calls().count < count || fake.calls().last?["stdin"] as? [String] == [] {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
