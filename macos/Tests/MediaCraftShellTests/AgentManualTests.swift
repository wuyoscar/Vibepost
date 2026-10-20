import Foundation
import MediaCraftMCP
import Testing
@testable import MediaCraftShell

/// 操作手册交给 Agent：App 里的 AI 每轮的说明书带短版，工作副本里有 AGENTS.md（全文，每轮重写）；AI 写回来的英文记号收下时换成中文；
/// 外部 Agent 握手时（App 开着）拿到操作手册全文，App 没开时只有短说明、不为握手把 App 打开；get_manual 随时读全文。
@MainActor
struct AgentManualTests {
    @Test("App 里的 AI：说明书带操作手册的短版并指向 AGENTS.md；工作副本里每轮重写 AGENTS.md（Agent 改了也不留）；写回来的英文记号收下时换成中文")
    func appAgentGetsTheManual() async throws {
        let english = ":::kicker\n论文：Agent 写的\n:::\n\n{{color:#d9480f|红字}}\n"
        let fake = try FakeClaude(script: [AIReviewTests.write("draft.md", english), AIReviewTests.write("AGENTS.md", "被 Agent 改坏了\n")] + StreamJSON.reply(["改好了。"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(AIReviewTests.helpers + """
            const draft = await mc.drafts.create({ markdown: "原来的一段" });
            await openAI();
            ask("排一下");
            await until(() => finished(1));
            await until(async () => (await mc.ai.review.get()).open);
            const hunks = (await mc.ai.review.get()).hunks.map((hunk) => hunk.after);
            await mc.ai.review.acceptAll();
            return { id: draft.id, hunks, markdown: await markdown(), manual: window.MediaCraftManual.document() };
        """) as? [String: Any]
        let id = result?["id"] as? String ?? ""
        let afterFirst = try? String(contentsOf: harness.aiRoot.appendingPathComponent(id).appendingPathComponent("AGENTS.md"), encoding: .utf8)
        // 再跑一轮：AGENTS.md 又被 App 写回操作手册
        try fake.script(StreamJSON.reply(["好的。"]))
        _ = try await harness.evaluate(AIReviewTests.helpers + """
            ask("再看看");
            await until(() => finished(2));
        """)
        let agents = try? String(contentsOf: harness.aiRoot.appendingPathComponent(id).appendingPathComponent("AGENTS.md"), encoding: .utf8)
        let systemPrompt = FakeClaude.option("--append-system-prompt", in: fake.calls().first ?? [:]) ?? ""
        await harness.tearDown()

        let manual = result?["manual"] as? String ?? "(没有)"
        #expect(afterFirst == "被 Agent 改坏了\n", "这一轮里 Agent 改的照写")
        #expect(agents?.hasPrefix(manual) == true && agents?.contains("## 写作手册") == true && agents?.contains("被 Agent 改坏了") == false,
                "下一轮开始时 App 重写 AGENTS.md：操作手册全文，后面是写作手册的目录（见 WritingManualsTests）")
        #expect(systemPrompt.contains("AGENTS.md") && systemPrompt.contains(":::小标签") && systemPrompt.contains("{{字色:#d9480f|文字}}"), "说明书带短版并指向 AGENTS.md")
        #expect((result?["hunks"] as? [String])?.joined(separator: "\n").contains(":::小标签") == true, "修改对比里看到的就是中文写法")
        #expect(result?["markdown"] as? String == ":::小标签\n论文：Agent 写的\n:::\n\n{{字色:#d9480f|红字}}", "收下时换成中文（行尾换行照原来的）")
        #expect(harness.pageErrors == [])
    }

    @Test("外部 Agent：App 开着时握手说明后面接着操作手册全文；get_manual 读全文；create_draft / update_draft 写来的英文记号换成中文；get_pages 带每页的问题")
    func externalAgentGetsTheManual() async throws {
        let config = MCPConfiguration.temporary()
        let harness = ShellHarness(onboarding: false, mcp: config)
        try await harness.load()
        let client = MCPTestClient(socketPath: config.socketPath)
        let hello = try await client.initialize()
        let manualTool = try await client.call("get_manual")
        _ = try await client.call("create_draft", ["markdown": ":::note align=center\n要点\n:::\n\n[[分页]]\n\n第二页一行"])
        let agent = try await harness.window(1)
        let created = try await agent.evaluate("return (await mediacraft.drafts.current()).markdown") as? String
        _ = try await client.call("update_draft", ["markdown": "# 只有标题\n\n[[分页]]\n\n{{bg:#fff3bf|高亮}}一行\n\n[[分页]]\n\n最后"])
        let updated = try await agent.evaluate("return (await mediacraft.drafts.current()).markdown") as? String
        let pages = try await client.call("get_pages")
        let manual = try await agent.evaluate("return window.MediaCraftManual.document()") as? String ?? "(没有)"
        client.close()
        await harness.tearDown()
        try? FileManager.default.removeItem(at: config.directory)

        let instructions = hello["instructions"] as? String ?? ""
        #expect(instructions.hasPrefix("Vibepost 是用户这台 Mac 上的排版 App"))
        #expect(instructions.hasSuffix(manual), "握手说明后面接着操作手册全文")
        #expect(manualTool.text == manual, "\(manualTool.text.prefix(80))")
        #expect(created == ":::提示 居中\n要点\n:::\n\n[[分页]]\n\n第二页一行")
        #expect(updated == "# 只有标题\n\n[[分页]]\n\n{{高亮:#fff3bf|高亮}}一行\n\n[[分页]]\n\n最后")
        #expect(pages.text.contains("⚠ 只有标题") && pages.text.contains("⚠ 太空"), "\(pages.text)")
    }

    @Test("App 没开（或没打开外部连接）时握手只有短说明、提示用 get_manual，不为了握手把 App 打开")
    func handshakeWithoutAppDoesNotLaunchIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-manual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let launched = LaunchFlag()
        let client = MCPTestClient(socketPath: folder.appendingPathComponent("没人.sock").path) { launched.set() }
        let hello = try await client.initialize()
        client.close()

        let instructions = hello["instructions"] as? String ?? ""
        #expect(instructions.contains("get_manual") && instructions.contains("get_writing_skill"), "没连上 App 时也提示读两份内置技能")
        #expect(!instructions.contains("# Vibepost 操作手册"))
        #expect(!launched.value, "握手不打开 App")
    }
}

private final class LaunchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var launched = false
    var value: Bool { lock.withLock { launched } }
    func set() { lock.withLock { launched = true } }
}
