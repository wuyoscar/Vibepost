import AppKit
import Foundation
import Testing

/// 保存：改动后不等出图就自动存（停手约 0.4 秒）；顶栏的保存按钮显示这篇存好了没有，点它或 ⌘S 马上存；
/// 没存上时说原因、能重试；窗口的「有改动」小圆点跟着变；退出、关窗、重新载入前壳让页面存完，刚打的字不丢。
@MainActor
struct SaveTests {
    static let helpers = StorageScripts.read + """
        window.mc = window.mediacraft;
        window.wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        window.until = async (condition, timeout = 8000) => {
          const deadline = Date.now() + timeout;
          while (Date.now() < deadline) {
            const value = await condition();
            if (value) return value;
            await wait(20);
          }
          throw new Error(`等不到：${condition}`);
        };
        window.body = () => document.querySelector('[role="textbox"][aria-label="正文"]');
        window.saveButton = () => ui.find("保存");
        window.storedMarkdown = async () => (await readStore("drafts", (await mc.drafts.current()).id))?.markdown;
        // 像键盘打字一样接在正文末尾
        window.typeAtEnd = async (text) => {
          const before = (await mc.drafts.current()).markdown;
          body().focus();
          await mc.editor.select(before.length);
          document.execCommand("insertText", false, text);
        };
        window.pressCmdS = () => {
          const event = new KeyboardEvent("keydown", { key: "s", metaKey: true, bubbles: true, cancelable: true });
          (document.activeElement || document.body).dispatchEvent(event);
          return event.defaultPrevented;
        };
    """

    @Test("打字后按钮先是「保存中」，停手一会儿自动存好变「已保存」（悬停看得到时间）；出图失败时照样存进去")
    func savesWithoutWaitingForRender() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "第一行" });
            const opened = { label: saveButton().textContent.trim(), state: saveButton().dataset.state, hidden: saveButton().hidden };
            // 模拟出图一直失败：改动照样要存进去
            window.MediaCraftRender.cards = () => Promise.reject(new Error("模拟出图失败"));
            const states = [];
            mc.on("save-state", ({ status }) => states.push(status));
            await typeAtEnd("，第二句");
            await until(() => saveButton().dataset.state === "pending", 2000);
            const typing = { label: saveButton().textContent.trim(), state: saveButton().dataset.state };
            await until(async () => (await storedMarkdown()) === "第一行，第二句");
            await until(() => saveButton().dataset.state === "saved");
            return {
              opened, typing, states, after: saveButton().textContent.trim(), title: saveButton().title,
              api: await mc.drafts.saveState(),
            };
        """) as? [String: Any]
        try await harness.screenshot("save-button-saved", of: ".titlebar-leading")
        await harness.tearDown()

        #expect(result?["opened"] as? [String: AnyHashable] == ["label": "已保存", "state": "saved", "hidden": false])
        #expect(result?["typing"] as? [String: String] == ["label": "保存中", "state": "pending"])
        let states = result?["states"] as? [String] ?? []
        #expect(states.first == "pending" && states.contains("saving") && states.last == "saved", "\(states)")
        #expect(result?["after"] as? String == "已保存")
        let title = result?["title"] as? String ?? ""
        #expect(title.hasPrefix("已保存（") && title.contains("⌘S"), "\(title)")
        let api = result?["api"] as? [String: Any] ?? [:]
        #expect(api["status"] as? String == "saved")
        #expect((api["savedAt"] as? Double ?? 0) > 0)
    }

    @Test("⌘S 与点保存按钮马上存（不等自动存），对勾跳一下；内置说明书不存，按钮藏起来，⌘S 也不弹「存储网页」")
    func saveNowFromButtonAndShortcut() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "开头" });
            await typeAtEnd("一");
            const prevented = pressCmdS();
            await until(() => saveButton().classList.contains("is-confirmed"), 1500);
            const byShortcut = await storedMarkdown();
            await typeAtEnd("二");
            ui.click("保存");
            await until(() => saveButton().classList.contains("is-confirmed") && saveButton().dataset.state === "saved", 1500);
            const byButton = await storedMarkdown();
            const guide = (await mc.drafts.list()).find((item) => item.builtIn);
            await mc.drafts.open(guide.id);
            const onGuide = { hidden: document.querySelector("#saveButton").hidden, prevented: pressCmdS(), state: (await mc.drafts.saveState()).status };
            return { prevented, byShortcut, byButton, onGuide };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["prevented"] as? Bool == true)
        #expect(result?["byShortcut"] as? String == "开头一")
        #expect(result?["byButton"] as? String == "开头一二")
        #expect(result?["onGuide"] as? [String: AnyHashable] == ["hidden": true, "prevented": true, "state": "none"])
    }

    @Test("存不进本机时按钮变「没存上」并说原因，改动不丢；好了以后点一下重写进去")
    func showsFailureAndRetries() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "稿子" });
            const store = window.MediaCraftDrafts.store;
            const write = store.write;
            // 模拟本机存储写不进去
            store.write = () => Promise.reject(new Error("磁盘满了"));
            await typeAtEnd("，后来加的");
            await until(() => saveButton().dataset.state === "error");
            const failed = { label: saveButton().textContent.trim(), title: saveButton().title, stored: await storedMarkdown() };
            let rejected = null;
            await mc.drafts.saveNow().catch((error) => { rejected = error.message; });
            store.write = write;
            ui.click("保存");
            await until(async () => saveButton().dataset.state === "saved" && (await storedMarkdown()) === "稿子，后来加的");
            return { failed, rejected, after: saveButton().textContent.trim() };
        """) as? [String: Any]
        await harness.tearDown()

        let failed = result?["failed"] as? [String: String] ?? [:]
        #expect(failed["label"] == "没存上")
        #expect(failed["title"]?.contains("磁盘满了") == true, "\(failed)")
        #expect(failed["stored"] == "稿子", "没写进去的时候存储里还是原来的")
        #expect((result?["rejected"] as? String)?.contains("磁盘满了") == true)
        #expect(result?["after"] as? String == "已保存")
    }

    @Test("窗口的「有改动」小圆点：有没存的时候亮，存好了灭")
    func windowShowsEditedDot() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "稿子" });
            await until(() => saveButton().dataset.state === "saved");
            // 存得慢一点，看得到「有改动」
            const store = window.MediaCraftDrafts.store;
            const write = store.write;
            store.write = async (changes) => { await wait(1500); return write(changes); };
            await typeAtEnd("，改一下");
        """)
        var lit = false
        for _ in 0..<100 where !lit {
            lit = harness.webView.window?.isDocumentEdited == true
            if !lit { try await Task.sleep(for: .milliseconds(20)) }
        }
        _ = try await harness.evaluate(Self.helpers + "await until(() => saveButton().dataset.state === 'saved');")
        var off = false
        for _ in 0..<100 where !off {
            off = harness.webView.window?.isDocumentEdited == false
            if !off { try await Task.sleep(for: .milliseconds(20)) }
        }
        await harness.tearDown()

        #expect(lit, "有没存的改动时关闭按钮上有小圆点")
        #expect(off, "存好了小圆点消失")
    }

    @Test("退出 / 关窗前壳让页面马上存完；⌘R 重新载入前也先存：刚打的字（还没到自动存的时候）不丢")
    func shellFlushesBeforeLeaving() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "开头" });
            await until(() => saveButton().dataset.state === "saved");
            await typeAtEnd("，退出前打的");
        """)
        let saved = await harness.shell.saveDrafts()
        try await harness.load()
        let afterQuit = try await harness.evaluate(Self.helpers + "return (await mc.drafts.current()).markdown;") as? String

        _ = try await harness.evaluate(Self.helpers + "await typeAtEnd('，重新载入前打的');")
        try await harness.shell.reload()
        _ = try await harness.evaluate(ShellHarness.startedScript)
        let afterReload = try await harness.evaluate(Self.helpers + "return (await mc.drafts.current()).markdown;") as? String
        await harness.tearDown()

        #expect(saved)
        #expect(afterQuit == "开头，退出前打的")
        #expect(afterReload == "开头，退出前打的，重新载入前打的")
    }
}
