import Foundation
import Testing

/// 编辑器像 PPT 一样顺手（v8）：格式条上的「表情」与字号读数；检查器「样式」各节能收起（收起时一行摘要，开合记在本机）、
/// 滑杆旁能输入精确数值的数值框；新的稿子字段「段距」；检查器能拖宽。
@MainActor
struct InspectorPolishTests {
    static let helpers = """
        const mc = window.mediacraft;
        window.until = async (condition, timeout = 8000) => {
          const deadline = Date.now() + timeout;
          while (Date.now() < deadline) {
            const value = await condition();
            if (value) return value;
            await new Promise((resolve) => setTimeout(resolve, 20));
          }
          throw new Error(`等不到：${condition}`);
        };
        window.settle = async () => { await mc.render.pages(); await new Promise((resolve) => setTimeout(resolve, 50)); };
        window.current = () => mc.drafts.current();
        // 检查器一节：{ folded, peek }
        window.section = (id) => {
          const element = document.querySelector(`#stylePanel [data-fold="${id}"]`);
          return { folded: element.classList.contains("is-folded"), expanded: element.querySelector(".section-fold").getAttribute("aria-expanded"), peek: element.querySelector(".section-peek").textContent, dots: element.querySelectorAll(".section-peek-dots > span").length };
        };
        // 在数值框里输入一个值、回车
        window.typeNumber = (name, value) => {
          const field = ui.find(`${name}（输入数值）`);
          field.focus();
          field.value = String(value);
          field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
        };
        window.keyNumber = (name, key, shiftKey = false) => {
          const field = ui.find(`${name}（输入数值）`);
          field.focus();
          field.dispatchEvent(new KeyboardEvent("keydown", { key, shiftKey, bubbles: true, cancelable: true }));
        };
    """

    @Test("格式条上的「表情」：插到正文光标处（出图、⌘Z 一步撤回）；最后在标题框里打字时插到标题；用过的进「最近」；A− 与 A+ 中间写着现在的字号")
    func emojiPicker() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "第一段\\n\\n第二段" });
            await settle();
            const text = (await current()).markdown;
            await mc.editor.select(text.indexOf("第二段"));
            ui.expand("插入表情", { within: "文字样式" });
            const tabs = [...document.querySelectorAll("[data-emoji-tabs] [role=tab]")].map((tab) => [ui.name(tab), tab.getAttribute("aria-selected")]);
            ui.click("插入 🔥");
            await until(async () => (await current()).markdown.includes("🔥"));
            const inserted = (await current()).markdown;
            const rendered = await until(async () => (await mc.render.pages()).flatMap((page) => page.items).some((item) => item.text?.includes("🔥第二段")), 3000).catch(() => false);
            const menuClosed = !document.querySelector("#emojiMenu").open;
            await mc.drafts.undo();
            const undone = (await current()).markdown;
            // 标题框里打字之后：插到标题
            const title = document.querySelector("#titleInput");
            title.focus();
            title.value = "周末";
            title.dispatchEvent(new Event("input", { bubbles: true }));
            title.setSelectionRange(2, 2);
            ui.expand("插入表情", { within: "文字样式" });
            ui.click("最近");
            const recent = [...document.querySelectorAll("[data-emoji-grid] .emoji-item")].map((item) => item.textContent);
            ui.click("常用");
            ui.click("插入 ✨");
            await until(async () => (await current()).title === "周末✨");
            const titled = (await current()).title;
            const bodyAfterTitle = (await current()).markdown;
            await mc.drafts.update({ fontSize: 27 });
            await settle();
            const readout = document.querySelector("[data-font-size-value]").textContent;
            return { tabs, inserted, rendered, menuClosed, undone, recent, titled, bodyAfterTitle, readout };
        """) as? [String: Any]
        _ = try await harness.evaluate("document.querySelector('#emojiMenu').open = true; await new Promise((resolve) => setTimeout(resolve, 300));")
        try await harness.screenshot("emoji-picker", of: ".editor-pane")
        await harness.tearDown()

        let tabs = result?["tabs"] as? [[String]] ?? []
        #expect(tabs.map { $0[0] } == ["最近", "常用", "表情", "手势", "生活", "自然", "符号"])
        #expect(tabs.first { $0[1] == "true" }?[0] == "常用", "还没用过时先看「常用」")
        #expect(result?["inserted"] as? String == "第一段\n\n🔥第二段", "插在光标处")
        #expect(result?["rendered"] as? Bool == true, "插了马上出图")
        #expect(result?["menuClosed"] as? Bool == true, "点一个就收起")
        #expect(result?["undone"] as? String == "第一段\n\n第二段", "⌘Z 一步撤回")
        #expect(result?["recent"] as? [String] == ["🔥"], "用过的进「最近」")
        #expect(result?["titled"] as? String == "周末✨", "最后在标题框里打字：插到标题")
        #expect(result?["bodyAfterTitle"] as? String == "第一段\n\n第二段", "插到标题时正文不动")
        #expect(result?["readout"] as? String == "27", "A− 与 A+ 中间写着现在的字号")
        #expect(harness.pageErrors == [])
    }

    @Test("检查器「样式」：版式、主题开着，其余收起并写一行摘要（配色是五个小色点）；点节名展开、⌥ 点全部一起；开合记在本机，重新打开还是那样")
    func sectionsFold() async throws {
        let harness = ShellHarness(onboarding: false, inspectorFolded: true)
        try await harness.load()
        let first = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "一段" });
            await settle();
            const ids = ["layout", "theme", "font", "cover", "colors", "images", "byline"];
            const initial = Object.fromEntries(ids.map((id) => [id, section(id)]));
            ui.click("配色", { within: "检查器" });
            const opened = section("colors");
            const panel = document.querySelector("#stylePanel");
            const contentHeight = () => Math.round(panel.lastElementChild.getBoundingClientRect().bottom - panel.firstElementChild.getBoundingClientRect().top);
            const tall = contentHeight();
            // ⌥ 点「版式」：全部收起
            ui.find("版式", { within: "检查器" }).dispatchEvent(new MouseEvent("click", { bubbles: true, altKey: true }));
            const allFolded = ids.every((id) => section(id).folded);
            const short = contentHeight();
            ui.find("版式", { within: "检查器" }).dispatchEvent(new MouseEvent("click", { bubbles: true, altKey: true }));
            ui.click("字体", { within: "检查器" });
            return { initial, opened, allFolded, short, tall, stored: localStorage.getItem("mediacraft.inspector.folds.v1") };
        """) as? [String: Any]
        try await harness.screenshot("inspector-folded", of: ".inspector")
        // 重新载入：开合还是那样（字体收着，别的都开着）
        try await harness.load()
        let second = try await harness.evaluate(Self.helpers + """
            return { font: section("font").folded, colors: section("colors").folded, layout: section("layout").folded };
        """) as? [String: Any]
        await harness.tearDown()

        let initial = first?["initial"] as? [String: [String: Any]] ?? [:]
        #expect(["layout", "theme"].allSatisfy { initial[$0]?["folded"] as? Bool == false }, "版式、主题默认开着")
        #expect(["font", "cover", "colors", "images", "byline"].allSatisfy { initial[$0]?["folded"] as? Bool == true && initial[$0]?["expanded"] as? String == "false" }, "其余默认收起：\(initial)")
        #expect(initial["font"]?["peek"] as? String == "跟随主题", "字体的摘要")
        #expect(initial["cover"]?["peek"] as? String == "不做封面")
        #expect(initial["colors"]?["dots"] as? Int == 5, "配色的摘要是五个小色点")
        #expect(initial["byline"]?["peek"] as? String == "还没填名字")
        #expect((first?["opened"] as? [String: Any])?["folded"] as? Bool == false, "点节名展开")
        #expect(first?["allFolded"] as? Bool == true, "⌥ 点一下全部收起")
        #expect((first?["short"] as? Int ?? 9999) < 400, "全部收起时只剩节名：\(first?["short"] ?? "")")
        #expect((first?["tall"] as? Int ?? 0) > (first?["short"] as? Int ?? 0))
        #expect(second?["font"] as? Bool == true && second?["colors"] as? Bool == false && second?["layout"] as? Bool == false, "开合记在本机：\(second ?? [:])")
        #expect(harness.pageErrors == [])
    }

    @Test("滑杆旁的数值框：输入精确的值、回车生效（超出范围收进来），↑ ↓ 一档、⇧ 十档，− ＋ 一档；和滑杆、稿子是同一个值")
    func steppers() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "一段\\n\\n二段" });
            await settle();
            typeNumber("字号", 27);
            await until(async () => (await current()).fontSize === 27);
            const typed = { size: (await current()).fontSize, slider: document.querySelector("#fontSizeInput").value };
            keyNumber("字号", "ArrowUp");
            await until(async () => (await current()).fontSize === 28);
            keyNumber("字号", "ArrowDown", true);
            await until(async () => (await current()).fontSize === 18);
            const shifted = (await current()).fontSize;
            typeNumber("字号", 99);
            await until(async () => (await current()).fontSize === 40);
            const clamped = [(await current()).fontSize, ui.find("字号（输入数值）").value];
            ui.click("行距调大一档");
            await until(async () => Math.abs((await current()).lineHeight - 1.9) < 0.001);
            const leading = [(await current()).lineHeight, ui.find("行距（输入数值）").value];
            // 拖滑杆：数值框跟着
            const slider = document.querySelector("#imageHeightInput");
            slider.value = "600";
            slider.dispatchEvent(new Event("input", { bubbles: true }));
            const follows = ui.find("图片高（输入数值）").value;
            return { typed, shifted, clamped, leading, follows };
        """) as? [String: Any]
        try await harness.screenshot("inspector-steppers", of: "[data-fold=\"layout\"]")
        await harness.tearDown()

        let typed = result?["typed"] as? [String: Any]
        #expect(typed?["size"] as? Int == 27 && typed?["slider"] as? String == "27", "输入 27 回车：稿子与滑杆都是 27")
        #expect(result?["shifted"] as? Int == 18, "⇧↓ 一次十档（28 → 18）")
        #expect(result?["clamped"] as? [AnyHashable] == [40, "40"], "超出范围收进 40")
        #expect(result?["leading"] as? [AnyHashable] == [1.9, "1.90"], "行距一档 0.05")
        #expect(result?["follows"] as? String == "600", "拖滑杆时数值框跟着")
        #expect(harness.pageErrors == [])
    }

    @Test("段距：块与块之间按行高的几倍；调小后块挨得更近、页数不变或变少；存进稿子、⌘Z 撤回、模板与 AI 的 set_style 都认，超出范围收进 0.1–1.5")
    func blockGap() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "第一段文字\\n\\n第二段文字\\n\\n第三段文字" });
            await settle();
            const gapOf = async () => {
              const items = (await mc.render.pages())[0].items.filter((item) => item.kind === "text");
              return Math.round(items[1].y - (items[0].y + items[0].height));
            };
            const initial = { value: (await current()).blockGap, gap: await gapOf() };
            typeNumber("段距", 0.2);
            await until(async () => (await current()).blockGap === 0.2);
            await settle();
            const tight = await gapOf();
            await mc.drafts.update({ blockGap: 1.2 }, { undoable: true });
            await settle();
            const loose = await gapOf();
            const undone = (await mc.drafts.undo()).blockGap;
            await mc.drafts.update({ blockGap: 9 });
            const clamped = (await current()).blockGap;
            // 模板文件里写 blockGap 一行，读回来还是它
            const format = window.MediaCraftTemplateFormat;
            const composed = format.compose({ name: "测试", blockGap: 0.4, markdown: ["一段"] });
            const parsed = format.entry("测试.md", composed).blockGap;
            return { initial, tight, loose, undone, clamped, composedLine: composed.split("\\n").find((line) => line.startsWith("blockGap")), parsed };
        """) as? [String: Any]
        await harness.tearDown()

        let initial = result?["initial"] as? [String: Any]
        #expect(initial?["value"] as? Double == 0.55, "默认 0.55 行")
        let start = initial?["gap"] as? Int ?? 0
        let tight = result?["tight"] as? Int ?? 0
        let loose = result?["loose"] as? Int ?? 0
        #expect(tight < start && start < loose, "段距小块挨得近、段距大块离得远：\(tight) / \(start) / \(loose)")
        #expect(result?["undone"] as? Double == 0.2, "⌘Z 撤回到上一步")
        #expect(result?["clamped"] as? Double == 1.5, "超出范围收进 1.5")
        #expect(result?["composedLine"] as? String == "blockGap: 0.4")
        #expect(result?["parsed"] as? Double == 0.4)
        #expect(harness.pageErrors == [])
    }

    @Test("检查器能拖宽：左边的分隔条往左拖变宽、← → 微调、双击恢复；宽度记在本机")
    func inspectorWidth() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const handle = document.querySelector('[role="separator"][aria-label="检查器宽度"]');
            const width = () => Math.round(document.querySelector(".inspector").getBoundingClientRect().width);
            const start = width();
            handle.focus();
            handle.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true, cancelable: true }));
            await new Promise((resolve) => setTimeout(resolve, 50));
            const wider = width();
            const box = handle.getBoundingClientRect();
            const x = box.left + box.width / 2;
            handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, button: 0, clientX: x, clientY: 300, pointerId: 1 }));
            window.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, clientX: x - 60, clientY: 300, pointerId: 1 }));
            window.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, clientX: x - 60, clientY: 300, pointerId: 1 }));
            await new Promise((resolve) => setTimeout(resolve, 50));
            const dragged = width();
            const stored = JSON.parse(localStorage.getItem("mediacraft.panels.v1")).inspector;
            handle.dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
            await new Promise((resolve) => setTimeout(resolve, 50));
            return { start, wider, dragged, stored, reset: width() };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["start"] as? Int == 340, "默认 340")
        #expect(result?["wider"] as? Int == 356, "← 一下宽 16")
        #expect(result?["dragged"] as? Int == 416, "往左拖 60 宽 60")
        #expect(result?["stored"] as? Int == 416, "宽度记在本机")
        #expect(result?["reset"] as? Int == 340, "双击恢复默认")
        #expect(harness.pageErrors == [])
    }
}
