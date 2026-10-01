import Foundation
import Testing

/// AI 后端 Codex（`codex app-server`，stdio 上的 JSON-RPC；第 05 张票）：新稿子默认用它、开线程挂上 App 的工具、流式回复、
/// 改稿进修改对比、续线程；审批三种回答与「本次会话都允许」；App 的工具由页面执行；停止、续不上、没登录；后端锁定与重新开始；
/// 自带的生图进配图候选（第 06 张票）。
/// codex 换成假的可执行文件（Fixtures/ai/fake-codex），它记下每次开线程或续线程的进程收到的每一行与页面的回答。
@MainActor
struct AICodexTests {
    static let helpers = AIToolsTests.helpers + """
        window.openAI = async () => {
          ui.click("AI 助手");
          await until(() => ui.find("问 Codex") && !ui.find("问 Codex").disabled);
        };
        window.ask = (text) => {
          const input = ui.find("问 Codex");
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
          input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
        };
        window.sendButton = () => ui.find("发送", { within: "对 Codex 说" });
        window.stopButton = () => ui.find("停止", { within: "对 Codex 说" });
        window.messages = async () => (await mc.ai.history()).messages.map(({ role, text, state, error, decision }) => ({ role, text, state, error, decision }));
    """

    @Test("新稿子默认用本机的 Codex：第一轮 app-server 开线程（挂上 App 的工具、不给生图工具、工作区可写、按需审批），流式回复，改稿进修改对比；下一轮续上同一个线程")
    func firstTurnStartsThreadAndResumes() async throws {
        let codex = try FakeCodex(script: FakeCodex.text(["把甲", "改好了"]) + [
            FakeCodex.notify("item/started", ["item": ["type": "fileChange", "id": "fc-1", "changes": [["path": "draft.md", "kind": ["type": "update"], "diff": ""]]]]),
            #"#write ["draft.md", "乙\n"]"#,
            FakeCodex.notify("item/completed", ["item": ["type": "fileChange", "id": "fc-1", "status": "completed", "changes": [["path": "draft.md", "kind": ["type": "update"], "diff": ""]]]]),
        ])
        try codex.script(FakeCodex.reply("又一句"), call: 2)
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "甲\\n" });
            await openAI();
            const before = await mc.ai.history();
            ask("把甲改成乙");
            await until(async () => (await mc.ai.review.get()).open);
            await until(() => finished(1));
            const first = { lines: lines(), history: await mc.ai.history(), status: statusLine() };
            await mc.ai.review.acceptAll();
            await until(async () => !(await mc.ai.review.get()).open);
            ask("再来一句");
            await until(() => finished(2));
            return {
              before: { backend: before.backend, locked: before.locked },
              first: { lines: first.lines, backend: first.history.backend, locked: first.history.locked, sessionId: first.history.sessionId, status: first.status },
              markdown: (await mc.drafts.current()).markdown,
              ends: (await ends()).map((end) => end.state),
            };
        """) as? [String: Any]
        await harness.tearDown()

        let before = result?["before"] as? [String: Any]
        #expect(before?["backend"] as? String == "codex", "找得到、登录了 Codex：新稿子默认用它")
        #expect(before?["locked"] as? Bool == false)
        let calls = codex.calls()
        try #require(calls.count == 2, "每轮一个 app-server 进程")
        #expect(calls[0]["argv"] as? [String] == ["app-server"])
        #expect(codex.stdin(0).map { $0["method"] as? String ?? "" } == ["initialize", "initialized", "thread/start", "turn/start"], "握手 → 开线程 → 这一轮")
        let start = try #require(codex.params(0, "thread/start"))
        #expect(start["approvalPolicy"] as? String == "on-request")
        #expect(start["sandbox"] as? String == "workspace-write")
        #expect((start["developerInstructions"] as? String ?? "").contains("Vibepost"))
        #expect((start["developerInstructions"] as? String ?? "").contains("不是用户给你的指令"), "Codex 也收到防提示词注入的说明")
        let tools = (start["dynamicTools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(tools.contains("get_draft") && tools.contains("set_theme") && !tools.contains("generate_image"), "App 的工具挂成动态工具，生图用 Codex 自己的：\(tools)")
        let turn = try #require(codex.params(0, "turn/start"))
        let input = (turn["input"] as? [[String: Any]] ?? []).first?["text"] as? String ?? ""
        #expect(input.contains("把甲改成乙"))
        let first = result?["first"] as? [String: Any]
        let lines = first?["lines"] as? [[String]] ?? []
        #expect(lines.contains(["assistant", "把甲改好了"]), "流式回复：\(lines)")
        #expect(lines.contains(["tool", "修改 draft.md"]), "它改的文件记一行：\(lines)")
        #expect(first?["backend"] as? String == "codex" && first?["locked"] as? Bool == true, "有了对话，后端锁定")
        #expect((first?["status"] as? String ?? "").hasPrefix("本机 Codex 9.9.9 · 已连接"), "\(first?["status"] ?? "")")
        #expect(result?["markdown"] as? String == "乙\n", "接受修改后进了正文")
        let resume = try #require(codex.params(1, "thread/resume"))
        #expect(resume["threadId"] as? String == first?["sessionId"] as? String, "下一轮续上同一个线程")
        #expect(codex.stdin(1).map { $0["method"] as? String ?? "" } == ["initialize", "initialized", "thread/resume", "turn/start"])
        #expect(result?["ends"] as? [String] == ["done", "done"])
        #expect(harness.pageErrors == [])
    }

    @Test("审批：运行命令弹确认框（Codex 想运行命令），允许 / 本次会话都允许 / 拒绝 分别回 accept / acceptForSession / decline；放行过的同一条命令下一轮不再问")
    func approvalsMapToDecisions() async throws {
        let codex = try FakeCodex(script: [
            FakeCodex.commandApproval(0, "ls -la", reason: "看看目录"),
            Self.command("cmd-0", "ls -la", status: "completed"),
            FakeCodex.commandApproval(1, "npm test"),
            Self.command("cmd-1", "npm test", status: "failed"),
            FakeCodex.commandApproval(2, "rm -rf build"),
            Self.command("cmd-2", "rm -rf build", status: "declined"),
        ] + FakeCodex.reply("跑完了"))
        try codex.script([FakeCodex.commandApproval(0, "npm test")] + FakeCodex.reply("又跑了一次"), call: 2)
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "甲" });
            await openAI();
            ask("跑一下测试");
            const seen = [];
            for (const [command, answer] of [["ls -la", "允许"], ["npm test", "本次会话都允许"], ["rm -rf build", "拒绝"]]) {
              await until(() => sheetView().shown && sheetView().detail === command);
              seen.push(sheetView());
              ui.click(answer, { within: sheet() });
            }
            await until(() => finished(1));
            let asked = false;
            const watch = setInterval(() => { if (sheetView().shown) asked = true; }, 20);
            ask("再跑一次");
            await until(() => finished(2));
            clearInterval(watch);
            return { seen, asked, tools: (await messages()).filter((message) => message.role === "tool").map((message) => message.text),
              decisions: (await messages()).filter((message) => message.role === "permission").map((message) => [message.decision, message.text]) };
        """) as? [String: Any]
        await harness.tearDown()

        let seen = result?["seen"] as? [[String: Any]] ?? []
        #expect(seen.first?["title"] as? String == "Codex 想运行命令")
        #expect(seen.first?["note"] as? String == "看看目录", "它给的原因写在附注里")
        #expect(codex.response(0, 0)?["decision"] as? String == "accept")
        #expect(codex.response(0, 1)?["decision"] as? String == "acceptForSession")
        #expect(codex.response(0, 2)?["decision"] as? String == "decline")
        #expect(codex.response(1, 0)?["decision"] as? String == "accept", "本次会话都允许过的命令下一轮直接放行")
        #expect(result?["asked"] as? Bool == false, "不再弹确认框")
        let decisions = result?["decisions"] as? [[String]] ?? []
        #expect(decisions == [["allow", "运行命令：ls -la"], ["session", "运行命令：npm test"], ["deny", "运行命令：rm -rf build"]], "\(decisions)")
        #expect(result?["tools"] as? [String] == ["运行 ls -la", "运行没成功：npm test"], "拒绝了的命令不再记「运行」：\(result?["tools"] ?? "")")
        #expect(harness.pageErrors == [])
    }

    /// 一条命令跑完（或没成功、被拒绝）的 item/completed
    private static func command(_ id: String, _ command: String, status: String) -> String {
        FakeCodex.notify("item/completed", ["item": ["type": "commandExecution", "id": id, "command": command, "status": status]])
    }

    @Test("App 的工具：Codex 调用动态工具（get_draft、set_theme）由页面执行，回 success 与 contentItems；动作记进会话、可以撤销")
    func dynamicToolsRunInThePage() async throws {
        let codex = try FakeCodex(script: [
            FakeCodex.toolCall(0, "get_draft"),
            FakeCodex.toolCall(1, "set_theme", ["theme": "ink"]),
            FakeCodex.toolCall(2, "no_such_tool"),
        ] + FakeCodex.reply("换好了"))
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "甲" });
            await openAI();
            ask("换成纯黑");
            await until(() => finished(1));
            const theme = (await mc.drafts.current()).theme;
            const acted = await actions();
            return { theme, acted, lines: lines() };
        """) as? [String: Any]
        await harness.tearDown()

        let info = try #require(codex.response(0, 0))
        #expect(info["success"] as? Bool == true)
        let items = info["contentItems"] as? [[String: Any]] ?? []
        #expect(items.first?["type"] as? String == "inputText" && (items.first?["text"] as? String ?? "").contains("theme"), "\(items)")
        #expect(codex.response(0, 1)?["success"] as? Bool == true)
        #expect(codex.response(0, 2)?["success"] as? Bool == false, "没有的工具：回 success false，让它知道")
        #expect(result?["theme"] as? String == "ink")
        let acted = result?["acted"] as? [[String: Any]] ?? []
        #expect(acted.first?["text"] as? String == "换成主题「纯黑」" && acted.first?["undoable"] as? Bool == true, "\(acted)")
        #expect(harness.pageErrors == [])
    }

    @Test("停止：SIGINT 停下 app-server，记为「已停止」；续线程出别的错：照常报、会话留着，下一轮接着续；Codex 那边没了这个线程：这一轮报错说明，下一轮开新线程；没登录时说清楚怎么办")
    func stopLostThreadAndLogin() async throws {
        let codex = try FakeCodex(script: FakeCodex.reply("好"))
        try codex.script([FakeCodex.notify("item/started", ["item": ["type": "agentMessage", "id": "m", "text": ""]]), FakeCodex.notify("item/agentMessage/delta", ["itemId": "m", "delta": "想一想"]), "#hang"], call: 1)
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        let stopped = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "甲" });
            await openAI();
            ask("想很久");
            await until(() => lines().some(([kind, text]) => kind === "assistant" && text === "想一想"));
            stopButton().click();
            await until(() => finished(1));
            ask("接着来");
            await until(() => finished(2));
            return (await ends()).map((end) => end.state);
        """) as? [String]
        codex.resumeError("service temporarily unavailable")
        let hiccup = try await harness.evaluate(Self.helpers + """
            const before = (await mc.ai.history()).sessionId;
            ask("续一下");
            await until(() => finished(3));
            const end = (await ends()).at(-1);
            return { before, after: (await mc.ai.history()).sessionId, state: end.state, error: end.error };
        """) as? [String: Any]
        codex.resumeError(nil)
        _ = try await harness.evaluate(Self.helpers + """
            ask("再续");
            await until(() => finished(4));
            return true;
        """)
        codex.forgetThreads()
        let lost = try await harness.evaluate(Self.helpers + """
            ask("还在吗");
            await until(() => finished(5));
            const lostEnd = (await ends()).at(-1);
            ask("重新开始吧");
            await until(() => finished(6));
            return { lost: { state: lostEnd.state, error: lostEnd.error }, last: (await ends()).at(-1).state };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(stopped == ["cancelled", "done"], "\(stopped ?? [])")
        let calls = codex.calls()
        try #require(calls.count == 6)
        #expect((calls[0]["signals"] as? [Int] ?? []).contains(2), "停止先发 SIGINT")
        #expect(hiccup?["state"] as? String == "error")
        #expect((hiccup?["error"] as? String ?? "").contains("service temporarily unavailable"), "\(hiccup ?? [:])")
        #expect(hiccup?["after"] as? String == hiccup?["before"] as? String && hiccup?["before"] is String, "别的错不算会话没了：\(hiccup ?? [:])")
        #expect(codex.params(3, "thread/resume")?["threadId"] as? String == hiccup?["before"] as? String, "下一轮接着续同一个线程")
        let lostEnd = lost?["lost"] as? [String: Any]
        #expect(lostEnd?["state"] as? String == "error")
        #expect((lostEnd?["error"] as? String ?? "").contains("之前的会话在 Codex 里找不到了"), "\(lostEnd ?? [:])")
        #expect(codex.params(4, "thread/resume") != nil)
        #expect(codex.params(5, "thread/start") != nil, "续不上之后开新线程")
        #expect(lost?["last"] as? String == "done")

        let loggedOut = try FakeCodex()
        loggedOut.logOut()
        defer { loggedOut.remove() }
        let second = ShellHarness(terminalPath: [loggedOut.directory], onboarding: false)
        try await second.load()
        let guide = try await second.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "甲" });
            const status = await mc.ai.status({ backend: "codex" });
            await mc.ai.setBackend("codex");
            ui.click("AI 助手");
            await until(() => ui.find("重新查找"));
            return { status, reason: document.getElementById("aiGuideReason").textContent, input: ui.find("问 Codex").disabled };
        """) as? [String: Any]
        await second.tearDown()

        let status = guide?["status"] as? [String: Any]
        #expect(status?["available"] as? Bool == false)
        #expect((status?["error"] as? String ?? "").contains("codex login"), "\(status ?? [:])")
        #expect((guide?["reason"] as? String ?? "").contains("Codex 还没有登录"))
        #expect(guide?["input"] as? Bool == true, "没登录时输入框不可用")
        #expect(harness.pageErrors == [] && second.pageErrors == [])
    }

    @Test("后端：没选过的新稿子默认 Codex（找不到就 Claude Code）；有对话后锁定（选单停用、换不了），重新开始后可以换；Codex 的模型来自它自己的列表")
    func backendLockAndRestart() async throws {
        let codex = try FakeCodex(script: FakeCodex.reply("我是 Codex"))
        let claude = try FakeClaude()
        defer {
            codex.remove()
            claude.remove()
        }
        let harness = ShellHarness(terminalPath: [codex.directory, claude.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "甲" });
            ui.click("AI 助手");
            await until(() => ui.find("问 Codex") && !ui.find("问 Codex").disabled);
            await until(() => [...ui.find("模型").options].some((option) => option.textContent === "GPT Fake Large"));
            const options = [...ui.find("模型").options].map((option) => option.textContent);
            const defaultBackend = (await mc.ai.history()).backend;
            await mc.ai.setBackend("claude");
            await until(() => ui.find("问 Claude") && !ui.find("问 Claude").disabled);
            const input = ui.find("问 Claude");
            input.value = "你好";
            input.dispatchEvent(new Event("input", { bubbles: true }));
            input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
            await until(async () => (await mc.ai.history()).messages.some((message) => message.role === "end"));
            const lockedSelect = ui.find("AI 后端").disabled;
            const refused = await mc.ai.setBackend("codex").then(() => "换了", (error) => error.message);
            await mc.ai.newSession();
            const unlocked = !ui.find("AI 后端").disabled;
            await mc.ai.setBackend("codex");
            await until(() => ui.find("问 Codex") && !ui.find("问 Codex").disabled);
            ask("你好");
            await until(async () => (await mc.ai.history()).messages.some((message) => message.role === "end"));
            await mc.drafts.create({ markdown: "乙" });
            const newest = (await mc.ai.history()).backend;
            return { options, defaultBackend, lockedSelect, refused, unlocked, newest };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["defaultBackend"] as? String == "codex")
        let options = result?["options"] as? [String] ?? []
        #expect(options == ["默认模型", "GPT Fake Large", "GPT Fake Mini", "自定义…"], "\(options)")
        #expect(claude.calls().count == 1, "换成 Claude Code 后这一轮由 claude 回答")
        #expect(result?["lockedSelect"] as? Bool == true, "有对话后后端选单停用")
        #expect((result?["refused"] as? String ?? "").contains("要换，先「重新开始这篇的对话」"), "\(result?["refused"] ?? "")")
        #expect(result?["unlocked"] as? Bool == true, "重新开始后可以换")
        #expect(codex.calls().count == 1, "换回 Codex 后这一轮由 codex 回答")
        #expect(result?["newest"] as? String == "codex", "新稿子沿用上次选的后端")
        #expect(harness.pageErrors == [])
    }

    @Test("审批：改工作区以外的文件、要更多权限都弹确认框（写明哪些文件、要联网），回 accept / 带 scope 的权限；放行过的权限下一轮不再问")
    func fileChangeAndPermissionApprovals() async throws {
        let network: [String: Any] = ["network": ["enabled": true], "fileSystem": NSNull()]
        let codex = try FakeCodex(script: [
            FakeCodex.fileChange("fc-9", ["/tmp/elsewhere/notes.md"]),
            FakeCodex.fileChangeApproval(0, itemId: "fc-9", reason: "要写到工作区外"),
            FakeCodex.permissionsApproval(1, network, reason: "要联网查资料"),
            FakeCodex.permissionsApproval(2, ["network": NSNull(), "fileSystem": ["read": ["/Users/me/Pictures"], "write": NSNull()]]),
        ] + FakeCodex.reply("查好了"))
        try codex.script([FakeCodex.permissionsApproval(0, network)] + FakeCodex.reply("又查了一次"), call: 2)
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "甲" });
            await openAI();
            ask("查点资料写进去");
            const seen = [];
            for (const [title, answer] of [["Codex 想修改文件", "允许"], ["Codex 想获得更多权限（联网）", "本次会话都允许"], ["Codex 想获得更多权限（读工作区以外的文件）", "拒绝"]]) {
              await until(() => sheetView().shown && sheetView().title === title);
              seen.push(sheetView());
              ui.click(answer, { within: sheet() });
            }
            await until(() => finished(1));
            let asked = false;
            const watch = setInterval(() => { if (sheetView().shown) asked = true; }, 20);
            ask("再查一次");
            await until(() => finished(2));
            clearInterval(watch);
            return { seen, asked };
        """) as? [String: Any]
        await harness.tearDown()

        let seen = result?["seen"] as? [[String: Any]] ?? []
        try #require(seen.count == 3)
        #expect(seen[0]["detail"] as? String == "/tmp/elsewhere/notes.md" && seen[0]["note"] as? String == "要写到工作区外", "\(seen[0])")
        #expect(seen[1]["detail"] as? String == "联网" && seen[1]["note"] as? String == "要联网查资料", "\(seen[1])")
        #expect(seen[2]["detail"] as? String == "读取 /Users/me/Pictures", "\(seen[2])")
        #expect(codex.response(0, 0)?["decision"] as? String == "accept")
        let granted = try #require(codex.response(0, 1))
        #expect(granted["scope"] as? String == "session")
        #expect((granted["permissions"] as? [String: Any])?["network"] as? [String: Bool] == ["enabled": true], "给的就是它要的，不带 null 的项：\(granted)")
        #expect((granted["permissions"] as? [String: Any])?.keys.sorted() == ["network"])
        let denied = try #require(codex.response(0, 2))
        #expect((denied["permissions"] as? [String: Any])?.isEmpty == true && denied["scope"] as? String == "turn", "拒绝：什么权限都不给：\(denied)")
        let again = try #require(codex.response(1, 0))
        #expect(again["scope"] as? String == "turn" && (again["permissions"] as? [String: Any])?["network"] != nil, "本次会话都允许过的权限下一轮直接给：\(again)")
        #expect(result?["asked"] as? Bool == false, "不再弹确认框")
        #expect(harness.pageErrors == [])
    }

    @Test("润色、改写选中的一段、预设命令在 Codex 下同样可用；app-server 半路崩了：这一轮以出错结束，写明它最后说的话")
    func commandsAndCrash() async throws {
        let codex = try FakeCodex(script: FakeCodex.reply("好"))
        try codex.script(FakeCodex.reply(#"["周末爬山真的会上瘾","第一次爬山就遇上云海","山顶的风好冷","爬山前要准备的五件事","我在山顶等日出"]"#), call: 3)
        try codex.script(FakeCodex.text(["写到一半"]) + [#"#stderr "codex: thread panicked: boom""#, "#exit 3"], call: 4)
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "周末去爬山\\n\\n山顶很冷。\\n" });
            await openAI();
            const polished = await mc.ai.polish();
            const rewritten = await mc.ai.send("", { context: { start: 0, end: 5 } });
            const titles = await mc.ai.preset("coverTitles");
            const crashed = await mc.ai.send("接着写");
            return {
              states: [polished.state, rewritten.state, titles.state],
              titles: titles.titles.map((option) => option.text),
              crashed: { state: crashed.state, error: crashed.error },
              end: (await ends()).at(-1),
              sendable: !ui.find("问 Codex").disabled,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["states"] as? [String] == ["done", "done", "done"])
        func input(_ call: Int) -> String {
            ((codex.params(call, "turn/start")?["input"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        #expect(input(0).contains("润色"), "润色的固定提示词：\(input(0))")
        #expect(input(1).contains("周末去爬山"), "改写带上选中的文字：\(input(1))")
        #expect((result?["titles"] as? [String])?.count == 5, "封面标题 5 选 1 从 Codex 的回复里读出来：\(result?["titles"] ?? "")")
        let crashed = result?["crashed"] as? [String: Any]
        #expect(crashed?["state"] as? String == "error")
        #expect((crashed?["error"] as? String ?? "").contains("codex: thread panicked: boom"), "\(crashed ?? [:])")
        #expect(result?["sendable"] as? Bool == true, "崩了之后还能接着发")
        #expect(harness.pageErrors == [])
    }

    @Test("Codex 自带的生图：生成中面板有进度；生成的图（存在它自己目录里的、只给了数据的）壳直接存成配图候选，不弹确认框、原图不动、不把几 MB 的原图推给页面；点了插进稿子；额度用完说清楚；说明里让它用自带的生图")
    func builtInImageGeneration() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-codex-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = folder.appendingPathComponent("ig_1.png")
        try AIToolsTests.writePNG(saved, width: 300, height: 400, red: 0.9, green: 0.5, blue: 0.2)
        let second = folder.appendingPathComponent("second.png")
        try AIToolsTests.writePNG(second, width: 200, height: 200, red: 0.2, green: 0.4, blue: 0.8)
        let savedData = try Data(contentsOf: saved)
        let base64 = try Data(contentsOf: second).base64EncodedString()
        let generating: (String) -> String = { id in
            FakeCodex.notify("item/started", ["item": ["type": "imageGeneration", "id": id, "status": "inProgress", "revisedPrompt": NSNull(), "result": "", "failure": NSNull()]])
        }
        let done: (String, [String: Any]) -> String = { id, fields in
            var item: [String: Any] = ["type": "imageGeneration", "id": id, "status": "completed", "revisedPrompt": NSNull(), "result": "", "failure": NSNull()]
            item.merge(fields) { $1 }
            return FakeCodex.notify("item/completed", ["item": item])
        }
        let codex = try FakeCodex(script: [
            generating("ig-1"), "#sleep 0.6",
            done("ig-1", ["revisedPrompt": "窗边的橘猫，水彩", "result": savedData.base64EncodedString(), "savedPath": saved.path]),
            generating("ig-2"),
            done("ig-2", ["result": base64]),
            generating("ig-3"),
            done("ig-3", ["status": "failed", "failure": ["type": "usageLimitExceeded", "limitId": "images", "resetsAt": NSNull()]]),
        ] + FakeCodex.reply("画好了"))
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const raw = [];
            window.addEventListener("mediacraft:native-ai", (event) => { if (event.detail.type === "lines") raw.push(...event.detail.lines); });
            await mc.drafts.create({ markdown: "# 猫\\n\\n正文" });
            await openAI();
            let sheetSeen = false;
            const watch = setInterval(() => { sheetSeen ||= sheetView().shown; }, 20);
            // 进度行只在生图的那一会儿在：看它什么时候出现（后台的 WKWebView 里定时器会被放慢，轮询可能错过）
            const rows = [];
            new MutationObserver(() => {
              const row = document.querySelector(".ai-generating");
              if (row) rows.push(row.textContent);
            }).observe(document.body, { childList: true, subtree: true, characterData: true });
            ask("画一张窗边的橘猫");
            await until(() => finished(1));
            clearInterval(watch);
            await until(() => document.querySelectorAll(".ai-candidate").length === 2);
            const history = await mc.ai.history();
            const images = history.messages.filter((message) => message.role === "candidates").flatMap((message) => message.images);
            document.querySelector(".ai-candidate").click();
            await until(async () => (await mc.ai.history()).messages.some((message) => message.images?.some((image) => image.inserted)));
            return {
              progress: rows[0] ?? "", sheetSeen, lines: lines(),
              captions: images.map((image) => image.caption ?? null),
              sizes: images.map((image) => [image.width, image.height]),
              markdown: (await mc.drafts.current()).markdown,
              media: (await mc.media.list()).length,
              rawSize: raw.reduce((sum, line) => sum + line.length, 0),
              rawHasImage: raw.some((line) => line.includes(key)),
            };
        """, arguments: ["key": String(base64.prefix(200))]) as? [String: Any]
        await harness.tearDown()

        #expect((result?["progress"] as? String ?? "").contains("Codex"), "生成中显示进度：\(result?["progress"] ?? "")")
        #expect(result?["sheetSeen"] as? Bool == false, "它自己画的图不用问")
        #expect(result?["sizes"] as? [[Int]] == [[300, 400], [200, 200]], "存在它目录里的与只给了数据的都进了配图候选：\(result?["sizes"] ?? "")")
        #expect((result?["captions"] as? [Any?])?.first as? String == "窗边的橘猫，水彩", "说明是它改写后的提示词")
        let lines = result?["lines"] as? [[String]] ?? []
        #expect(lines.contains { $0.first == "tool" && ($0.last ?? "").contains("生成图片没成功") && ($0.last ?? "").contains("额度") }, "\(lines)")
        #expect(result?["media"] as? Int == 1 && (result?["markdown"] as? String ?? "").contains("[[image:"), "点了一张才插进稿子")
        #expect(result?["rawHasImage"] as? Bool == false, "原图的数据不推给页面")
        #expect(FileManager.default.fileExists(atPath: saved.path) && (try? Data(contentsOf: saved)) == savedData, "它目录里的原图不动")
        let start = try #require(codex.params(0, "thread/start"))
        let instructions = start["developerInstructions"] as? String ?? ""
        #expect(instructions.contains("自带的生图") && !instructions.contains("generate_image"), "给 Codex 的说明：用它自带的生图")
        #expect(harness.pageErrors == [])
    }

    @Test("Codex 生图中点「停止这一轮」：停掉 app-server，这一轮记为已停止")
    func stopWhileGeneratingImage() async throws {
        let codex = try FakeCodex(script: [
            FakeCodex.notify("item/started", ["item": ["type": "imageGeneration", "id": "ig-1", "status": "inProgress", "revisedPrompt": NSNull(), "result": "", "failure": NSNull()]]),
            "#hang",
        ])
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "甲" });
            await openAI();
            ask("画张图");
            await until(() => document.querySelector(".ai-generating button"));
            const label = document.querySelector(".ai-generating button").textContent;
            document.querySelector(".ai-generating button").click();
            await until(() => finished(1));
            return { label, end: (await ends()).at(-1).state, row: Boolean(document.querySelector(".ai-generating")) };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["label"] as? String == "停止这一轮")
        #expect(result?["end"] as? String == "cancelled")
        #expect(result?["row"] as? Bool == false)
        #expect(harness.pageErrors == [])
    }

    @Test("两篇稿子同时用 Codex，审批请求的 id 都是 0（每轮都是新进程）：各答各的，不会答到另一篇；新稿子第一轮进行中存下的后端就是 Codex")
    func concurrentDraftsKeepApprovalsApart() async throws {
        let codex = try FakeCodex(script: FakeCodex.reply("好"))
        try codex.script([FakeCodex.commandApproval(0, "echo 甲")] + FakeCodex.reply("甲好了"), call: 1)
        try codex.script([FakeCodex.commandApproval(0, "echo 乙")] + FakeCodex.reply("乙好了"), call: 2)
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + StorageScripts.read + """
            const first = await mc.drafts.create({ markdown: "甲" });
            await openAI();
            ask("跑甲");
            await until(async () => (await mc.ai.history(first.id)).permissions.length === 1);
            const midTurn = (await until(async () => {
              const record = await readStore("drafts", first.id);
              return record?.ai?.messages?.length && record;
            })).ai.backend;
            const second = await mc.drafts.create({ markdown: "乙" });
            await until(() => ui.find("问 Codex") && !ui.find("问 Codex").disabled);
            ask("跑乙");
            await until(async () => (await mc.ai.history(second.id)).permissions.length === 1);
            const [a] = (await mc.ai.history(first.id)).permissions;
            const [b] = (await mc.ai.history(second.id)).permissions;
            await mc.ai.answer(b.id, "allow");
            await mc.ai.answer(a.id, "deny");
            await until(async () => !(await mc.ai.history(first.id)).running && !(await mc.ai.history(second.id)).running);
            return { ids: [a.id, b.id], midTurn, backends: [(await mc.ai.history(first.id)).backend, (await mc.ai.history(second.id)).backend] };
        """) as? [String: Any]
        await harness.tearDown()

        let ids = result?["ids"] as? [String] ?? []
        #expect(ids.count == 2 && ids[0] != ids[1] && ids.allSatisfy { $0.hasSuffix(":0") }, "确认框的 id 带上这一轮的 id：\(ids)")
        #expect(result?["midTurn"] as? String == "codex", "第一轮还没说完时存下的也是 Codex，不会被当成这版之前的 Claude Code 稿子")
        #expect(result?["backends"] as? [String] == ["codex", "codex"])
        try #require(codex.calls().count == 2)
        #expect(codex.response(0, 0)?["decision"] as? String == "decline", "甲的请求：拒绝")
        #expect(codex.response(1, 0)?["decision"] as? String == "accept", "乙的请求：允许，没有答到甲那边")
        #expect(harness.pageErrors == [])
    }

    @Test("Codex 的子线程也走这条连接：它的话不混进回复，它说完不算这一轮说完（壳不提前关 stdin）")
    func childThreadNotificationsAreIgnored() async throws {
        let codex = try FakeCodex(script: FakeCodex.text(["我先看看"], id: "m1") + [
            FakeCodex.notify("item/started", ["threadId": "child-thread", "turnId": "child-turn", "item": ["type": "agentMessage", "id": "c1", "text": ""]]),
            FakeCodex.notify("item/agentMessage/delta", ["threadId": "child-thread", "turnId": "child-turn", "itemId": "c1", "delta": "子线程的话"]),
            FakeCodex.notify("turn/completed", ["threadId": "child-thread", "turn": ["id": "child-turn", "status": "completed", "items": [], "error": NSNull()]]),
            "#sleep 0.3",
        ] + FakeCodex.text(["说完了"], id: "m2"))
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "甲" });
            await openAI();
            ask("分头看看");
            await until(() => finished(1));
            return { lines: lines(), ends: (await ends()).map((end) => end.state) };
        """) as? [String: Any]
        await harness.tearDown()

        let lines = result?["lines"] as? [[String]] ?? []
        #expect(lines.contains(["assistant", "说完了"]), "子线程说完之后这一轮还在：\(lines)")
        #expect(!lines.contains { ($0.last ?? "").contains("子线程的话") }, "\(lines)")
        #expect(result?["ends"] as? [String] == ["done"])
        #expect(harness.pageErrors == [])
    }

    @Test("壳只把认得的几种写进 Codex：线程的工作目录、沙箱、审批由壳定，续线程不要整段历史，这一轮只带文字；别的请求不写")
    func shellGuardsCodexRequests() async throws {
        let codex = try FakeCodex(script: FakeCodex.reply("好"))
        try codex.script(["#hang"], call: 2)
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const draft = await mc.drafts.create({ markdown: "甲" });
            await openAI();
            ask("你好");
            await until(() => finished(1));
            // 等进程起来、这一轮已经发出去（收到 turn/start 的回答）
            const answered = [];
            window.addEventListener("mediacraft:native-ai", (event) => {
              if (event.detail.type === "lines") answered.push(...event.detail.lines.map((line) => JSON.parse(line).id).filter(Boolean));
            });
            ask("接着来");
            await until(() => answered.includes("turn"));
            const turnId = (await mc.ai.history()).messages.at(-1).turn;
            const send = (message) => window.MediaCraftNative.ai.respond(draft.id, turnId, message).then((reply) => (reply.delivered ? "写了" : "没送到"), (error) => error.message);
            const exec = await send({ id: "x1", method: "command/exec", params: { command: ["ls"] } });
            const widen = await send({ id: "x2", method: "thread/start", params: {
              sandbox: "danger-full-access", approvalPolicy: "never", cwd: "/", config: { sandbox_mode: "danger-full-access" }, model: "gpt-fake-mini",
            } });
            const turn = await send({ id: "x3", method: "turn/start", params: {
              threadId: "t", cwd: "/", sandboxPolicy: { type: "dangerFullAccess" }, approvalPolicy: "never",
              input: [{ type: "text", text: "hi" }, { type: "localImage", path: "/etc/hosts" }],
            } });
            stopButton().click();
            await until(() => finished(2));
            return { exec, widen, turn, draftId: draft.id };
        """) as? [String: Any]
        await harness.tearDown()

        #expect((result?["exec"] as? String ?? "").contains("AI 回应的字段不对"), "别的请求不写：\(result?["exec"] ?? "")")
        #expect(result?["widen"] as? String == "写了" && result?["turn"] as? String == "写了")
        let draftId = result?["draftId"] as? String ?? "?"
        let workDirectory = harness.aiRoot.appendingPathComponent(draftId).path
        let lines = codex.stdin(1)
        let widened = try #require(lines.first { $0["id"] as? String == "x2" }?["params"] as? [String: Any])
        #expect(widened["sandbox"] as? String == "workspace-write" && widened["approvalPolicy"] as? String == "on-request", "\(widened)")
        #expect((widened["cwd"] as? String ?? "").hasSuffix(draftId) && widened["config"] == nil, "\(widened)")
        #expect(widened["model"] as? String == "gpt-fake-mini", "模型照给")
        let turned = try #require(lines.first { $0["id"] as? String == "x3" }?["params"] as? [String: Any])
        #expect(Set(turned.keys) == ["threadId", "input"], "这一轮不带覆盖：\(turned)")
        #expect((turned["input"] as? [[String: Any]])?.count == 1, "只带文字")
        #expect(!lines.contains { $0["id"] as? String == "x1" })
        let resume = try #require(codex.params(1, "thread/resume"))
        #expect(resume["excludeTurns"] as? Bool == true && resume["sandbox"] as? String == "workspace-write", "\(resume)")
        #expect((resume["cwd"] as? String ?? "").hasSuffix(draftId) && workDirectory.hasSuffix(draftId))
        #expect(harness.pageErrors == [])
    }

    @Test("这版之前「新会话」留下的模型（Claude 的 opus，没记后端）不带进 Codex：没记后端的模型算 Claude Code 的")
    func legacyModelStaysWithClaude() async throws {
        let codex = try FakeCodex(script: FakeCodex.reply("好"))
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + StorageScripts.read + """
            const draft = await mc.drafts.create({ markdown: "甲" });
            const record = await until(async () => await readStore("drafts", draft.id));
            await writeStore("drafts", [{ ...record, ai: { model: "opus", sessionId: null, resumable: false, messages: [] } }]);
            return true;
        """)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + StorageScripts.read + """
            await openAI();
            const before = await mc.ai.model();
            ask("你好");
            await until(() => finished(1));
            const id = (await mc.drafts.current()).id;
            const stored = await until(async () => {
              const record = await readStore("drafts", id);
              return record?.ai?.messages?.some((message) => message.role === "end") && record;
            });
            return { before, backend: stored.ai.backend, model: stored.ai.model ?? null };
        """) as? [String: Any]
        await harness.tearDown()

        let before = result?["before"] as? [String: Any]
        #expect(before?["backend"] as? String == "codex" && before?["model"] is NSNull, "\(before ?? [:])")
        let start = try #require(codex.params(0, "thread/start"))
        #expect(start["model"] == nil, "没把 Claude 的 opus 交给 Codex：\(start["model"] ?? "")")
        #expect(result?["backend"] as? String == "codex" && result?["model"] is NSNull, "\(result ?? [:])")
        #expect(harness.pageErrors == [])
    }
}
