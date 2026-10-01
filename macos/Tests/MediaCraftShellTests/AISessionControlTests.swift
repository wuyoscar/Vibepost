import Foundation
import Testing

/// AI 会话（四）：模型、新会话与这一轮说完之后。claude 启动时关掉后台任务；说完（result）之后关上 stdin、有上限地等它退出；
/// 之后它还发来的权限请求送不到，面板里明说并结束这一轮，不让它一路失败下去。模型每篇各选、默认沿用上次选的；
/// 「新会话」清空这篇的会话记录、下一轮用新的会话 id。claude 换成假的（Fixtures/ai/fake-claude）。
@MainActor
struct AISessionControlTests {
    static let helpers = AIToolsTests.helpers

    private static func argv(_ fake: FakeClaude, _ index: Int) -> [String] {
        let calls = fake.calls()
        return index < calls.count ? calls[index]["argv"] as? [String] ?? [] : []
    }

    @Test("后台任务回归：claude 启动时关掉后台任务；说完之后还发来的权限请求送不到——不弹确认框，面板明说原因，这一轮结束、进程停掉")
    func lateControlRequestAfterResult() async throws {
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(),
            StreamJSON.toolUse("Bash", ["command": "uv run generate.py -p 猫", "run_in_background": true]),
            StreamJSON.assistantText("图片在后台生成，好了告诉你。"),
            StreamJSON.result("图片在后台生成，好了告诉你。"),
            "#await-eof",
            StreamJSON.permission("late", tool: "Bash", input: ["command": "which uv"], wait: false),
            "#hang",
        ])
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            const outcome = await Promise.race([mc.ai.send("配一张猫的图"), wait(10000).then(() => "一直挂着")]);
            await until(() => sendButton());
            return { outcome, sheet: sheetView().shown, end: shown().at(-1), pending: (await mc.ai.history()).permissions.length };
        """) as? [String: Any]
        let call = fake.calls().first ?? [:]
        let pid = (call["pid"] as? NSNumber)?.int32Value ?? 0
        let gone = await FakeClaude.waitUntilGone(pid)
        await harness.tearDown()

        #expect(call["disableBackgroundTasks"] as? String == "1", "启动 claude 时关掉后台任务")
        let outcome = result?["outcome"] as? [String: Any]
        #expect(outcome?["state"] as? String == "error", "这一轮结束了，不一直挂着：\(String(describing: result?["outcome"]))")
        let error = outcome?["error"] as? String ?? ""
        #expect(error.contains("说完之后") && error.contains("运行命令") && error.contains("which uv"), "\(error)")
        #expect((result?["end"] as? [String])?.last?.contains("说完之后") == true, "对话结尾说明原因")
        #expect(result?["sheet"] as? Bool == false, "送不到的请求不弹确认框")
        #expect(result?["pending"] as? Int == 0)
        #expect(pid > 0 && gone, "claude 进程被停掉")
        #expect(harness.pageErrors == [])
    }

    @Test("模型：每篇各选，启动时传 --model（默认不传）；没选过的新稿子沿用上次选的；自定义 ID 检查格式；状态行显示 claude 报的实际模型；重新打开还在")
    func modelChoicePerDraft() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["好"]))
        try fake.script([StreamJSON.initEvent(model: "claude-haiku-4-5")] + Array(StreamJSON.reply(["好"]).dropFirst()), call: 2)
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            window.select = () => ui.find("模型");
            window.pick = async (value) => {
              select().value = value;
              select().dispatchEvent(new Event("change", { bubbles: true }));
            };
            window.typeModel = (text) => {
              const input = ui.find("模型 ID");
              input.value = text;
              input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
            };
            const a = await mc.drafts.create({ title: "甲", markdown: "甲" });
            await openAI();
            const initial = { select: select().value, model: await mc.ai.model() };
            ask("一");
            await until(() => finished(1));
            const afterDefault = statusLine();
            await pick("haiku");
            await until(async () => (await mc.ai.model()).model === "haiku");
            ask("二");
            await until(() => finished(2));
            const afterHaiku = statusLine();
            await pick("custom");
            const customShown = Boolean(ui.find("模型 ID")) && document.activeElement === ui.find("模型 ID");
            typeModel("claude sonnet");
            const spaced = await until(() => document.querySelector("#aiModelError:not([hidden])")?.textContent);
            const dashed = await mc.ai.setModel("--dangerously-skip-permissions").then(() => "收下了", (error) => `${error.name}：${error.message}`);
            typeModel("claude-sonnet-4-6");
            await until(async () => (await mc.ai.model()).model === "claude-sonnet-4-6");
            const b = await mc.drafts.create({ title: "乙", markdown: "乙" });
            await until(() => select().value === "claude-sonnet-4-6" && select().selectedOptions[0].textContent === "claude-sonnet-4-6" && !ui.find("模型 ID"));
            const inherited = await mc.ai.model();
            await pick("default");
            await until(async () => (await mc.ai.model()).model === null);
            ask("三");
            await until(() => finished(1));
            await mc.drafts.open(a.id);
            await until(() => select().value === "claude-sonnet-4-6");
            const kept = await mc.ai.model();
            ask("四");
            await until(() => finished(3));
            const bridge = await MediaCraftNative.ai.send({
              turnId: "x", draftId: a.id, sessionId: crypto.randomUUID(), prompt: "hi", markdown: "", model: "-p",
            }).then(() => "启动了", (error) => error.message);
            return { initial, afterDefault, afterHaiku, customShown, spaced, dashed, inherited, kept, bridge, a: a.id };
        """) as? [String: Any]
        try await harness.screenshot("model-selector", of: "#aiPanel")
        try await harness.load()
        let reopened = try await harness.evaluate(Self.helpers + """
            await mc.drafts.open(a);
            return await mc.ai.model();
        """, arguments: ["a": result?["a"] as? String ?? ""]) as? [String: Any]
        await harness.tearDown()

        let models = (0..<5).map { FakeClaude.option("--model", in: fake.calls().indices.contains($0) ? fake.calls()[$0] : [:]) }
        #expect(models == [nil, "haiku", nil, "claude-sonnet-4-6", nil], "\(models)")
        let initial = result?["initial"] as? [String: Any]
        #expect(initial?["select"] as? String == "default")
        let initialModel = initial?["model"] as? [String: Any]
        #expect(initialModel?["backend"] as? String == "claude" && initialModel?["model"] is NSNull && initialModel?["used"] is NSNull, "\(initialModel ?? [:])")
        #expect(result?["afterDefault"] as? String == "本机 Claude Code 9.9.9 · 已连接 · claude-opus-4-6", "状态行显示实际模型")
        #expect(result?["afterHaiku"] as? String == "本机 Claude Code 9.9.9 · 已连接 · claude-haiku-4-5")
        #expect(result?["customShown"] as? Bool == true, "选「自定义…」出现模型 ID 输入框并聚焦")
        #expect((result?["spaced"] as? String ?? "").contains("不能有空格"), "\(String(describing: result?["spaced"]))")
        #expect((result?["dashed"] as? String ?? "").hasPrefix("TypeError：模型 ID 不对"), "\(String(describing: result?["dashed"]))")
        #expect((result?["inherited"] as? [String: Any])?["model"] as? String == "claude-sonnet-4-6", "新稿子沿用上次选的")
        let kept = result?["kept"] as? [String: Any]
        #expect(kept?["model"] as? String == "claude-sonnet-4-6", "乙改成默认不影响甲")
        #expect(kept?["used"] as? String == "claude-haiku-4-5", "甲最近一轮实际用的模型")
        #expect((result?["bridge"] as? String ?? "").contains("模型 ID 不对"), "壳也拒绝会被当成选项的模型")
        #expect(reopened?["model"] as? String == "claude-sonnet-4-6", "重新打开 App 还在")
        #expect(harness.pageErrors == [])
    }

    @Test("重新开始这篇的对话：问一次；正在跑的一轮先停，还没确认的修改丢掉，会话记录清空，下一轮用新的 --session-id、从编辑器重新写工作副本；版本保留")
    func newSessionStartsOver() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["好"]))
        try fake.script([StreamJSON.initEvent(), #"#edit ["draft.md", "甲", "乙"]"#] + Array(StreamJSON.reply(["改好了"]).dropFirst()), call: 2)
        try fake.script([StreamJSON.initEvent(), StreamJSON.textStart(), StreamJSON.textDelta("想一想"), "#hang"], call: 3)
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let draftId = try await harness.evaluate(Self.helpers + """
            const draft = await mc.drafts.create({ title: "标题", markdown: "甲" });
            await openAI();
            const disabledWhenEmpty = ui.find("重新开始").disabled;
            ask("你好");
            await until(() => finished(1));
            ask("把甲改成乙");
            await until(async () => (await mc.ai.review.get()).open);
            ui.click("重新开始");
            await until(() => ui.alert());
            window.disabledWhenEmpty = disabledWhenEmpty;
            return draft.id;
        """) as? String ?? ""
        try await harness.screenshot("new-session-confirm")
        let workingCopy = harness.aiRoot.appendingPathComponent(draftId)
        let copyBefore = FileManager.default.fileExists(atPath: workingCopy.path)
        let result = try await harness.evaluate("""
            const message = ui.alert().textContent.replace(/\\s+/g, " ");
            ui.click("取消", { within: ui.alert() });
            const kept = (await mc.ai.history()).messages.length;
            ui.click("重新开始");
            await until(() => ui.alert());
            ui.click("重新开始", { within: ui.alert() });
            await until(async () => (await mc.ai.history()).messages.length === 0);
            const cleared = { history: await mc.ai.history(), review: (await mc.ai.review.get()).open, markdown: (await mc.drafts.current()).markdown,
                              shown: shown().length, button: ui.find("重新开始").disabled };
            ask("想很久");
            await until(() => shown().some(([kind, text]) => kind === "assistant" && text === "想一想"));
            const stopped = await mc.ai.newSession();
            ask("重新来");
            await until(() => finished(1));
            return { disabledWhenEmpty, message, kept, cleared, stopped: { running: stopped.running, messages: stopped.messages.length },
                     versions: (await mc.ai.versions.list()).length, roles: (await mc.ai.history()).messages.map((item) => item.role) };
        """) as? [String: Any]
        let copyAfterClear = FileManager.default.fileExists(atPath: workingCopy.appendingPathComponent("draft.md").path)
        let calls = fake.calls()
        await harness.tearDown()

        #expect(result?["disabledWhenEmpty"] as? Bool == true, "没有会话记录时不用重新开始")
        let message = result?["message"] as? String ?? ""
        #expect(message.contains("清空这篇稿子的 AI 会话记录") && message.contains("版本都保留"), "\(message)")
        #expect((result?["kept"] as? Int ?? 0) > 0, "取消就什么都不动")
        let cleared = result?["cleared"] as? [String: Any]
        let history = cleared?["history"] as? [String: Any]
        #expect(history?["sessionId"] is NSNull && (history?["messages"] as? [Any])?.isEmpty == true)
        #expect(cleared?["review"] as? Bool == false, "还没确认的修改丢掉")
        #expect(cleared?["markdown"] as? String == "甲", "丢掉的修改没进正文")
        #expect(cleared?["shown"] as? Int == 0 && cleared?["button"] as? Bool == true)
        #expect(copyBefore, "清空之前有工作副本")
        let stopped = result?["stopped"] as? [String: Any]
        #expect(stopped?["running"] as? Bool == false && stopped?["messages"] as? Int == 0, "正在跑的一轮先停再清空")
        #expect(result?["versions"] as? Int == 4, "每轮之前存的版本都保留")
        #expect(result?["roles"] as? [String] == ["user", "assistant", "end"])
        try #require(calls.count == 4)
        let first = FakeClaude.option("--session-id", in: calls[0])
        #expect(FakeClaude.option("--resume", in: calls[1]) == first)
        let fresh = [calls[2], calls[3]].map { FakeClaude.option("--session-id", in: $0) }
        #expect(fresh.allSatisfy { $0 != nil && $0 != first } && fresh[0] != fresh[1], "新会话用新的 --session-id：\(fresh)")
        #expect(copyAfterClear, "下一轮从编辑器重新写入工作副本")
        #expect(harness.pageErrors == [])
    }

    @Test("说完之后关上 stdin，claude 还不退出（有东西占着它）：有上限地等（测试里 2 秒），到时 SIGTERM 结束它，这一轮照常算说完")
    func lingeringProcessIsTerminated() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["好了"]) + ["#await-eof", "#hang"])
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let started = ContinuousClock.now
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            return await Promise.race([mc.ai.send("你好"), wait(15000).then(() => ({ state: "一直挂着" }))]);
        """) as? [String: Any]
        let elapsed = started.duration(to: .now)
        let call = fake.calls().first ?? [:]
        await harness.tearDown()

        #expect(result?["state"] as? String == "done", "\(String(describing: result))")
        #expect(call["stdinClosed"] as? Bool == true, "说完就关上 stdin")
        #expect(call["signals"] as? [String] == ["TERM"], "过了上限才结束它")
        #expect(elapsed > .seconds(2) && elapsed < .seconds(10), "\(elapsed)")
        #expect(harness.pageErrors == [])
    }
}
