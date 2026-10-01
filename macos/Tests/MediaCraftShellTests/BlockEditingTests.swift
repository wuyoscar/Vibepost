import Testing

/// HTML 卡片上直接编排（ADR 0006）：点选一块出工具条，上移下移、换样式、拖动换位置、删除都改成原文的一步编辑，可以撤销。
@MainActor
@Suite(.serialized)
struct BlockEditingTests {
    static let setup = """
        const mc = window.mediacraft;
        window.boxes = () => [...document.querySelectorAll("#stageCards .stage-block")];
        window.boxOf = (label) => boxes().find((box) => box.getAttribute("aria-label") === `选择${label}` && box.parentElement);
        window.markdown = async () => (await mc.drafts.current()).markdown;
        window.settle = async () => { await mc.render.pages(); await new Promise((resolve) => setTimeout(resolve, 50)); };
        window.pointer = (element, type, x, y) => element.dispatchEvent(new PointerEvent(type, { bubbles: true, pointerId: 1, button: 0, clientX: x, clientY: y }));
    """

    @Test("点选一块：工具条上移、下移、换样式、删除，都能 ⌘Z 撤回；样式换成小标签后还是选中它")
    func toolbarEditsTheDraft() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            await mc.drafts.create({ markdown: "# 标题\\n\\n第一段\\n\\n第二段" });
            await settle();
            const labels = boxes().map((box) => box.getAttribute("aria-label"));
            boxes()[1].focus();
            const bar = ui.find("段落操作");
            ui.click("下移", { within: "段落操作" });
            await settle();
            const moved = await markdown();
            const stillSelected = document.querySelector(".stage-block.is-selected")?.getAttribute("aria-label");
            await mc.drafts.undo();
            await settle();
            const undone = await markdown();
            boxes()[1].focus();
            ui.click("换样式", { within: "段落操作" });
            ui.click("小标签");
            await settle();
            const styled = await markdown();
            const selectedAfterStyle = document.querySelector(".stage-block.is-selected")?.getAttribute("aria-label");
            ui.click("删除这个组件", { within: "小标签操作" });
            await settle();
            const removed = await markdown();
            return { labels, bar: Boolean(bar), moved, stillSelected, undone, styled, selectedAfterStyle, removed };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["labels"] as? [String] == ["选择标题", "选择段落", "选择段落"])
        #expect(result?["moved"] as? String == "# 标题\n\n第二段\n\n第一段")
        #expect(result?["stillSelected"] as? String == "选择段落", "挪完还选中那一块")
        #expect(result?["undone"] as? String == "# 标题\n\n第一段\n\n第二段", "⌘Z 撤回")
        #expect(result?["styled"] as? String == "# 标题\n\n:::kicker\n第一段\n:::\n\n第二段")
        #expect(result?["selectedAfterStyle"] as? String == "选择小标签")
        #expect(result?["removed"] as? String == "# 标题\n\n第二段")
        #expect(harness.pageErrors == [])
    }

    @Test("换样式在一组里互换：小标题「食材准备」换成正文，正文换成大标题、引用，列表换成步骤；菜单标出现在是哪种")
    func stylesSwapWithinOneMenu() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            await mc.drafts.create({ markdown: "# 番茄炒蛋\\n\\n## 食材准备\\n\\n番茄两个，鸡蛋三个。\\n\\n- 打蛋\\n- 下锅" });
            await settle();
            const restyle = async (index, label) => {
              boxes()[index].focus();
              ui.click("换样式");
              const checked = document.querySelector(".stage-block-menu [aria-checked='true']")?.textContent;
              const items = [...document.querySelectorAll(".stage-block-menu-item")].map((item) => item.textContent);
              ui.click(label, { within: document.querySelector(".stage-block-menu") });
              await settle();
              return { checked, items, markdown: await markdown() };
            };
            const heading = await restyle(1, "正文");
            const paragraph = await restyle(2, "大标题");
            const quote = await restyle(2, "引用");
            const list = await restyle(3, "步骤");
            return { heading, paragraph, quote, list };
        """) as? [String: [String: Any]]
        await harness.tearDown()

        #expect(result?["heading"]?["checked"] as? String == "小标题")
        #expect(result?["heading"]?["items"] as? [String] == ["正文", "大标题", "小标题", "三级标题", "引用", "小标签", "提示", "页尾", "等宽"])
        #expect(result?["heading"]?["markdown"] as? String == "# 番茄炒蛋\n\n食材准备\n\n番茄两个，鸡蛋三个。\n\n- 打蛋\n- 下锅")
        #expect(result?["paragraph"]?["markdown"] as? String == "# 番茄炒蛋\n\n食材准备\n\n# 番茄两个，鸡蛋三个。\n\n- 打蛋\n- 下锅")
        #expect(result?["quote"]?["checked"] as? String == "大标题")
        #expect(result?["quote"]?["markdown"] as? String == "# 番茄炒蛋\n\n食材准备\n\n> 番茄两个，鸡蛋三个。\n\n- 打蛋\n- 下锅")
        #expect(result?["list"]?["items"] as? [String] == ["无序列表", "有序列表", "标签列表", "步骤", "正文"])
        #expect(result?["list"]?["markdown"] as? String == "# 番茄炒蛋\n\n食材准备\n\n> 番茄两个，鸡蛋三个。\n\n:::steps\n- 打蛋\n- 下锅\n:::")
        #expect(harness.pageErrors == [])
    }

    @Test("拖一块到另一块下半截：挪到它后面；标题改级别；键盘 ⌥↓ 下移、⌫ 删除；内置说明书只读时没有工具条")
    func dragAndKeyboard() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            await mc.drafts.create({ markdown: "# 标题\\n\\n第一段\\n\\n第二段\\n\\n第三段" });
            await settle();
            const [heading, first, , third] = boxes();
            const from = first.getBoundingClientRect();
            const to = third.getBoundingClientRect();
            // 按 WebKit 自己的命中测试找按下的元素（压在上面的层会挡住块）
            const hit = document.elementFromPoint(from.left + 10, from.top + from.height / 2);
            const hitLabel = hit?.closest(".stage-block")?.getAttribute("aria-label") ?? hit?.className;
            pointer(hit, "pointerdown", from.left + 10, from.top + 5);
            pointer(hit, "pointermove", from.left + 10, from.top + 30);
            pointer(hit, "pointermove", to.left + 10, to.bottom - 2);
            pointer(hit, "pointerup", to.left + 10, to.bottom - 2);
            await settle();
            const dragged = await markdown();
            boxes()[0].focus();
            ui.click("换样式", { within: "标题操作" });
            ui.click("小标题");
            await settle();
            const level = await markdown();
            boxes()[1].focus();
            boxes()[1].dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", altKey: true, bubbles: true }));
            await settle();
            const keyed = await markdown();
            boxes().at(-1).focus();
            boxes().at(-1).dispatchEvent(new KeyboardEvent("keydown", { key: "Backspace", bubbles: true }));
            await settle();
            const deleted = await markdown();
            const guide = (await mc.drafts.list()).find((item) => item.builtIn && item.mode === "cards");
            await mc.drafts.open(guide.id);
            await settle();
            boxes()[0].focus();
            const guideBar = Boolean(document.querySelector(".stage-block-bar"));
            return { hitLabel, dragged, level, keyed, deleted, guideBar, guideBoxes: boxes().length };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["hitLabel"] as? String == "选择段落", "按下的地方命中的是块（没有被别的层挡住）")
        #expect(result?["dragged"] as? String == "# 标题\n\n第二段\n\n第三段\n\n第一段")
        #expect(result?["level"] as? String == "## 标题\n\n第二段\n\n第三段\n\n第一段")
        #expect(result?["keyed"] as? String == "## 标题\n\n第三段\n\n第二段\n\n第一段")
        #expect(result?["deleted"] as? String == "## 标题\n\n第三段\n\n第二段")
        #expect((result?["guideBoxes"] as? Int ?? 0) > 0)
        #expect(result?["guideBar"] as? Bool == false, "只读的说明书能点选，没有改稿的工具条")
        #expect(harness.pageErrors == [])
    }

    @Test("截图给人看：选中一块、展开换样式菜单（设了 MEDIACRAFT_SCREENSHOTS 才存）")
    func screenshots() async throws {
        let markdown = try String(contentsOf: ShellHarness.repoRoot.appendingPathComponent("macos/Tests/Fixtures/html-cards-reference.md"), encoding: .utf8)
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(Self.setup + """
            await mc.drafts.create({ markdown, theme: "notes" });
            await settle();
            boxes()[2].focus();
            ui.click("换样式");
            await new Promise((resolve) => setTimeout(resolve, 300));
        """, arguments: ["markdown": markdown])
        try await harness.screenshot("block-selected-menu", of: "#stageScroller")
        _ = try await harness.evaluate(Self.setup + """
            document.querySelector(".stage-block-menu")?.remove();
            boxes()[1].focus();
            ui.click("批注");
            document.querySelector(".stage-note-editor textarea").value = "标题再醒目一点";
            ui.click("添加");
            boxes()[3].focus();
            ui.click("批注");
            document.querySelector(".stage-note-editor textarea").value = "这段太长，拆成标签列表";
            await new Promise((resolve) => setTimeout(resolve, 300));
        """)
        try await harness.screenshot("block-notes", of: ".stage")
        await harness.tearDown()
        #expect(harness.pageErrors == [])
    }

    @Test("批注几处一次交给 AI：写批注出编号圆点、点圆点能改；交给 AI 时每处带第几页与原文开头，会话里显示「按 N 处批注改」，发完清空")
    func annotationsGoToAI() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        try fake.script(StreamJSON.reply(["改好了"]), call: 1)
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.setup + """
            await mc.drafts.create({ markdown: "# 标题\\n\\n第一段写得很长很长\\n\\n第二段" });
            await settle();
            const write = async (index, text) => {
              boxes()[index].focus();
              ui.click("批注", { within: boxes()[index].getAttribute("aria-label").replace("选择", "") + "操作" });
              const input = document.querySelector(".stage-note-editor textarea");
              input.value = text;
              ui.click("添加");
            };
            await write(1, "太长了，精简一下");
            await write(2, "换成提示框");
            const pins = [...document.querySelectorAll(".stage-note-pin")].map((pin) => pin.textContent);
            const tray = document.querySelector(".stage-note-tray").textContent;
            document.querySelectorAll(".stage-note-pin")[0].click();
            document.querySelector(".stage-note-editor textarea").value = "太长了，砍到一半";
            ui.click("改好了");
            ui.click("交给 AI");
            const until = async (check) => { for (let i = 0; i < 200 && !(await check()); i += 1) await new Promise((resolve) => setTimeout(resolve, 50)); };
            await until(async () => (await mc.ai.history()).messages.some((message) => message.role === "end"));
            const users = (await mc.ai.history()).messages.filter((message) => message.role === "user").map((message) => message.text);
            return { pins, tray, users, after: document.querySelectorAll(".stage-note-pin").length, trayHidden: document.querySelector(".stage-note-tray").hidden };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["pins"] as? [String] == ["1", "2"])
        #expect((result?["tray"] as? String ?? "").contains("2 处批注"))
        #expect(result?["users"] as? [String] == ["按 2 处批注改"], "会话里显示简短的一句")
        let prompt = fake.prompt(0)
        #expect(prompt.contains("1. 第 1 页「第一段写得很长很长」：太长了，砍到一半"), "改过的批注：\(prompt)")
        #expect(prompt.contains("2. 第 1 页「第二段」：换成提示框"))
        #expect(prompt.contains("view_page") && prompt.contains("restyle_block"))
        #expect(result?["after"] as? Int == 0 && result?["trayHidden"] as? Bool == true, "发完清空")
        #expect(harness.pageErrors == [])
    }
}
