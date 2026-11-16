import AppKit
import Foundation
import Testing

/// 给人看的走查截图：检查器「样式」各节与「AI 助手」在浅色、深色、最小窗口下的样子。
/// 只在设了 `MEDIACRAFT_SCREENSHOTS=<目录>` 时跑（存成 `walk-*.png`），不做断言之外的事；界面打磨前后各跑一遍就是对比图。
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEDIACRAFT_SCREENSHOTS"] != nil))
struct InspectorWalkthroughTests {
    static let helpers = AISessionTests.helpers + """
        window.pngFile = (name, color, width = 400, height = 300) => new Promise((resolve) => {
          const canvas = Object.assign(document.createElement("canvas"), { width, height });
          const context = canvas.getContext("2d");
          context.fillStyle = color;
          context.fillRect(0, 0, width, height);
          canvas.toBlob((blob) => resolve(new File([blob], name, { type: "image/png" })), "image/png");
        });
        window.settle = async (ms = 350) => { await mc.render.pages(); await wait(ms); };
        window.unfold = (open) => {
          for (const section of document.querySelectorAll("#stylePanel [data-fold]")) {
            const toggle = section.querySelector(".section-fold");
            if ((toggle.getAttribute("aria-expanded") === "true") !== open) toggle.click();
          }
        };
    """

    static let article = "# 周末去湖边\\n\\n早上七点出门，湖边的柳树发了新芽。\\n\\n## 带什么\\n\\n- 一壶热茶\\n- 折叠椅\\n- 充电宝\\n\\n> 风大，记得带外套。\\n\\n下午三点往回走，路上买了两斤草莓。"

    private func resize(_ harness: ShellHarness, _ width: CGFloat, _ height: CGFloat) async throws {
        harness.webView.window?.setContentSize(NSSize(width: width, height: height))
        _ = try await harness.evaluate("await new Promise((resolve) => setTimeout(resolve, 400)); return true;")
    }

    @Test("样式：默认开合、全部展开、配色库、色轮、字体列表；浅色与深色")
    func stylePanel() async throws {
        let harness = ShellHarness(onboarding: false, inspectorFolded: true)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "周末去湖边", markdown: "\(Self.article)" });
            const [photo] = await mc.media.import([await pngFile("湖边.png", "#2f9e44", 800, 600)]);
            await settle(1500);
            return true;
        """)
        for dark in [false, true] {
            let tone = dark ? "dark" : "light"
            harness.setAppearance(dark: dark)
            try await resize(harness, 1440, 960)
            _ = try await harness.evaluate("unfold(false); document.querySelector('[data-fold=layout] .section-fold').click(); document.querySelector('[data-fold=theme] .section-fold').click(); await settle(600); return true;")
            try await harness.screenshot("walk-style-default-\(tone)", of: ".inspector")
            _ = try await harness.evaluate("unfold(false); await settle(); return true;")
            try await harness.screenshot("walk-style-all-folded-\(tone)", of: ".inspector")
            // 全部展开：窗口拉得很高，一张图看全
            try await resize(harness, 1440, 2300)
            _ = try await harness.evaluate("""
                unfold(true);
                const cover = document.querySelector("#coverToggle");
                if (!cover.checked) cover.click();
                await settle(800);
                return true;
            """)
            try await harness.screenshot("walk-style-all-open-\(tone)", of: ".inspector")
            try await resize(harness, 1440, 960)
            _ = try await harness.evaluate("unfold(false); document.querySelector('[data-fold=colors] .section-fold').click(); await settle(); ui.expand('配色库'); await wait(900); return true;")
            try await harness.screenshot("walk-palette-library-\(tone)", of: ".inspector")
            _ = try await harness.evaluate("document.querySelector('#paletteLibrary').open = false; ui.expand('色轮'); await wait(1500); return true;")
            try await harness.screenshot("walk-color-wheel-\(tone)", of: ".inspector")
            _ = try await harness.evaluate("document.querySelector('#colorWheel').open = false; unfold(false); document.querySelector('[data-fold=font] .section-fold').click(); await settle(); document.querySelector('#zhFontInput').click(); await wait(500); return true;")
            try await harness.screenshot("walk-font-list-\(tone)", of: ".inspector")
            _ = try await harness.evaluate("document.querySelector('#zhFontInput').click(); await wait(200); return true;")
        }
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }

    @Test("最小窗口（Mac 1100 × 720、Windows 900 × 650）：样式默认开合、署名展开、AI 助手")
    func minimumWindows() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["好了，改完了。"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false, inspectorFolded: true)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "周末去湖边", markdown: "\(Self.article)" });
            await settle(1200);
            return true;
        """)
        for (width, height) in [(1100, 720), (900, 650)] {
            try await resize(harness, CGFloat(width), CGFloat(height))
            _ = try await harness.evaluate("ui.click('样式'); await settle(600); return true;")
            try await harness.screenshot("walk-min-\(width)-style")
            _ = try await harness.evaluate("unfold(true); await settle(); document.querySelector('#stylePanel').scrollTop = 1e6; await wait(300); return true;")
            try await harness.screenshot("walk-min-\(width)-style-bottom", of: ".inspector")
            _ = try await harness.evaluate("unfold(false); document.querySelector('[data-fold=layout] .section-fold').click(); document.querySelector('[data-fold=theme] .section-fold').click(); await openAI(); await wait(500); return true;")
            try await harness.screenshot("walk-min-\(width)-ai")
            _ = try await harness.evaluate("ui.expand('AI 设置'); await wait(600); return true;")
            try await harness.screenshot("walk-min-\(width)-ai-settings")
            _ = try await harness.evaluate("document.querySelector('#aiSettings').open = false; return true;")
        }
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }

    @Test("AI 助手：还没有对话、权限确认卡、有了对话、快捷命令弹出、AI 设置；浅色与深色")
    func aiPanel() async throws {
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(),
            StreamJSON.permission("p1", tool: "Bash", input: ["command": "ls -la ~/Desktop/素材", "description": "看看桌面上的素材文件夹"]),
        ] + StreamJSON.reply(["看过了，素材里有三张湖边的照片。\n\n我建议：\n\n1. 封面用第二张\n2. 正文按时间顺序排\n\n要我现在动手吗？"]).dropFirst())
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false, inspectorFolded: true)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "周末去湖边", markdown: "\(Self.article)" });
            await openAI();
            await wait(500);
            return true;
        """)
        try await harness.screenshot("walk-ai-empty-light", of: ".inspector")
        harness.setAppearance(dark: true)
        _ = try await harness.evaluate("await wait(400); return true;")
        try await harness.screenshot("walk-ai-empty-dark", of: ".inspector")
        _ = try await harness.evaluate("ask('帮我看看桌面上的素材，配到这篇里'); await until(() => ui.find('允许')); await wait(500); return true;")
        try await harness.screenshot("walk-ai-permission-dark", of: ".inspector")
        harness.setAppearance(dark: false)
        _ = try await harness.evaluate("await wait(400); return true;")
        try await harness.screenshot("walk-ai-permission-light", of: ".inspector")
        _ = try await harness.evaluate("ui.click('允许'); await until(() => finished(1)); await wait(500); return true;")
        try await harness.screenshot("walk-ai-talk-light", of: ".inspector")
        _ = try await harness.evaluate("ui.click('快捷命令'); await wait(500); return true;")
        try await harness.screenshot("walk-ai-presets-light", of: ".inspector")
        _ = try await harness.evaluate("ui.click('快捷命令'); ui.click('写作手册'); await wait(500); return true;")
        try await harness.screenshot("walk-ai-manual-picker-light", of: ".inspector")
        _ = try await harness.evaluate("ui.click('完成'); return true;")
        // AI 设置：窗口拉高，一张图看全
        try await resize(harness, 1440, 2000)
        _ = try await harness.evaluate("ui.expand('AI 设置'); await wait(700); return true;")
        try await harness.screenshot("walk-ai-settings-light", of: ".inspector")
        harness.setAppearance(dark: true)
        _ = try await harness.evaluate("await wait(400); return true;")
        try await harness.screenshot("walk-ai-settings-dark", of: ".inspector")
        try await resize(harness, 1440, 960)
        _ = try await harness.evaluate("document.querySelector('#aiSettings').open = false; await wait(300); return true;")
        try await harness.screenshot("walk-ai-talk-dark", of: ".inspector")
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }
}
