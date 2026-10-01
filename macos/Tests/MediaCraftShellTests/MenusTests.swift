import Testing

/// 下拉菜单（details.pop-menu）的共同行为：窗口缩放时开着的菜单要挪回窗口里，不能报错。
@MainActor
struct MenusTests {
    @Test("窗口缩放时开着的下拉菜单挪回窗口里，页面不报错")
    func openMenuStaysInsideWindowOnResize() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate("""
            const menu = [...document.querySelectorAll("details.pop-menu")].find((item) => item.querySelector(".pop-menu-panel"));
            menu.open = true;
            await new Promise((resolve) => setTimeout(resolve, 50)); // 屏幕外的测试窗口不跑 requestAnimationFrame
            const panel = menu.querySelector(".pop-menu-panel");
            // 把弹出层推到窗口右边外面，再发一次 resize：应该挪回来
            panel.style.left = `${window.innerWidth}px`;
            window.dispatchEvent(new Event("resize"));
            await new Promise((resolve) => setTimeout(resolve, 50)); // 屏幕外的测试窗口不跑 requestAnimationFrame
            const rect = panel.getBoundingClientRect();
            return { inside: rect.right <= window.innerWidth, open: menu.open };
        """) as? [String: Bool]
        await harness.tearDown()

        #expect(result?["open"] == true)
        #expect(result?["inside"] == true, "开着的菜单挪回窗口里")
        #expect(harness.pageErrors == [])
    }
}
