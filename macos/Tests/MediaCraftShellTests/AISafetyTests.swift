import Foundation
import Testing
@testable import MediaCraftShell

/// AI 会话的数据与安全（v4/05）：删稿子等进程真正退出、取消正在下载的配图再删，删完不再有东西写回来；
/// 配图下载的重定向逐跳校验、主机名指向本机 / 局域网时不载入、放行范围按站点的结构比较；
/// 停不下这一轮时说清楚并结束；查找 claude 时进程组号不会落到别人头上；SIGPIPE 由壳自己忽略。
/// claude 换成假的（Fixtures/ai/fake-claude），网上的图片换成本机的 HTTP 服务（LocalHTTPServer）。
@MainActor
@Suite(.serialized)
struct AISafetyTests {
    static let helpers = AIToolsTests.helpers

    private static func tail(_ text: String) -> [String] {
        [StreamJSON.textStart(), StreamJSON.textDelta(text), StreamJSON.assistantText(text), StreamJSON.result(text)]
    }

    private static func toolText(_ fake: FakeClaude, call: Int, _ requestId: String) -> String {
        let response = (fake.response(call, requestId)?["response"] as? [String: Any])?["mcp_response"] as? [String: Any]
        let content = (response?["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func propose(_ requestId: String, _ sources: [String], wait: Bool = true) -> String {
        StreamJSON.control(requestId, [
            "subtype": "mcp_message", "server_name": "mediacraft",
            "message": ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
                "name": "propose_images", "arguments": ["images": sources.map { ["source": $0] }],
            ]],
        ], wait: wait)
    }

    private static func png(width: Int = 64, height: Int = 48) throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try AIToolsTests.writePNG(file, width: width, height: height, red: 0.3, green: 0.6, blue: 0.4)
        return try Data(contentsOf: file)
    }

    @Test("删稿子：claude 还在往工作副本里写、配图还在下载时，先停下它们再删——删完工作副本与 .candidates 都不会再出现")
    func removingWaitsForWritersToStop() async throws {
        let server = try LocalHTTPServer()
        defer { server.stop() }
        server.route("/slow.png", .init(headers: ["Content-Type": "image/png"], body: try Self.png(width: 400, height: 300), trickle: (20, 0.1)))
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(), "#ignore-sigint", Self.propose("c1", ["\(server.base)/slow.png"], wait: false), "#keep-writing 4",
        ] + Self.tail("好"))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let draftId = try await harness.evaluate(Self.helpers + """
            const draft = await mc.drafts.create({ title: "要删的", markdown: "正文" });
            await openAI();
            ask("配张图");
            await until(() => sheetView().shown);
            ui.click("允许", { within: sheet() });
            return draft.id;
        """) as? String ?? ""
        let deadline = ContinuousClock.now + .seconds(10)
        while !server.requests.contains("/slow.png"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let removed = try await harness.evaluate("""
            await mc.drafts.remove(draftId);
            return (await mc.drafts.list()).some((draft) => draft.id === draftId);
        """, arguments: ["draftId": draftId]) as? Bool
        let workingCopy = harness.aiRoot.appendingPathComponent(draftId)
        let candidates = harness.aiRoot.appendingPathComponent(".candidates").appendingPathComponent(draftId)
        let exists = { FileManager.default.fileExists(atPath: workingCopy.path) || FileManager.default.fileExists(atPath: candidates.path) }
        let rightAfter = exists()
        // 慢慢下载的图约 2 秒下完，假 claude 不停手的话还要写好几秒：等过这段再看
        try await Task.sleep(for: .seconds(2.5))
        let later = exists()
        let pid = (fake.calls().first?["pid"] as? NSNumber)?.int32Value ?? 0
        let gone = await FakeClaude.waitUntilGone(pid)
        await harness.tearDown()

        #expect(server.requests.contains("/slow.png"), "删的时候配图正在下载")
        #expect(removed == false, "稿子删掉了")
        #expect(rightAfter == false, "删完工作副本与配图候选都不在")
        #expect(later == false, "之后也没有被正在写的 claude、正在下载的配图写回来")
        #expect(pid > 0 && gone, "claude 进程停掉了")
        #expect(harness.pageErrors == [])
    }

    @Test("配图下载的重定向逐跳校验：同站点照跟；跳到别的站点先停下、再问一次（确认框写明跳去哪），同意了才下载那边的；主机名指向本机的不载入")
    func redirectsAreCheckedHopByHop() async throws {
        let other = try LocalHTTPServer()
        defer { other.stop() }
        other.route("/b.png", .init(headers: ["Content-Type": "image/png"], body: try Self.png(width: 90, height: 60)))
        let site = try LocalHTTPServer()
        defer { site.stop() }
        site.route("/a.png", .init(headers: ["Content-Type": "image/png"], body: try Self.png(width: 80, height: 60)))
        site.route("/same", .init(status: 302, headers: ["Location": "/a.png"]))
        site.route("/hop", .init(status: 302, headers: ["Location": "\(other.base)/b.png"]))
        // 2130706433 就是 127.0.0.1：换个写法指向本机，用户在确认框里看不出来
        let disguised = "http://2130706433:\(site.port)/a.png"
        let fake = try FakeClaude()
        try fake.script([StreamJSON.initEvent(), Self.propose("c1", ["\(site.base)/same"])] + Self.tail("一"), call: 1)
        try fake.script([StreamJSON.initEvent(), Self.propose("c2", ["\(site.base)/hop"])] + Self.tail("二"), call: 2)
        try fake.script([StreamJSON.initEvent(), Self.propose("c3", [disguised])] + Self.tail("三"), call: 3)
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            const asked = [];
            const answer = async (count, button) => {
              while (!(await finished(count))) {
                if (sheetView().shown) {
                  asked.push(sheetView().detail);
                  ui.click(button, { within: sheet() });
                  await until(() => !sheetView().shown || !asked.includes(sheetView().detail));
                }
                await wait(50);
              }
            };
            ask("同站点");
            await answer(1, "允许");
            ask("跳到别的站点");
            await answer(2, "允许");
            ask("换个写法");
            await answer(3, "允许");
            const { messages } = await mc.ai.history();
            return {
              asked,
              candidates: messages.filter((message) => message.role === "candidates").map((message) => message.images.map((image) => `${image.width}x${image.height}`)),
            };
        """) as? [String: Any]
        await harness.tearDown()

        let asked = result?["asked"] as? [String] ?? []
        #expect(asked == [
            "\(site.base)/same",
            "\(site.base)/hop",
            "\(site.base)/hop → \(other.base)/b.png",
            disguised,
        ], "同站点的重定向不再问；跳到别的站点再问一次，写明跳去哪：\(asked)")
        #expect(result?["candidates"] as? [[String]] == [["80x60"], ["90x60"]], "同意了才载入")
        #expect(site.requests.filter { $0 == "/a.png" }.count == 1, "指向本机的写法没有去读：\(site.requests)")
        #expect(other.requests == ["/b.png"], "第二次同意之前没有去读别的站点")
        #expect(Self.toolText(fake, call: 2, "c3").contains("指向本机或局域网地址"), Comment(rawValue: Self.toolText(fake, call: 2, "c3")))
        #expect(harness.pageErrors == [])
    }

    @Test("防提示词注入：网上的图每批都问、不提供「本次会话都允许」（页面硬要也不行），同一站点换个写法下一批照样问；带一长串编码的网址在确认框里点名；超过 2048 字的网址不载入")
    func remoteImagesAskEveryBatch() async throws {
        let fake = try FakeClaude()
        let encoded = "https://example.invalid/p.png?d=" + String(repeating: "c3NoLXJzYSBBQUFB", count: 4)
        let tooLong = "https://example.invalid/" + String(repeating: "a", count: 2100) + ".png"
        try fake.script([StreamJSON.initEvent(), Self.propose("c1", ["https://example.invalid/甲.png", encoded])] + Self.tail("一"), call: 1)
        try fake.script([StreamJSON.initEvent(), Self.propose("c2", ["HTTPS://EXAMPLE.invalid:443/乙.png", tooLong])] + Self.tail("二"), call: 2)
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            ask("配图");
            await until(() => sheetView().shown);
            const first = { detail: sheetView().detail, note: sheetView().note, session: !document.getElementById("aiAllowSessionBtn").hidden };
            const [request] = (await mc.ai.history()).permissions;
            const forced = await mc.ai.answer(request.id, "session").then(() => "answered", (error) => error.message);
            ui.click("允许", { within: sheet() });
            await until(() => finished(1));
            ask("再配一张");
            await until(() => sheetView().shown);
            const second = { detail: sheetView().detail, session: !document.getElementById("aiAllowSessionBtn").hidden };
            ui.click("拒绝", { within: sheet() });
            await until(() => finished(2));
            return { first, forced, second };
        """) as? [String: Any]
        await harness.tearDown()

        let first = result?["first"] as? [String: Any]
        #expect(first?["detail"] as? String == ["https://example.invalid/甲.png", encoded].joined(separator: "\n"), "确认框写出每个网址")
        #expect(first?["session"] as? Bool == false, "网上的图不提供「本次会话都允许」")
        let note = first?["note"] as? String ?? ""
        #expect(note.contains("example.invalid") && note.contains("一长串编码"), "带编码的网址单独点名：\(note)")
        #expect((result?["forced"] as? String ?? "").contains("没有可以放行的范围"), "页面硬要「本次会话都允许」也不行")
        let second = result?["second"] as? [String: Any]
        #expect(second?["detail"] as? String == "HTTPS://EXAMPLE.invalid:443/乙.png", "同一站点下一批照样问；太长的网址不问、直接不载入")
        #expect(second?["session"] as? Bool == false)
        let secondText = Self.toolText(fake, call: 1, "c2")
        #expect(secondText.contains("网址太长") && secondText.contains("用户没有同意载入"), "\(secondText)")
        #expect(harness.pageErrors == [])
    }

    @Test("回答没送到、壳连停都停不下时：不再一直等，原因记进这一轮并结束它")
    func failedCancelEndsTheTurn() async throws {
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(), "#close-stdin",
            StreamJSON.permission("p1", tool: "Bash", input: ["command": "ls"], wait: false), "#hang",
        ])
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            MediaCraftNative.ai.cancel = () => Promise.reject(new Error("壳没回应"));
            const turn = mc.ai.send("列一下文件");
            await until(async () => (await mc.ai.history()).permissions.length);
            const [request] = (await mc.ai.history()).permissions;
            await mc.ai.answer(request.id, "allow").catch(() => undefined);
            const outcome = await Promise.race([turn, wait(8000).then(() => "一直挂着")]);
            return { outcome, end: shown().at(-1) };
        """) as? [String: Any]
        await harness.tearDown()

        let outcome = result?["outcome"] as? [String: Any]
        #expect(outcome?["state"] as? String == "error", "这一轮结束了，不一直挂着：\(String(describing: result?["outcome"]))")
        let error = outcome?["error"] as? String ?? ""
        #expect(error.contains("权限回答没送到 Claude") && error.contains("停止这一轮也没成功（壳没回应）"), "\(error)")
        #expect((result?["end"] as? [String])?.last?.contains("停止这一轮也没成功") == true, "对话结尾说明原因")
        #expect(harness.pageErrors == [])
    }

    @Test("查找 claude：登录 shell 退出了、它起的进程还占着输出时，到超时前它的进程号一直留着（没回收），对进程组发的 SIGKILL 只落在这一组上")
    func loginShellGroupStaysReserved() async throws {
        let marks = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: marks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: marks) }
        let script = "#!/bin/sh\necho $$ > '\(marks.path)/shell.pid'\nsleep 300 &\necho $! > '\(marks.path)/child.pid'\nexit 0\n"
        let harness = ShellHarness(onboarding: false, loginShell: script, shellTimeout: .seconds(3))
        try await harness.load()
        _ = try await harness.evaluate("window.statusCall = window.mediacraft.ai.status(); return true;")
        let read = { (name: String) -> Int32? in
            (try? String(contentsOf: marks.appendingPathComponent(name), encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while read("child.pid") == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .seconds(1)) // 登录 shell 早就退出了，还没到超时
        let shell = read("shell.pid") ?? 0
        let child = read("child.pid") ?? 0
        let reserved = shell > 0 && kill(shell, 0) == 0
        _ = try await harness.evaluate("await window.statusCall; return true;")
        let childGone = await FakeClaude.waitUntilGone(child, timeout: .seconds(3))
        let shellGone = await FakeClaude.waitUntilGone(shell, timeout: .seconds(3))
        await harness.tearDown()

        #expect(reserved, "登录 shell 退出后还没回收：组号仍是这次启动的")
        #expect(child > 0 && childGone, "超时时它起的进程随整组结束")
        #expect(shellGone, "结束后回收了")
        #expect(harness.pageErrors == [])
    }

    @Test("壳一建好就忽略 SIGPIPE（往已经退出的 claude 写字只得到 EPIPE），不靠 App 与测试各自设置")
    func shellIgnoresBrokenPipes() async throws {
        let harness = ShellHarness(onboarding: false)
        var action = sigaction()
        sigaction(SIGPIPE, nil, &action)
        await harness.tearDown()
        #expect(unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self))
    }
}
