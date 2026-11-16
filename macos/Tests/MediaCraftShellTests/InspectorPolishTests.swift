import AppKit
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
            const ids = ["layout", "theme", "font", "cover", "colors", "images", "cardCss", "byline"];
            const initial = Object.fromEntries(ids.map((id) => [id, section(id)]));
            const bylineAvatar = document.querySelector('[data-fold="byline"] .section-peek img')?.getAttribute("src") ?? "";
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
            return { initial, bylineAvatar, opened, allFolded, short, tall, stored: localStorage.getItem("mediacraft.inspector.folds.v1") };
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
        #expect(["font", "cover", "colors", "images", "cardCss", "byline"].allSatisfy { initial[$0]?["folded"] as? Bool == true && initial[$0]?["expanded"] as? String == "false" }, "其余默认收起：\(initial)")
        #expect(initial["cardCss"]?["peek"] as? String == "没有", "卡片样式的摘要：还没写")
        #expect((first?["bylineAvatar"] as? String ?? "").isEmpty == false, "署名的摘要带着头像的小圆")
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

    @Test("署名好找：名字框空着时写着「你的名字」；收起时摘要是头像的小圆与名字，填了名字、换了头像都跟上；头像上盖着一枚「换」的图标（指上去才显）")
    func bylineIsDiscoverable() async throws {
        let harness = ShellHarness(onboarding: false, inspectorFolded: true)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "一段" });
            await settle();
            const peek = () => {
              const node = document.querySelector('[data-fold="byline"] .section-peek');
              return { text: node.textContent, avatar: node.querySelector("img")?.getAttribute("src") ?? "" };
            };
            const empty = peek();
            ui.click("署名", { within: "检查器" });
            const name = ui.find("署名", { within: document.querySelector('[data-fold="byline"] .byline-row') });
            const placeholder = name.placeholder;
            const hint = document.querySelector(".avatar-button .avatar-button-hint");
            const hintHidden = getComputedStyle(hint).opacity === "0" && hint.getAttribute("aria-hidden") === "true";
            name.value = "小满";
            name.dispatchEvent(new Event("input", { bubbles: true }));
            // 收起（展开着时名字框也叫「署名」，直接点节名的按钮）
            document.querySelector('[data-fold="byline"] .section-fold').click();
            await until(() => peek().text === "小满");
            // 换头像：摘要里的小圆跟着换
            const pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
            await mc.profile.update({ avatar: pixel });
            await until(() => peek().avatar === pixel, 3000).catch(() => null);
            return { empty, placeholder, hintHidden, named: peek() };
        """) as? [String: Any]
        try await harness.screenshot("inspector-byline-peek", of: "[data-fold=\"byline\"]")
        await harness.tearDown()

        let empty = result?["empty"] as? [String: String]
        #expect(empty?["text"] == "还没填名字" && empty?["avatar"]?.isEmpty == false, "没填名字时：头像的小圆 + 「还没填名字」：\(empty ?? [:])")
        #expect(result?["placeholder"] as? String == "你的名字", "名字框的占位")
        #expect(result?["hintHidden"] as? Bool == true, "「换头像」的图标平时不显")
        let named = result?["named"] as? [String: String]
        #expect(named?["text"] == "小满", "填了名字摘要跟上")
        #expect(named?["avatar"]?.hasPrefix("data:image/png") == true, "换了头像摘要跟上：\(named ?? [:])")
        #expect(harness.pageErrors == [])
    }

    @Test("「高级 · 卡片样式」和别的节一样收起：摘要写着几条规则，点节名展开；图文尺寸的选单和字体选单一样高，紧接着排版密度")
    func cardCssFoldsLikeOthers() async throws {
        let harness = ShellHarness(onboarding: false, inspectorFolded: true)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "一段" });
            await settle();
            const before = section("cardCss");
            await mc.drafts.update({ cardCss: ".mc-note { border-radius: 20px; }\\n.mc-body { color: red; }" });
            await until(() => section("cardCss").peek === "2 条规则", 3000).catch(() => null);
            const written = section("cardCss");
            ui.click("高级 · 卡片样式", { within: "检查器" });
            const input = ui.find("卡片样式（CSS）");
            const open = { expanded: section("cardCss").expanded, input: Boolean(input), chevrons: document.querySelectorAll('[data-fold="cardCss"] .section-fold-chevron').length, details: document.querySelectorAll("#stylePanel details.advanced-field").length };
            ui.click("字体", { within: "检查器" });
            const box = (node) => node.getBoundingClientRect();
            const size = box(ui.find("图文尺寸"));
            const density = box(document.querySelector('[aria-label="排版密度"]'));
            const font = box(document.querySelector("#zhFontInput"));
            return { before, written, open, sizeHeight: size.height, fontHeight: font.height, gap: Math.round(density.top - size.bottom), sizeFont: getComputedStyle(ui.find("图文尺寸")).fontSize };
        """) as? [String: Any]
        try await harness.screenshot("inspector-card-css", of: ".inspector")
        await harness.tearDown()

        let before = result?["before"] as? [String: Any]
        #expect(before?["folded"] as? Bool == true && before?["peek"] as? String == "没有", "默认收起：\(before ?? [:])")
        #expect((result?["written"] as? [String: Any])?["peek"] as? String == "2 条规则", "摘要跟着这篇的卡片样式")
        let open = result?["open"] as? [String: Any]
        #expect(open?["expanded"] as? String == "true" && open?["input"] as? Bool == true, "点节名展开：\(open ?? [:])")
        #expect(open?["chevrons"] as? Int == 1 && open?["details"] as? Int == 0, "箭头和别的节一样在左边，不再是另一种折叠")
        #expect(result?["sizeHeight"] as? Double == 32 && result?["fontHeight"] as? Double == 32, "图文尺寸与字体选单一样高：\(result?["sizeHeight"] ?? "") / \(result?["fontHeight"] ?? "")")
        #expect(result?["sizeFont"] as? String == "13px")
        #expect(result?["gap"] as? Int == 10, "排版密度紧接在图文尺寸下面（一节里的行距）：\(result?["gap"] ?? "")")
        #expect(harness.pageErrors == [])
    }

    @Test("展开一节、内容超出检查器时版面不横着挪：滚动条的位置一直留着，主题格子一样宽；两边留白差不多")
    func panelDoesNotShiftWhenItOverflows() async throws {
        let harness = ShellHarness(onboarding: false, inspectorFolded: true)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "一段" });
            await settle();
            const panel = document.querySelector("#stylePanel");
            const label = document.querySelector('[data-fold="layout"] .section-label');
            const measure = () => ({ overflows: panel.scrollHeight > panel.clientHeight + 1, width: label.getBoundingClientRect().width });
            const fold = (open) => { for (const toggle of panel.querySelectorAll(".section-fold")) if ((toggle.getAttribute("aria-expanded") === "true") !== open) toggle.click(); };
            fold(false);
            const short = measure();
            fold(true);
            const tall = measure();
            const box = panel.getBoundingClientRect();
            const content = label.getBoundingClientRect();
            return { short, tall, left: content.left - box.left, right: box.right - content.right, scrollbar: getComputedStyle(document.documentElement).getPropertyValue("--scrollbar-width") };
        """) as? [String: Any]
        await harness.tearDown()

        let short = result?["short"] as? [String: Any]
        let tall = result?["tall"] as? [String: Any]
        #expect(short?["overflows"] as? Bool == false && tall?["overflows"] as? Bool == true, "全收起放得下、全展开要滚动：\(short ?? [:]) \(tall ?? [:])")
        #expect(short?["width"] as? Double == tall?["width"] as? Double, "内容一样宽：\(short?["width"] ?? "") / \(tall?["width"] ?? "")")
        let left = result?["left"] as? Double ?? 0
        let right = result?["right"] as? Double ?? 99
        #expect(left == 16 && right >= 16 && right <= 22, "两边留白差不多：左 \(left)、右 \(right)（滚动条 \(result?["scrollbar"] ?? "")）")
        #expect(harness.pageErrors == [])
    }

    @Test("窗口缩到最小（检查器 280 宽）：配色五个色块的色值都在自己的格子里，不压到旁边")
    func swatchesFitNarrowInspector() async throws {
        let harness = ShellHarness(onboarding: false)
        harness.webView.window?.setContentSize(NSSize(width: 900, height: 650))
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "一段" });
            await settle();
            const tiles = [...document.querySelectorAll(".color-roles .swatch-tile")];
            document.querySelector('[data-fold="colors"]').scrollIntoView({ block: "center" });
            return {
              inspector: Math.round(document.querySelector(".inspector").getBoundingClientRect().width),
              clipped: tiles.filter((tile) => { const hex = tile.querySelector(".swatch-hex"); return hex.scrollWidth > hex.clientWidth; }).length,
              outside: tiles.filter((tile) => { const a = tile.getBoundingClientRect(); const b = tile.querySelector(".swatch-hex").getBoundingClientRect(); return b.left < a.left || b.right > a.right; }).length,
              text: tiles.map((tile) => tile.querySelector(".swatch-hex").textContent),
            };
        """) as? [String: Any]
        try await harness.screenshot("inspector-swatches-narrow", of: "[data-fold=\"colors\"]")
        await harness.tearDown()

        #expect(result?["inspector"] as? Int == 280, "最小窗口里检查器 280 宽")
        #expect(result?["clipped"] as? Int == 0 && result?["outside"] as? Int == 0, "色值写得全、在格子里：\(result ?? [:])")
        #expect((result?["text"] as? [String])?.allSatisfy { $0.count == 7 } == true)
        #expect(harness.pageErrors == [])
    }

    @Test("AI 助手的会话栏：后端、模型、推理强度三个药丸按选中那一项的字宽，默认宽度的检查器里排成一行；检查器最窄时「Claude Code」也写得全；AI 设置和面板一样宽，两个「保存」只有填了新路径才是主按钮")
    func aiSessionBarFitsOneRow() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["好"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let measure = """
            const pickers = [...document.querySelectorAll(".ai-session-bar .ai-picker")];
            const rows = new Set(pickers.map((picker) => Math.round(picker.getBoundingClientRect().top))).size;
            const clipped = pickers.filter((picker) => { const select = picker.querySelector("select"); return select.scrollWidth > select.clientWidth + 1; }).map((picker) => picker.querySelector("select").value);
            const bar = document.querySelector(".ai-session-bar").getBoundingClientRect();
            const outside = pickers.filter((picker) => picker.getBoundingClientRect().right > bar.right + 1).length;
        """
        let wide = try await harness.evaluate(AISessionTests.helpers + """
            await mc.drafts.create({ title: "周末去湖边", markdown: "正文" });
            await openAI();
            await until(() => document.querySelector("#aiEffortSelect").style.width);
            \(measure)
            ui.expand("AI 设置");
            await wait(100);
            const popover = document.querySelector(".ai-settings-popover");
            const head = document.querySelector(".ai-session-head");
            const widths = [popover.offsetWidth, head.offsetWidth];
            // 两个「保存」平时都不是主按钮；路径框里填了新的，那一组的才是
            const saves = () => [...popover.querySelectorAll("[data-path-save]")].map((button) => button.classList.contains("primary-button"));
            const idle = saves();
            const path = ui.find("claude 的路径");
            path.value = "/opt/claude";
            path.dispatchEvent(new Event("input", { bubbles: true }));
            const typed = saves();
            path.value = "";
            path.dispatchEvent(new Event("input", { bubbles: true }));
            const cleared = saves();
            document.querySelector("#aiSettings").open = false;
            return { rows, clipped, outside, widths, idle, typed, cleared, inspector: Math.round(document.querySelector(".inspector").getBoundingClientRect().width) };
        """) as? [String: Any]
        harness.webView.window?.setContentSize(NSSize(width: 900, height: 650))
        let narrow = try await harness.evaluate("""
            await wait(300);
            \(measure)
            return { rows, clipped, outside, inspector: Math.round(document.querySelector(".inspector").getBoundingClientRect().width) };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(wide?["inspector"] as? Int == 340)
        #expect(wide?["rows"] as? Int == 1, "默认宽度：三个药丸一行")
        #expect(wide?["clipped"] as? [String] == [] && wide?["outside"] as? Int == 0, "字都写得全：\(wide ?? [:])")
        let widths = wide?["widths"] as? [Int] ?? []
        #expect(widths.count == 2 && widths[0] == widths[1] + 16, "AI 设置比会话栏两边各宽出 8：\(widths)")
        #expect(wide?["idle"] as? [Bool] == [false, false] && wide?["cleared"] as? [Bool] == [false, false], "「保存」平时是普通按钮：\(wide?["idle"] ?? "")")
        #expect(wide?["typed"] as? [Bool] == [false, true], "填了新路径的那一组才是主按钮：\(wide?["typed"] ?? "")")
        #expect(narrow?["inspector"] as? Int == 280)
        #expect(narrow?["clipped"] as? [String] == [] && narrow?["outside"] as? Int == 0, "最窄时折行、不截断：\(narrow ?? [:])")
        #expect(harness.pageErrors == [])
    }
}
