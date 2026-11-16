import Testing

@MainActor
struct ToolbarShortcutsTests {
    /// 用户操作的入口：写正文、把光标放到某段文字上、点工具条按钮（按可访问名称找）、按快捷键。
    static let helpers = """
        const mc = window.mediacraft;
        window.markdown = async () => (await mc.drafts.current()).markdown;
        window.setBody = (text) => mc.drafts.update({ markdown: text });
        window.caretAt = async (text, offset = 0) => {
          const at = (await markdown()).indexOf(text) + offset;
          await mc.editor.select(at);
        };
        window.selectText = async (text) => {
          const at = (await markdown()).indexOf(text);
          await mc.editor.select(at, at + text.length);
        };
        // 格式条上的按钮（只管写字：行内格式、插入、源码；段落样式在预览里点选那一块换）；插入项在下拉菜单里，先展开再点
        window.inMenu = { 分割线: "插入", 分页: "插入" };
        window.tool = (name) => {
          if (inMenu[name]) ui.expand(inMenu[name], { within: "文字样式" });
          return ui.find(name, { within: "文字样式" });
        };
        window.clickTool = (name) => tool(name).click();
        window.press = (key, modifiers = {}) => {
          const event = new KeyboardEvent("keydown", { key, metaKey: true, bubbles: true, cancelable: true, ...modifiers });
          (document.activeElement || document.body).dispatchEvent(event);
          return event.defaultPrevented;
        };
        window.lines = async () => (await markdown()).split("\\n");
        window.settle = () => new Promise((resolve) => setTimeout(resolve, 80));
        // 格式条（含收起的菜单）里处于选中态的按钮
        window.activeFormats = () => [...document.querySelector('[aria-label="文字样式"]').querySelectorAll('[aria-pressed="true"]')]
          .map((button) => ui.name(button));
    """

    @Test("格式条上的 A− / A+：每按一下这篇的字号 ±1（和检查器的字号滑块同一个值），到 18 / 40 按钮变灰；⇧⌘> / ⇧⌘< 在哪都能按；是撤销历史里的一步")
    func fontSizeButtons() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            window.until = async (condition, timeout = 15000) => {
              const started = Date.now();
              while (!(await condition())) {
                if (Date.now() - started > timeout) throw new Error("等不到条件");
                await new Promise((resolve) => setTimeout(resolve, 50));
              }
            };
            await mc.drafts.create({ markdown: "# 标题\\n\\n一段。" });
            const slider = () => Number(document.querySelector("#fontSizeInput").value);
            const start = (await mc.drafts.current()).fontSize;
            clickTool("字号增大");
            await until(async () => (await mc.drafts.current()).fontSize === start + 1);
            const up = { size: (await mc.drafts.current()).fontSize, slider: slider(), title: tool("字号增大").title };
            await mc.drafts.update({ fontSize: 40 });
            await settle();
            const atMax = [tool("字号增大").disabled, tool("字号减小").disabled];
            // 到顶了：快捷键再按不动；减小的快捷键能按
            document.body.focus();
            press(".", { shiftKey: true, code: "Period" });
            await settle();
            const stillMax = (await mc.drafts.current()).fontSize;
            const handled = press(",", { shiftKey: true, code: "Comma" });
            await until(async () => (await mc.drafts.current()).fontSize === 39);
            const down = (await mc.drafts.current()).fontSize;
            const undone = (await mc.drafts.undo()).fontSize;
            await mc.drafts.update({ fontSize: 18 });
            await settle();
            const atMin = [tool("字号增大").disabled, tool("字号减小").disabled];
            return { start, up, atMax, stillMax, handled, down, undone, atMin };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["start"] as? Int == 34)
        let up = result?["up"] as? [String: Any]
        #expect(up?["size"] as? Int == 35 && up?["slider"] as? Int == 35, "按一下 +1，滑块跟着：\(up ?? [:])")
        #expect((up?["title"] as? String ?? "").contains("35"), "提示里写着现在的字号：\(up?["title"] ?? "")")
        #expect(result?["atMax"] as? [Bool] == [true, false], "到 40 增大变灰")
        #expect(result?["stillMax"] as? Int == 40 && result?["handled"] as? Bool == true)
        #expect(result?["down"] as? Int == 39, "⇧⌘< 减一")
        #expect(result?["undone"] as? Int == 40, "是撤销历史里的一步")
        #expect(result?["atMin"] as? [Bool] == [false, true], "到 18 减小变灰")
        #expect(harness.pageErrors == [])
    }

    @Test("格式条最左边是「样式」（写着光标所在那块的样式，详见 StyleMenuTests）；「插入」菜单的分割线插在当前段落之后")
    func toolbarShowsStyleMenuAndInsertsDivider() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            await setBody("第一段\\n第二段");
            await caretAt("第一段", 1);
            clickTool("分割线");
            const { start: caret } = await mc.editor.selection();
            const divided = await markdown();
            const styleMenu = document.querySelector('[role="toolbar"][aria-label="文字样式"] > *:first-child summary');
            return { styleMenu: styleMenu ? [ui.name(styleMenu), styleMenu.textContent.trim()] : null, divided, caretBeforeSecond: caret === divided.indexOf("第二段") };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["styleMenu"] as? [String] == ["段落样式", "正文"], "格式条最左边是「样式」（可访问名称「段落样式」，和检查器的「样式」标签区分），写着光标所在那块是正文")
        #expect(result?["divided"] as? String == "第一段\n\n---\n\n第二段")
        #expect(result?["caretBeforeSecond"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("光标停在一段的末尾（刚打完字的位置）：「样式」照样写着这一块是什么、各项能点，点「小标题」换的就是这一段；空行上没有块，各项是灰的")
    func styleMenuWorksAtTheEndOfABlock() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            await setBody("第一段内容\\n\\n## 已经是小标题\\n\\n最后一段");
            const menu = document.querySelector("#styleMenu");
            const state = () => [menu.querySelector("[data-style-current]").textContent, menu.querySelector('[data-style="h2"]').disabled];
            const seen = {};
            await caretAt("第一段内容", 5); await settle(); seen.endOfFirst = state();
            await caretAt("第一段内容", 0); await settle(); seen.startOfFirst = state();
            await caretAt("第一段内容", 6); await settle(); seen.blankLine = state();
            await caretAt("已经是小标题", 6); await settle(); seen.endOfHeading = state();
            await caretAt("最后一段", 4); await settle(); seen.endOfDocument = state();
            // 文末：点「小标题」，换的是最后一段
            menu.open = true;
            menu.querySelector('[data-style="h2"]').click();
            await settle();
            const restyled = await markdown();
            // 第一段的末尾：点「引用」
            await caretAt("第一段内容", 5); await settle();
            menu.open = true;
            menu.querySelector('[data-style="quote"]').click();
            await settle();
            return { seen, restyled, quoted: await markdown() };
        """) as? [String: Any]
        await harness.tearDown()

        let seen = result?["seen"] as? [String: [Any]] ?? [:]
        func shows(_ key: String, _ name: String, disabled: Bool) -> Bool {
            seen[key]?.first as? String == name && seen[key]?.last as? Bool == disabled
        }
        #expect(shows("endOfFirst", "正文", disabled: false), "一段的末尾算在这一段里：\(seen["endOfFirst"] ?? [])")
        #expect(shows("startOfFirst", "正文", disabled: false))
        #expect(shows("blankLine", "样式", disabled: true), "空行上没有块：\(seen["blankLine"] ?? [])")
        #expect(shows("endOfHeading", "小标题", disabled: false))
        #expect(shows("endOfDocument", "正文", disabled: false), "文末（刚打完字）：\(seen["endOfDocument"] ?? [])")
        #expect(result?["restyled"] as? String == "第一段内容\n\n## 已经是小标题\n\n## 最后一段")
        #expect(result?["quoted"] as? String == "> 第一段内容\n\n## 已经是小标题\n\n## 最后一段")
        #expect(harness.pageErrors == [])
    }

    @Test("光标所在处的行内格式在按钮上显示选中态；按钮标出快捷键")
    func activeStateFollowsCaretAndTooltipsShowShortcuts() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            await setBody("**加粗的字** *斜体的字* 普通的字");
            const active = [];
            for (const text of ["加粗的字", "斜体的字", "普通的字"]) {
              await caretAt(text, 1);
              await settle();
              active.push(activeFormats().join(","));
            }
            return {
              active,
              keys: ["加粗", "斜体", "下划线"].map((name) => tool(name).getAttribute("aria-keyshortcuts")),
              tips: ["加粗", "斜体", "下划线"].map((name) => tool(name).title),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["active"] as? [String] == ["加粗", "斜体", ""])
        #expect(result?["keys"] as? [String] == ["Meta+B", "Meta+I", "Meta+U"])
        let tips = result?["tips"] as? [String] ?? []
        #expect(zip(tips, ["⌘B", "⌘I", "⌘U"]).allSatisfy { $0.contains($1) } && tips.count == 3, "图标按钮的提示写出快捷键：\(tips)")
        #expect(harness.pageErrors == [])
    }

    @Test("⌘1 / ⌘2 / ⌘3 设标题、⌘0 回正文、⌘U 下划线、⌘K 把选中文字变成链接并把光标放进网址")
    func formattingShortcuts() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            await setBody("标题行\\n看看这个网站吧");
            const steps = [];
            await caretAt("标题行");
            press("2"); steps.push((await lines())[0]);
            press("1"); steps.push((await lines())[0]);
            press("3"); steps.push((await lines())[0]);
            press("0"); steps.push((await lines())[0]);
            await selectText("这个网站");
            press("u"); steps.push((await lines())[1]);
            press("u"); steps.push((await lines())[1]);
            await selectText("这个网站");
            press("k"); steps.push((await lines())[1]);
            const { start, end } = await mc.editor.selection();
            const text = await markdown();
            const caretInUrl = start === end && text[start - 1] === "(" && text[start] === ")";
            await selectText("看看");
            press("b"); steps.push((await lines())[1]);
            press("z"); steps.push((await lines())[1]);
            return { steps, caretInUrl };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["steps"] as? [String] == [
            "## 标题行", "# 标题行", "### 标题行", "标题行",
            "看看{{下划线:实线|这个网站}}吧", "看看这个网站吧",
            "看看[这个网站]()吧",
            "**看看**[这个网站]()吧", "看看[这个网站]()吧",
        ])
        #expect(result?["caretInUrl"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("⌘F 打开查找；⌃⌘F 留给系统全屏，页面不拦截")
    func findShortcutLeavesControlCommandFToFullScreen() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            // 查找栏打开、光标在查找框里
            const findOpen = () => ui.find("查找替换").getAttribute("aria-expanded") === "true" && document.activeElement === ui.find("查找");
            await mc.editor.focus();
            const fullScreenIntercepted = press("f", { ctrlKey: true });
            const openedByFullScreenKey = findOpen();
            await mc.editor.focus();
            const findIntercepted = press("f");
            return { fullScreenIntercepted, openedByFullScreenKey, findIntercepted, findOpened: findOpen() };
        """) as? [String: Bool]
        await harness.tearDown()

        #expect(result == ["fullScreenIntercepted": false, "openedByFullScreenKey": false, "findIntercepted": true, "findOpened": true])
        #expect(harness.pageErrors == [])
    }
}
