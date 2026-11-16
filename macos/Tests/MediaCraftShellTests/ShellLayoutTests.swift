import AppKit
import Foundation
import Testing
@testable import MediaCraftShell

/// 界面骨架：顶栏、稿件抽屉、编辑区、预览舞台、检查器；8 套皮肤令牌；原生毛玻璃外框。
@MainActor
struct ShellLayoutTests {
    static let helpers = """
        const mc = window.mediacraft;
        window.visible = (element) => Boolean(element) && element.getClientRects().length > 0 && getComputedStyle(element).visibility !== "hidden";
        window.region = (name) => document.querySelector(`[aria-label="${name}"]`);
        window.css = (element, property) => getComputedStyle(element).getPropertyValue(property).trim();
        window.center = (element) => {
          const box = element.getBoundingClientRect();
          return [box.left + box.width / 2, box.top + box.height / 2];
        };
    """

    @Test("布局：顶栏、编辑器、预览、检查器都在；看得见的控件都有名字，图标按钮也不例外")
    func regionsAndAccessibleNames() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# 标题\\n\\n第一段" });
            await mc.render.pages();
            const controls = [...document.querySelectorAll('button, summary, [role="button"], [role="tab"], input:not([type="hidden"]), textarea')]
              .filter(visible);
            return {
              regions: ["编辑器", "预览", "检查器", "文字样式", "排版模式"].filter((name) => visible(region(name))),
              toolbar: ["稿件列表", "主题：备忘", "手机预览", "AI", "批量下载", "发送到 iPhone", "图文卡片", "长文"].filter((name) => ui.find(name)),
              unnamed: controls.filter((element) => !ui.name(element)).map((element) => element.outerHTML.slice(0, 80)),
              iconOnly: controls.filter((element) => element.matches("button, summary") && !element.textContent.trim()).map(ui.name),
              phoneDisabled: ui.find("手机预览").disabled,
              phonePressed: ui.find("手机预览").getAttribute("aria-pressed"),
              heading: document.querySelector("h1")?.textContent,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["regions"] as? [String] == ["编辑器", "预览", "检查器", "文字样式", "排版模式"])
        #expect(result?["toolbar"] as? [String] == ["稿件列表", "主题：备忘", "手机预览", "AI", "批量下载", "发送到 iPhone", "图文卡片", "长文"])
        #expect(result?["unnamed"] as? [String] == [], "没有名字的控件")
        let iconOnly = Set(result?["iconOnly"] as? [String] ?? [])
        #expect(iconOnly.isSuperset(of: ["稿件列表", "上一张", "下一张"]), "只有图标的按钮也有名字：\(iconOnly)")
        #expect(result?["phoneDisabled"] as? Bool == false)
        #expect(result?["phonePressed"] as? String == "false", "手机预览是个开关按钮，默认关着")
        #expect(result?["heading"] as? String == "Vibepost")
        #expect(harness.pageErrors == [])
    }

    @Test("稿件抽屉：顶栏按钮开合（aria-expanded 跟着变），按名字搜索，搜不到时说一声")
    func draftsDrawerTogglesAndSearches() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "春天的书单", markdown: "书单正文" });
            await mc.drafts.create({ title: "夏天的菜单", markdown: "菜单正文" });
            const toggle = ui.find("稿件列表");
            const state = () => [toggle.getAttribute("aria-expanded"), visible(region("稿件")) ? "显示" : "隐藏"];
            const search = (text) => {
              const input = ui.find("搜索稿件");
              input.value = text;
              input.dispatchEvent(new Event("input", { bubbles: true }));
              return ["春天的书单", "夏天的菜单"].filter((title) => ui.find(title, { within: "稿件" }));
            };
            if (toggle.getAttribute("aria-expanded") === "true") toggle.click();
            const closed = state();
            toggle.click();
            const opened = state();
            const all = search("");
            const found = search("书单");
            const none = search("冬天");
            const notFound = visible([...region("稿件").querySelectorAll("p")].find((p) => p.textContent === "没有找到这篇稿件"));
            const cleared = search("");
            toggle.click();
            return { closed, opened, all, found, none, notFound, cleared, closedAgain: state() };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["closed"] as? [String] == ["false", "隐藏"])
        #expect(result?["opened"] as? [String] == ["true", "显示"])
        #expect(result?["all"] as? [String] == ["春天的书单", "夏天的菜单"])
        #expect(result?["found"] as? [String] == ["春天的书单"])
        #expect(result?["none"] as? [String] == [])
        #expect(result?["notFound"] as? Bool == true)
        #expect(result?["cleared"] as? [String] == ["春天的书单", "夏天的菜单"])
        #expect(result?["closedAgain"] as? [String] == ["false", "隐藏"])
        #expect(harness.pageErrors == [])
    }

    @Test("检查器：样式 / AI 助手两个标签，点击或左右键切换；顶栏 AI 按钮与标签同步；没找到 claude 时 AI 助手不可用")
    func inspectorTabsSwitch() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            const styleTab = ui.find("样式");
            const aiTab = ui.find("AI 助手");
            const panel = (tab) => document.getElementById(tab.getAttribute("aria-controls"));
            const state = () => ({
              selected: [styleTab, aiTab].filter((tab) => tab.getAttribute("aria-selected") === "true").map(ui.name),
              shown: [styleTab, aiTab].filter((tab) => visible(panel(tab))).map(ui.name),
              aiButton: ui.find("AI").getAttribute("aria-pressed"),
            });
            const steps = [state()];
            aiTab.click();
            steps.push(state());
            const placeholder = {
              polish: ui.find("一键润色全文").disabled,
              composer: ui.find("问 Claude").disabled,
            };
            styleTab.click();
            steps.push(state());
            styleTab.focus();
            styleTab.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
            steps.push({ ...state(), focus: ui.name(document.activeElement) });
            ui.click("AI");
            steps.push(state());
            ui.click("AI");
            steps.push(state());
            return { steps, placeholder };
        """) as? [String: Any]
        await harness.tearDown()

        let steps = result?["steps"] as? [[String: Any]] ?? []
        let selected = steps.map { $0["selected"] as? [String] ?? [] }
        #expect(selected == [["样式"], ["AI 助手"], ["样式"], ["AI 助手"], ["样式"], ["AI 助手"]])
        #expect(steps.map { $0["shown"] as? [String] ?? [] } == selected, "只显示选中标签的面板")
        #expect(steps.map { $0["aiButton"] as? String ?? "" } == ["false", "true", "false", "true", "false", "true"])
        #expect(steps.count > 3 && steps[3]["focus"] as? String == "AI 助手", "左右键切换并把焦点带过去")
        #expect(result?["placeholder"] as? [String: Bool] == ["polish": true, "composer": true])
        #expect(harness.pageErrors == [])
    }

    /// 两套界面皮肤的令牌：纸（编辑区）、玻璃（没有原生毛玻璃时是不透明的）、桌面（舞台）、主色、正文色、细线（半透明），以及深浅。
    static let skins: [String: [String: String]] = [
        "light": ["window": "#ffffff", "glass": "#ececf0", "stage": "#f0f0f3", "accent": "#0f62fe", "text": "#1c1c1e", "line": "rgba(0, 0, 0, 0.1)", "scheme": "light"],
        "dark": ["window": "#232326", "glass": "#1b1b1e", "stage": "#161618", "accent": "#78a9ff", "text": "#f5f5f7", "line": "rgba(255, 255, 255, 0.1)", "scheme": "dark"],
    ]

    static func rgb(_ hex: String) -> String {
        guard hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return hex }
        return "rgb(\(value >> 16 & 0xff), \(value >> 8 & 0xff), \(value & 0xff))"
    }

    @Test("界面皮肤：浅色、深色两套跟随系统外观（ADR 0007），界面各处跟着换；换卡片主题不改界面")
    func skinFollowsSystemAppearance() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let read = Self.helpers + """
            document.getAnimations().forEach((animation) => animation.finish());
            return {
              id: document.documentElement.dataset.uiTheme,
              window: css(region("编辑器"), "background-color"),
              glass: css(document.querySelector(".app"), "background-color"),
              chrome: [document.querySelector("header"), region("稿件"), region("检查器")].map((element) => css(element, "background-color")).join(" | "),
              stage: css(region("预览"), "background-color"),
              accent: css(ui.find("发送到 iPhone"), "background-color"),
              text: css(document.body, "color"),
              line: css(region("编辑器"), "border-right-color"),
              scheme: css(document.documentElement, "color-scheme"),
            };
        """
        _ = try await harness.evaluate("await window.mediacraft.drafts.create({ markdown: '正文' });")
        let light = try await harness.evaluate(read) as? [String: String]
        _ = try await harness.evaluate("await window.mediacraft.themes.apply('ink'); await window.mediacraft.render.pages();")
        let afterTheme = try await harness.evaluate(read) as? [String: String]
        harness.setAppearance(dark: true)
        try await waitUntilPage(harness, "document.documentElement.dataset.uiTheme === 'dark'")
        let dark = try await harness.evaluate(read) as? [String: String]
        harness.setAppearance(dark: false)
        try await waitUntilPage(harness, "document.documentElement.dataset.uiTheme === 'light'")
        await harness.tearDown()

        #expect(afterTheme == light, "换成纯黑主题，界面仍是浅色")
        for (id, skin) in [("light", light), ("dark", dark)] {
            let expected = Self.skins[id]!
            let skin = skin ?? [:]
            #expect(skin["id"] == id, "\(id)：<html data-ui-theme>")
            #expect(skin["window"] == Self.rgb(expected["window"]!), "\(id) 内容区")
            #expect(skin["glass"] == Self.rgb(expected["glass"]!), "\(id) 玻璃那一层（.app）")
            #expect(skin["chrome"] == "rgba(0, 0, 0, 0) | rgba(0, 0, 0, 0) | rgba(0, 0, 0, 0)", "\(id) 顶栏、稿件抽屉、检查器直接坐在玻璃上，自己不画底")
            #expect(skin["stage"] == Self.rgb(expected["stage"]!), "\(id) 舞台")
            #expect(skin["accent"] == Self.rgb(expected["accent"]!), "\(id) 主按钮")
            #expect(skin["text"] == Self.rgb(expected["text"]!), "\(id) 正文色")
            #expect(skin["line"] == expected["line"], "\(id) 分隔线")
            #expect(skin["scheme"] == expected["scheme"], "\(id) 深浅")
        }
        #expect(harness.pageErrors == [])
    }

    /// 等页面里的一个条件成立（每 50 毫秒看一次，最多 5 秒）
    private func waitUntilPage(_ harness: ShellHarness, _ condition: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await harness.evaluate("return \(condition)") as? Bool != true {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("预览舞台：一次看一张大卡片；上一张 / 下一张、胶片、页码同步，出图后停在原来那张，光标移到哪页就跟到哪页")
    func stageShowsOneCardAtATime() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const markdown = "第一页\\n\\n[[分页]]\\n\\n第二页\\n\\n[[分页]]\\n\\n第三页";
            await mc.drafts.create({ markdown });
            await mc.render.pages();
            document.activeElement?.blur();
            const stage = region("预览");
            // 舞台正中那张卡片是第几页（按出图画布认）
            const shown = async () => {
              const [x, y] = center(stage.querySelector(".stage-scroller"));
              const canvas = document.elementFromPoint(x, y)?.closest(".card-frame")?.querySelector("canvas");
              return (await mc.render.canvases()).indexOf(canvas) + 1;
            };
            const thumbs = () => ui.all("第", { within: "全部卡片" });
            const state = async () => ({
              shown: await shown(),
              label: stage.querySelector("[aria-live]").textContent,
              current: thumbs().findIndex((thumb) => thumb.getAttribute("aria-current") === "true") + 1,
              prev: ui.find("上一张").disabled,
              next: ui.find("下一张").disabled,
            });
            const steps = [await state()];
            ui.click("下一张");
            steps.push(await state());
            ui.click("第 3 张", { within: "全部卡片" });
            steps.push(await state());
            await mc.drafts.update({ markdown: markdown + "，再多写一句" });
            steps.push(await state());
            ui.click("上一张");
            steps.push(await state());
            stage.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true }));
            steps.push(await state());
            await mc.editor.select(markdown.indexOf("第三页"));
            await new Promise((resolve) => setTimeout(resolve, 1200));
            steps.push(await state());
            return { steps, thumbs: thumbs().map(ui.name) };
        """) as? [String: Any]
        await harness.tearDown()

        let steps = result?["steps"] as? [[String: Any]] ?? []
        #expect(steps.map { $0["shown"] as? Int ?? 0 } == [1, 2, 3, 3, 2, 1, 3], "舞台上看到的那张")
        #expect(steps.map { $0["current"] as? Int ?? 0 } == [1, 2, 3, 3, 2, 1, 3], "胶片高亮的那张")
        #expect(steps.map { $0["label"] as? String ?? "" } == [1, 2, 3, 3, 2, 1, 3].map { "第 \($0) 张 · 共 3 张" })
        #expect(steps.map { $0["prev"] as? Bool ?? false } == [true, false, false, false, false, true, false])
        #expect(steps.map { $0["next"] as? Bool ?? false } == [false, false, true, true, false, false, true])
        #expect(result?["thumbs"] as? [String] == ["第 1 张", "第 2 张", "第 3 张"])
        #expect(harness.pageErrors == [])
    }

    @Test("原生毛玻璃：网页透明、玻璃那一层半透明（顶栏、抽屉、检查器坐在上面）、内容区不透明；顶栏空白处可拖窗口、按钮照常点；换主题不改窗口外观")
    func nativeGlassFrame() async throws {
        let harness = ShellHarness(glass: true, onboarding: false)
        try await harness.load()
        let web = try #require(harness.webView as? ChromeWebView)
        let page = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "玻璃", markdown: "正文" });
            await new Promise((resolve) => setTimeout(resolve, 300));
            // 半透明色可能写成 rgba(…, a) 或 color(srgb … / a)
            const alpha = (color) => {
              const slash = color.match(/\\/\\s*([\\d.]+)\\)/);
              if (slash) return Number(slash[1]);
              const parts = color.slice(color.indexOf("(") + 1, -1).split(",");
              return parts.length > 3 ? Number(parts[3]) : 1;
            };
            return {
              glass: document.documentElement.dataset.glass,
              body: css(document.body, "background-color"),
              glassAlpha: alpha(css(document.querySelector(".app"), "background-color")),
              chrome: [document.querySelector("header"), region("稿件"), region("检查器")].map((element) => alpha(css(element, "background-color"))),
              editor: css(region("编辑器"), "background-color"),
              inset: css(document.querySelector("header"), "padding-left"),
              title: center(document.querySelector("header [role='status']").previousElementSibling),
              send: center(ui.find("发送到 iPhone")),
              mode: center(ui.find("长文", { within: "排版模式" })),
              editorPoint: center(region("编辑器")),
            };
        """) as? [String: Any]
        let point = { (key: String) -> CGPoint in
            let values = page?[key] as? [Double] ?? [0, 0]
            return CGPoint(x: values[0], y: values[1])
        }
        try await waitUntil { !web.dragRegions.isEmpty }
        let dragAtTitle = web.isWindowDragPoint(point("title"))
        let dragAtButtons = [point("send"), point("mode"), point("editorPoint")].map(web.isWindowDragPoint)

        let before = harness.webView.window?.appearance?.name
        _ = try await harness.evaluate("await window.mediacraft.themes.apply('ink'); await window.mediacraft.render.pages();")
        try await Task.sleep(for: .milliseconds(200))
        let afterTheme = harness.webView.window?.appearance?.name

        // 对话框盖住顶栏时不拖窗口，点击交给对话框
        _ = try await harness.evaluate("ui.expand('稿件列表'); ui.click('删除 玻璃');")
        try await waitUntil { !web.isWindowDragPoint(point("title")) }
        let coveredByDialog = !web.isWindowDragPoint(point("title"))
        await harness.tearDown()

        #expect(page?["glass"] as? String == "native")
        #expect(page?["body"] as? String == "rgba(0, 0, 0, 0)", "网页不画底色，透出窗口后的毛玻璃")
        let glassAlpha = page?["glassAlpha"] as? Double ?? 1
        #expect(glassAlpha > 0.2 && glassAlpha < 0.6, "玻璃那一层半透明：\(glassAlpha)")
        #expect(page?["chrome"] as? [Double] == [0, 0, 0], "顶栏、稿件抽屉、检查器不再叠一层底")
        #expect(page?["editor"] as? String == "rgb(255, 255, 255)", "内容区不透明")
        #expect(page?["inset"] as? String == "92px", "给红绿灯留出位置")
        #expect(dragAtTitle, "顶栏里的稿件名处可以拖动窗口")
        #expect(dragAtButtons == [false, false, false], "按钮、分段控件和编辑区不拖窗口")
        #expect(afterTheme == before, "窗口外观跟随系统，不跟卡片主题")
        #expect(coveredByDialog)
        #expect(harness.pageErrors == [])
    }
}
