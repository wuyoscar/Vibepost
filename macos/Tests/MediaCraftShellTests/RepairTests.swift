import AppKit
import Foundation
import Testing
@testable import MediaCraftShell

/// 换显示器、唤醒之后的自愈（「第二天卡住，只显示中间」）：壳把网页重新挂上，确认页面能画出新的一帧；
/// 还是不行就先存稿、再重新载入这个窗口。屏幕外的测试窗口本来就不出新帧，正好当作「WebKit 还认着旧屏幕」；
/// 要「能画」的测试用页面脚本让下一帧照常来。
@MainActor
struct RepairTests {
    /// 显示器正常时：下一帧照常来（屏幕外的测试窗口自己不出帧）
    static let framesArrive = "window.requestAnimationFrame = (callback) => setTimeout(() => callback(performance.now()), 16);"

    static let helpers = """
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
        window.typeAtEnd = async (text) => {
          const before = (await mc.drafts.current()).markdown;
          document.querySelector('[role="textbox"][aria-label="正文"]').focus();
          await mc.editor.select(before.length);
          document.execCommand("insertText", false, text);
          await until(async () => (await mc.drafts.current()).markdown !== before);
        };
    """

    private func waitForRepair(_ harness: ShellHarness, timeout: Duration = .seconds(15)) async throws -> ShellWebView.Repair? {
        let deadline = ContinuousClock.now + timeout
        while harness.shell.lastRepair == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return harness.shell.lastRepair
    }

    @Test("显示器变了、页面还是画不出新的一帧：壳先存稿再重新载入这个窗口，回来还是那篇，刚打的字还在")
    func reloadsWhenStillNotPainting() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        harness.shell.isShown = { true }
        let id = try await harness.evaluate(Self.helpers + """
            const draft = await mc.drafts.create({ markdown: "开头" });
            window.samePage = true;
            await typeAtEnd("，换显示器前打的");
            return draft.id;
        """) as? String
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        let repair = try await waitForRepair(harness)
        _ = try await harness.evaluate(ShellHarness.startedScript)
        let after = try await harness.evaluate(Self.helpers + """
            const current = await mc.drafts.current();
            return { samePage: window.samePage === true, id: current.id, markdown: current.markdown };
        """) as? [String: AnyHashable]
        await harness.tearDown()

        #expect(repair == .reloaded)
        #expect(after?["samePage"] as? Bool == false, "重新载入了")
        #expect(after?["id"] as? String == id)
        #expect(after?["markdown"] as? String == "开头，换显示器前打的")
    }

    @Test("显示器变了：重新挂上网页后能画就不重新载入（页面、焦点照旧）；窗口自己换屏时先查，能画就什么都不动")
    func reattachesWithoutReloading() async throws {
        let harness = ShellHarness(onboarding: false, pageScripts: [Self.framesArrive])
        try await harness.load()
        harness.shell.isShown = { true }
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "开头" });
            window.samePage = true;
        """)
        let window = harness.webView.window
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        let afterDisplays = try await waitForRepair(harness)
        let attached = harness.webView.window === window && harness.webView.superview != nil
        harness.shell.lastRepair = nil
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        let afterScreen = try await waitForRepair(harness)
        let samePage = try await harness.evaluate("return window.samePage === true") as? Bool
        await harness.tearDown()

        #expect(afterDisplays == .reattached)
        #expect(attached, "网页还在原来的窗口里")
        #expect(afterScreen == .healthy)
        #expect(samePage == true, "没有重新载入")
    }

    @Test("窗口看不见时不查（看不见的页面本来就不出帧），回到前面再修")
    func defersWhileHidden() async throws {
        let harness = ShellHarness(onboarding: false, pageScripts: [Self.framesArrive])
        try await harness.load()
        harness.shell.isShown = { false }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        let hidden = try await waitForRepair(harness)
        harness.shell.lastRepair = nil
        harness.shell.isShown = { true }
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: harness.webView.window)
        let shown = try await waitForRepair(harness)
        await harness.tearDown()

        #expect(hidden == .deferred)
        #expect(shown == .reattached)
    }
}
