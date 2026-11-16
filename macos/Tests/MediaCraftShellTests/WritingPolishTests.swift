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

    @Test("格式条的「样式」「插入」菜单用键盘走：↓ ↑ 在各项之间走并绕回去，Home / End 到头尾，Esc 收起、焦点回到按钮")
    func formatBarMenusFollowArrowKeys() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# 标题\\n\\n第一段" });
            await mc.render.pages();
            await mc.editor.select(0);
            const open = (name) => { const button = ui.find(name); button.focus(); button.click(); return button.parentElement; };
            // 样式：光标在大标题上，↓ 先落在现在的那一项
            const style = open("段落样式");
            const steps = [];
            press("ArrowDown"); steps.push(focused());
            press("ArrowDown"); steps.push(focused());
            press("ArrowUp"); press("ArrowUp"); steps.push(focused());
            press("Home"); steps.push(focused());
            press("ArrowUp"); steps.push(focused());
            const last = steps.at(-1) === ui.name([...style.querySelectorAll(".menu-item")].at(-1));
            press("ArrowDown"); steps.push(focused());
            const handled = press("End");
            press("Escape");
            const closed = { open: style.open, focus: focused() };
            // 插入：第一项是连着文件选择框的「图片或 PDF」
            const insert = open("插入");
            press("ArrowDown");
            const first = { name: focused(), tag: document.activeElement.tagName };
            press("ArrowDown"); press("ArrowDown");
            const third = focused();
            press("Escape");
            // 表情面板是格子，方向键不归这里管
            const emoji = open("插入表情");
            const emojiHandled = press("ArrowDown");
            press("Escape");
            return { steps, last, handled, closed, first, third, insertOpen: insert.open, emojiHandled, emojiOpen: emoji.open };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["steps"] as? [String] == ["大标题", "小标题", "正文", "正文", "步骤", "正文"], "\(result?["steps"] ?? "")")
        #expect(result?["last"] as? Bool == true, "从第一项按 ↑ 绕到最后一项")
        #expect(result?["handled"] as? Bool == true, "方向键不再滚动页面")
        let closed = result?["closed"] as? [String: Any]
        #expect(closed?["open"] as? Bool == false && closed?["focus"] as? String == "段落样式")
        let first = result?["first"] as? [String: Any]
        #expect(first?["name"] as? String == "图片或 PDF" && first?["tag"] as? String == "INPUT", "\(first ?? [:])")
        #expect(result?["third"] as? String == "分割线")
        #expect(result?["insertOpen"] as? Bool == false)
        #expect(result?["emojiHandled"] as? Bool == false && result?["emojiOpen"] as? Bool == false)
        #expect(harness.pageErrors == [])
    }

    @Test("稿件列表用键盘走：搜索框里按 ↓ 进到第一篇，↓ ↑ 在各篇之间走、到头不绕，第一篇上按 ↑ 回搜索框；回车打开一篇后焦点还在那一行上")
    func draftListFollowsArrowKeysAndKeepsFocus() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            for (const title of ["第一篇", "第二篇", "第三篇"]) {
              await mc.drafts.create({ title, markdown: title });
              await wait(5); // 修改时间错开，列表的先后才确定
            }
            ui.expand("稿件列表");
            const drawer = document.querySelector('[aria-label="稿件"]');
            const rows = () => [...drawer.querySelectorAll('[role="listitem"] > button:first-child')];
            const titleOf = (button) => button?.querySelector("span")?.textContent ?? null;
            const at = () => (document.activeElement === ui.find("搜索稿件") ? "搜索" : titleOf(rows().find((row) => row === document.activeElement)));
            await until(() => rows().length >= 3);
            const order = rows().slice(0, 3).map(titleOf);
            const search = ui.find("搜索稿件");
            search.focus();
            const steps = [];
            press("ArrowDown"); steps.push(at());
            press("ArrowDown"); steps.push(at());
            press("ArrowUp"); press("ArrowUp"); steps.push(at());
            press("ArrowDown"); press("End"); steps.push(at() === titleOf(rows().at(-1)));
            press("ArrowDown"); steps.push(at() === titleOf(rows().at(-1)));
            press("Home"); steps.push(at());
            // 回车（按钮的点按）打开第二篇：这一行成了当前稿、重建了，焦点还在它上面
            press("ArrowDown");
            const picked = at();
            document.activeElement.click();
            await until(async () => (await mc.drafts.current()).title === picked);
            await until(() => rows().some((row) => row.getAttribute("aria-current") === "true" && titleOf(row) === picked));
            await wait(100);
            const after = { at: at(), current: titleOf(rows().find((row) => row.getAttribute("aria-current") === "true")) };
            // 右键菜单开着时方向键归菜单
            document.activeElement.closest('[role="listitem"]').dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 60, clientY: 200 }));
            const menuFirst = ui.name(document.activeElement);
            press("ArrowDown");
            const menuNext = ui.name(document.activeElement);
            press("Escape");
            return { order, steps, picked, after, menuFirst, menuNext, backOnRow: at() };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["order"] as? [String] == ["第三篇", "第二篇", "第一篇"])
        let steps = result?["steps"] as? [Any]
        #expect(steps?[0] as? String == "第三篇" && steps?[1] as? String == "第二篇", "搜索框里按 ↓ 进到第一篇，再按到下一篇：\(steps ?? [])")
        #expect(steps?[2] as? String == "搜索", "第一篇上按 ↑ 回到搜索框")
        #expect(steps?[3] as? Bool == true && steps?[4] as? Bool == true, "End 到最后一篇，再按 ↓ 不绕回去")
        #expect(steps?[5] as? String == "第三篇", "Home 到第一篇")
        #expect(result?["picked"] as? String == "第二篇")
        let after = result?["after"] as? [String: Any]
        #expect(after?["at"] as? String == "第二篇" && after?["current"] as? String == "第二篇", "打开以后焦点还在这一篇上：\(after ?? [:])")
        #expect(result?["menuFirst"] as? String != result?["menuNext"] as? String, "右键菜单开着时方向键在菜单里走")
        #expect(result?["backOnRow"] as? String == "第二篇", "Esc 收起菜单，焦点回到那一行")
        #expect(harness.pageErrors == [])
    }

    @Test("正文栏：自己点开（或在这一行上按回车）光标直接进输入框，不用再点一次；收起再点开照旧")
    func openingCaptionPutsCaretInIt() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "卡片上的字", caption: "图片下面的正文" });
            await mc.render.pages();
            const field = document.getElementById("captionField");
            const summary = ui.find("小红书正文");
            const state = () => ({ open: field.open, focused: document.activeElement === document.getElementById("captionInput"), onRow: document.activeElement === summary });
            const closedAtFirst = state();
            summary.click();
            await until(() => field.open && document.activeElement === document.getElementById("captionInput"));
            const opened = state();
            summary.click();
            await until(() => !field.open);
            await wait(50);
            const folded = state();
            summary.click();
            await until(() => field.open && document.activeElement === document.getElementById("captionInput"));
            return { closedAtFirst, opened, folded, again: state() };
        """) as? [String: [String: Bool]]
        await harness.tearDown()

        #expect(result?["closedAtFirst"]?["open"] == false)
        #expect(result?["opened"] == ["open": true, "focused": true, "onRow": false], "点开以后光标在输入框里")
        #expect(result?["folded"] == ["open": false, "focused": false, "onRow": true], "收起以后焦点回到这一行，不留在看不见的输入框里")
        #expect(result?["again"] == ["open": true, "focused": true, "onRow": false])
        #expect(harness.pageErrors == [])
    }

    @Test("新手引导第一步说的是眼前圈着的东西：稿件栏收着时圈「稿件列表」、说点开它；点开以后圈和说明都换成栏头的两个按钮")
    func onboardingFirstStepNamesWhatItPointsAt() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const tour = () => ui.dialogs().find((dialog) => dialog.textContent.includes("新手引导"));
            const body = () => tour().querySelector(".onboarding-body").textContent;
            const ring = () => box(document.querySelector(".onboarding-spot"));
            const around = (nodes) => {
              const boxes = nodes.map(box);
              const spot = ring();
              return boxes.every((item) => item.left >= spot.left - 1 && item.right <= spot.right + 1 && item.top >= spot.top - 1 && item.bottom <= spot.bottom + 1);
            };
            await until(tour);
            const toggle = ui.find("稿件列表");
            if (toggle.getAttribute("aria-expanded") === "true") toggle.click();
            await until(() => body().startsWith("点这里打开稿件栏"));
            const closed = { body: body(), around: around([toggle]), title: tour().querySelector(".onboarding-title").textContent };
            toggle.click();
            await until(() => body().startsWith("稿件栏里有三本"));
            await until(() => around([ui.find("从模板新建"), ui.find("新建稿件")]));
            const cardInside = box(tour()).left >= 0 && box(tour()).right <= innerWidth && box(tour()).bottom <= innerHeight;
            return { closed, opened: { body: body(), step: tour().textContent.includes("1 / 4") }, cardInside };
        """) as? [String: Any]
        await harness.tearDown()

        let closed = result?["closed"] as? [String: Any]
        #expect(closed?["around"] as? Bool == true, "稿件栏收着时圈住的是「稿件列表」")
        #expect((closed?["body"] as? String ?? "").contains("从模板新建"), "说明里还是讲了新建与模板")
        #expect(closed?["title"] as? String == "新建，或从模板开始")
        let opened = result?["opened"] as? [String: Any]
        #expect((opened?["body"] as? String ?? "").contains("点 + 开一篇空白稿子"))
        #expect(opened?["step"] as? Bool == true, "点开稿件栏还在第一步")
        #expect(result?["cardInside"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }
}
