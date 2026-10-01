import Testing

/// 查找栏：⌘F / ⌥⌘F 打开，⌘G / ⇧⌘G 与 ↩ / ⇧↩ 跳转并循环，替换、全部替换（一步撤销），只读时不能换，Esc 收起。
@MainActor
struct FindReplaceTests {
    static let helpers = """
        const mc = window.mediacraft;
        window.press = (key, modifiers = {}) => {
          const event = new KeyboardEvent("keydown", { key, metaKey: true, bubbles: true, cancelable: true, ...modifiers });
          (document.activeElement || document.body).dispatchEvent(event);
          return event.defaultPrevented;
        };
        window.typeInto = (name, text) => {
          const input = ui.find(name, { within: "查找替换" });
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        };
        window.enter = (name, modifiers = {}) => ui.find(name, { within: "查找替换" })
          .dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true, ...modifiers }));
        window.count = () => document.querySelector('[role="search"] [aria-live]').textContent;
        window.picked = async () => {
          const { start, end } = await mc.editor.selection();
          return `${start}-${end}`;
        };
        window.settle = () => new Promise((resolve) => setTimeout(resolve, 50));
    """

    @Test("⌘F 带上选中的字打开查找栏；打字就跳到第一处；⌘G / ⇧⌘G、↩ / ⇧↩ 前后跳并循环，不分大小写；Esc 收起回到正文")
    func findNavigates() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "Apple 苹果 apple\\n\\n**APPLE** pie 苹果" });
            await mc.editor.select(6, 8);
            press("f");
            const prefilled = { value: ui.find("查找", { within: "查找替换" }).value, focused: document.activeElement === ui.find("查找", { within: "查找替换" }), count: count() };
            typeInto("查找", "apple");
            await settle();
            const typed = [await picked(), count()];
            const steps = [];
            press("g"); steps.push(await picked());
            press("g"); steps.push(await picked());
            press("g"); steps.push(await picked());
            press("g", { shiftKey: true }); steps.push(await picked());
            enter("查找"); steps.push(await picked());
            enter("查找", { shiftKey: true }); steps.push(await picked());
            ui.click("下一个", { within: "查找替换" }); steps.push(await picked());
            typeInto("查找", "没有的字");
            await settle();
            const none = count();
            ui.find("查找", { within: "查找替换" }).dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
            await settle();
            return {
              prefilled, typed, steps, none,
              closed: ui.find("查找替换").getAttribute("aria-expanded"),
              editorFocused: document.activeElement.closest("#markdownEditor") !== null,
              highlights: document.querySelectorAll(".cm-find-match").length,
            };
        """) as? [String: Any]
        await harness.tearDown()

        let prefilled = result?["prefilled"] as? [String: Any]
        #expect(prefilled?["value"] as? String == "苹果")
        #expect(prefilled?["focused"] as? Bool == true)
        #expect(prefilled?["count"] as? String == "1/2", "选中的正好是第一处")
        #expect(result?["typed"] as? [String] == ["9-14", "2/3"], "从光标处往后找第一处")
        #expect(result?["steps"] as? [String] == ["18-23", "0-5", "9-14", "0-5", "9-14", "0-5", "9-14"], "到头了从另一头接着找")
        #expect(result?["none"] as? String == "无结果")
        #expect(result?["closed"] as? String == "false")
        #expect(result?["editorFocused"] as? Bool == true)
        #expect(result?["highlights"] as? Int == 0, "收起后正文里不再标出")
        #expect(harness.pageErrors == [])
    }

    @Test("⌥⌘F 展开替换：替换当前这处并跳到下一处，全部替换是一步撤销；内置说明书里能找不能换")
    func replaceAndUndo() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "猫 狗 猫\\n猫" });
            await mc.editor.select(0);
            press("f", { altKey: true });
            const replaceShown = ui.find("替换成", { within: "查找替换" }) !== null;
            typeInto("查找", "猫");
            typeInto("替换成", "鱼");
            await settle();
            ui.click("替换", { within: "查找替换" });
            await settle();
            const one = [(await mc.drafts.current()).markdown, await picked(), count()];
            ui.click("全部替换", { within: "查找替换" });
            const all = [(await mc.drafts.current()).markdown, document.querySelector("#statusText").textContent, count()];
            const undone = (await mc.drafts.undo()).markdown;
            const guide = (await mc.drafts.list()).find((item) => item.builtIn);
            await mc.drafts.open(guide.id);
            press("f");
            typeInto("查找", "说明书");
            await settle();
            return {
              replaceShown, one, all, undone,
              guideCount: count(),
              guideButtons: ["替换", "全部替换"].map((name) => ui.find(name, { within: "查找替换" })?.disabled),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["replaceShown"] as? Bool == true)
        #expect(result?["one"] as? [String] == ["鱼 狗 猫\n猫", "4-5", "1/2"])
        #expect(result?["all"] as? [String] == ["鱼 狗 鱼\n鱼", "已替换 2 处", "无结果"])
        #expect(result?["undone"] as? String == "鱼 狗 猫\n猫", "全部替换一步撤回")
        #expect((result?["guideCount"] as? String)?.contains("/") == true, "只读时照样能找")
        #expect(result?["guideButtons"] as? [Bool] == [true, true])
        #expect(harness.pageErrors == [])
    }
}
