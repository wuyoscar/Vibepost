import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// AI 会话（三）：权限与工具。claude 经控制通道问「要不要允许」（App 里弹确认框，回答写回它的 stdin），
/// 调用 App 自己的工具（SDK MCP 服务 mediacraft，在页面里经 window.mediacraft 执行，每个动作列在会话里、可以撤销），
/// 配图先作为候选，用户点了才插入。claude 换成假的可执行文件，它按脚本发控制请求、记下页面的回答。
@MainActor
struct AIToolsTests {
    static let helpers = AISessionTests.helpers + """
        window.sheet = () => document.getElementById("aiPermission");
        window.sheetView = () => ({
          shown: !sheet().hidden,
          title: document.getElementById("aiPermissionTitle").textContent,
          detail: document.getElementById("aiPermissionDetail").hidden ? "" : document.getElementById("aiPermissionDetail").textContent,
          note: document.getElementById("aiPermissionNote").hidden ? "" : document.getElementById("aiPermissionNote").textContent,
          queue: document.getElementById("aiPermissionQueue").hidden ? "" : document.getElementById("aiPermissionQueue").textContent,
        });
        // 对话里看得见的每一条：[种类, 文字]
        window.lines = () => [...log().children].map((node) => [
          ["user", "assistant", "tool", "end", "typing", "action", "permission-line", "candidates"].find((kind) => node.classList.contains(`ai-${kind}`)),
          node.innerText.replace(/\\s+/g, " ").trim(),
        ]);
        window.actions = async () => (await mc.ai.history()).messages.filter((message) => message.role === "action")
          .map(({ text, undone, undoable }) => ({ text, undone: Boolean(undone), undoable }));
        window.pngFile = (name, width, height, color) => new Promise((resolve) => {
          const canvas = document.createElement("canvas");
          canvas.width = width;
          canvas.height = height;
          const context = canvas.getContext("2d");
          context.fillStyle = color;
          context.fillRect(0, 0, width, height);
          canvas.toBlob((blob) => resolve(new File([blob], name, { type: "image/png" })), "image/png");
        });
        window.shape = async () => {
          let text = (await mc.drafts.current()).markdown;
          for (const image of await mc.media.list()) text = text.split(image.id).join(image.name);
          return text;
        };
    """

    /// 页面对这个控制请求的回答里的 response（allow / deny 或 mcp_response）
    private static func answer(_ fake: FakeClaude, call: Int = 0, _ requestId: String) -> [String: Any]? {
        fake.response(call, requestId)?["response"] as? [String: Any]
    }

    /// 工具调用的结果（MCP tools/call 的 result）
    private static func toolResult(_ fake: FakeClaude, call: Int = 0, _ requestId: String) -> [String: Any]? {
        (answer(fake, call: call, requestId)?["mcp_response"] as? [String: Any])?["result"] as? [String: Any]
    }

    private static func toolText(_ fake: FakeClaude, call: Int = 0, _ requestId: String) -> String {
        (toolResult(fake, call: call, requestId)?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func tail(_ text: String) -> [String] {
        [StreamJSON.textStart(), StreamJSON.textDelta(text), StreamJSON.assistantText(text), StreamJSON.result(text)]
    }

    @Test("命令行：权限确认交给 App（--permission-prompt-tool stdio），App 的工具挂成 SDK MCP 服务 mediacraft 并直接允许；stdin 先 initialize 再说话，握手与工具清单由页面回答")
    func commandLineAndHandshake() async throws {
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(),
            StreamJSON.mcp("m1", method: "initialize", params: ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "9.9.9"]], id: 0),
            StreamJSON.control("m2", ["subtype": "mcp_message", "server_name": "mediacraft", "message": ["jsonrpc": "2.0", "method": "notifications/initialized"]]),
            StreamJSON.mcp("m3", method: "tools/list"),
            StreamJSON.control("m4", ["subtype": "mcp_message", "server_name": "别的服务", "message": ["jsonrpc": "2.0", "id": 5, "method": "tools/list"]]),
            StreamJSON.control("m5", ["subtype": "hook_callback", "callback_id": "hook-1", "input": [:]]),
        ] + Self.tail("好"))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            return await mc.ai.send("你好");
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["state"] as? String == "done")
        let call = try #require(fake.calls().first)
        #expect(FakeClaude.option("--permission-prompt-tool", in: call) == "stdio")
        #expect(FakeClaude.option("--permission-mode", in: call) == "acceptEdits", "draft.md 仍然自动接受修改")
        #expect(FakeClaude.option("--setting-sources", in: call) == "user", "工作副本里的项目级设置（hook）不生效")
        #expect(FakeClaude.option("--allowedTools", in: call) == "mcp__mediacraft", "App 自己的工具直接允许")
        let config = try JSONSerialization.jsonObject(with: Data((FakeClaude.option("--mcp-config", in: call) ?? "").utf8)) as? [String: Any]
        let server = (config?["mcpServers"] as? [String: Any])?["mediacraft"] as? [String: Any]
        #expect(server?["type"] as? String == "sdk")
        #expect(server?["name"] as? String == "mediacraft")
        #expect(server?["alwaysLoad"] as? Bool == true)

        let stdin = fake.stdin(0)
        #expect(stdin.first?["type"] as? String == "control_request")
        let initialize = stdin.first?["request"] as? [String: Any]
        #expect(initialize?["subtype"] as? String == "initialize")
        #expect(initialize?["sdkMcpServers"] as? [String] == ["mediacraft"])
        #expect(stdin.dropFirst().first?["type"] as? String == "user", "登记完工具服务再说话")

        let handshake = (Self.answer(fake, "m1")?["mcp_response"] as? [String: Any])?["result"] as? [String: Any]
        #expect((handshake?["serverInfo"] as? [String: Any])?["name"] as? String == "mediacraft")
        #expect(handshake?["protocolVersion"] as? String == "2025-11-25")
        #expect((handshake?["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(fake.response(0, "m2")?["subtype"] as? String == "success", "通知也回一个空结果")
        let tools = ((Self.answer(fake, "m3")?["mcp_response"] as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        #expect(tools.map { $0["name"] as? String ?? "" } == [
            "get_draft", "get_pages", "view_page", "set_theme", "set_style", "set_mode", "insert_page_break", "remove_page_break",
            "move_section", "set_card_css", "restyle_block", "insert_section", "move_image", "insert_image", "resize_image", "crop_image", "propose_images", "generate_image",
            "save_writing_manual", "list_templates", "create_draft_from_template",
        ])
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" && !($0["description"] as? String ?? "").isEmpty })
        #expect((Self.answer(fake, "m4")?["mcp_response"] as? [String: Any])?["error"] != nil, "别的服务的消息回错误")
        #expect(fake.response(0, "m5")?["subtype"] as? String == "error", "不支持的控制请求回错误，不会卡住")
        #expect(harness.pageErrors == [])
    }

    @Test("需要授权的操作弹出确认框：允许 / 拒绝 / 本次会话都允许按 request_id 写回 stdin，拒绝带原因；本次会话都允许按 claude 建议的范围放行（这一轮给 updatedPermissions，之后每轮经命令行带上）")
    func permissionsRoundTrip() async throws {
        let listFiles: [String: Any] = ["command": "ls -la", "description": "列出文件"]
        let fetch: [String: Any] = ["url": "https://example.com", "prompt": "看看写了什么"]
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(),
            StreamJSON.toolUse("Bash", listFiles),
            StreamJSON.permission("p1", tool: "Bash", input: listFiles),
            StreamJSON.toolUse("WebFetch", fetch),
            StreamJSON.permission("p2", tool: "WebFetch", input: fetch),
            StreamJSON.permission("p3", tool: "Bash", input: ["command": "python3 -c 1"]),
            StreamJSON.permission("p4", tool: "Bash", input: ["command": "echo 自动"], wait: false),
            StreamJSON.permission("p5", tool: "Bash", input: ["command": "echo 第二条"], wait: false),
            "#await p4", "#await p5",
        ] + Self.tail("查好了"))
        try fake.script([
            StreamJSON.initEvent(),
            StreamJSON.permission("p6", tool: "Write", input: ["file_path": "/tmp/外面.txt", "content": "hi"], extra: ["blocked_path": "/tmp/外面.txt"]),
        ] + Self.tail("写好了"), call: 2)
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            ask("帮我查点东西");
            await until(() => sheetView().shown);
            const first = { ...sheetView(), line: statusLine(), typing: Boolean(document.querySelector(".ai-typing")), pending: (await mc.ai.history()).permissions.map((request) => request.id) };
            ui.click("允许", { within: sheet() });
            await until(() => sheetView().title === "Claude 想打开网页");
            const second = sheetView();
            ui.click("拒绝", { within: sheet() });
            await until(() => sheetView().detail === "python3 -c 1");
            const scope = document.getElementById("aiAllowSessionBtn").title;
            ui.click("本次会话都允许", { within: sheet() });
            await until(() => sheetView().detail === "echo 自动");
            const queued = sheetView().queue;
            // 双击「允许」：第一下答完，确认框换成下一个请求；第二下（detail 2）不会批准这个还没看清的请求
            const allow = document.getElementById("aiAllowBtn");
            allow.dispatchEvent(new MouseEvent("click", { bubbles: true, detail: 1 }));
            await until(() => sheetView().detail === "echo 第二条");
            allow.dispatchEvent(new MouseEvent("click", { bubbles: true, detail: 2 }));
            await wait(300);
            const stillAsking = sheetView().detail === "echo 第二条";
            ui.click("拒绝", { within: sheet() });
            await until(() => finished(1));
            const turn1 = { lines: lines(), hidden: sheet().hidden };
            ask("再写个文件");
            await until(() => sheetView().title === "Claude 想写入文件");
            const third = sheetView();
            ui.click("允许", { within: sheet() });
            await until(() => finished(2));
            const stale = await mc.ai.answer("p6", "allow").then(() => "answered", (error) => error.message);
            return { first, second, scope, queued, stillAsking, turn1, third, stale, hidden: sheet().hidden };
        """) as? [String: Any]
        await harness.tearDown()

        let first = result?["first"] as? [String: Any]
        #expect(first?["title"] as? String == "Claude 想运行命令")
        #expect(first?["detail"] as? String == "ls -la")
        #expect(first?["note"] as? String == "列出文件", "带上 Claude 自己的说明")
        #expect(first?["line"] as? String == "Claude 在等你确认…（claude-opus-4-6）")
        #expect(first?["typing"] as? Bool == false)
        #expect(first?["pending"] as? [String] == ["p1"])
        #expect((result?["second"] as? [String: Any])?["detail"] as? String == "https://example.com")

        #expect(fake.response(0, "p1")?["request_id"] as? String == "p1")
        #expect(Self.answer(fake, "p1")?["behavior"] as? String == "allow")
        #expect(NSDictionary(dictionary: Self.answer(fake, "p1")?["updatedInput"] as? [String: Any] ?? [:]) == NSDictionary(dictionary: listFiles), "允许时原样带回输入")
        #expect(Self.answer(fake, "p2")?["behavior"] as? String == "deny")
        let denial = Self.answer(fake, "p2")?["message"] as? String ?? ""
        #expect(denial.contains("用户在 Vibepost 里拒绝了这次操作"), "拒绝带着原因交给 Claude")
        #expect(Self.answer(fake, "p3")?["behavior"] as? String == "allow")
        let updates = Self.answer(fake, "p3")?["updatedPermissions"] as? [[String: Any]] ?? []
        #expect(updates.count == 1)
        #expect(updates.first?["destination"] as? String == "session", "只在这次会话里有效，不写进 Claude Code 的设置")
        #expect(updates.first?["behavior"] as? String == "allow")
        let rules = updates.first?["rules"] as? [[String: Any]] ?? []
        #expect(rules.first?["toolName"] as? String == "Bash" && rules.first?["ruleContent"] as? String == "python3 -c 1", "范围是 claude 建议的那条命令，不是整个 Bash")
        let scope = result?["scope"] as? String ?? ""
        #expect(scope.contains("Bash(python3 -c 1)"), "按钮说明放行的范围")
        #expect(Self.answer(fake, "p4")?["behavior"] as? String == "allow", "别的命令照样要问")
        #expect(result?["queued"] as? String == "还有 1 个请求等你确认")
        #expect(result?["stillAsking"] as? Bool == true, "双击的第二下不算")
        #expect(Self.answer(fake, "p5")?["behavior"] as? String == "deny")
        #expect(Self.answer(fake, call: 1, "p6")?["behavior"] as? String == "allow")
        let second = fake.calls()[1]["argv"] as? [String] ?? []
        let allowed = second.firstIndex(of: "--allowedTools").map { Array(second[($0 + 1)...].prefix { !$0.hasPrefix("-") }) }
        #expect(allowed == ["mcp__mediacraft", "Bash(python3 -c 1)"], "下一轮经命令行带上这次会话放行的规则")

        let turn1 = (result?["turn1"] as? [String: Any])?["lines"] as? [[String]] ?? []
        #expect(turn1.filter { $0.first == "permission-line" }.map { $0.last ?? "" } == [
            "已允许 · 运行命令：ls -la", "已拒绝 · 打开网页：https://example.com", "本次会话都允许 · 运行命令：python3 -c 1",
            "已允许 · 运行命令：echo 自动", "已拒绝 · 运行命令：echo 第二条",
        ], "每个回答记一行")
        #expect((result?["turn1"] as? [String: Any])?["hidden"] as? Bool == true)
        let third = result?["third"] as? [String: Any]
        #expect(third?["detail"] as? String == "/tmp/外面.txt")
        let note = third?["note"] as? String ?? ""
        #expect(note.contains("不在这篇稿子的工作目录里：/tmp/外面.txt"))
        #expect(result?["stale"] as? String == "这个请求已经不在了")
        #expect(result?["hidden"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("claude 撤回请求时确认框收起；等确认时点停止（claude 问的、App 的工具自己问的）：确认框收起、进程结束、记为已停止")
    func withdrawnAndStoppedRequestsCloseTheSheet() async throws {
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(),
            StreamJSON.permission("p1", tool: "Bash", input: ["command": "sleep 100"], wait: false),
            "#wait-file seen",
            "#cancel-control p1",
        ] + Self.tail("算了"))
        try fake.script([StreamJSON.initEvent(), StreamJSON.permission("p2", tool: "Bash", input: ["command": "rm -rf 缓存"])], call: 2)
        try fake.script([StreamJSON.initEvent(), StreamJSON.toolCall("c1", "propose_images", ["images": [["source": "/tmp/外面的图.png"]]])], call: 3)
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            ask("跑一下");
            await until(() => sheetView().shown);
        """)
        fake.release("seen")
        let result = try await harness.evaluate("""
            await until(() => !sheetView().shown && finished(1));
            ask("删掉缓存");
            await until(() => sheetView().detail === "rm -rf 缓存");
            stopButton().click();
            await until(() => sendButton());
            const afterBash = sheet().hidden;
            ask("配张图");
            await until(() => sheetView().title === "Claude 想载入网上或工作目录以外的图片" && sheetView().detail === "/tmp/外面的图.png");
            stopButton().click();
            await until(() => sendButton());
            const { messages, permissions } = await mc.ai.history();
            return {
              afterBash, hidden: sheet().hidden, states: (await ends()).map((end) => end.state), pending: permissions.length,
              lastTurn: messages.slice(messages.findLastIndex((message) => message.role === "user")).map((message) => message.role),
            };
        """) as? [String: Any]
        let pids = fake.calls().compactMap { ($0["pid"] as? NSNumber)?.int32Value }
        var gone: [Bool] = []
        for pid in pids { gone.append(await FakeClaude.waitUntilGone(pid)) }
        await harness.tearDown()

        #expect(result?["afterBash"] as? Bool == true)
        #expect(result?["hidden"] as? Bool == true)
        #expect(result?["states"] as? [String] == ["done", "cancelled", "cancelled"])
        #expect(result?["pending"] as? Int == 0)
        #expect(result?["lastTurn"] as? [String] == ["user", "end"], "停止后不再记工具的失败，也没有候选")
        #expect(Self.answer(fake, "p1") == nil, "撤回的请求不再回答")
        #expect(gone == [true, true, true])
        #expect(harness.pageErrors == [])
    }

    @Test("App 的工具：换主题、插分页、挪一节、调图片大小与裁剪、调样式都在编辑器里生效并同步 draft.md；看分页与看一页；每个动作列在会话里，⌘Z 或行尾「撤销」都能撤回")
    func toolsOperateTheAppAndAreUndoable() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let setup = try await harness.evaluate(Self.helpers + """
            const draft = await mc.drafts.create({ markdown: "# 周末\\n\\n第一段文字。\\n\\n## 第一节\\n\\n第一节的内容。\\n\\n## 第二节\\n\\n第二节的内容。" });
            const [image] = await mc.media.import([await pngFile("湖.png", 400, 300, "#1971c2")], { at: draft.markdown.length });
            return { draftId: draft.id, image };
        """) as? [String: Any]
        let draftId = try #require(setup?["draftId"] as? String)
        let image = try #require(setup?["image"] as? String)
        try fake.script([
            StreamJSON.initEvent(),
            StreamJSON.toolCall("t1", "get_draft"),
            StreamJSON.toolCall("t2", "set_theme", ["theme": "纯黑"]),
            StreamJSON.toolCall("t3", "insert_page_break", ["after": "第一段文字"]),
            StreamJSON.toolCall("t4", "move_section", ["section": "## 第二节", "before": "## 第一节"]),
            StreamJSON.toolCall("t5", "resize_image", ["image": image, "widthPercent": 60, "align": "left"]),
            StreamJSON.toolCall("t6", "crop_image", ["image": image, "aspect": "1:1"]),
            StreamJSON.toolCall("t7", "set_style", ["fontSize": 36, "colors": ["accent": "#d9480f"]]),
            StreamJSON.toolCall("t8", "get_pages"),
            StreamJSON.toolCall("t9", "view_page", ["page": 2]),
            StreamJSON.toolCall("t10", "insert_page_break", ["after": "没有这段"]),
        ] + Self.tail("排好了"))
        let result = try await harness.evaluate("""
            await openAI();
            ask("帮我排一下");
            await until(() => finished(1));
            const draft = await mc.drafts.current();
            const after = {
              shape: await shape(), theme: draft.theme, fontSize: draft.fontSize, accent: draft.colors.accent,
              image: await mc.media.get(image), actions: await actions(), lines: lines(), edited: (await ends()).at(-1).edited ?? false,
            };
            // ⌘Z：最近两步是调样式与裁剪（换主题、调样式也是撤销历史里的一步）
            const styleUndone = (await mc.drafts.undo()).fontSize;
            await mc.drafts.undo();
            const cropUndone = (await mc.media.get(image)).crop;
            ui.click("撤销：换成主题「纯黑」");
            await until(async () => (await mc.drafts.current()).theme === "notes");
            ui.click("撤销：插入分页：在「第一段文字」之后");
            // 先撤回正文，再在会话里标上「已撤销」：两样都到了再看
            await until(async () => !(await mc.drafts.current()).markdown.includes("[[分页]]")
              && (await actions()).filter((action) => action.undone).length === 2);
            return { after, styleUndone, cropUndone, undone: { shape: await shape(), actions: await actions(), lines: lines() } };
        """, arguments: ["image": image]) as? [String: Any]
        let workFile = try String(contentsOf: harness.aiRoot.appendingPathComponent(draftId).appendingPathComponent("draft.md"), encoding: .utf8)
        await harness.tearDown()

        let expected = "# 周末\n\n第一段文字。\n\n[[分页]]\n\n## 第二节\n\n第二节的内容。\n[[图片:湖.png]]\n\n## 第一节\n\n第一节的内容。"
        let after = result?["after"] as? [String: Any]
        #expect((after?["shape"] as? String)?.trimmingCharacters(in: .newlines) == expected)
        #expect(workFile.replacingOccurrences(of: image, with: "湖.png").trimmingCharacters(in: .newlines) == expected, "结构改动同步进了 draft.md")
        #expect(after?["edited"] as? Bool == false, "同步过的改动不会在这一轮结束时再套用一次")
        #expect(after?["theme"] as? String == "ink")
        #expect(after?["fontSize"] as? Int == 36)
        #expect(after?["accent"] as? String == "#d9480f")
        let media = after?["image"] as? [String: Any]
        #expect(NSDictionary(dictionary: media?["layout"] as? [String: Any] ?? [:]) == NSDictionary(dictionary: ["align": "left", "widthPercent": 60]))
        #expect(NSDictionary(dictionary: media?["crop"] as? [String: Any] ?? [:]) == NSDictionary(dictionary: ["x": 50, "y": 0, "width": 300, "height": 300]))

        let actionTexts = (after?["actions"] as? [[String: Any]] ?? []).map { $0["text"] as? String ?? "" }
        #expect(actionTexts == [
            "换成主题「纯黑」", "插入分页：在「第一段文字」之后", "挪动「第二节」一节：在「## 第一节」之前",
            "图片「湖.png」宽度 60%、靠左", "裁剪图片「湖.png」为 1:1", "调整样式：强调 #d9480f、字号 36",
        ])
        #expect((after?["actions"] as? [[String: Any]] ?? []).allSatisfy { $0["undoable"] as? Bool == true })
        let kinds = (after?["lines"] as? [[String]] ?? []).map { $0.first ?? "" }
        #expect(kinds == ["user", "tool", "action", "action", "action", "action", "action", "action", "tool", "tool", "tool", "assistant", "end"],
                "App 的工具不另记「调用」行，看的记一行、做的记动作")
        let tools = (after?["lines"] as? [[String]] ?? []).filter { $0.first == "tool" }.map { $0.last ?? "" }
        #expect(tools == ["查看稿子设置", "查看分页（共 2 页）", "查看第 2 页", "插入分页没成功：稿子里找不到「没有这段」（原文要照抄、不跨行）"])

        let draftInfo = try JSONSerialization.jsonObject(with: Data(Self.toolText(fake, "t1").utf8)) as? [String: Any]
        #expect(draftInfo?["theme"] as? String == "notes")
        let images = draftInfo?["images"] as? [[String: Any]] ?? []
        #expect(images.first?["id"] as? String == image && images.first?["width"] as? Int == 400 && images.first?["inText"] as? Bool == true)
        #expect(((draftInfo?["options"] as? [String: Any])?["themes"] as? [Any])?.count == ThemeTests.ids.count)
        #expect(Self.toolText(fake, "t2") == "换成主题「纯黑」。")
        #expect(Self.toolText(fake, "t3") == "插入分页：在「第一段文字」之后。draft.md 已同步。")
        let pages = Self.toolText(fake, "t8")
        #expect(pages.hasPrefix("共 2 页") && pages.contains("这里有 [[分页]]") && pages.contains("标题 2「第二节」") && pages.contains("图片 \(image)"))
        let view = Self.toolResult(fake, "t9")?["content"] as? [[String: Any]] ?? []
        #expect(view.first?["text"] as? String == "第 2 页（共 2 页）")
        #expect(view.last?["type"] as? String == "image" && view.last?["mimeType"] as? String == "image/jpeg")
        #expect((view.last?["data"] as? String ?? "").count > 1000)
        #expect(Self.toolResult(fake, "t10")?["isError"] as? Bool == true)

        #expect(result?["styleUndone"] as? Int == 34, "第一次 ⌘Z 撤回了调样式")
        #expect(result?["cropUndone"] is NSNull, "第二次 ⌘Z 撤回了裁剪")
        let undone = result?["undone"] as? [String: Any]
        #expect((undone?["shape"] as? String)?.trimmingCharacters(in: .newlines)
                == "# 周末\n\n第一段文字。\n\n## 第二节\n\n第二节的内容。\n[[图片:湖.png]]\n\n## 第一节\n\n第一节的内容。", "只撤掉分页，之后挪的一节还在")
        let undoneActions = undone?["actions"] as? [[String: Any]] ?? []
        #expect(undoneActions.map { $0["undone"] as? Bool } == [true, true, false, false, false, false])
        let undoneLines = (undone?["lines"] as? [[String]] ?? []).filter { $0.first == "action" }.map { $0.last ?? "" }
        #expect(undoneLines.first?.hasSuffix("已撤销") == true)
        #expect(harness.pageErrors == [])
    }

    @Test("结构工具的边界：子节能挪到本章之前；挪到原位、挪进自己里面说明原因；去掉紧贴正文的分页不会把两段并成一段；和别的内容写在同一行的块不单独挪")
    func structureEdgeCases() async throws {
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(),
            StreamJSON.toolCall("s1", "move_section", ["section": "## 乙节", "before": "# 甲章"]),
            StreamJSON.toolCall("s2", "move_section", ["section": "第二段", "before": "[[分页]]"]),
            StreamJSON.toolCall("s3", "move_section", ["section": "# 甲章", "before": "第一段"]),
            StreamJSON.toolCall("s4", "remove_page_break", ["number": 1]),
            StreamJSON.toolCall("s5", "move_section", ["section": "行内", "after": "结尾"]),
        ] + Self.tail("好"))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# 甲章\\n\\n第一段\\n\\n## 乙节\\n\\n乙节内容\\n\\n# 丙章\\n\\n第二段\\n[[分页]]\\n结尾\\n\\n行内 [[image:abc]] 文字" });
            await mc.ai.send("调整结构");
            return (await mc.drafts.current()).markdown;
        """) as? String
        await harness.tearDown()

        #expect(result == "## 乙节\n\n乙节内容\n\n# 甲章\n\n第一段\n\n# 丙章\n\n第二段\n\n结尾\n\n行内 [[image:abc]] 文字")
        #expect(Self.toolText(fake, "s1") == "挪动「乙节」一节：在「# 甲章」之前。draft.md 已同步。")
        #expect(Self.toolText(fake, "s2") == "已经在那个位置了")
        #expect(Self.toolText(fake, "s3") == "要挪到的位置就在它自己里面")
        #expect(Self.toolText(fake, "s4") == "去掉第 1 个分页。draft.md 已同步。")
        #expect(Self.toolText(fake, "s5") == "这一块和别的内容写在同一行，没法单独挪")
        #expect(harness.pageErrors == [])
    }

    @Test("换样式工具：段落套成提示并居中、提示换成页尾、拆回正文、改标题级别；不对的用法说明原因；和舞台上的「换样式」同一套")
    func restyleBlockTool() async throws {
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(),
            StreamJSON.toolCall("r1", "restyle_block", ["block": "要提醒的一段", "style": "note", "align": "center"]),
            StreamJSON.toolCall("r2", "restyle_block", ["block": "要提醒的一段", "style": "footnote"]),
            StreamJSON.toolCall("r3", "restyle_block", ["block": "## 小节", "headingLevel": 1]),
            StreamJSON.toolCall("r4", "restyle_block", ["block": "普通一段", "style": "text"]),
            StreamJSON.toolCall("r5", "restyle_block", ["block": "普通一段", "align": "center"]),
            StreamJSON.toolCall("r6", "restyle_block", ["block": "- 甲", "style": "rows"]),
            StreamJSON.toolCall("r7", "set_card_css", ["css": ".mc-note { border-radius: 20px; }"]),
            StreamJSON.toolCall("r8", "set_card_css", ["css": ".mc-footnote { color: red; }", "append": true]),
        ] + Self.tail("好"))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "## 小节\\n\\n要提醒的一段\\n\\n普通一段\\n\\n- 甲\\n- 乙" });
            await mc.ai.send("换样式");
            const after = (await mc.drafts.current()).markdown;
            const css = (await mc.drafts.current()).cardCss;
            await mc.drafts.undo();
            const cssUndone = (await mc.drafts.current()).cardCss;
            await mc.drafts.undo();
            await mc.drafts.undo();
            return { after, css, cssUndone, undone: (await mc.drafts.current()).markdown };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["after"] as? String == "# 小节\n\n:::页尾 居中\n要提醒的一段\n:::\n\n普通一段\n\n:::标签列表\n- 甲\n- 乙\n:::")
        #expect(Self.toolText(fake, "r1") == "「要提醒的一段」换成提示、居中。draft.md 已同步。")
        #expect(Self.toolText(fake, "r4") == "这一块已经是正文了")
        #expect(result?["css"] as? String == ".mc-note { border-radius: 20px; }\n\n.mc-footnote { color: red; }")
        #expect(result?["cssUndone"] as? String == ".mc-note { border-radius: 20px; }", "卡片样式每次改动是撤销历史里的一步")
        #expect(Self.toolText(fake, "r8") == "追加卡片样式（2 条规则）。")
        #expect(Self.toolText(fake, "r5") == "对齐只对组件有用（先用 style 换成组件）")
        #expect(result?["undone"] as? String == "# 小节\n\n:::页尾 居中\n要提醒的一段\n:::\n\n普通一段\n\n- 甲\n- 乙", "每次换样式是撤销历史里的一步")
        #expect(harness.pageErrors == [])
    }

    @Test("insert_section 的锚点落在组件（:::提示 等）里时整个组件算一单元：after 插在组件之后、before 插在组件之前，不插进组件内部；position 只认 start / end（constructor 这类名字也拒绝）")
    func sectionsAroundComponents() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        try fake.script([
            StreamJSON.initEvent(),
            StreamJSON.toolCall("t1", "insert_section", ["markdown": "## 新节\n\n内容", "after": "要点一"]),
            StreamJSON.toolCall("t2", "insert_section", ["markdown": "前面", "before": "要点一"]),
            StreamJSON.toolCall("t3", "insert_section", ["snippet": "对比", "position": "constructor"]),
        ] + Self.tail("插好了"), call: 1)
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# T\\n\\n:::提示\\n要点一\\n:::\\n\\n段落" });
            await openAI();
            ask("插两段");
            await until(() => finished(1));
            return { markdown: (await mc.drafts.current()).markdown, actions: (await actions()).map((action) => action.text) };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["markdown"] as? String == "# T\n\n前面\n\n:::提示\n要点一\n:::\n\n## 新节\n\n内容\n\n段落", "after 在组件之后、before 在组件之前：\n\(result?["markdown"] ?? "")")
        #expect(result?["actions"] as? [String] == ["插入一段（9 字）：在「要点一」之后", "插入一段（2 字）：在「要点一」之前"])
        #expect(Self.toolResult(fake, "t3")?["isError"] as? Bool == true)
        #expect(Self.toolText(fake, "t3").contains("position 只能是 start"), Comment(rawValue: Self.toolText(fake, "t3")))
        #expect(harness.pageErrors == [])
    }

    @Test("片段与模板：list_templates 列出模板库；insert_section 把片段（id 或中文名）或一段 Markdown（英文记号换成中文）插在某块前后或稿子头尾，前后隔空行、同步 draft.md，每次是会话里一个可撤销的动作；[[结尾]] 不在末尾、没有的片段、两样都给、已有结尾页都说明原因；create_draft_from_template 在这个窗口里照模板新建并切过去，原来那篇留在抽屉里、这一轮仍记在它的会话里")
    func templatesAndSections() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let draftId = try await harness.evaluate(Self.helpers + """
            return (await mc.drafts.create({ markdown: "# 周末\\n\\n第一段文字。\\n\\n## 第一节\\n\\n第一节的内容。" })).id;
        """) as? String ?? ""
        try fake.script([
            StreamJSON.initEvent(),
            StreamJSON.toolCall("t1", "list_templates"),
            StreamJSON.toolCall("t2", "insert_section", ["snippet": "三步教程", "after": "第一段文字"]),
            StreamJSON.toolCall("t3", "insert_section", ["markdown": ":::note align=center\n要点\n:::", "position": "start"]),
            StreamJSON.toolCall("t4", "insert_section", ["snippet": "ending", "before": "## 第一节"]),
            StreamJSON.toolCall("t5", "insert_section", ["snippet": "没有的"]),
            StreamJSON.toolCall("t6", "insert_section", ["snippet": "对比", "markdown": "两样都给"]),
            StreamJSON.toolCall("t7", "insert_section", ["snippet": "结尾引导"]),
            StreamJSON.toolCall("t8", "insert_section", ["snippet": "ending"]),
        ] + Self.tail("插好了"), call: 1)
        try fake.script([
            StreamJSON.initEvent(),
            StreamJSON.toolCall("t9", "create_draft_from_template", ["template": "没有这个"]),
            StreamJSON.toolCall("t10", "create_draft_from_template", ["template": "干货清单"]),
        ] + Self.tail("新建了"), call: 2)
        let after = try await harness.evaluate("""
            await openAI();
            ask("插几段");
            await until(() => finished(1));
            return {
              markdown: (await mc.drafts.current()).markdown, actions: await actions(), lines: lines(),
              snippets: { tutorial: window.MediaCraftSnippets.get("tutorial").markdown, ending: window.MediaCraftSnippets.get("ending").markdown },
            };
        """) as? [String: Any]
        // 下一轮开始时 App 会按编辑器重写 draft.md，所以这一轮刚说完就看
        let workFile = try String(contentsOf: harness.aiRoot.appendingPathComponent(draftId).appendingPathComponent("draft.md"), encoding: .utf8)
        let result = try await harness.evaluate("""
            // ⌘Z 撤回最后一步（结尾引导）；行尾「撤销」只撤三步教程那一处，开头插的那段保留
            const undone = (await mc.drafts.undo()).markdown;
            ui.click("撤销：插入片段「三步教程」：在「第一段文字」之后");
            await until(async () => (await actions()).filter((action) => action.undone).length === 1);
            const single = (await mc.drafts.current()).markdown;
            const created = await mc.ai.send("照模板新建一篇");
            const current = await mc.drafts.current();
            const template = window.MediaCraftTemplateRegistry.find((item) => item.name === "干货清单");
            return {
              undone, single, created: created.state,
              current: { id: current.id, theme: current.theme, sameMarkdown: current.markdown === template.markdown.join("\\n") },
              listed: (await mc.drafts.list()).map((item) => item.id),
              session: (await mc.ai.history(draftId)).messages.filter((message) => message.role === "tool").map((message) => message.text),
            };
        """, arguments: ["draftId": draftId]) as? [String: Any]
        await harness.tearDown()

        let snippets = after?["snippets"] as? [String: String] ?? [:]
        let tutorial = try #require(snippets["tutorial"])
        let ending = try #require(snippets["ending"])
        let note = ":::提示 居中\n要点\n:::"
        let body = "# 周末\n\n第一段文字。\n\n\(tutorial)\n\n## 第一节\n\n第一节的内容。"
        let expected = "\(note)\n\n\(body)\n\n\(ending)"
        #expect(after?["markdown"] as? String == expected, "片段插在那一块之后、一段插在开头（英文记号换成中文）、结尾引导在末尾，前后隔开空行")
        #expect(workFile.trimmingCharacters(in: .newlines) == expected, "每次插入都同步进了 draft.md")
        let actionTexts = (after?["actions"] as? [[String: Any]] ?? []).map { $0["text"] as? String ?? "" }
        #expect(actionTexts == ["插入片段「三步教程」：在「第一段文字」之后", "插入一段（15 字）：稿子开头", "插入片段「结尾引导」：稿子末尾"])
        #expect((after?["actions"] as? [[String: Any]] ?? []).allSatisfy { $0["undoable"] as? Bool == true })
        let lines = after?["lines"] as? [[String]] ?? []
        #expect(lines.map { $0.first ?? "" } == ["user", "tool", "action", "action", "tool", "tool", "tool", "action", "tool", "assistant", "end"])
        let tools = lines.filter { $0.first == "tool" }.map { $0.last ?? "" }
        #expect(tools.first?.hasPrefix("查看模板（共 ") == true)
        #expect(tools.dropFirst().first == "插入片段没成功：结尾引导只能插在稿子末尾：把光标放到最后再插")
        #expect(tools.dropFirst(2).first?.hasPrefix("插入片段没成功：没有片段「没有的」（有这些：tutorial 三步教程、") == true)
        #expect(tools.dropFirst(3).first == "插入片段没成功：snippet（片段的 id 或中文名）与 markdown（一段 Markdown）要给、且只给一个")
        #expect(tools.last == "插入片段没成功：稿子里已经有结尾页了：一篇只能有一个 [[结尾]]")

        let listing = Self.toolText(fake, "t1")
        #expect(listing.hasPrefix("共 ") && listing.contains("干货清单（") && listing.contains("（清单 / 简洁，主题 备忘）"), "每套一行：名字（id）— 说明（题材 / 风格，主题）：\(listing.prefix(200))")
        #expect(Self.toolText(fake, "t2") == "插入片段「三步教程」：在「第一段文字」之后。draft.md 已同步。")
        #expect(Self.toolText(fake, "t3") == "插入一段（15 字）：稿子开头。draft.md 已同步。")
        #expect(Self.toolResult(fake, "t4")?["isError"] as? Bool == true && Self.toolResult(fake, "t5")?["isError"] as? Bool == true)
        #expect(Self.toolResult(fake, "t6")?["isError"] as? Bool == true && Self.toolResult(fake, "t8")?["isError"] as? Bool == true)
        #expect(Self.toolText(fake, "t7") == "插入片段「结尾引导」：稿子末尾。draft.md 已同步。")

        #expect(result?["undone"] as? String == "\(note)\n\n\(body)", "⌘Z 撤回最后插的结尾引导")
        #expect(result?["single"] as? String == "\(note)\n\n# 周末\n\n第一段文字。\n\n## 第一节\n\n第一节的内容。", "只撤三步教程那一处，开头的一段保留")

        #expect(result?["created"] as? String == "done")
        #expect(Self.toolText(fake, call: 1, "t9") == "没有模板「没有这个」（有哪些用 list_templates 看）")
        #expect(Self.toolResult(fake, call: 1, "t9")?["isError"] as? Bool == true)
        let createdText = Self.toolText(fake, call: 1, "t10")
        #expect(createdText.hasPrefix("已照模板「干货清单」新建稿子「") && createdText.contains("原来那篇已经保存"), "\(createdText)")
        let current = result?["current"] as? [String: Any]
        #expect(current?["id"] as? String != draftId && current?["theme"] as? String == "notes" && current?["sameMarkdown"] as? Bool == true, "这个窗口切到了照模板新建的那篇")
        #expect((result?["listed"] as? [String] ?? []).contains(draftId), "原来那篇留在稿件抽屉里")
        let session = result?["session"] as? [String] ?? []
        #expect(session.contains("照模板新建没成功：没有模板「没有这个」（有哪些用 list_templates 看）"))
        #expect(session.contains { $0.hasPrefix("照模板「干货清单」新建稿子「") }, "记在原来那篇的会话里：\(session)")
        #expect(harness.pageErrors == [])
    }

    @Test("配图候选：工作目录以外的图片（路径或 file:// 网址）、网上的图片先弹确认框，同意了才读，不同意 Claude 收到原因；工作目录里的不用问；不是图片的拒绝；会话里显示缩略图，稿子不变，点了才插进建议的位置（可撤销），重新打开还在")
    func candidatesInsertOnlyOnClick() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let willow = fake.directory.appendingPathComponent("柳树.png")
        let lake = fake.directory.appendingPathComponent("湖面.png")
        try Self.writePNG(willow, width: 600, height: 800, red: 0.2, green: 0.6, blue: 0.3)
        try Self.writePNG(lake, width: 800, height: 600, red: 0.1, green: 0.4, blue: 0.8)
        let notImage = fake.directory.appendingPathComponent("说明.txt")
        try "不是图片".write(to: notImage, atomically: true, encoding: .utf8)
        try fake.script([
            StreamJSON.initEvent(),
            StreamJSON.toolCall("c1", "propose_images", ["images": [
                ["source": willow.path, "caption": "湖边的柳树", "after": "第一段"],
                ["source": lake.absoluteString],
                ["source": notImage.path],
            ]]),
        ] + Self.tail("放了两张候选"), call: 1)
        try fake.script([
            StreamJSON.initEvent(),
            StreamJSON.toolCall("c2", "propose_images", ["images": [["source": "本地.png"], ["source": "https://example.invalid/远方.png"]]]),
        ] + Self.tail("又放了一张"), call: 2)
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let first = try await harness.evaluate(Self.helpers + """
            const draft = await mc.drafts.create({ markdown: "第一段\\n\\n第二段" });
            await openAI();
            ask("配两张图");
            await until(() => sheetView().shown);
            const sheet1 = sheetView();
            ui.click("允许", { within: sheet() });
            await until(() => finished(1));
            return { draftId: draft.id, sheet: sheet1 };
        """) as? [String: Any]
        let draftId = try #require(first?["draftId"] as? String)
        // Claude 在工作目录里生成的图：不用问
        try Self.writePNG(harness.aiRoot.appendingPathComponent(draftId).appendingPathComponent("本地.png"), width: 300, height: 300, red: 0.9, green: 0.7, blue: 0.2)
        let result = try await harness.evaluate("""
            ask("再来一张");
            await until(() => sheetView().detail === "https://example.invalid/远方.png");
            ui.click("拒绝", { within: sheet() });
            await until(() => finished(2));
            const before = { markdown: (await mc.drafts.current()).markdown, media: (await mc.media.list()).length };
            const buttons = ui.all("插入配图").map((button) => ({ name: ui.name(button), thumb: button.querySelector("img").src.slice(0, 22), disabled: button.disabled }));
            ui.click("插入配图「柳树.png」");
            await until(async () => (await mc.media.list()).length === 1);
            await until(() => ui.find("已插入配图「柳树.png」"));
            const inserted = { shape: await shape(), disabled: ui.find("已插入配图「柳树.png」").disabled };
            const message = (await mc.ai.history()).messages.find((item) => item.role === "candidates");
            await mc.drafts.undo();
            return { before, buttons, inserted, images: message.images.map(({ name, caption, inserted }) => ({ name, caption: caption ?? null, inserted: Boolean(inserted) })), undone: (await mc.drafts.current()).markdown };
        """) as? [String: Any]
        try await harness.load()
        let reopened = try await harness.evaluate(Self.helpers + """
            await openAI();
            return [...document.querySelectorAll(".ai-candidate")].map((button) => ui.name(button));
        """) as? [String]
        let stored = (try? FileManager.default.contentsOfDirectory(atPath: harness.aiRoot.appendingPathComponent(".candidates").appendingPathComponent(draftId).path)) ?? []
        let inWorkingCopy = FileManager.default.fileExists(atPath: harness.aiRoot.appendingPathComponent(draftId).appendingPathComponent("candidates").path)
        await harness.tearDown()

        let sheet = first?["sheet"] as? [String: Any]
        #expect(sheet?["title"] as? String == "Claude 想载入网上或工作目录以外的图片")
        #expect(sheet?["detail"] as? String == [willow.path, lake.absoluteString, notImage.path].joined(separator: "\n"), "一次问完这一批")
        let text = Self.toolText(fake, "c1")
        #expect(text.hasPrefix("已把 2 张图作为配图候选"))
        #expect(text.contains("说明.txt") && text.contains("不是能打开的图片"), "不是图片的拒绝，并说明原因")
        let second = Self.toolText(fake, call: 1, "c2")
        #expect(second.hasPrefix("已把 1 张图作为配图候选"), "工作目录里的不用问")
        #expect(second.contains("https://example.invalid/远方.png：用户没有同意载入"), "不同意时 Claude 收到原因")
        let before = result?["before"] as? [String: Any]
        #expect(before?["markdown"] as? String == "第一段\n\n第二段", "只放候选，稿子不变")
        #expect(before?["media"] as? Int == 0)
        let buttons = result?["buttons"] as? [[String: Any]] ?? []
        #expect(buttons.map { $0["name"] as? String } == ["插入配图「柳树.png」", "插入配图「湖面.png」", "插入配图「本地.png」"])
        #expect(buttons.allSatisfy { $0["thumb"] as? String == "data:image/jpeg;base64" && $0["disabled"] as? Bool == false })
        let inserted = result?["inserted"] as? [String: Any]
        #expect(inserted?["shape"] as? String == "第一段\n[[图片:柳树.png]]\n\n第二段", "插在建议的那一块后面")
        #expect(inserted?["disabled"] as? Bool == true)
        let images = result?["images"] as? [[String: Any]] ?? []
        #expect(images.map { $0["inserted"] as? Bool } == [true, false])
        #expect(images.first?["caption"] as? String == "湖边的柳树")
        #expect(result?["undone"] as? String == "第一段\n\n第二段", "插入是一步可以撤销的编辑")
        #expect(reopened == ["已插入配图「柳树.png」", "插入配图「湖面.png」", "插入配图「本地.png」"], "候选随会话保存")
        #expect(stored.count == 3, "原图存在 AI 目录的 .candidates 里")
        #expect(!inWorkingCopy, "不放进 claude 的工作目录")
        #expect(harness.pageErrors == [])
    }

    /// 纯色 PNG
    static func writePNG(_ url: URL, width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
