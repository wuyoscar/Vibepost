import Foundation
import Testing

/// AI 会话的健壮性：回答送不到时这一轮明说并结束、「本次会话都允许」只按 claude 给的范围放行、
/// 载入目录外与网上的配图由壳记账且只放行同一目录 / 同一站点、查找 claude 时登录 shell 出问题有总超时并说明原因、
/// 收尾不卡主线程、删稿子连 AI 的工作副本一起删。claude 换成假的（Fixtures/ai/fake-claude）。
@MainActor
struct AIRobustnessTests {
    static let helpers = AIToolsTests.helpers

    private static func tail(_ text: String) -> [String] {
        [StreamJSON.textStart(), StreamJSON.textDelta(text), StreamJSON.assistantText(text), StreamJSON.result(text)]
    }

    private static func toolText(_ fake: FakeClaude, call: Int, _ requestId: String) -> String {
        let response = (fake.response(call, requestId)?["response"] as? [String: Any])?["mcp_response"] as? [String: Any]
        let content = (response?["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    @Test("权限回答写不进 claude 的 stdin：壳回错误，这一轮以「权限回答没送到」结束、停掉进程，不一直挂着；这一轮结束后再回答是 delivered: false")
    func undeliveredAnswerEndsTheTurn() async throws {
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(), "#close-stdin",
            StreamJSON.permission("p1", tool: "Bash", input: ["command": "ls"], wait: false), "#hang",
        ])
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const draft = await mc.drafts.create({ markdown: "正文" });
            await openAI();
            const turn = mc.ai.send("列一下文件");
            await until(async () => (await mc.ai.history()).permissions.length);
            const { permissions: [request], messages } = await mc.ai.history();
            const turnId = messages.at(-1).turn;
            const answered = await mc.ai.answer(request.id, "allow").then(() => "送到了", (error) => error.message);
            const outcome = await Promise.race([turn, wait(10000).then(() => "一直挂着")]);
            await until(() => sendButton());
            const late = await MediaCraftNative.ai.respond(draft.id, turnId, {
              type: "control_response", response: { subtype: "success", request_id: "p1", response: {} },
            });
            const recorded = (await mc.ai.history()).messages.filter((message) => message.role === "permission").length;
            return { answered, outcome, end: shown().at(-1), recorded, late: late.delivered };
        """) as? [String: Any]
        let pid = (fake.calls().first?["pid"] as? NSNumber)?.int32Value ?? 0
        let gone = await FakeClaude.waitUntilGone(pid)
        await harness.tearDown()

        #expect((result?["answered"] as? String ?? "").contains("权限回答没送到 Claude"), "回答的调用明说没送到")
        let outcome = result?["outcome"] as? [String: Any]
        #expect(outcome?["state"] as? String == "error", "这一轮结束了，不一直挂着：\(String(describing: result?["outcome"]))")
        #expect((outcome?["error"] as? String ?? "").contains("权限回答没送到 Claude"))
        #expect((result?["end"] as? [String])?.last?.contains("权限回答没送到") == true, "对话结尾说明原因")
        #expect(result?["recorded"] as? Int == 0, "没送到的回答不记成「已允许」")
        #expect(result?["late"] as? Bool == false, "这一轮结束后再回答：delivered 为 false")
        #expect(pid > 0 && gone, "claude 进程被停掉")
        #expect(harness.pageErrors == [])
    }

    @Test("claude 没给「以后不再问」的建议：确认框不提供「本次会话都允许」，answer 选它时 reject，不退而放行整个工具")
    func sessionAllowNeedsSuggestions() async throws {
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(),
            StreamJSON.permission("p1", tool: "WebFetch", input: ["url": "https://example.com"], suggest: false),
            StreamJSON.permission("p2", tool: "Bash", input: ["command": "ls"]),
        ] + Self.tail("好"))
        try fake.script(StreamJSON.reply(["好"]), call: 2)
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            ask("看看这个网页");
            await until(() => sheetView().detail === "https://example.com");
            const withoutScope = {
              hidden: document.getElementById("aiAllowSessionBtn").hidden,
              findable: Boolean(ui.find("本次会话都允许", { within: sheet() })),
            };
            const [request] = (await mc.ai.history()).permissions;
            const refused = await mc.ai.answer(request.id, "session").then(() => "放行了", (error) => error.message);
            const stillAsking = (await mc.ai.history()).permissions.map((item) => item.id);
            ui.click("允许", { within: sheet() });
            await until(() => sheetView().detail === "ls");
            const withScope = !document.getElementById("aiAllowSessionBtn").hidden;
            ui.click("允许", { within: sheet() });
            await until(() => finished(1));
            ask("再来");
            await until(() => finished(2));
            return { withoutScope, refused, stillAsking, withScope };
        """) as? [String: Any]
        await harness.tearDown()

        let withoutScope = result?["withoutScope"] as? [String: Bool]
        #expect(withoutScope == ["hidden": true, "findable": false], "没有建议时不提供「本次会话都允许」")
        #expect((result?["refused"] as? String ?? "").contains("没有可以放行的范围"))
        #expect(result?["stillAsking"] as? [String] == ["p1"], "选不了时请求还在，等你允许或拒绝")
        #expect(result?["withScope"] as? Bool == true, "有建议的请求照常提供")
        let p1 = fake.response(0, "p1")?["response"] as? [String: Any]
        #expect(p1?["behavior"] as? String == "allow")
        #expect(p1?["updatedPermissions"] == nil, "只允许这一次")
        let second = fake.calls().dropFirst().first?["argv"] as? [String] ?? []
        let allowed = second.firstIndex(of: "--allowedTools").map { Array(second[($0 + 1)...].prefix { !$0.hasPrefix("-") }) }
        #expect(allowed == ["mcp__mediacraft"], "下一轮没有放行整个 WebFetch")
        #expect(harness.pageErrors == [])
    }

    @Test("载入目录外、网上的配图：同意由壳记账，页面自己说「同意了」不算；「本次会话都允许」只放行同一目录，别的目录照样问；网上的图每批都问")
    func candidateApprovalsAreScopedAndVerified() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let first = fake.directory.appendingPathComponent("甲目录")
        let second = fake.directory.appendingPathComponent("乙目录")
        for directory in [first, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let one = first.appendingPathComponent("一.png")
        let two = first.appendingPathComponent("二.png")
        let three = second.appendingPathComponent("三.png")
        let four = second.appendingPathComponent("四.png")
        for (index, file) in [one, two, three, four].enumerated() {
            try AIToolsTests.writePNG(file, width: 200 + index * 10, height: 150, red: 0.2, green: 0.5, blue: 0.7)
        }
        let propose = { (requestId: String, sources: [String]) in
            StreamJSON.toolCall(requestId, "propose_images", ["images": sources.map { ["source": $0] }])
        }
        try fake.script([StreamJSON.initEvent(), propose("c1", [one.path, "https://example.invalid/甲.png"])] + Self.tail("一"), call: 1)
        try fake.script([StreamJSON.initEvent(), propose("c2", [two.path, "https://example.invalid/乙.png"])] + Self.tail("二"), call: 2)
        try fake.script(
            [StreamJSON.initEvent(), "#wait-file forged", propose("c3", [three.path, "https://other.invalid/丙.png"])] + Self.tail("三"),
            call: 3
        )
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let before = try await harness.evaluate(Self.helpers + """
            window.draft = await mc.drafts.create({ markdown: "正文" });
            await openAI();
            ask("配图");
            await until(() => sheetView().shown);
            const asked = { detail: sheetView().detail, scope: document.getElementById("aiAllowSessionBtn").title };
            ui.click("本次会话都允许", { within: sheet() });
            await until(() => finished(1));
            ask("再配一张");
            // 同一目录的不再问；网上的图每批都问，也不提供「本次会话都允许」
            await until(() => sheetView().shown);
            const again = { detail: sheetView().detail, session: !document.getElementById("aiAllowSessionBtn").hidden };
            ui.click("允许", { within: sheet() });
            await until(() => finished(2));
            ask("换个地方找");
            // 页面自己说同意了：旧的 approved、伪造的凭据、别的图的凭据，壳都不认
            const turnId = await until(async () => (await mc.ai.history()).running && (await mc.ai.history()).messages.at(-1).turn);
            const bridge = MediaCraftNative.ai;
            await until(() => bridge.workFile(draft.id, turnId).then(() => true, () => false)); // 壳里这一轮已经跑起来
            const flagged = await bridge.candidate(draft.id, turnId, three, { approved: true });
            const forged = await bridge.candidate(draft.id, turnId, three, { approval: crypto.randomUUID() });
            const borrowed = await bridge.candidate(draft.id, turnId, four, { approval: forged.approval });
            return { asked, again, forgedAsks: [flagged, forged, borrowed].map((reply) => reply.needsApproval === true && !reply.id) };
        """, arguments: ["three": three.path, "four": four.path]) as? [String: Any]
        fake.release("forged")
        let after = try await harness.evaluate("""
            await until(() => sheetView().shown);
            const asked = sheetView().detail;
            ui.click("拒绝", { within: sheet() });
            await until(() => finished(3));
            const { messages } = await mc.ai.history();
            const turns = [...new Set(messages.map((message) => message.turn))];
            return {
              asked,
              answers: turns.map((turn) => messages.filter((message) => message.turn === turn && message.role === "permission").map((message) => message.decision)),
              candidates: messages.filter((message) => message.role === "candidates").map((message) => message.images.map((image) => image.name)),
            };
        """) as? [String: Any]
        let stored = (try? FileManager.default.contentsOfDirectory(atPath: harness.aiRoot.appendingPathComponent(".candidates").path)) ?? []
        await harness.tearDown()

        let asked = before?["asked"] as? [String: String]
        #expect(asked?["detail"] == [one.path, "https://example.invalid/甲.png"].joined(separator: "\n"))
        let scope = asked?["scope"] ?? ""
        #expect(scope.contains("目录 ") && scope.contains("甲目录") && !scope.contains("网站"), "按钮只放行这个目录，不放行网站：\(scope)")
        let again = before?["again"] as? [String: Any]
        #expect(again?["detail"] as? String == "https://example.invalid/乙.png", "同一目录的不再问，网上的图照样问")
        #expect(again?["session"] as? Bool == false, "网上的图不提供「本次会话都允许」")
        #expect(before?["forgedAsks"] as? [Bool] == [true, true, true], "页面说「同意了」、伪造或挪用凭据都不读")
        #expect(Self.toolText(fake, call: 0, "c1").hasPrefix("已把 1 张图"), "同意之后读了目录外的图")
        let secondText = Self.toolText(fake, call: 1, "c2")
        #expect(secondText.hasPrefix("已把 1 张图"), "同一目录不再问")
        #expect(secondText.contains("example.invalid/乙.png") && !secondText.contains("没有同意"), "问过、同意了才去下载（下载本身失败）：\(secondText)")
        #expect(after?["asked"] as? String == [three.path, "https://other.invalid/丙.png"].joined(separator: "\n"), "别的目录、别的站点照样问")
        #expect(after?["answers"] as? [[String]] == [["session"], ["allow"], ["deny"]])
        #expect(after?["candidates"] as? [[String]] == [["一.png"], ["二.png"]])
        #expect(Self.toolText(fake, call: 2, "c3").contains("用户没有同意载入"))
        #expect(stored.count == 1, "候选只存了同意过的那一篇")
        #expect(harness.pageErrors == [])
    }

    @Test("删稿子时一并删掉它的 AI 工作副本与配图候选，别的稿子的不动；Claude Code 自己的会话记录不删；删除确认框说明这一点")
    func deletingDraftRemovesItsWorkingCopy() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        try fake.script([StreamJSON.initEvent(), StreamJSON.toolCall("c1", "propose_images", ["images": [["source": "本地.png"]]])] + Self.tail("放好了"), call: 2)
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let ids = try await harness.evaluate(Self.helpers + """
            const kept = await mc.drafts.create({ title: "留下的", markdown: "留下的" });
            await mc.ai.send("你好");
            const doomed = await mc.drafts.create({ title: "要删的", markdown: "要删的" });
            return [kept.id, doomed.id];
        """) as? [String] ?? []
        try #require(ids.count == 2)
        let workingCopy = harness.aiRoot.appendingPathComponent(ids[1])
        try FileManager.default.createDirectory(at: workingCopy, withIntermediateDirectories: true)
        try AIToolsTests.writePNG(workingCopy.appendingPathComponent("本地.png"), width: 120, height: 90, red: 0.8, green: 0.3, blue: 0.2)
        let result = try await harness.evaluate("""
            await mc.ai.send("配张图");
            const proposed = (await mc.ai.history()).messages.some((message) => message.role === "candidates");
            ui.expand("稿件列表");
            ui.click("删除 要删的");
            await until(() => ui.alert());
            const message = ui.alert().textContent.replace(/\\s+/g, " ");
            ui.click("删除", { within: ui.alert() });
            await until(async () => !(await mc.drafts.list()).some((draft) => draft.id === doomed));
            await until(() => document.querySelector('[role="status"]').textContent.startsWith("已删除"));
            return { proposed, message, status: document.querySelector('[role="status"]').textContent };
        """, arguments: ["doomed": ids[1]]) as? [String: Any]
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        let candidates = harness.aiRoot.appendingPathComponent(".candidates")
        let state = [
            exists(workingCopy), exists(candidates.appendingPathComponent(ids[1])),
            exists(harness.aiRoot.appendingPathComponent(ids[0]).appendingPathComponent("draft.md")),
        ]
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: fake.directory.appendingPathComponent("sessions").path)) ?? []
        await harness.tearDown()

        #expect(result?["proposed"] as? Bool == true, "删之前有工作副本与配图候选")
        let message = result?["message"] as? String ?? ""
        #expect(message.contains("AI 的工作副本") && message.contains("Claude Code、Codex 自己的会话记录不在此列"), "\(message)")
        #expect(result?["status"] as? String == "已删除：要删的")
        #expect(state == [false, false, true], "删掉这篇的工作副本与候选，别的稿子的留着")
        #expect(sessions.count == 2, "Claude Code 那边的会话（假 claude 记在 sessions/）不动")
        #expect(harness.pageErrors == [])
    }

    @Test("查找 claude：登录 shell 卡住时有总超时，到时结束它和它启动的所有进程，原因写进 status.error；登录 shell 出错退出时也说明")
    func loginShellFailuresAreBoundedAndExplained() async throws {
        let marks = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: marks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: marks) }
        // 起一个占着输出的子进程，再一直等它：只杀登录 shell 本身的话，输出永远读不完
        let hanging = "#!/bin/sh\necho $$ > '\(marks.path)/shell.pid'\nsleep 300 &\necho $! > '\(marks.path)/child.pid'\nwait\n"
        let status = """
            const started = Date.now();
            const status = await Promise.race([
              window.mediacraft.ai.status(),
              new Promise((resolve) => setTimeout(() => resolve({ error: "一直等着" }), 20000)),
            ]);
            return { error: status.error, available: status.available, seconds: (Date.now() - started) / 1000 };
        """
        let stuck = ShellHarness(onboarding: false, loginShell: hanging, shellTimeout: .seconds(2))
        try await stuck.load()
        let timedOut = try await stuck.evaluate(status) as? [String: Any]
        let pids = ["shell.pid", "child.pid"].compactMap {
            (try? String(contentsOf: marks.appendingPathComponent($0), encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        var gone: [Bool] = []
        for pid in pids { gone.append(await FakeClaude.waitUntilGone(pid, timeout: .seconds(3))) }
        await stuck.tearDown()

        let broken = ShellHarness(onboarding: false, loginShell: "#!/bin/sh\necho '.zshrc 第 3 行出错' >&2\nexit 3\n")
        try await broken.load()
        let failed = try await broken.evaluate(status) as? [String: Any]
        await broken.tearDown()

        let error = timedOut?["error"] as? String ?? ""
        #expect(timedOut?["available"] as? Bool == false)
        #expect(error.contains("在终端的 PATH 里没有找到 claude") && error.contains("登录 shell") && error.contains("2 秒"), "\(error)")
        #expect((timedOut?["seconds"] as? Double ?? 99) < 8, "有总超时，不一直等")
        #expect(pids.count == 2 && gone == [true, true], "登录 shell 与它启动的进程都结束了")
        let reason = failed?["error"] as? String ?? ""
        #expect(reason.contains("退出码 3") && reason.contains(".zshrc 第 3 行出错"), "\(reason)")
        #expect(stuck.pageErrors == [] && broken.pageErrors == [])
    }

    @Test("收尾不卡主线程：shutdown 立即返回，不听 SIGTERM 的 claude 约 1.5 秒后被 SIGKILL，都退出后才回调")
    func shutdownDoesNotBlockTheMainThread() async throws {
        let fake = try FakeClaude(script: ["#ignore-sigterm", StreamJSON.initEvent(), StreamJSON.textStart(), StreamJSON.textDelta("等着"), "#hang"])
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            void mc.ai.send("一直等着");
            await until(async () => (await mc.ai.history()).messages.some((message) => message.text === "等着"));
        """)
        let pid = (fake.calls().first?["pid"] as? NSNumber)?.int32Value ?? 0
        let clock = ContinuousClock()
        let stamp = Stamp()
        let start = clock.now
        harness.shell.shutdown { stamp.at = clock.now }
        let returned = start.duration(to: clock.now)
        let deadline = clock.now + .seconds(6)
        while stamp.at == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let goneAtCompletion = pid > 0 && kill(pid, 0) != 0
        let signals = fake.calls().first?["signals"] as? [String]
        await harness.tearDown()

        #expect(returned < .milliseconds(200), "shutdown 立即返回：\(returned)")
        let completed = try #require(stamp.at)
        #expect(start.duration(to: completed) > .seconds(1), "等到 SIGKILL 之后才回调")
        #expect(goneAtCompletion, "回调时进程已经没了")
        #expect(signals == ["TERM"], "先 SIGTERM（不听），再 SIGKILL")
    }
}

/// 在主线程上记下回调的时刻
@MainActor
private final class Stamp {
    var at: ContinuousClock.Instant?
}
