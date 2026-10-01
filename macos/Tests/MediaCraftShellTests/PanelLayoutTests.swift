import Foundation
import Testing

/// 编辑区宽度：拖分隔条、← → 微调、双击恢复，有上下限；记在本机，重新打开还是它；旧版记下的宽度搬过来一次。
@MainActor
struct PanelLayoutTests {
    static let helpers = """
        window.handle = () => document.querySelector('[role="separator"][aria-label="编辑区宽度"]');
        window.width = () => document.querySelector('[aria-label="编辑器"]').getBoundingClientRect().width;
        window.drag = (dx) => {
          const box = handle().getBoundingClientRect();
          const x = box.left + box.width / 2;
          const pointer = (type, clientX, target) => target.dispatchEvent(new PointerEvent(type, { clientX, clientY: 300, bubbles: true, pointerId: 1, button: 0 }));
          pointer("pointerdown", x, handle());
          pointer("pointermove", x + dx / 2, window);
          pointer("pointermove", x + dx, window);
          pointer("pointerup", x + dx, window);
        };
        window.key = (key, shiftKey = false) => handle().dispatchEvent(new KeyboardEvent("keydown", { key, shiftKey, bubbles: true, cancelable: true }));
        window.value = () => Number(handle().getAttribute("aria-valuenow"));
    """

    @Test("拖动、键盘与双击改编辑区宽度，收在 360–760 之间；宽度重新打开后还在")
    func resizeAndRemember() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const before = { value: value(), width: width() };
            drag(-60);
            const dragged = { value: value(), width: width() };
            key("ArrowRight");
            const right = value();
            key("ArrowLeft", true);
            const left = value();
            drag(-2000);
            const min = value();
            drag(3000);
            const max = value();
            handle().dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
            const reset = value();
            drag(-40);
            return { before, dragged, right, left, min, max, reset, saved: value() };
        """) as? [String: Any]
        try await harness.load()
        let reopened = try await harness.evaluate(Self.helpers + "return value();") as? Int
        await harness.tearDown()

        let before = result?["before"] as? [String: Double] ?? [:]
        let dragged = result?["dragged"] as? [String: Double] ?? [:]
        #expect(before["value"] == 500)
        #expect(dragged["value"] == 440)
        #expect((before["width"] ?? 0) - (dragged["width"] ?? 0) > 50, "编辑区真的变窄了")
        #expect(result?["right"] as? Int == 456)
        #expect(result?["left"] as? Int == 392)
        #expect(result?["min"] as? Int == 360)
        #expect(result?["max"] as? Int == 760)
        #expect(result?["reset"] as? Int == 500)
        #expect(result?["saved"] as? Int == 460)
        #expect(reopened == 460)
        #expect(harness.pageErrors == [])
    }

    @Test("删除确认框弹出时，编辑区的分隔线压在遮罩下面：分隔线那一点点到的是对话框，分隔线的 z-index 再高也一样")
    func dividerStaysUnderDialogs() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await window.mediacraft.drafts.create({ title: "要删的稿子", markdown: "正文" });
            ui.expand("稿件列表");
            const center = () => {
              const box = handle().getBoundingClientRect();
              return [box.left + box.width / 2, box.top + box.height / 2];
            };
            const hit = () => {
              const element = document.elementFromPoint(...center());
              return element === handle() ? "divider" : element?.closest(".modal") ? "dialog" : element?.className || "nothing";
            };
            const before = hit();
            ui.click("删除 要删的稿子");
            const shown = Boolean(ui.alert());
            const open = hit();
            // 就算分隔线自己的层级拔得很高，也出不了编辑区所在的那一层
            handle().style.zIndex = "9999";
            const raised = hit();
            handle().style.zIndex = "";
            ui.click("取消", { within: ui.alert() });
            return { before, shown, open, raised, after: hit() };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["before"] as? String == "divider", "没有对话框时点得到分隔线")
        #expect(result?["shown"] as? Bool == true, "删除确认框弹出来了")
        #expect(result?["open"] as? String == "dialog")
        #expect(result?["raised"] as? String == "dialog")
        #expect(result?["after"] as? String == "divider", "关上对话框后分隔线照常能拖")
        #expect(harness.pageErrors == [])
    }
}
