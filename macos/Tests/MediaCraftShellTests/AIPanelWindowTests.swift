import AppKit
import Foundation
import Testing

/// AI 助手顶上的「+」：新建一篇稿子，在新窗口里打开，一开就是 AI 助手；AI 设置是浮在窗口里的面板，
/// 窗口矮的时候不超出窗口下沿，内容多了在面板里面滚动。
@MainActor
struct AIPanelWindowTests {
    @Test("「+」：开一个新窗口，里面是一篇新稿子，检查器直接在 AI 助手；原来的窗口不换稿子")
    func plusOpensFreshWindowWithAI() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let before = try await harness.evaluate("""
            const mc = window.mediacraft;
            const draft = await mc.drafts.create({ markdown: "原来那篇" });
            ui.click("AI 助手");
            ui.click("新建一篇，在新窗口里和 AI 聊");
            return draft.id;
        """) as? String
        let opened = try await harness.window(1)
        let inNew = try await opened.evaluate("""
            const mc = window.mediacraft;
            const draft = await mc.drafts.current();
            return {
              markdown: draft.markdown, id: draft.id,
              aiSelected: document.querySelector("#aiTab").getAttribute("aria-selected"),
              aiHidden: document.querySelector("#aiPanel").hidden,
            };
        """) as? [String: Any]
        let stayed = try await harness.evaluate("return (await window.mediacraft.drafts.current()).id") as? String
        await harness.tearDown()

        #expect(inNew?["markdown"] as? String == "", "新窗口里是一篇新稿子")
        #expect(inNew?["id"] as? String != before)
        #expect(inNew?["aiSelected"] as? String == "true" && inNew?["aiHidden"] as? Bool == false, "一开就是 AI 助手")
        #expect(stayed == before, "原来的窗口不换稿子")
        #expect(harness.pageErrors == [])
    }

    @Test("AI 设置：窗口矮的时候面板不超出窗口下沿，内容多了在面板里面滚动")
    func settingsFitTheWindow() async throws {
        let harness = ShellHarness(onboarding: false)
        harness.webView.window?.setContentSize(NSSize(width: 1440, height: 560))
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create();
            ui.click("AI 助手");
            ui.expand("AI 设置");
            await new Promise((resolve) => setTimeout(resolve, 400));
            const panel = document.querySelector(".ai-settings-popover");
            const box = panel.getBoundingClientRect();
            return { bottom: box.bottom, height: innerHeight, scrolls: panel.scrollHeight > panel.clientHeight, overflow: getComputedStyle(panel).overflowY };
        """) as? [String: Any]
        await harness.tearDown()

        let bottom = result?["bottom"] as? Double ?? .infinity
        let height = result?["height"] as? Double ?? 0
        #expect(bottom <= height, "面板底边在窗口里：\(bottom) / \(height)")
        #expect(result?["scrolls"] as? Bool == true, "内容多了在面板里面滚动")
        #expect(result?["overflow"] as? String == "auto")
        #expect(harness.pageErrors == [])
    }
}
