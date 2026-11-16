import AppKit
import Foundation
import Testing

/// 写作一侧的打磨（顶栏、稿件抽屉、标题、格式条的菜单、新手引导）：一处一个断言，都是用起来看得见的小事。
@MainActor
struct WritingPolishTests {
    static let helpers = """
        const mc = window.mediacraft;
        window.wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        window.until = async (condition, timeout = 15000) => {
          const deadline = Date.now() + timeout;
          while (Date.now() < deadline) {
            const value = await condition();
            if (value) return value;
            await wait(50);
          }
          throw new Error(`等不到：${condition}`);
        };
        window.box = (node) => { const r = node.getBoundingClientRect(); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height }; };
        window.press = (key, target = document.activeElement) => {
          const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
          target.dispatchEvent(event);
          return event.defaultPrevented;
        };
        // 焦点在哪个控件上（按可访问名称）
        window.focused = () => ui.name(document.activeElement.closest("label.menu-item") ?? document.activeElement);
    """

    @Test("稿件抽屉：搜不到、这一类还没有稿件时，那句话写在列表该在的地方（紧跟在筛选下面），不沉到抽屉底下")
    func emptyDraftListNoteSitsWhereTheListWouldBe() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "春天的书单", markdown: "正文" });
            ui.expand("稿件列表");
            const drawer = document.querySelector('[aria-label="稿件"]');
            const search = ui.find("搜索稿件");
            search.value = "冬天";
            search.dispatchEvent(new Event("input", { bubbles: true }));
            const note = await until(() => [...drawer.querySelectorAll("p")].find((p) => p.textContent === "没有找到这篇稿件" && p.getClientRects().length));
            const filter = drawer.querySelector('[aria-label="稿件类型"]');
            const storage = [...drawer.querySelectorAll("p")].find((p) => p.textContent.startsWith("稿件只存在"));
            return {
              gap: box(note).top - box(filter).bottom,
              centered: getComputedStyle(note).textAlign,
              storageAtBottom: box(drawer).bottom - box(storage).bottom,
              storageBelowNote: box(storage).top - box(note).bottom,
            };
        """) as? [String: Any]
        await harness.tearDown()

        let gap = result?["gap"] as? Double ?? .infinity
        #expect(gap >= 0 && gap < 24, "「没有找到」紧跟在筛选下面：\(gap)")
        #expect(result?["centered"] as? String == "center")
        #expect((result?["storageAtBottom"] as? Double ?? .infinity) < 24, "「稿件只存在这台电脑上」还在抽屉底下")
        #expect((result?["storageBelowNote"] as? Double ?? 0) > 200, "两句话不挤在一起")
        #expect(harness.pageErrors == [])
    }

    @Test("标题框：编辑区窄、标题长时末尾收成省略号，不把半个字切在字数前面")
    func longTitleEndsWithEllipsis() async throws {
        let harness = ShellHarness(onboarding: false)
        harness.webView.window?.setContentSize(NSSize(width: 1100, height: 720))
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "周末去湖边的一天，值得再去一次，下次还去", markdown: "正文" });
            await mc.render.pages();
            const input = ui.find("标题");
            return { overflow: getComputedStyle(input).textOverflow, clipped: input.scrollWidth > input.clientWidth };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["clipped"] as? Bool == true, "这个标题在最小窗口里放不下一行")
        #expect(result?["overflow"] as? String == "ellipsis")
        #expect(harness.pageErrors == [])
    }

    @Test("顶栏的状态文字说完就退场：几秒后淡出、不再占那一行，稿件名回到正中，文字还留着；新的一句又显出来")
    func statusLineSettlesAfterAWhile() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "周末去湖边", markdown: "早上七点出门。" });
            await mc.render.pages();
            const status = document.getElementById("statusText");
            const heading = document.getElementById("draftHeading");
            const bar = document.querySelector(".titlebar");
            // 稿件名的中线离顶栏中线多远
            const offCenter = () => Math.abs((box(heading).top + box(heading).bottom) / 2 - (box(bar).top + box(bar).bottom) / 2);
            const shown = () => getComputedStyle(status).opacity === "1" && getComputedStyle(status).position !== "absolute" && box(status).height > 0;
            ui.click("复制卡片文字");
            await until(() => status.textContent.startsWith("已复制"));
            const said = { text: status.textContent, shown: shown(), offCenter: offCenter() };
            await until(() => !shown(), 12000);
            const settled = { text: status.textContent, opacity: getComputedStyle(status).opacity, offCenter: offCenter() };
            ui.click("复制卡片文字");
            await until(() => shown());
            return { said, settled, again: { shown: shown(), offCenter: offCenter() } };
        """) as? [String: [String: Any]]
        await harness.tearDown()

        let said = result?["said"]
        let settled = result?["settled"]
        #expect(said?["shown"] as? Bool == true, "刚说的那句看得见")
        #expect((said?["offCenter"] as? Double ?? 0) > 3, "有状态时稿件名让出下面一行")
        #expect(settled?["opacity"] as? String == "0", "几秒后淡出")
        #expect((settled?["offCenter"] as? Double ?? .infinity) < 1.5, "稿件名回到顶栏正中：\(settled?["offCenter"] ?? "")")
        #expect(settled?["text"] as? String == said?["text"] as? String, "文字还留在元素里")
        #expect(result?["again"]?["shown"] as? Bool == true, "新的一句又显出来")
        #expect(harness.pageErrors == [])
    }

    @Test("切到长文，顶栏中间的排版模式切换不被右边多出来的导出按钮挤走（默认窗口 1440 与更窄的几档，带红绿灯的留位）", arguments: [1440, 1400, 1340])
    func layoutSwitchStaysPutInArticleMode(width: Int) async throws {
        let harness = ShellHarness(glass: true, onboarding: false)
        harness.webView.window?.setContentSize(NSSize(width: width, height: 960))
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "周末去湖边", markdown: "早上七点出门。" });
            await mc.render.pages();
            const control = document.querySelector('[aria-label="排版模式"]');
            const bar = document.querySelector(".titlebar");
            const outside = () => [...bar.querySelectorAll("button")].filter((button) => button.getClientRects().length && box(button).right > innerWidth + 1).map(ui.name);
            const cards = box(control).left;
            ui.click("长文", { within: control });
            await until(() => document.body.dataset.layoutMode === "article" && ui.find("下载长图"));
            await mc.render.articleHtml();
            const article = box(control).left;
            const articleOutside = outside();
            const phone = await until(() => ui.find("手机预览")?.disabled && ui.find("手机预览"));
            const icons = { phone: box(phone).width < 40, ai: box(ui.find("AI")).width < 40, exportNamed: box(ui.find("下载长图")).width > 60 };
            ui.click("图文卡片", { within: control });
            await until(() => document.body.dataset.layoutMode === "cards" && ui.find("批量下载"));
            return { width: innerWidth, cards, article, back: box(control).left, articleOutside, icons };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["width"] as? Double == Double(width))
        let cards = result?["cards"] as? Double ?? -1
        let article = result?["article"] as? Double ?? -2
        #expect(abs(cards - article) < 1, "点了「长文」，切换还在原地：\(cards) → \(article)")
        #expect(result?["back"] as? Double == cards)
        #expect(result?["articleOutside"] as? [String] == [], "右边的按钮都在窗口里")
        let icons = result?["icons"] as? [String: Bool]
        #expect(icons?["phone"] == true && icons?["ai"] == true, "长文里手机预览（停用着）与 AI 只留图标，名字还在：\(icons ?? [:])")
        if width >= 1440 { #expect(icons?["exportNamed"] == true, "默认窗口里导出按钮的名字留着") }
        #expect(harness.pageErrors == [])
    }
}
