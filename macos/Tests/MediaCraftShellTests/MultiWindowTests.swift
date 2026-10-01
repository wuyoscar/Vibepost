import Foundation
import Testing
@testable import MediaCraftShell

/// 多窗口（v5 第 07 张票）：几个窗口共用一份 ShellCore（AI 进程、存储……），各开各的稿子、各改各存；页面要开新窗口经原生桥
/// （「新建窗口」、⌘ 点稿件、右键「在新窗口打开」）；AI 的一轮只推给发起它的窗口，别的窗口重新载入不打断它，关掉发起的窗口就结束它。
@MainActor
struct MultiWindowTests {
    static let helpers = AISessionTests.helpers + StorageScripts.read
    static let currentId = "return (await window.mediacraft.drafts.current()).id"

    @Test("两个窗口各开一篇、各改各存互不覆盖；「新建窗口」里是一篇新稿子，重新载入还是它；⌘ 点稿件、右键「在新窗口打开」都在新窗口打开那篇")
    func windowsKeepTheirOwnDrafts() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let first = try await harness.evaluate(Self.helpers + """
            const a = await mc.drafts.create({ title: "甲", markdown: "甲的正文" });
            const c = await mc.drafts.create({ title: "丙", markdown: "丙的正文" });
            const d = await mc.drafts.create({ title: "丁", markdown: "丁的正文" });
            await mc.drafts.open(a.id);
            await window.MediaCraftNative.windows.open({ fresh: true });
            return { a: a.id, c: c.id, d: d.id };
        """) as? [String: String]
        let a = try #require(first?["a"])
        let c = try #require(first?["c"])
        let d = try #require(first?["d"])
        let second = try await harness.window(1)
        let b = try #require(try await second.evaluate(Self.currentId) as? String)
        #expect(b != a && b != c, "新建窗口里是一篇新稿子")
        // 两个窗口交替改自己的那篇
        _ = try await second.evaluate("await window.mediacraft.drafts.update({ title: '乙', markdown: '乙的正文，第一次' }); return true;")
        _ = try await harness.evaluate("await mc.drafts.update({ markdown: '甲的正文，改过了' }); return true;")
        _ = try await second.evaluate("await window.mediacraft.drafts.update({ markdown: '乙的正文，第二次' }); return true;")
        _ = try await harness.evaluate("await mc.drafts.update({ title: '甲改名' }); return true;")
        let stored = try await harness.evaluate("""
            const records = await readStore("drafts");
            return Object.fromEntries(records.map((record) => [record.id, [record.title, record.markdown]]));
        """) as? [String: [String]]
        #expect(stored?[a] == ["甲改名", "甲的正文，改过了"])
        #expect(stored?[b] == ["乙", "乙的正文，第二次"], "另一个窗口没用旧的乙盖掉它")
        #expect(try await harness.evaluate(Self.currentId) as? String == a, "第一个窗口还是甲")
        try await second.reload()
        #expect(try await second.evaluate(Self.currentId) as? String == b, "「新建窗口」的窗口重新载入还是乙，不再新建一篇")

        // ⌘ 点稿件列表里的丙：新窗口里打开丙，这个窗口不换
        _ = try await harness.evaluate("""
            ui.expand("稿件列表");
            const row = await until(() => [...document.querySelectorAll(".draft-row")].find((row) => row.dataset.draftId === id));
            row.querySelector(".draft-row-open").dispatchEvent(new MouseEvent("click", { bubbles: true, metaKey: true }));
            return true;
        """, arguments: ["id": c])
        let third = try await harness.window(2)
        #expect(try await third.evaluate(Self.currentId) as? String == c)
        #expect(try await harness.evaluate(Self.currentId) as? String == a, "⌘ 点不换掉这个窗口的稿子")

        // 右键丁：菜单里有「在新窗口打开」与「删除…」，点前者
        let menu = try await harness.evaluate("""
            const row = [...document.querySelectorAll(".draft-row")].find((row) => row.dataset.draftId === id);
            row.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 60, clientY: 200 }));
            const menu = document.getElementById("draftMenu");
            const items = ui.all("", { within: menu }).map((item) => ui.name(item));
            const focused = ui.name(document.activeElement);
            ui.click("在新窗口打开", { within: menu });
            return { items, focused, hidden: menu.hidden };
        """, arguments: ["id": d]) as? [String: Any]
        #expect(menu?["items"] as? [String] == ["在新窗口打开 ⌘ 点按", "删除…"], "\(menu?["items"] ?? "")")
        #expect(menu?["focused"] as? String == "在新窗口打开 ⌘ 点按", "菜单开着时焦点在第一项")
        #expect(menu?["hidden"] as? Bool == true, "点了就收起")
        let fourth = try await harness.window(3)
        #expect(try await fourth.evaluate(Self.currentId) as? String == d)
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }

    @Test("AI 的一轮只推给发起它的窗口；别的窗口重新载入不打断它；关掉发起的窗口就结束它发起的那一轮，别的窗口照常")
    func aiTurnsBelongToTheirWindow() async throws {
        let fake = try FakeClaude(script: [StreamJSON.initEvent(), "#sleep 1.5"] + StreamJSON.reply(["好了"]))
        try fake.script([StreamJSON.initEvent(), "#hang"], call: 2)
        try fake.script([StreamJSON.initEvent()] + StreamJSON.reply(["还在"]), call: 3)
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + "await mc.drafts.create({ markdown: '甲' }); return true;")
        let second = try await harness.openWindow(WindowRequest(fresh: true))
        _ = try await second.evaluate("""
            window.heard = 0;
            window.addEventListener("mediacraft:native-ai", () => { window.heard += 1; });
            return true;
        """)
        _ = try await harness.evaluate("""
            window.heard = 0;
            window.addEventListener("mediacraft:native-ai", () => { window.heard += 1; });
            await openAI();
            ask("你好");
            await until(async () => (await mc.ai.history()).running);
            return true;
        """)
        let heard = try await second.evaluate("return window.heard") as? Int
        // 第一个窗口的这一轮还在跑（假的 claude 睡着），第二个窗口重新载入
        try await second.reload()
        let firstRun = try await harness.evaluate("""
            await until(() => finished(1));
            return { states: (await ends()).map((end) => end.state), heard: window.heard };
        """) as? [String: Any]
        #expect(heard == 0, "别的窗口收不到这一轮的事件")
        #expect((firstRun?["heard"] as? Int ?? 0) > 0)
        #expect(firstRun?["states"] as? [String] == ["done"], "别的窗口重新载入没打断它")

        // 第二个窗口发起一轮（一直不说完），然后关掉它：只结束它发起的这一轮
        _ = try await second.evaluate(Self.helpers + """
            await openAI();
            ask("你好");
            await until(async () => (await mc.ai.history()).running);
            return true;
        """)
        // 等假的 claude 真的起来了再关窗口
        let started = ContinuousClock.now + .seconds(10)
        while fake.calls().count < 2, ContinuousClock.now < started { try await Task.sleep(for: .milliseconds(50)) }
        await second.close()
        let deadline = ContinuousClock.now + .seconds(10)
        while fake.calls().count < 2 || (fake.calls()[1]["signals"] as? [String] ?? []).isEmpty {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect((fake.calls()[1]["signals"] as? [String] ?? []).contains("TERM"), "关掉窗口：它发起的那一轮先 SIGTERM")
        let after = try await harness.evaluate("""
            ask("还在吗");
            await until(() => finished(2));
            return (await ends()).map((end) => end.state);
        """) as? [String]
        #expect(after == ["done", "done"], "第一个窗口照常聊")
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }
    // MARK: - 第 08 张票：同一篇只在一个窗口里、窗口之间同步、恢复窗口

    @Test("同一篇只在一个窗口里：要开的那篇在别的窗口里开着（或那里的 AI 还在跑）时，那个窗口到前面并换到那篇，这个窗口不换；在新窗口打开它也一样")
    func oneDraftOneWindow() async throws {
        let fake = try FakeClaude(script: [StreamJSON.initEvent(), "#hang"])
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let a = try #require(try await harness.evaluate(Self.helpers + "return (await mc.drafts.create({ title: '甲', markdown: '甲' })).id;") as? String)
        let second = try await harness.openWindow(WindowRequest(fresh: true))
        let b = try #require(try await second.evaluate(Self.currentId) as? String)
        let refused = try await harness.evaluate("""
            await until(() => mc.drafts.list().then((list) => list.some((item) => item.id === id)));
            return await mc.drafts.open(id).then(() => "开了", (error) => error.message);
        """, arguments: ["id": b]) as? String
        #expect((refused ?? "").contains("在另一个窗口里开着"), "\(refused ?? "")")
        #expect(try await harness.evaluate(Self.currentId) as? String == a, "这个窗口不换")
        #expect(harness.shell.core.pages.last === second.shell, "开着它的那个窗口到了前面")

        // 第二个窗口里 AI 在跑乙，它换到新的一篇；这时在第一个窗口里开乙：第二个窗口换回乙
        _ = try await second.evaluate(Self.helpers + """
            await openAI();
            ask("你好");
            await until(async () => (await mc.ai.history()).running);
            await mc.drafts.create({ title: "丙", markdown: "丙" });
            return true;
        """)
        let c = try #require(try await second.evaluate(Self.currentId) as? String)
        let again = try await harness.evaluate("return await mc.drafts.open(id).then(() => '开了', (error) => error.message);", arguments: ["id": b]) as? String
        #expect((again ?? "").contains("在另一个窗口里开着"), "AI 还在跑的那篇也只在它的窗口里：\(again ?? "")")
        let backToB = try await second.evaluate("await until(async () => (await mc.drafts.current()).id === id); return true;", arguments: ["id": b]) as? Bool
        #expect(backToB == true && c != b, "第二个窗口换回了乙")
        // 在新窗口打开乙：不开新窗口，第二个窗口到前面
        let opened = try await harness.evaluate("return await window.MediaCraftNative.windows.open({ draftId: id });", arguments: ["id": b]) as? [String: Any]
        #expect(opened?["elsewhere"] as? Bool == true && harness.windows.count == 1)
        // 说明书只读，哪个窗口都能开
        let guide = try await second.evaluate("""
            const guide = (await mc.drafts.list()).find((item) => item.builtIn);
            await mc.drafts.open(guide.id);
            return (await mc.drafts.current()).id === guide.id;
        """) as? Bool
        #expect(guide == true)
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }

    @Test("窗口之间同步：新建、改标题、删除进各自的稿件列表；署名与我的配色跟过来，改了别的也不会把它们改回去；删掉的稿子正开在别的窗口时那个窗口换到另一篇，它也不会被写回来")
    func windowsStayInSync() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let a = try #require(try await harness.evaluate(Self.helpers + "return (await mc.drafts.create({ title: '甲', markdown: '甲' })).id;") as? String)
        let second = try await harness.openWindow(WindowRequest(fresh: true))
        let b = try #require(try await second.evaluate(Self.currentId) as? String)
        _ = try await second.evaluate(Self.helpers + "await mc.drafts.update({ title: '乙' }); return true;")
        let seesB = try await harness.evaluate("""
            await until(async () => (await mc.drafts.list()).some((item) => item.id === id && item.title === "乙"));
            ui.expand("稿件列表");
            return await until(() => [...document.querySelectorAll(".draft-row")].some((row) => row.dataset.draftId === id && row.textContent.includes("乙")));
        """, arguments: ["id": b]) as? Bool
        #expect(seesB == true, "另一个窗口新建、改名的稿子进了这个窗口的稿件列表")

        // 署名与我的配色
        _ = try await harness.evaluate("await mc.profile.update({ name: '新的署名' }); await mc.palettes.save('窗口一的配色'); return true;")
        let synced = try await second.evaluate("""
            await until(async () => (await mc.profile.get()).name === "新的署名");
            await until(async () => (await mc.palettes.list()).some((palette) => palette.name === "窗口一的配色"));
            await mc.drafts.update({ markdown: "乙改了正文" });
            return { name: (await mc.profile.get()).name };
        """) as? [String: Any]
        #expect(synced?["name"] as? String == "新的署名")
        let profile = try await harness.evaluate("return (await readStore('meta', 'profile')).name;") as? String
        #expect(profile == "新的署名", "第二个窗口存别的时没把旧署名写回去")

        // 在第一个窗口里删乙（正开在第二个窗口里）：第二个窗口换到另一篇，乙不会被写回来
        _ = try await harness.evaluate("await mc.drafts.remove(id); return true;", arguments: ["id": b])
        let moved = try await second.evaluate("""
            await until(async () => (await mc.drafts.current()).id !== id);
            await mc.drafts.update({ markdown: (await mc.drafts.current()).markdown + "。" }).catch(() => undefined);
            await new Promise((resolve) => setTimeout(resolve, 300));
            return { current: (await mc.drafts.current()).id, listed: (await mc.drafts.list()).some((item) => item.id === id), status: document.getElementById("statusText").textContent };
        """, arguments: ["id": b]) as? [String: Any]
        #expect(moved?["current"] as? String != b && moved?["listed"] as? Bool == false, "\(moved ?? [:])")
        #expect((moved?["status"] as? String ?? "").contains("在另一个窗口里删掉了"), "\(moved?["status"] ?? "")")
        #expect(moved?["current"] as? String != a, "换到的不是第一个窗口正开着的那篇")
        let stored = try await harness.evaluate("return (await readStore('drafts', id)) ?? null;", arguments: ["id": b])
        #expect(stored is NSNull, "删掉的乙没被第二个窗口写回来")
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }

    @Test("重开 App 恢复窗口：记下每个窗口开着的那篇与位置（关掉的窗口不记，退出时的不再改）；恢复时稿子已经不在的窗口关掉")
    func windowsAreRestored() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let ids = try await harness.evaluate(Self.helpers + """
            const c = await mc.drafts.create({ title: "丙", markdown: "丙" });
            const d = await mc.drafts.create({ title: "丁", markdown: "丁" });
            const a = await mc.drafts.create({ title: "甲", markdown: "甲" });
            return [a.id, c.id, d.id];
        """) as? [String] ?? []
        try #require(ids.count == 3)
        let (a, c, d) = (ids[0], ids[1], ids[2])
        let second = try await harness.openWindow(WindowRequest(draftId: c))
        let third = try await harness.openWindow(WindowRequest(draftId: d))
        _ = try await third.evaluate("return true;")
        let core = harness.shell.core
        let deadline = ContinuousClock.now + .seconds(10)
        while Set(core.savedWindows().map(\.draftId)) != [a, c, d], ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(Set(core.savedWindows().map(\.draftId)) == [a, c, d], "\(core.savedWindows())")
        #expect(core.savedWindows().allSatisfy { $0.frame?.count == 4 }, "位置大小一起记")
        await third.close()
        #expect(core.savedWindows().map(\.draftId).contains(d) == false, "关掉的窗口不再记")
        core.freezeSession()
        await second.close()
        #expect(core.savedWindows().map(\.draftId).contains(c), "退出时记下的不再改")

        // 照记录恢复：丙的窗口照常开；丁已经删了，它的窗口关掉
        _ = try await harness.evaluate("await mc.drafts.remove(id); return true;", arguments: ["id": d])
        let restored = try await harness.openWindow(WindowRequest(draftId: c))
        #expect(try await restored.evaluate(Self.currentId) as? String == c)
        let gone = try await harness.openWindow(WindowRequest(draftId: d))
        let closedBy = ContinuousClock.now + .seconds(10)
        while !gone.closed, ContinuousClock.now < closedBy { try await Task.sleep(for: .milliseconds(50)) }
        #expect(gone.closed, "要开的那篇已经不在了：还有别的窗口时关掉它")
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }

    @Test("窗口换了页面（重新载入）：换掉了的页面迟到的占用报告不算；新页面报来之前壳照旧替它占着正开着的那篇")
    func replacedPagesDoNotHoldDrafts() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let ids = try await harness.evaluate(Self.helpers + """
            const a = await mc.drafts.create({ title: "甲", markdown: "甲" });
            const c = await mc.drafts.create({ title: "丙", markdown: "丙" });
            await mc.drafts.open(a.id);
            return [a.id, c.id];
        """) as? [String] ?? []
        try #require(ids.count == 2)
        let c = ids[1]
        let second = try await harness.openWindow(WindowRequest(fresh: true))
        let b = try #require(try await second.evaluate(Self.currentId) as? String)
        let core = harness.shell.core
        // 第二个窗口的页面报过占用（页面 id 为 old-page），然后被换掉
        _ = try await second.evaluate("""
            await window.MediaCraftNative.windows.occupy({ current: b, drafts: [b], page: "old-page", sequence: 1 });
            return true;
        """, arguments: ["b": b])
        try await second.reload()
        #expect(try await second.evaluate(Self.currentId) as? String == b, "重新载入还是乙")
        // 旧页面迟到的一次报告（说它占着丙）：不算，第一个窗口照样开丙
        _ = await core.windowAction("occupy", ["current": b, "drafts": [b, c], "page": "old-page", "sequence": 2], from: second.shell.windowId)
        let opened = try await harness.evaluate("return await mc.drafts.open(id).then(() => '开了', (error) => error.message);", arguments: ["id": c]) as? String
        #expect(opened == "开了", "\(opened ?? "")")
        // 换页面的那一刻（新页面还没报来）：乙照旧是第二个窗口的，第一个窗口开不了
        core.pageReplaced(second.shell)
        let claim = await core.windowAction("claim", ["draftId": b, "focus": false], from: harness.shell.windowId)
        let reply = try JSONSerialization.jsonObject(with: claim.body) as? [String: Any]
        #expect(reply?["elsewhere"] as? Bool == true, "\(reply ?? [:])")
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }
}
