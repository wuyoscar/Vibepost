import Foundation
import MediaCraftMCP
import Testing
@testable import MediaCraftShell

/// 外部 Agent（MCP）：终端里的 Claude Code 等启动 mediacraft-mcp（stdio），它经 Unix 域套接字连进 App，工具在页面里经 App API 执行。
/// 测试的客户端经管道对着 mediacraft-mcp 的核心说 JSON-RPC，核心连到 ShellHarness 里的 App；AirDrop 是假接收端。
@MainActor
struct MCPTests {
    static let tools = [
        "get_manual", "list_writing_manuals", "read_writing_manual", "save_writing_manual",
        "list_drafts", "get_draft", "create_draft", "open_draft", "update_draft",
        "set_theme", "set_style", "set_mode", "list_palettes", "apply_palette",
        "insert_page_break", "remove_page_break", "move_section", "restyle_block", "set_card_css",
        "import_images", "insert_image", "move_image", "resize_image", "crop_image",
        "get_pages", "render_pages", "export", "send_to_iphone",
    ]
    static let modern: [String: Any] = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": ["name": "测试", "version": "1"],
        "io.modelcontextprotocol/clientCapabilities": [:],
    ]
    static let caption = "周末去湖边散步，柳树发芽了。\n\n#周末 #散步"
    static let body = "# 周末去哪儿\n\n湖边散步，柳树发了新芽。\n\n[[分页]]\n\n## 带什么\n\n- 野餐垫\n- 两杯热咖啡"

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }

    private static func start(_ config: MCPConfiguration = .temporary()) async throws -> (ShellHarness, MCPTestClient) {
        let harness = ShellHarness(onboarding: false, mcp: config)
        try await harness.load()
        let client = MCPTestClient(socketPath: config.socketPath)
        _ = try await client.initialize()
        return (harness, client)
    }

    private static func finish(_ harness: ShellHarness, _ client: MCPTestClient, _ config: MCPConfiguration) async {
        client.close()
        await harness.tearDown()
        try? FileManager.default.removeItem(at: config.directory)
    }

    @Test("握手：旧版 initialize、现行的 server/discover 与逐请求声明的版本都认，不认的版本回 -32022；工具清单由页面给出，描述里没有 draft.md；连着时顶栏出现「外部 Agent」，断开后消失")
    func handshakeAndToolList() async throws {
        let config = MCPConfiguration.temporary()
        let harness = ShellHarness(onboarding: false, mcp: config)
        try await harness.load()
        let client = MCPTestClient(socketPath: config.socketPath)
        let hello = try await client.initialize()
        let ping = try await client.request("ping")
        let discover = try await client.request("server/discover", ["_meta": Self.modern])["result"] as? [String: Any]
        let unsupported = try await client.request("tools/list", ["_meta": ["io.modelcontextprotocol/protocolVersion": "1900-01-01"]])
        let unknown = try await client.request("resources/list")
        try client.sendRaw("[{\"jsonrpc\":\"2.0\",\"id\":900,\"method\":\"ping\"}]")
        let batch = try await client.unaddressedResponse()
        let modernList = try await client.request("tools/list", ["_meta": Self.modern])["result"] as? [String: Any]
        let connected = try await harness.waitForPage("!document.getElementById('mcpIndicator').hidden")
        let status = try await harness.evaluate("return await mediacraft.mcp.status()") as? [String: Any]
        client.close()
        let disconnected = try await harness.waitForPage("document.getElementById('mcpIndicator').hidden")
        await harness.tearDown()
        try? FileManager.default.removeItem(at: config.directory)

        #expect(hello["protocolVersion"] as? String == "2025-11-25")
        #expect((hello["serverInfo"] as? [String: Any])?["name"] as? String == "mediacraft")
        #expect((hello["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(ping["result"] != nil)
        #expect((discover?["supportedVersions"] as? [String])?.first == "2026-07-28")
        #expect(discover?["resultType"] as? String == "complete")
        #expect((unsupported["error"] as? [String: Any])?["code"] as? Int == -32022)
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect((batch["error"] as? [String: Any])?["code"] as? Int == -32600, "不支持批量请求")
        #expect(modernList?["resultType"] as? String == "complete")
        let tools = modernList?["tools"] as? [[String: Any]] ?? []
        #expect(tools.map { $0["name"] as? String ?? "" } == Self.tools)
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" && !($0["description"] as? String ?? "").isEmpty })
        let listing = String(decoding: try JSONSerialization.data(withJSONObject: tools), as: UTF8.self)
        #expect(!listing.contains("draft.md") && !listing.contains("propose_images"), "外部 Agent 没有 draft.md，也不能放配图候选")
        #expect(connected && disconnected)
        #expect(status?["clients"] as? Int == 1)
        #expect(status?["enabled"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("新建稿子（开在新窗口，用户的窗口不动）→ 写正文 → 换主题 → 出图（每页一张 PNG）→ 导出 ZIP 与单页 PNG 到指定目录（文件名随标题、空格照原样；不覆盖，除非 overwrite；目录要存在、要绝对路径）→ 发送到 iPhone（假接收端）；每步列进那个窗口的「外部 Agent 的操作」")
    func draftToIPhone() async throws {
        let config = MCPConfiguration.temporary()
        let exports = try Self.temporaryDirectory()
        let (harness, client) = try await Self.start(config)
        let userDraft = try await harness.evaluate("return (await mediacraft.drafts.create({ markdown: \"用户自己的\" })).id") as? String
        let created = try await client.call("create_draft", ["title": "周末 去哪儿", "markdown": "# 草稿"])
        let draftId = (created.json as? [String: Any])?["id"] as? String
        let agent = try await harness.window(1)
        let updated = try await client.call("update_draft", ["markdown": Self.body, "caption": Self.caption])
        let viewed = try await client.call("get_draft")
        let theme = try await client.call("set_theme", ["theme": "纯黑"])
        let page = try await agent.evaluate("""
            const draft = await mediacraft.drafts.current();
            return { id: draft.id, title: draft.title, markdown: draft.markdown, theme: draft.theme };
        """) as? [String: Any]
        let user = try await harness.evaluate("return (await mediacraft.drafts.current()).id") as? String
        let rendered = try await client.call("render_pages")
        let second = try await client.call("render_pages", ["pages": [2], "width": 300])
        let beyond = try await client.call("render_pages", ["pages": [5]])

        let zip = try await client.call("export", ["format": "zip", "directory": exports.path])
        let again = try await client.call("export", ["format": "zip", "directory": exports.path])
        let overwritten = try await client.call("export", ["format": "zip", "directory": exports.path, "overwrite": true])
        let png = try await client.call("export", ["format": "png", "page": 2, "directory": exports.path])
        let missing = try await client.call("export", ["format": "zip", "directory": exports.appendingPathComponent("没有").path])
        let relative = try await client.call("export", ["format": "zip", "directory": "exports"])
        let sent = try await client.call("send_to_iphone")
        try await waitUntil(timeout: .seconds(20)) { !harness.sender.batches.isEmpty }
        let log = try await agent.evaluate("return (await mediacraft.mcp.log()).map(({ text, undoable }) => [text, undoable])") as? [[Any]] ?? []
        let userLog = try await harness.evaluate("return (await mediacraft.mcp.log()).length") as? Int
        await Self.finish(harness, client, config)
        let zipFile = exports.appendingPathComponent("周末 去哪儿.zip")
        let zipBytes = try Data(contentsOf: zipFile)
        let pngFile = exports.appendingPathComponent("周末 去哪儿-02.png")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: exports.path).sorted()
        try? FileManager.default.removeItem(at: exports)

        #expect(!created.isError && draftId != nil)
        #expect(harness.windows.count == 1, "新建的稿子开在一个新窗口里")
        #expect(user == userDraft && user != draftId, "用户的窗口还是用户自己的稿子")
        #expect(userLog == 0, "操作记在 Agent 的那个窗口里")
        #expect(updated.text.contains("现在排成 2 页"))
        #expect((viewed.json as? [String: Any])?["caption"] as? String == Self.caption, "get_draft 带着小红书正文")
        #expect((viewed.json as? [String: Any])?["markdown"] as? String == Self.body)
        #expect(theme.text == "换成主题「纯黑」。")
        #expect(page?["id"] as? String == draftId)
        #expect(page?["title"] as? String == "周末 去哪儿")
        #expect(page?["markdown"] as? String == Self.body)
        #expect(page?["theme"] as? String == "ink")
        #expect(!rendered.isError && rendered.text.contains("共 2 页"))
        #expect(rendered.images.count == 2)
        #expect(rendered.images.allSatisfy { MCPTestClient.pixelWidth($0) == 540 })
        #expect(second.images.count == 1 && second.images.first.flatMap(MCPTestClient.pixelWidth) == 300)
        #expect(beyond.isError && beyond.text.contains("只有 2 页"))

        #expect(!zip.isError)
        #expect((zip.json as? [String: Any])?["files"] as? [String] == [zipFile.path])
        #expect(zipBytes.prefix(2) == Data("PK".utf8))
        #expect(again.isError && again.text.contains("overwrite: true"), "同名文件不覆盖：\(again.text)")
        #expect(!overwritten.isError)
        #expect((png.json as? [String: Any])?["files"] as? [String] == [pngFile.path])
        #expect(missing.isError && missing.text.contains("没有这个文件夹"))
        #expect(relative.isError && relative.text.contains("绝对路径"))
        #expect(leftovers == ["周末 去哪儿-02.png", "周末 去哪儿.zip"], "写进的只有这两个文件")

        #expect(!sent.isError && sent.text.contains("隔空投送") && sent.text.contains("选") && sent.text.contains("小红书正文已放进剪贴板"))
        #expect(harness.sender.batches.first?.map(\.lastPathComponent) == ["01.png", "02.png"])
        #expect(harness.clipboard.text == Self.caption, "剪贴板是小红书正文，不是卡片上的字")
        #expect(log.map { $0.first as? String ?? "" } == [
            "新建稿子「周末 去哪儿」",
            "小红书正文改写（\(Self.caption.count) 字）、卡片内容改写（\(Self.body.count) 字）",
            "换成主题「纯黑」",
            "导出整组卡片 ZIP：\(zipFile.path)",
            "导出整组卡片 ZIP：\(zipFile.path)",
            "导出单页 PNG：\(pngFile.path)",
            "发送到 iPhone（2 页）",
        ])
        #expect(log.map { $0.last as? Bool ?? false } == [false, true, true, false, false, false, false], "改稿子的操作才能撤销")
        #expect(harness.pageErrors == [])
    }

    @Test("内置说明书只能看：打开可以，写正文、调样式、插图都拒绝，稿子不变")
    func guidesAreReadOnly() async throws {
        let config = MCPConfiguration.temporary()
        let images = try Self.temporaryDirectory()
        let image = images.appendingPathComponent("湖.png")
        try AIToolsTests.writePNG(image, width: 400, height: 300, red: 0.2, green: 0.5, blue: 0.45)
        let (harness, client) = try await Self.start(config)
        let list = try await client.call("list_drafts")
        let guides = (list.json as? [[String: Any]] ?? []).filter { $0["builtIn"] as? Bool == true }.compactMap { $0["id"] as? String }
        let opened = try await client.call("open_draft", ["id": "guide_cards"])
        let original = (opened.json as? [String: Any])?["markdown"] as? String
        let update = try await client.call("update_draft", ["markdown": "改掉"])
        let style = try await client.call("set_style", ["fontSize": 33])
        let insert = try await client.call("import_images", ["paths": [image.path]])
        let after = try await harness.evaluate("return (await mediacraft.drafts.current()).markdown") as? String
        let log = try await harness.evaluate("return (await mediacraft.mcp.log()).map((entry) => entry.text)") as? [String]
        await Self.finish(harness, client, config)
        try? FileManager.default.removeItem(at: images)

        #expect(guides == ["guide_cards", "guide_article"])
        #expect((opened.json as? [String: Any])?["readOnly"] as? Bool == true)
        for result in [update, style, insert] {
            #expect(result.isError && result.text.contains("内置说明书"), "\(result.text)")
        }
        #expect(original != nil && after == original)
        #expect(log == ["打开稿子「图文卡片说明书」"])
        #expect(harness.pageErrors == [])
    }

    @Test("从本机路径插图：绝对路径、存在的图片才收，插在给的原文之后（不给插在末尾），一步可撤销；相对路径、不存在的、不是图片的都拒绝")
    func importImagesFromPaths() async throws {
        let config = MCPConfiguration.temporary()
        let folder = try Self.temporaryDirectory()
        let lake = folder.appendingPathComponent("湖.png")
        let hill = folder.appendingPathComponent("山.png")
        let text = folder.appendingPathComponent("说明.txt")
        try AIToolsTests.writePNG(lake, width: 800, height: 600, red: 0.2, green: 0.5, blue: 0.45)
        try AIToolsTests.writePNG(hill, width: 600, height: 800, red: 0.6, green: 0.4, blue: 0.3)
        try "不是图片".write(to: text, atomically: true, encoding: .utf8)
        let (harness, client) = try await Self.start(config)
        _ = try await client.call("create_draft", ["markdown": "第一段\n\n第二段"])
        let agent = try await harness.window(1)
        let inserted = try await client.call("import_images", ["paths": [lake.path, hill.path], "after": "第一段"])
        let ids = (inserted.json as? [String: Any])?["imageIds"] as? [String] ?? []
        let shape = try await agent.evaluate("""
            let text = (await mediacraft.drafts.current()).markdown;
            for (const image of await mediacraft.media.list()) text = text.split(image.id).join(image.name);
            return text;
        """) as? String
        let relative = try await client.call("import_images", ["paths": ["湖.png"]])
        let absent = try await client.call("import_images", ["paths": [folder.appendingPathComponent("没有.png").path]])
        let notImage = try await client.call("import_images", ["paths": [text.path]])
        let count = try await agent.evaluate("return (await mediacraft.media.list()).length") as? Int
        let undone = try await agent.evaluate("return (await mediacraft.drafts.undo()).markdown") as? String
        await Self.finish(harness, client, config)
        try? FileManager.default.removeItem(at: folder)

        #expect(!inserted.isError && ids.count == 2)
        #expect(shape == "第一段\n[[图片:湖.png]]\n[[图片:山.png]]\n\n第二段", "每张一行，紧跟在那一块后面：\(String(reflecting: shape))")
        #expect(relative.isError && relative.text.contains("绝对路径"))
        #expect(absent.isError && absent.text.contains("找不到图片文件"))
        #expect(notImage.isError && notImage.text.contains("不是能打开的图片"))
        #expect(count == 2, "拒绝的一张都没进稿子")
        #expect(undone == "第一段\n\n第二段", "一次 ⌘Z 撤回这次插的两张图")
        #expect(harness.pageErrors == [])
    }

    @Test("外部 Agent 的改动都能撤销：⌘Z（drafts.undo）一步步撤回样式、主题与正文；「外部 Agent 的操作」里点「撤销」只撤那一个")
    func undoExternalChanges() async throws {
        let config = MCPConfiguration.temporary()
        let (harness, client) = try await Self.start(config)
        _ = try await client.call("create_draft", ["markdown": "甲"])
        let agent = try await harness.window(1)
        let before = try await agent.evaluate("return (await mediacraft.drafts.current()).theme") as? String
        let written = try await client.call("update_draft", ["markdown": "乙"])
        let themed = try await client.call("set_theme", ["theme": "ink"])
        let styled = try await client.call("set_style", ["fontSize": 30])
        let undone = try await agent.evaluate("""
            const steps = [];
            for (let step = 0; step < 3; step += 1) {
              const draft = await mediacraft.drafts.undo();
              steps.push([draft.fontSize, draft.theme, draft.markdown]);
            }
            await mediacraft.drafts.redo();
            return steps;
        """) as? [[Any]] ?? []

        // 撤回到「乙」之后又写了两次正文：只撤第一次（丙），后来的（丁）保留
        _ = try await client.call("update_draft", ["markdown": "乙\n\n丙"])
        _ = try await client.call("update_draft", ["markdown": "乙\n\n丙\n\n丁", "title": "新标题"])
        let lines = try await agent.evaluate("""
            ui.click("外部 Agent 已连接（1 个），看它做了什么");
            await new Promise((resolve) => setTimeout(resolve, 100));
            const box = document.getElementById("mcpLogBox");
            const texts = () => [...document.querySelectorAll("#mcpLog .ai-action")].map((node) => node.innerText.replace(/\\s+/g, " ").trim());
            const shown = { open: box.open, visible: !box.hidden, lines: texts(), aiTab: document.getElementById("aiTab").getAttribute("aria-selected") };
            ui.click("撤销：卡片内容改写（4 字）");
            const deadline = Date.now() + 5000;
            while (!texts().some((text) => text.includes("已撤销")) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 50));
            const draft = await mediacraft.drafts.current();
            return { ...shown, after: texts(), markdown: draft.markdown, title: draft.title };
        """) as? [String: Any]
        await Self.finish(harness, client, config)

        #expect(!written.isError && !themed.isError && !styled.isError, "\(written.text) \(themed.text) \(styled.text)")
        #expect(undone.count == 3, "\(undone)")
        #expect(undone.first?.first as? Int != 30, "第一次 ⌘Z 撤回字号")
        #expect(undone.dropFirst().first?[1] as? String == before, "第二次撤回主题")
        #expect(undone.last?[2] as? String == "甲", "第三次撤回正文")
        #expect(lines?["open"] as? Bool == true && lines?["visible"] as? Bool == true, "点顶栏的提示展开操作记录")
        #expect(lines?["aiTab"] as? String == "true")
        #expect((lines?["lines"] as? [String])?.first == "标题改成「新标题」、卡片内容改写（7 字） 撤销", "新的在上面")
        #expect((lines?["after"] as? [String] ?? []).contains("卡片内容改写（4 字） 已撤销"))
        #expect(lines?["markdown"] as? String == "乙\n\n丁", "只撤了那一次，之后的改动保留")
        #expect(lines?["title"] as? String == "新标题")
        #expect(harness.pageErrors == [])
    }

    @Test("用户在 Agent 的窗口里切到别的稿子后，Agent 不再看、不再改：报错并说明怎么接着改（断开重连后仍记得）；open_draft 在新窗口里打开它之后照常")
    func switchedDraftIsProtected() async throws {
        let config = MCPConfiguration.temporary()
        let (harness, client) = try await Self.start(config)
        let created = try await client.call("create_draft", ["title": "Agent 的稿子", "markdown": "甲"])
        let agentDraft = (created.json as? [String: Any])?["id"] as? String ?? ""
        let agent = try await harness.window(1)
        // 用户在 Agent 的那个窗口里换成了自己的一篇
        let userDraft = try await agent.evaluate("return (await mediacraft.drafts.create({ markdown: \"用户自己的\" })).id") as? String
        let peek = try await client.call("get_draft")
        // App 断开了这个连接（关掉再打开外部连接）：重连之后仍认定 Agent 的稿子
        _ = try await harness.evaluate("await mediacraft.mcp.setEnabled(false); await mediacraft.mcp.setEnabled(true);")
        let blocked = try await client.call("update_draft", ["markdown": "乙"])
        let reopened = try await client.call("open_draft", ["id": agentDraft])
        let allowed = try await client.call("update_draft", ["markdown": "乙"])
        let reopenedIn = try await harness.window(2).evaluate("return (await mediacraft.drafts.current()).id") as? String
        let drafts = try await harness.evaluate("""
            await new Promise((resolve) => setTimeout(resolve, 300));
            return [(await mediacraft.drafts.get(agentDraft)).markdown, (await mediacraft.drafts.get(userDraft)).markdown];
        """, arguments: ["agentDraft": agentDraft, "userDraft": userDraft ?? ""]) as? [String]
        let stillUser = try await agent.evaluate("return (await mediacraft.drafts.current()).id") as? String
        await Self.finish(harness, client, config)

        #expect(peek.isError && peek.text.contains("切到了别的稿子"), "get_draft 也只看认定的那篇：\(peek.text)")
        #expect(blocked.isError && blocked.text.contains("切到了别的稿子") && blocked.text.contains("open_draft"), "\(blocked.text)")
        #expect(!reopened.isError && !allowed.isError)
        #expect(reopenedIn == agentDraft, "open_draft 在新窗口里打开它（原来的窗口用户在用）")
        #expect(stillUser == userDraft, "用户换成的那篇不被抢走")
        #expect(drafts == ["乙", "用户自己的"])
        #expect(harness.pageErrors == [])
    }

    @Test("两个 Agent 各改一篇：各开各的窗口、各改各的，请求不会交错到对方的稿子；打开对方开着的那篇就交给那个窗口，不再开新窗口")
    func twoAgentsTwoDrafts() async throws {
        let config = MCPConfiguration.temporary()
        let (harness, first) = try await Self.start(config)
        let second = MCPTestClient(socketPath: config.socketPath)
        _ = try await second.initialize()
        let a = try await first.call("create_draft", ["title": "甲 Agent", "markdown": "甲"])
        let b = try await second.call("create_draft", ["title": "乙 Agent", "markdown": "乙"])
        _ = try await first.call("update_draft", ["markdown": "甲改了"])
        _ = try await second.call("update_draft", ["markdown": "乙改了"])
        _ = try await first.call("set_theme", ["theme": "ink"])
        let aId = (a.json as? [String: Any])?["id"] as? String ?? ""
        let bId = (b.json as? [String: Any])?["id"] as? String ?? ""
        let peekOther = try await first.call("open_draft", ["id": bId])
        let windowsAfter = harness.windows.count
        let result = try await harness.evaluate("""
            await new Promise((resolve) => setTimeout(resolve, 300));
            const get = async (id) => { const draft = await mediacraft.drafts.get(id); return [draft.markdown, draft.theme]; };
            return { a: await get(a), b: await get(b) };
        """, arguments: ["a": aId, "b": bId]) as? [String: [String]]
        second.close()
        await Self.finish(harness, first, config)

        #expect(windowsAfter == 2, "两个 Agent 各一个窗口，打开对方开着的不再开新窗口")
        #expect(result?["a"]?.first == "甲改了" && result?["a"]?.last == "ink")
        #expect(result?["b"]?.first == "乙改了" && result?["b"]?.last != "ink", "乙没被甲的换主题改到")
        #expect(!peekOther.isError)
        #expect(harness.pageErrors == [])
    }

    @Test("外部 Agent 不动用户的窗口：它新建的稿子开在新窗口、不到最前面（没认定稿子的 Agent 还是看用户正开着的那篇）；开不了新窗口时新建报错；AI 正在用户窗口里改着、没显示出来的那篇不让它打开")
    func agentsLeaveUserWindowsAlone() async throws {
        let fake = try FakeClaude(script: [StreamJSON.initEvent(), "#hang"])
        defer { fake.remove() }
        let config = MCPConfiguration.temporary()
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false, mcp: config)
        try await harness.load()
        let agent = MCPTestClient(socketPath: config.socketPath)
        _ = try await agent.initialize()
        let other = MCPTestClient(socketPath: config.socketPath)
        _ = try await other.initialize()
        let user = try await harness.evaluate(AISessionTests.helpers + "return (await mc.drafts.create({ title: '用户的', markdown: '用户的' })).id;") as? String
        let created = try await agent.call("create_draft", ["title": "Agent 的", "markdown": "甲"])
        let userWindowInFront = harness.shell.core.pages.last === harness.shell
        let seen = try await other.call("get_draft")

        // 开不了新窗口：新建报错，不在用户的窗口里新建
        let openWindow = harness.shell.core.openWindow
        harness.shell.core.openWindow = { _ in nil }
        let refused = try await agent.call("create_draft", ["title": "又一篇"])
        harness.shell.core.openWindow = openWindow
        let drafts = try await harness.evaluate("return (await mc.drafts.list()).filter((item) => !item.builtIn).length;") as? Int

        // 用户的窗口里 AI 在改「用户的」，用户换到了另一篇：Agent 打开「用户的」报错，不开新窗口、不把用户的窗口换回去
        let switched = try await harness.evaluate("""
            await openAI();
            ask("你好");
            await until(async () => (await mc.ai.history()).running);
            return (await mc.drafts.create({ title: "另一篇", markdown: "另一篇" })).id;
        """) as? String
        let windows = harness.windows.count
        let held = try await agent.call("open_draft", ["id": user ?? ""])
        let stillSwitched = try await harness.evaluate("return (await mc.drafts.current()).id;") as? String
        other.close()
        await Self.finish(harness, agent, config)

        #expect(!created.isError, "\(created.text)")
        #expect(userWindowInFront, "Agent 开的窗口不抢到最前面")
        #expect((seen.json as? [String: Any])?["id"] as? String == user, "没认定稿子的 Agent 看的还是用户正开着的那篇：\(seen.text)")
        #expect(refused.isError && refused.text.contains("开不了新窗口"), "\(refused.text)")
        #expect(drafts == 2, "没在用户的窗口里新建")
        #expect(held.isError && held.text.contains("AI 正在"), "\(held.text)")
        #expect(harness.windows.count == windows && stillSwitched == switched, "不开新窗口，用户的窗口不换")
        #expect(harness.pageErrors == [])
    }

    @Test("「允许外部 Agent 连接」默认是关的：刚装好时连进来被拒绝并说明怎么打开，设置里的开关没勾；打开之后照常")
    func externalAgentsOffByDefault() async throws {
        let config = MCPConfiguration.temporary(allowExternalAgents: nil)
        let (harness, client) = try await Self.startWithoutHandshake(config)
        let status = try await harness.evaluate("return await mediacraft.mcp.status()") as? [String: Any]
        let refused = try await client.request("tools/list")
        client.close()
        let checked = try await harness.evaluate("""
            document.getElementById("aiButton").click();
            ui.expand("AI 设置");
            return document.getElementById("mcpEnabledInput").checked;
        """) as? Bool
        _ = try await harness.evaluate("await mediacraft.mcp.setEnabled(true)")
        let again = MCPTestClient(socketPath: config.socketPath)
        _ = try await again.initialize()
        let allowed = try await again.call("list_drafts")
        await Self.finish(harness, again, config)

        #expect(status?["enabled"] as? Bool == false)
        let message = (refused["error"] as? [String: Any])?["message"] as? String ?? ""
        #expect(message.contains("没有打开「允许外部 Agent 连接」") && message.contains("AI 助手 › 设置"), "\(message)")
        #expect(checked == false)
        #expect(!allowed.isError)
        #expect(harness.pageErrors == [])
    }

    @Test("「允许外部 Agent 连接」：设置里有开关与「复制接入命令」；关掉后已连着的断开、新连接被拒绝并说明原因，设置存进 mcp.json，重新打开 App 仍是关的；再打开照常")
    func toggleRefusesConnections() async throws {
        let config = MCPConfiguration.temporary()
        let (harness, client) = try await Self.start(config)
        let first = try await client.call("list_drafts")
        let settings = try await harness.evaluate("""
            document.getElementById("aiButton").click();
            ui.expand("AI 设置");
            const input = document.getElementById("mcpEnabledInput");
            const shown = {
              visible: !document.getElementById("mcpSettings").hidden, checked: input.checked,
              command: document.getElementById("mcpCommand").textContent,
            };
            ui.click("复制接入命令");
            await new Promise((resolve) => setTimeout(resolve, 200));
            ui.click("允许外部 Agent 连接");
            const deadline = Date.now() + 5000;
            while ((await mediacraft.mcp.status()).enabled && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 50));
            return { ...shown, status: await mediacraft.mcp.status() };
        """) as? [String: Any]
        let copied = harness.clipboard.text
        let dropped = try await harness.waitForPage("document.getElementById('mcpIndicator').hidden")
        let refused = try await client.call("list_drafts")
        let fresh = MCPTestClient(socketPath: config.socketPath)
        let freshList = try await fresh.request("tools/list")
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: config.settingsFile)) as? [String: Any]
        fresh.close()
        client.close()
        await harness.tearDown()

        // 重新打开 App（同一个设置目录）：仍是关的；打开之后照常
        let (reopened, again) = try await Self.startWithoutHandshake(config)
        let reopenedStatus = try await reopened.evaluate("return await mediacraft.mcp.status()") as? [String: Any]
        _ = try await reopened.evaluate("await mediacraft.mcp.setEnabled(true)")
        _ = try await again.initialize()
        let allowed = try await again.call("list_drafts")
        await Self.finish(reopened, again, config)

        let command = "claude mcp add mediacraft -- \"/Applications/MediaCraft.app/Contents/MacOS/mediacraft-mcp\""
        #expect(!first.isError)
        #expect(settings?["visible"] as? Bool == true && settings?["checked"] as? Bool == true)
        #expect(settings?["command"] as? String == command)
        #expect(copied == command, "「复制接入命令」把命令放进剪贴板")
        #expect((settings?["status"] as? [String: Any])?["enabled"] as? Bool == false)
        #expect(dropped, "关掉时断开已连着的")
        #expect(refused.isError && refused.text.contains("没有打开「允许外部 Agent 连接」"), "\(refused.text)")
        #expect(((freshList["error"] as? [String: Any])?["message"] as? String ?? "").contains("没有打开「允许外部 Agent 连接」"))
        #expect(stored?["allowExternalAgents"] as? Bool == false)
        #expect(reopenedStatus?["enabled"] as? Bool == false, "开关存下来了")
        #expect(!allowed.isError)
        #expect(harness.pageErrors == [] && reopened.pageErrors == [])
    }

    @Test("只让当前用户连：连进来的进程不是设置里的用户（getpeereid）时拒绝并说明原因，不算连着")
    func peerUserIsChecked() async throws {
        let config = MCPConfiguration.temporary(peerUserID: getuid() &+ 1)
        let harness = ShellHarness(onboarding: false, mcp: config)
        try await harness.load()
        let client = MCPTestClient(socketPath: config.socketPath)
        let list = try await client.request("tools/list")
        let call = try await client.call("list_drafts")
        let status = try await harness.evaluate("return await mediacraft.mcp.status()") as? [String: Any]
        let permissions = try FileManager.default.attributesOfItem(atPath: config.socketPath)[.posixPermissions] as? Int
        await Self.finish(harness, client, config)

        let error = list["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32603)
        #expect((error?["message"] as? String ?? "").contains("只允许这台 Mac 上的当前用户"))
        #expect(call.isError && call.text.contains("只允许这台 Mac 上的当前用户"))
        #expect(status?["clients"] as? Int == 0)
        #expect(permissions == 0o600, "套接字只有自己能读写")
        #expect(harness.pageErrors == [])
    }

    @Test("同时开着两个 MediaCraft（Debug 与装好的）：后开的不抢先开的套接字，退出时也不删别人的")
    func secondInstanceDoesNotStealSocket() async throws {
        let config = MCPConfiguration.temporary()
        let (first, client) = try await Self.start(config)
        let second = ShellHarness(onboarding: false, mcp: config)
        try await second.load()
        let secondStatus = try await second.evaluate("return await mediacraft.mcp.status()") as? [String: Any]
        let settingsHidden = try await second.evaluate("return document.getElementById('mcpSettings').hidden") as? Bool
        await second.tearDown()
        let stillServed = try await client.call("list_drafts")
        let socketKept = FileManager.default.fileExists(atPath: config.socketPath)
        await Self.finish(first, client, config)

        #expect(secondStatus?["available"] as? Bool == false)
        #expect(settingsHidden == true, "没在接外部 Agent 的那个不显示开关")
        #expect(!stillServed.isError && socketKept, "先开的照常服务")
        #expect(first.pageErrors == [] && second.pageErrors == [])
    }

    @Test("App 没开时 mediacraft-mcp 先打开它，等套接字出现再连（有上限）；打不开、等不到都回清楚的原因")
    func launchesAppWhenNeeded() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("mcp.sock").path
        let launches = LaunchCounter()
        let client = MCPTestClient(socketPath: socket) {
            launches.increment()
            try FakeApp.start(at: socket)
        }
        let list = try await client.request("tools/list")
        client.close()

        let silent = MCPTestClient(socketPath: folder.appendingPathComponent("没人.sock").path, launchTimeout: .seconds(1)) {}
        let waited = try await silent.call("list_drafts")
        silent.close()
        let broken = MCPTestClient(socketPath: folder.appendingPathComponent("没人.sock").path) {
            throw MCPFailure("没能打开 MediaCraft（测试）")
        }
        let failed = try await broken.call("list_drafts")
        broken.close()

        #expect(launches.count == 1)
        #expect(((list["result"] as? [String: Any])?["tools"] as? [Any])?.count == 0)
        #expect(waited.isError && waited.text.contains("没有在 1 秒内准备好"), "\(waited.text)")
        #expect(failed.isError && failed.text == "没能打开 MediaCraft（测试）")
    }

    /// 打开 App（不握手：测试开关时第一个请求要自己看结果）
    private static func startWithoutHandshake(_ config: MCPConfiguration) async throws -> (ShellHarness, MCPTestClient) {
        let harness = ShellHarness(onboarding: false, mcp: config)
        try await harness.load()
        return (harness, MCPTestClient(socketPath: config.socketPath))
    }
}

private final class LaunchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

/// 假的 App：在套接字上接一个连接，回 ready，之后每个请求回一个空的工具清单
private enum FakeApp {
    static func start(at path: String) throws {
        let listener = try UnixSocket.listen(at: path)
        Thread {
            var descriptor: Int32?
            while descriptor == nil {
                descriptor = UnixSocket.accept(listener)
                if descriptor == nil { Thread.sleep(forTimeInterval: 0.02) }
            }
            let channel = LineChannel(descriptor: descriptor!)
            try? channel.send(["ready": true])
            while let request = channel.readObject() {
                try? channel.send(["id": request["id"] ?? 0, "result": ["tools": []]])
            }
            channel.close()
            close(listener)
        }.start()
    }
}
