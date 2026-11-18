import Foundation
import Testing

/// 说 ACP 的 AI 后端（OpenCode、Oh My Pi、Kimi Code：`<程序> acp`，stdio 上的 JSON-RPC）：开会话、说明书随第一句给、流式回复、
/// 改稿进修改对比、续会话；权限请求的三种回答与「本次会话都允许」；模型与推理强度来自它自己报的选单；
/// 停止、续不上、出错、没登录、找不到时的指引；壳只放行认得的几种请求。
/// 程序换成假的可执行文件（Fixtures/ai/fake-acp），它记下每次调用收到的每一行与页面的回答。
@MainActor
struct AIACPTests {
    /// name：这个后端在界面上的名字（输入框叫「问 OpenCode」）
    static func helpers(_ name: String) -> String {
        AIToolsTests.helpers + """
            window.openAI = async () => {
              ui.click("AI 助手");
              await until(() => ui.find("问 \(name)") && !ui.find("问 \(name)").disabled);
            };
            window.ask = (text) => {
              const input = ui.find("问 \(name)");
              input.value = text;
              input.dispatchEvent(new Event("input", { bubbles: true }));
              input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
            };
            window.sendButton = () => ui.find("发送", { within: "对 \(name) 说" });
            window.stopButton = () => ui.find("停止", { within: "对 \(name) 说" });
            window.messages = async () => (await mc.ai.history()).messages.map(({ role, text, state, error, decision }) => ({ role, text, state, error, decision }));
        """
    }

    /// 路径去掉 /private 前缀再比（临时目录在 /var 与 /private/var 下是同一个）
    static func canonical(_ path: Any?) -> String {
        let text = path as? String ?? ""
        return text.hasPrefix("/private/") ? String(text.dropFirst("/private".count)) : text
    }

    @Test("OpenCode：第一轮 acp 开会话（工作目录是工作副本、只挂 App 的工具这一个 MCP 服务、运行命令要先问），说明书随第一句给（讲了 App 的工具怎么叫），流式回复，改稿进修改对比；下一轮续上同一个会话、不再带说明书；工具调用的大块输出不推给页面")
    func firstTurnOpensSessionAndResumes() async throws {
        let agent = try FakeACP(script: FakeACP.text(["把甲", "改好了"])
            + FakeACP.tool("t1", kind: "read", title: "read", input: ["filePath": "{{CWD}}/draft.md"])
            + [#"#write ["draft.md", "乙\n"]"#]
            + FakeACP.tool("t2", kind: "edit", title: "edit", input: ["filePath": "{{CWD}}/draft.md", "oldString": "甲", "newString": "乙"])
            + FakeACP.reply("好了"))
        try agent.script(FakeACP.reply("又一句"), call: 2)
        defer { agent.remove() }
        let harness = ShellHarness(terminalPath: [agent.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers("OpenCode") + """
            await mc.drafts.create({ markdown: "甲\\n" });
            await mc.ai.setBackend("opencode");
            await openAI();
            let longest = 0;
            window.addEventListener("mediacraft:native-ai", (event) => {
              for (const line of event.detail.lines ?? []) longest = Math.max(longest, line.length);
            });
            ask("把甲改成乙");
            await until(async () => (await mc.ai.review.get()).open);
            await until(() => finished(1));
            const first = { lines: lines(), history: await mc.ai.history(), status: statusLine() };
            await mc.ai.review.acceptAll();
            await until(async () => !(await mc.ai.review.get()).open);
            ask("再来一句");
            await until(() => finished(2));
            return {
              first: { lines: first.lines, backend: first.history.backend, locked: first.history.locked, sessionId: first.history.sessionId,
                usedModel: first.history.usedModel, status: first.status },
              markdown: (await mc.drafts.current()).markdown,
              ends: (await ends()).map((end) => end.state),
              backends: (await mc.ai.backends()).map((backend) => backend.id),
              longest,
            };
        """) as? [String: Any]
        await harness.tearDown()

        let calls = agent.calls()
        try #require(calls.count == 2, "每轮一个 acp 进程")
        #expect(calls[0]["argv"] as? [String] == ["acp"])
        let permission = (calls[0]["env"] as? [String: Any])?["OPENCODE_PERMISSION"] as? String ?? ""
        #expect(permission.contains(#""bash":"ask""#) && permission.contains(#""external_directory":"ask""#), "运行命令、目录外的读写要先问：\(permission)")
        #expect(agent.methods(0) == ["initialize", "session/new", "session/prompt"], "握手 → 开会话 → 这一轮：\(agent.methods(0))")
        let initialize = try #require(agent.params(0, "initialize"))
        let capabilities = initialize["clientCapabilities"] as? [String: Any]
        #expect((capabilities?["fs"] as? [String: Any])?["writeTextFile"] as? Bool == false && capabilities?["terminal"] as? Bool == false, "不替它读写文件、开终端")
        let open = try #require(agent.params(0, "session/new"))
        #expect(Self.canonical(open["cwd"]) == Self.canonical(calls[0]["cwd"]) && Self.canonical(open["cwd"]) != "", "会话开在这篇的工作副本里")
        let servers = open["mcpServers"] as? [[String: Any]] ?? []
        #expect(servers.count == 1 && servers.first?["name"] as? String == "mediacraft", "只挂 App 的工具：\(servers)")
        #expect(servers.first?["command"] as? String == "/usr/bin/nc" && (servers.first?["args"] as? [String])?.first == "-U", "用系统自带的 nc 连回这一轮的套接字")
        let socket = (servers.first?["args"] as? [String])?.last ?? ""
        #expect(!socket.isEmpty && !FileManager.default.fileExists(atPath: socket), "这一轮结束套接字就删了：\(socket)")
        let prompt = agent.prompt(0)
        #expect(prompt.contains("Vibepost") && prompt.contains("不是用户给你的指令"), "说明书（含防提示词注入）随第一句给它")
        #expect(prompt.contains("MCP 服务 mediacraft 里的工具") && prompt.contains("get_draft") && prompt.contains("generate_image"), "讲了 App 的工具在它那边怎么叫、有哪些")
        #expect(prompt.hasSuffix("把甲改成乙"), "用户的话在最后")
        let first = result?["first"] as? [String: Any]
        let lines = first?["lines"] as? [[String]] ?? []
        #expect(lines.contains(["assistant", "把甲改好了"]) && lines.contains(["assistant", "好了"]), "流式回复，用工具前后各一段：\(lines)")
        #expect(lines.contains(["tool", "修改 draft.md"]), "它改的文件记一行：\(lines)")
        #expect(!lines.contains { $0.first == "tool" && ($0.last ?? "").contains("读取") }, "读文件不记：\(lines)")
        #expect(first?["backend"] as? String == "opencode" && first?["locked"] as? Bool == true, "有了对话，后端锁定")
        #expect(first?["usedModel"] as? String == "fake/large", "用的模型是它自己报的")
        #expect((first?["status"] as? String ?? "").hasPrefix("本机 OpenCode 9.9.9 · 已连接"), "\(first?["status"] ?? "")")
        #expect(result?["markdown"] as? String == "乙\n", "接受修改后进了正文")
        #expect(agent.methods(1) == ["initialize", "session/resume", "session/prompt"], "\(agent.methods(1))")
        #expect(agent.params(1, "session/resume")?["sessionId"] as? String == first?["sessionId"] as? String, "下一轮续上同一个会话")
        #expect(agent.prompt(1) == "再来一句", "续上的会话不再带说明书：\(agent.prompt(1).prefix(80))")
        #expect(result?["ends"] as? [String] == ["done", "done"])
        #expect(result?["backends"] as? [String] == ["claude", "codex", "opencode", "omp", "kimi"])
        #expect((result?["longest"] as? Int ?? .max) < 3000, "工具调用的整份输出不推给页面：\(result?["longest"] ?? "")")
        #expect(harness.pageErrors == [])
    }

    @Test("App 的工具经 MCP 挂给它：握手、列工具、调工具都由页面里的工具回答（和 Claude Code、Codex 用的是同一套）；换主题马上生效、会话里记一个能撤销的动作，它自己报的这次工具调用不再记一行、要权限时直接放行；通知不回答")
    func appToolsOverMCP() async throws {
        let agent = try FakeACP(script: [
            FakeACP.mcp(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any], "clientInfo": ["name": "fake", "version": "1"]]),
            FakeACP.mcp(nil, "notifications/initialized"),
            FakeACP.mcp(2, "tools/list"),
            FakeACP.update("tool_call", ["toolCallId": "m1", "title": "mediacraft_set_theme", "kind": "other", "status": "pending", "rawInput": [:] as [String: Any]]),
            FakeACP.permission(40, kind: "other", title: "mediacraft_set_theme", input: ["theme": "纯黑"], callId: "m1"),
            FakeACP.appTool(3, "set_theme", ["theme": "纯黑"]),
            FakeACP.update("tool_call_update", ["toolCallId": "m1", "status": "completed"]),
            FakeACP.appTool(4, "get_pages"),
            FakeACP.appTool(5, "no_such_tool"),
        ] + FakeACP.reply("换好了"))
        defer { agent.remove() }
        let harness = ShellHarness(terminalPath: [agent.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers("OpenCode") + """
            await mc.drafts.create({ markdown: "# 周末\\n\\n第一段文字。\\n", theme: "notes" });
            await mc.ai.setBackend("opencode");
            await openAI();
            ask("换个深色的主题");
            await until(() => finished(1));
            const after = { theme: (await mc.drafts.current()).theme, lines: lines(), actions: await actions(), asked: sheetView().shown };
            ui.click("撤销：换成主题「纯黑」");
            await until(async () => (await mc.drafts.current()).theme === "notes");
            return { ...after, ends: (await ends()).map((end) => end.state) };
        """) as? [String: Any]
        await harness.tearDown()

        let replies = agent.mcpReplies(0)
        try #require(replies.count == 5, "五条有 id 的消息各有一个回答，通知没有：\(replies)")
        let server = (replies[0]["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        #expect(replies[0]["id"] as? Int == 1 && server?["name"] as? String == "mediacraft", "握手：\(replies[0])")
        let tools = ((replies[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        for name in ["get_draft", "get_pages", "view_page", "set_theme", "set_style", "move_image", "propose_images", "generate_image", "save_writing_manual"] {
            #expect(tools.contains(name), "工具清单里有 \(name)")
        }
        let text = { (reply: [String: Any]) in
            ((reply["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        #expect(replies[2]["id"] as? Int == 3 && text(replies[2]).contains("纯黑"), "换主题的结果：\(replies[2])")
        #expect(text(replies[3]).contains("第 1 页") || text(replies[3]).contains("1"), "get_pages 看得到页面：\(replies[3])")
        #expect((replies[4]["result"] as? [String: Any])?["isError"] as? Bool == true || replies[4]["error"] != nil, "没有的工具报错：\(replies[4])")

        #expect(result?["theme"] as? String == "ink", "主题真的换了")
        let actions = result?["actions"] as? [[String: Any]] ?? []
        #expect(actions.map { $0["text"] as? String } == ["换成主题「纯黑」"], "会话里记一个能撤销的动作：\(actions)")
        let lines = result?["lines"] as? [[String]] ?? []
        #expect(!lines.contains { $0.last?.contains("mediacraft_set_theme") == true }, "它自己报的这次工具调用不再记一行：\(lines)")
        #expect(result?["asked"] as? Bool == false && agent.chosen(0, 40) == "once", "App 的工具要权限时直接放行，不弹确认框")
        #expect(result?["ends"] as? [String] == ["done"])
        #expect(harness.pageErrors == [])
    }

    @Test("权限：运行命令、改目录外的文件弹确认框（OpenCode 想运行命令），允许 / 本次会话都允许 / 拒绝 回它给的选项（都允许也只答这一次，规则由 App 记着）；放行过的同一条命令下一轮不再问；拒绝了的不记「运行」")
    func permissionsMapToOptions() async throws {
        let agent = try FakeACP(script:
            [FakeACP.commandPermission(0, "ls -la")] + FakeACP.tool("call-0", kind: "execute", title: "ls -la", input: ["command": "ls -la"])
            + [FakeACP.commandPermission(1, "npm test")] + FakeACP.tool("call-1", kind: "execute", title: "npm test", input: ["command": "npm test"], status: "failed")
            + [FakeACP.commandPermission(2, "rm -rf build")] + FakeACP.tool("call-2", kind: "execute", title: "rm -rf build", input: ["command": "rm -rf build"], status: "failed")
            + [FakeACP.permission(3, kind: "edit", title: "edit", input: ["filePath": "/etc/hosts"])]
            + FakeACP.reply("跑完了"))
        try agent.script([FakeACP.commandPermission(0, "npm test")] + FakeACP.reply("又跑了一次"), call: 2)
        defer { agent.remove() }
        let harness = ShellHarness(terminalPath: [agent.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers("OpenCode") + """
            await mc.drafts.create({ markdown: "甲" });
            await mc.ai.setBackend("opencode");
            await openAI();
            ask("跑一下测试");
            const seen = [];
            for (const [detail, answer] of [["ls -la", "允许"], ["npm test", "本次会话都允许"], ["rm -rf build", "拒绝"], ["/etc/hosts", "允许"]]) {
              await until(() => sheetView().shown && sheetView().detail === detail);
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
        #expect(seen.first?["title"] as? String == "OpenCode 想运行命令")
        #expect(seen.last?["title"] as? String == "OpenCode 想修改文件")
        #expect(agent.chosen(0, 0) == "once")
        #expect(agent.chosen(0, 1) == "once", "「本次会话都允许」对它也只答这一次（它的「总是允许」范围比这一条命令宽）")
        #expect(agent.chosen(0, 2) == "reject")
        #expect(agent.chosen(0, 3) == "once")
        #expect(agent.chosen(1, 0) == "once", "放行过的命令下一轮直接放行")
        #expect(result?["asked"] as? Bool == false, "不再弹确认框")
        let decisions = result?["decisions"] as? [[String]] ?? []
        #expect(decisions == [["allow", "运行命令：ls -la"], ["session", "运行命令：npm test"], ["deny", "运行命令：rm -rf build"], ["allow", "修改文件：/etc/hosts"]], "\(decisions)")
        #expect(result?["tools"] as? [String] == ["运行 ls -la", "运行没成功：npm test"], "拒绝了的命令不再记「运行」：\(result?["tools"] ?? "")")
        #expect(harness.pageErrors == [])
    }

    @Test("Oh My Pi：模型与推理强度来自它开会话时报的选单（名字不合规的不列），没选过时跟随它自己的；选了就在发这一轮之前换好；它要别的（读文件）回答不支持；壳只放行认得的请求、工作目录与 MCP 服务由壳定")
    func modelsEffortAndShellGuards() async throws {
        let agent = try FakeACP(program: "omp", script: [FakeACP.request(7, "fs/read_text_file", ["sessionId": "{{SESSION}}", "path": "/etc/passwd"])] + FakeACP.reply("好"))
        try agent.script(FakeACP.reply("想一想") + [FakeACP.commandPermission(9, "date")] + FakeACP.reply("好"), call: 2)
        defer { agent.remove() }
        let harness = ShellHarness(terminalPath: [agent.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers("Oh My Pi") + """
            await mc.drafts.create({ markdown: "甲" });
            await mc.ai.setBackend("omp");
            await openAI();
            const models = await mc.ai.models("omp");
            const untouched = await mc.ai.effort();
            await mc.ai.setModel("fake/mini");
            await mc.ai.setEffort("high");
            ask("你好");
            await until(() => finished(1));
            const usedModel = (await mc.ai.history()).usedModel;
            ask("再来");
            await until(() => sheetView().shown);
            const { id: draftId } = await mc.drafts.current();
            const turnId = (await mc.ai.history()).messages.at(-1).turn;
            const refused = await MediaCraftNative.ai.respond(draftId, turnId, { jsonrpc: "2.0", id: 50, method: "session/delete", params: { sessionId: "x" } })
              .then(() => "写进去了", (error) => error.message);
            await MediaCraftNative.ai.respond(draftId, turnId, { jsonrpc: "2.0", id: 51, method: "session/new",
              params: { cwd: "/", mcpServers: [{ name: "evil", command: "/bin/sh", args: [], env: [] }] } });
            ui.click("允许", { within: sheet() });
            await until(() => finished(2));
            return { models, untouched, usedModel, refused, ends: (await ends()).map((end) => end.state) };
        """) as? [String: Any]
        await harness.tearDown()

        let models = result?["models"] as? [[String: Any]] ?? []
        #expect(models.compactMap { $0["id"] as? String } == ["fake/large", "fake/mini"], "名字里有空格的不列：\(models)")
        #expect(models.first?["isDefault"] as? Bool == true && models.first?["name"] as? String == "Fake Large")
        let untouched = result?["untouched"] as? [String: Any]
        #expect(untouched?["efforts"] as? [String] == ["off", "low", "high"], "档位是它报的：\(untouched ?? [:])")
        #expect(untouched?["effort"] as? String == "low", "没选过时跟随它自己的，不是 medium")
        #expect(agent.calls().count == 2, "问模型的那次（只开会话）不算调用")
        #expect(agent.methods(0) == ["initialize", "session/new", "session/set_config_option", "session/set_config_option", "session/prompt"], "\(agent.methods(0))")
        let model = agent.params(0, "session/set_config_option")
        #expect(model?["configId"] as? String == "model" && model?["value"] as? String == "fake/mini")
        let effort = agent.params(0, "session/set_config_option", nth: 1)
        #expect(effort?["configId"] as? String == "effort" && effort?["value"] as? String == "high")
        #expect(result?["usedModel"] as? String == "fake/mini")
        let unsupported = (agent.response(0, 7)?["error"] as? [String: Any])?["message"] as? String ?? ""
        #expect(unsupported.contains("不支持 fs/read_text_file"), "它要读文件：回答不支持（握手时说了不提供）\(agent.response(0, 7) ?? [:])")
        #expect(agent.methods(1).prefix(3) == ["initialize", "session/resume", "session/prompt"], "续上的会话已经是选好的模型，不用再换：\(agent.methods(1))")
        #expect((result?["refused"] as? String ?? "") != "写进去了" && !agent.methods(1).contains("session/delete"), "不认得的请求不写：\(result?["refused"] ?? "")")
        let smuggled = try #require(agent.params(1, "session/new"))
        #expect(Self.canonical(smuggled["cwd"]) == Self.canonical(agent.calls()[1]["cwd"]) && Self.canonical(smuggled["cwd"]) != "", "工作目录由壳定")
        #expect((smuggled["mcpServers"] as? [[String: Any]])?.map { $0["name"] as? String } == ["mediacraft"], "页面给的 MCP 服务不带进去，只有壳挂的那一个")
        #expect(result?["ends"] as? [String] == ["done", "done"])
        #expect(harness.pageErrors == [])
    }

    @Test("停止记为「已停止」；续不上：这一轮报错说明，下一轮开新会话；接口出错、到了长度上限：以出错结束、写明原因；只有 session/load 的 Agent：重放的历史不进对话；没登录、找不到程序时说清楚怎么办")
    func stopLostSessionErrorsAndGuides() async throws {
        let agent = try FakeACP(program: "kimi")
        try agent.script(FakeACP.text(["想一想"]) + ["#hang"], call: 1)
        try agent.script([#"#error {"code": -32603, "message": "Internal error: Insufficient Balance"}"#], call: 5)
        try agent.script(FakeACP.reply("写到一半") + [#"#stop "max_tokens""#], call: 6)
        defer { agent.remove() }
        let harness = ShellHarness(terminalPath: [agent.directory], onboarding: false)
        try await harness.load()
        let stopped = try await harness.evaluate(Self.helpers("Kimi Code") + """
            await mc.drafts.create({ markdown: "甲" });
            await mc.ai.setBackend("kimi");
            await openAI();
            ask("想很久");
            await until(() => lines().some(([kind, text]) => kind === "assistant" && text === "想一想"));
            stopButton().click();
            await until(() => finished(1));
            ask("接着来");
            await until(() => finished(2));
            return { states: (await ends()).map((end) => end.state), sessionId: (await mc.ai.history()).sessionId };
        """) as? [String: Any]
        agent.resumeError("boom")
        let lost = try await harness.evaluate(Self.helpers("Kimi Code") + """
            ask("续一下");
            await until(() => finished(3));
            const end = (await ends()).at(-1);
            const after = (await mc.ai.history()).sessionId;
            return { state: end.state, error: end.error, after };
        """) as? [String: Any]
        agent.resumeError(nil)
        let failures = try await harness.evaluate(Self.helpers("Kimi Code") + """
            const errors = [];
            for (const [index, text] of [[4, "重新开始吧"], [5, "余额不够"], [6, "写很长"]]) {
              ask(text);
              await until(() => finished(index));
              const end = (await ends()).at(-1);
              errors.push({ state: end.state, error: end.error ?? "" });
            }
            return errors;
        """) as? [[String: Any]]
        agent.flag("no-resume")
        let loaded = try await harness.evaluate(Self.helpers("Kimi Code") + """
            ask("还记得吗");
            await until(() => finished(7));
            return { state: (await ends()).at(-1).state, replayed: lines().some(([, text]) => text.includes("重放的历史")) };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(stopped?["states"] as? [String] == ["cancelled", "done"], "\(stopped ?? [:])")
        let calls = agent.calls()
        try #require(calls.count == 7)
        #expect((calls[0]["signals"] as? [Int] ?? []).contains(2), "停止先发 SIGINT")
        #expect(agent.params(1, "session/resume")?["sessionId"] as? String == stopped?["sessionId"] as? String, "停止过的会话下一轮照样续")
        #expect(lost?["state"] as? String == "error")
        #expect((lost?["error"] as? String ?? "").contains("续不上") && (lost?["error"] as? String ?? "").contains("boom"), "\(lost ?? [:])")
        #expect(lost?["after"] is NSNull || lost?["after"] == nil, "续不上之后不再留着那个会话：\(lost ?? [:])")
        #expect(agent.methods(3) == ["initialize", "session/new", "session/prompt"], "下一轮开新会话：\(agent.methods(3))")
        #expect(agent.prompt(3).contains("Vibepost") && agent.prompt(3).hasSuffix("重新开始吧"), "新会话又带上说明书")
        #expect(failures?[0]["state"] as? String == "done")
        #expect(failures?[1]["state"] as? String == "error" && (failures?[1]["error"] as? String ?? "").contains("Insufficient Balance"), "\(failures ?? [])")
        #expect(failures?[2]["state"] as? String == "error" && (failures?[2]["error"] as? String ?? "").contains("长度上限"), "\(failures ?? [])")
        #expect(agent.methods(6) == ["initialize", "session/load", "session/prompt"], "没有 session/resume 时用 session/load：\(agent.methods(6))")
        #expect(loaded?["state"] as? String == "done" && loaded?["replayed"] as? Bool == false, "重放的历史不进对话：\(loaded ?? [:])")

        let loggedOut = try FakeACP(program: "kimi")
        loggedOut.flag("logged-out")
        defer { loggedOut.remove() }
        let second = ShellHarness(terminalPath: [loggedOut.directory], onboarding: false)
        try await second.load()
        let guides = try await second.evaluate(Self.helpers("Kimi Code") + """
            await mc.drafts.create({ markdown: "甲" });
            await mc.ai.setBackend("kimi");
            await openAI();
            ask("你好");
            await until(() => finished(1));
            const login = (await ends()).at(-1);
            await mc.ai.newSession();
            await mc.ai.setBackend("omp");
            await until(() => !document.getElementById("aiGuide").hidden);
            return {
              login: { state: login.state, error: login.error },
              title: document.getElementById("aiGuideTitle").textContent,
              steps: document.getElementById("aiGuideSteps").innerText,
              input: ui.find("问 Oh My Pi").disabled,
            };
        """) as? [String: Any]
        await second.tearDown()

        let login = guides?["login"] as? [String: Any]
        #expect(login?["state"] as? String == "error")
        #expect((login?["error"] as? String ?? "").contains("Kimi Code 还没有登录") && (login?["error"] as? String ?? "").contains("kimi auth login"), "照它自己说的登录办法：\(login ?? [:])")
        #expect(guides?["title"] as? String == "没有找到本机 Oh My Pi")
        #expect((guides?["steps"] as? String ?? "").contains("bun install -g @oh-my-pi/pi-coding-agent") && (guides?["steps"] as? String ?? "").contains("which omp"), "\(guides?["steps"] ?? "")")
        #expect(guides?["input"] as? Bool == true, "找不到时输入框不可用")
        #expect(harness.pageErrors == [] && second.pageErrors == [])
    }
}
