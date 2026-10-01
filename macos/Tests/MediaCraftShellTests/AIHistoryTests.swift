import Foundation
import Testing
@testable import MediaCraftShell

/// 第 10 张票：AI 助手顶上的这篇会话（标题就是稿子的标题）、会话历史（聊过的稿子按最近一次 AI 活动排、搜、
/// 打开 / 新窗口 / 跳到开着它的窗口）、找不到 / 没登录时按后端的指引、快捷命令有了对话后收成一行。
@MainActor
struct AIHistoryTests {
    static let helpers = MultiWindowTests.helpers + """
        window.historyList = () => document.getElementById("aiHistoryList");
        window.historyRows = () => [...historyList().querySelectorAll(".ai-history-item")].map((row) => ({
          id: row.dataset.draftId,
          title: row.querySelector(".ai-history-title").textContent,
          time: row.querySelector(".ai-history-time").textContent,
          meta: row.querySelector(".ai-history-meta").textContent.replace(/\\s+/g, " ").trim(),
          current: row.classList.contains("is-current"),
        }));
        window.searchHistory = (text) => {
          const input = ui.find("搜索会话");
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        };
        window.historyButton = (id) => [...historyList().querySelectorAll(".ai-history-item")]
          .find((row) => row.dataset.draftId === id).querySelector(".ai-history-open");
    """

    @Test("会话历史：聊过的稿子按最近一次 AI 活动排（不是修改时间），没聊过的不列；每行有后端、最后一句话与多久以前；按标题与聊过的话搜；点一篇在这个窗口打开，⌘ 点按在新窗口打开，开在别的窗口里的就跳过去")
    func historyListsSessions() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["好的，已经看过了"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let first = try await harness.evaluate(Self.helpers + """
            const a = await mc.drafts.create({ title: "周末去湖边", markdown: "湖边散步" });
            await openAI();
            ask("帮我看看这篇");
            await until(() => finished(1));
            const b = await mc.drafts.create({ title: "麻婆豆腐", markdown: "豆腐切块" });
            ask("豆腐要不要焯水");
            await until(() => finished(1));
            // 甲后来又改过（修改时间最新），最近一次 AI 活动还是乙
            await mc.drafts.open(a.id);
            await mc.drafts.update({ markdown: "湖边散步，柳树发芽了" });
            const c = await mc.drafts.create({ title: "没聊过的", markdown: "还没问过 AI" });
            const listed = (await mc.ai.sessions()).map((session) => session.draftId);
            ui.expand("会话历史");
            await until(() => historyRows().length === 2);
            const rows = historyRows();
            const focused = document.activeElement === ui.find("搜索会话");
            searchHistory("焯水");
            await until(() => historyRows().length === 1);
            const byWords = historyRows().map((row) => row.id);
            searchHistory("湖边");
            await until(() => historyRows().length === 1 && historyRows()[0].id === a.id);
            searchHistory("没有这句话");
            await until(() => !document.getElementById("aiHistoryEmpty").hidden);
            const empty = document.getElementById("aiHistoryEmpty").textContent;
            searchHistory("");
            await until(() => historyRows().length === 2);
            // 键盘：搜索框里 ↓ 进列表，↓ 下一行，最上面再 ↑ 回搜索框
            const key = (target, name) => target.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
            const search = ui.find("搜索会话");
            const walk = [];
            key(search, "ArrowDown");
            walk.push(document.activeElement.closest("li")?.dataset.draftId);
            key(document.activeElement, "ArrowDown");
            walk.push(document.activeElement.closest("li")?.dataset.draftId);
            key(document.activeElement, "ArrowUp");
            key(document.activeElement, "ArrowUp");
            walk.push(document.activeElement === search ? "search" : "?");
            // 点乙：在这个窗口打开，弹层收起
            ui.click("麻婆豆腐", { within: historyList() });
            await until(async () => (await mc.drafts.current()).id === b.id);
            return { a: a.id, b: b.id, c: c.id, listed, rows, focused, byWords, empty, walk, closed: !document.getElementById("aiHistory").open };
        """) as? [String: Any]
        let a = try #require(first?["a"] as? String)
        let b = try #require(first?["b"] as? String)
        #expect(first?["listed"] as? [String] == [b, a], "按最近一次 AI 活动排，没聊过的不列：\(first?["listed"] ?? "")")
        let rows = first?["rows"] as? [[String: Any]] ?? []
        #expect(rows.map { $0["title"] as? String } == ["麻婆豆腐", "周末去湖边"])
        #expect(rows.allSatisfy { ($0["meta"] as? String ?? "").contains("Claude Code") && ($0["meta"] as? String ?? "").contains("好的，已经看过了") }, "\(rows)")
        #expect(rows.allSatisfy { $0["time"] as? String == "刚刚" }, "\(rows)")
        #expect(first?["focused"] as? Bool == true, "打开时光标在搜索框里")
        #expect(first?["byWords"] as? [String] == [b], "按聊过的话也搜得到")
        #expect(first?["empty"] as? String == "没有找到「没有这句话」")
        #expect(first?["walk"] as? [String] == [b, a, "search"], "\(first?["walk"] ?? "")")
        #expect(first?["closed"] as? Bool == true)

        // ⌘ 点按甲：在新窗口打开，这个窗口不换
        _ = try await harness.evaluate("""
            ui.expand("会话历史");
            await until(() => historyRows().length === 2);
            historyButton(id).dispatchEvent(new MouseEvent("click", { bubbles: true, metaKey: true }));
            return true;
        """, arguments: ["id": a])
        let second = try await harness.window(1)
        #expect(try await second.evaluate(MultiWindowTests.currentId) as? String == a)
        #expect(try await harness.evaluate(MultiWindowTests.currentId) as? String == b, "⌘ 点按不换这个窗口的稿子")

        // 甲开在第二个窗口里：在第一个窗口的历史里点它，跳到第二个窗口，这个窗口不换
        let jumped = try await harness.evaluate("""
            ui.expand("会话历史");
            await until(() => historyRows().length === 2);
            ui.click("周末去湖边", { within: historyList() });
            await until(() => document.getElementById("statusText").textContent.includes("另一个窗口"));
            return { current: (await mc.drafts.current()).id, status: document.getElementById("statusText").textContent };
        """) as? [String: Any]
        #expect(jumped?["current"] as? String == b)
        #expect(harness.shell.core.pages.last === second.shell, "开着甲的那个窗口到了前面")
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }

    @Test("顶上的标题就是稿子的标题：标题框里改了它跟着变；在这里改完按 ↩ 写回稿子，⌘Z 撤回；Esc 放弃；内置说明书的不能改")
    func sessionTitleIsDraftTitle() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "旧标题", markdown: "正文" });
            ui.click("AI 助手");
            const head = ui.find("会话标题");
            await until(() => head.value === "旧标题");
            // 在标题框里改：顶上跟着变
            const field = document.getElementById("titleInput");
            field.value = "标题框里改的";
            field.dispatchEvent(new Event("input", { bubbles: true }));
            await until(() => head.value === "标题框里改的");
            // 在顶上改，↩ 写回稿子
            head.focus();
            head.value = "在 AI 助手里改的";
            head.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
            await until(async () => (await mc.drafts.current()).title === "在 AI 助手里改的");
            const renamed = { field: field.value, focused: document.activeElement === head };
            await mc.drafts.undo();
            await until(async () => (await mc.drafts.current()).title === "标题框里改的");
            await until(() => head.value === "标题框里改的");
            // Esc：放弃，稿子不变
            head.focus();
            head.value = "不要了";
            head.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
            await wait(200);
            const cancelled = { head: head.value, title: (await mc.drafts.current()).title };
            const guide = (await mc.drafts.list()).find((item) => item.builtIn);
            await mc.drafts.open(guide.id);
            await until(() => head.disabled);
            return { renamed, cancelled, guide: head.value === guide.title };
        """) as? [String: Any]
        await harness.tearDown()

        let renamed = result?["renamed"] as? [String: Any]
        #expect(renamed?["field"] as? String == "在 AI 助手里改的", "标题框也换了")
        #expect(renamed?["focused"] as? Bool == false, "↩ 之后离开输入框")
        let cancelled = result?["cancelled"] as? [String: String]
        #expect(cancelled == ["head": "标题框里改的", "title": "标题框里改的"], "\(cancelled ?? [:])")
        #expect(result?["guide"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("指引按后端说：这篇选了 Codex 却没装时给 Codex 的安装与登录步骤，另一个后端能用时可以一键改用它；Codex 没登录时说 codex login")
    func guidesFollowBackend() async throws {
        let claude = try FakeClaude()
        defer { claude.remove() }
        let harness = ShellHarness(terminalPath: [claude.directory], onboarding: false)
        try await harness.load()
        let missing = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            ui.click("AI 助手");
            await until(() => ui.find("问 Claude") && !ui.find("问 Claude").disabled);
            await mc.ai.setBackend("codex");
            await until(() => ui.find("重新查找"));
            const guide = () => document.getElementById("aiGuide").textContent.replace(/\\s+/g, " ");
            await until(() => ui.find("改用 Claude Code"));
            const text = guide();
            ui.click("改用 Claude Code");
            await until(() => ui.find("问 Claude") && !ui.find("问 Claude").disabled);
            return { text, backend: (await mc.ai.history()).backend, hidden: document.getElementById("aiGuide").hidden };
        """) as? [String: Any]
        await harness.tearDown()
        let text = missing?["text"] as? String ?? ""
        #expect(text.contains("没有找到本机 Codex") && text.contains("npm install -g @openai/codex") && text.contains("which codex"), "\(text)")
        #expect(missing?["backend"] as? String == "claude" && missing?["hidden"] as? Bool == true)

        let codex = try FakeCodex()
        codex.logOut()
        defer { codex.remove() }
        let second = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await second.load()
        let login = try await second.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await mc.ai.setBackend("codex");
            ui.click("AI 助手");
            await until(() => ui.find("重新查找"));
            return { text: document.getElementById("aiGuide").textContent.replace(/\\s+/g, " "), status: await mc.ai.status({ backend: "codex" }) };
        """) as? [String: Any]
        await second.tearDown()
        let guide = login?["text"] as? String ?? ""
        #expect(guide.contains("Codex 还没有登录") && guide.contains("codex login"), "\(guide)")
        #expect((login?["status"] as? [String: Any])?["reason"] as? String == "login")
        #expect(harness.pageErrors == [] && second.pageErrors == [])
    }

    @Test("快捷命令：还没有对话时摊开在输入框上面；有了对话收成一行，「快捷命令」弹出两组，点一个就发、弹层收起；截图（浅色、深色）")
    func presetsCollapseOnceTalking() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["好了，改完了。"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "周末去湖边", markdown: "湖边散步，柳树发了新芽。" });
            await openAI();
            const spread = { chip: Boolean(ui.find("封面标题 5 选 1")), toggle: Boolean(ui.find("快捷命令")) };
            ask("帮我看看这篇");
            await until(() => finished(1));
            await until(() => document.getElementById("aiPresets").classList.contains("is-compact"));
            const compact = { chip: Boolean(ui.find("封面标题 5 选 1")), polish: Boolean(ui.find("一键润色全文")) };
            ui.click("快捷命令");
            await until(() => ui.find("去 AI 味"));
            const open = ui.find("快捷命令").getAttribute("aria-expanded");
            ui.click("去 AI 味");
            await until(async () => (await mc.ai.history()).messages.filter((message) => message.role === "user").length === 2);
            const closed = !document.getElementById("aiPresets").classList.contains("is-open");
            await until(() => finished(2));
            return { spread, compact, open, closed };
        """) as? [String: Any]
        #expect(result?["spread"] as? [String: Bool] == ["chip": true, "toggle": false], "\(result?["spread"] ?? "")")
        #expect(result?["compact"] as? [String: Bool] == ["chip": false, "polish": true], "\(result?["compact"] ?? "")")
        #expect(result?["open"] as? String == "true")
        #expect(result?["closed"] as? Bool == true)
        try await harness.screenshot("ai-panel-conversation", of: ".inspector")
        _ = try await harness.evaluate("ui.expand('会话历史'); await until(() => historyRows().length === 1); return true;")
        try await harness.screenshot("ai-history-light", of: ".inspector")
        harness.setAppearance(dark: true)
        _ = try await harness.evaluate("await new Promise((resolve) => setTimeout(resolve, 400)); return true;")
        try await harness.screenshot("ai-history-dark", of: ".inspector")
        _ = try await harness.evaluate("document.getElementById('aiHistory').open = false; await new Promise((resolve) => setTimeout(resolve, 300)); return true;")
        try await harness.screenshot("ai-panel-conversation-dark", of: ".inspector")
        _ = try await harness.evaluate("await mc.drafts.create({ title: '新的一篇', markdown: '还没聊过' }); await new Promise((resolve) => setTimeout(resolve, 400)); return true;")
        try await harness.screenshot("ai-panel-empty-dark", of: ".inspector")
        harness.setAppearance(dark: false)
        _ = try await harness.evaluate("await new Promise((resolve) => setTimeout(resolve, 400)); return true;")
        try await harness.screenshot("ai-panel-empty-light", of: ".inspector")
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }
}
