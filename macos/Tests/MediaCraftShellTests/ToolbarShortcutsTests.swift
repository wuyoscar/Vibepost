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

    @Test("格式条上没有段落样式（标题、列表、引用在预览里点选那一块换）；「插入」菜单的分割线插在当前段落之后")
    func toolbarHasNoBlockStylesAndInsertsDivider() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            const blockStyles = ["段落样式", "大标题", "无序列表", "有序列表", "引用"].filter((name) => ui.find(name, { within: "文字样式" }));
            await setBody("第一段\\n第二段");
            await caretAt("第一段", 1);
            clickTool("分割线");
            const { start: caret } = await mc.editor.selection();
            const divided = await markdown();
            return { blockStyles, divided, caretBeforeSecond: caret === divided.indexOf("第二段") };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["blockStyles"] as? [String] == [], "格式条上不再有段落样式的入口")
        #expect(result?["divided"] as? String == "第一段\n\n---\n\n第二段")
        #expect(result?["caretBeforeSecond"] as? Bool == true)
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
            "看看{{underline:solid|这个网站}}吧", "看看这个网站吧",
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
