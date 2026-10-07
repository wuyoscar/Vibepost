import Foundation
import Testing

/// 实时预览编辑器（ADR 0002）：看到的是排好的样子，光标所在行露出标记；源码开关；小部件；浮动条、「/」菜单、快捷键与撤销。
/// 只通过 App API、界面（可访问名称、编辑区里看得见的文字）和真实的键盘 / 输入事件说话。
@MainActor
struct LivePreviewEditorTests {
    static let helpers = """
        const mc = window.mediacraft;
        window.mc = mc; // 后面分开执行的脚本也能用
        window.markdown = async () => (await mc.drafts.current()).markdown;
        window.setBody = (text) => mc.drafts.update({ markdown: text });
        // 等到条件成立（浮动条、菜单有显示延迟，编辑器读回输入的 DOM 改动也可能晚一点），超时报出等的是什么
        window.until = async (condition, timeout = 5000) => {
          const deadline = Date.now() + timeout;
          while (Date.now() < deadline) {
            const value = await condition();
            if (value) return value;
            await new Promise((resolve) => setTimeout(resolve, 10));
          }
          throw new Error(`等不到：${condition}`);
        };
        // 编辑区：可访问名称「正文」的文本框；每个子元素是一行
        window.body = () => document.querySelector('[role="textbox"][aria-label="正文"]');
        // 看得见的字（不算只给眼睛看的占位提示）
        window.shownText = (element) => {
          const copy = element.cloneNode(true);
          copy.querySelectorAll('[aria-hidden="true"]').forEach((node) => node.remove());
          return copy.textContent;
        };
        window.shownLines = () => [...body().children].map(shownText);
        window.lineOf = (text) => [...body().children].find((line) => line.textContent.includes(text));
        window.caretAt = async (text, offset = 0) => mc.editor.select((await markdown()).indexOf(text) + offset);
        window.selectText = async (text) => {
          const at = (await markdown()).indexOf(text);
          return mc.editor.select(at, at + text.length);
        };
        // 真实的键盘事件：发给当前焦点（编辑区）
        window.press = (key, modifiers = {}) => {
          const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...modifiers });
          (document.activeElement || document.body).dispatchEvent(event);
          return event.defaultPrevented;
        };
        window.cmd = (key, extra = {}) => press(key, { metaKey: true, ...extra });
        // 像键盘打字一样在光标处输入（浏览器改编辑区的 DOM，编辑器从 DOM 读回改动）
        window.type = async (text) => {
          const before = await markdown();
          document.execCommand("insertText", false, text);
          await until(async () => (await markdown()) !== before);
        };
        window.visible = (element) => Boolean(element) && element.getClientRects().length > 0 && !element.closest("[hidden]");
    """

    @Test("实时预览：标题、加粗、颜色、列表、引用显示成排好的样子，光标所在行才露出 Markdown 标记")
    func markersHiddenOffCaretAndShownOnCaretLine() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            await setBody("# 大标题\\n**加粗** 和 {{color:#d9480f|红字}} 还有 [链接](https://example.com)\\n- 列表项\\n2. 第二项\\n> 引用的话\\n\\n最后一行");
            await caretAt("最后一行");
            await until(() => lineOf("大标题")?.textContent === "大标题");
            const away = shownLines();
            const heading = lineOf("大标题");
            const styled = {
              headingBig: parseFloat(getComputedStyle(heading).fontSize) > parseFloat(getComputedStyle(lineOf("最后一行")).fontSize),
              bold: getComputedStyle([...lineOf("加粗").querySelectorAll("*")].find((node) => node.textContent === "加粗")).fontWeight,
              red: getComputedStyle([...lineOf("红字").querySelectorAll("*")].find((node) => node.textContent === "红字")).color,
              quoteBar: getComputedStyle(lineOf("引用的话")).borderLeftWidth,
            };
            await caretAt("大标题");
            await until(() => lineOf("大标题").textContent.startsWith("#"));
            const onHeading = lineOf("大标题").textContent;
            await caretAt("红字");
            await until(() => lineOf("红字").textContent.startsWith("**"));
            const onInline = lineOf("红字").textContent;
            await caretAt("第二项");
            await until(() => lineOf("第二项").textContent.startsWith("2. "));
            const onList = [lineOf("列表项").textContent, lineOf("第二项").textContent];
            return { away, styled, onHeading, onInline, onList, stored: await markdown() };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["away"] as? [String] == ["大标题", "加粗 和 红字 还有 链接", "•列表项", "2.第二项", "引用的话", "", "最后一行"])
        let styled = result?["styled"] as? [String: Any]
        #expect(styled?["headingBig"] as? Bool == true)
        #expect(styled?["bold"] as? String == "700")
        #expect(styled?["red"] as? String == "rgb(217, 72, 15)")
        #expect(styled?["quoteBar"] as? String == "3px")
        #expect(result?["onHeading"] as? String == "# 大标题", "光标行露出标题标记")
        #expect(result?["onInline"] as? String == "**加粗** 和 {{color:#d9480f|红字}} 还有 [链接](https://example.com)")
        #expect(result?["onList"] as? [String] == ["•列表项", "2. 第二项"], "只牵连光标所在的那一行")
        #expect(result?["stored"] as? String == "# 大标题\n**加粗** 和 {{color:#d9480f|红字}} 还有 [链接](https://example.com)\n- 列表项\n2. 第二项\n> 引用的话\n\n最后一行")
        #expect(harness.pageErrors == [])
    }

    /// docs/markdown-syntax.md 里每一种写法（含边界情况与 \r、制表符、全角空格、Emoji）
    static let corpus: [String] = [
        "# 标题\n## 标题\n### 标题\n#### 四级\n###### 六级",
        "#标题\n#\n# \n####### 七个井号\n# 标题 #\n   # 缩进标题",
        "第一行\n第二行\n\n另一段\n\n\n\n多空几行",
        "- 项目\n* 项目\n+ 项目\n1. 项目\n2) 项目\n7. 七\n001. 零零一\n2024. 年份",
        "-无空格\n1.无空格\n3、三\n- \n1.\n  - 子项\n- [ ] 待办\n* *斜*\n- - -",
        "> 引用\n> 第二行\n>\n> 空行之后\n\n> 另一段\n>文字\n>\t制表符\n＞ 全角\n> # 文字\n> > 文字",
        "---\n***\n___\n- - -\n* * *\n----------\n-- -\n--\n* *\n-*-\n——",
        "**加粗** *斜体* ***加粗斜体*** ~~删除线~~ `代码`",
        "**粗*斜*粗** *斜**粗**斜* ***粗斜** 斜*\n** 文字 ** 中**文**字\n5 * 3 = 15 **没写完\n**a*b**c* ****四个",
        "~~删掉~~ 好开心~~ 明天见~~ ~单个~ ~~~三个~~~",
        "`**不粗**` ``a`b`` `` 两端空格 `` `没配对",
        "{{color:#d9480f|文字}} {{bg:#fff3bf|高亮}} {{underline:solid|实线}} {{underline:dashed|虚线}}",
        "{{color:#abc|短}} {{color:#d9480f80|八位}} {{color:red|颜色名}} {{underline:wavy|波浪}} {{ color:#abc|空格}}",
        "{{color:#d9480f|**粗** *斜* ~~删~~ `码` [链](https://x.com)}} **{{color:#abc|整个}}** {{color:#abc|外{{color:#def|里}}外}}",
        "{{color:#abc|a|b}} {{color:#abc|}} 空的",
        "[文字](https://example.com) [带标题](https://example.com \"标题\") [邮件](mailto:a@b.c) [相对](a/b.md) [www](www.x.com)",
        "[括号](https://x.com/(p)) [空]() [[方括号]](https://x.com) [只有方括号] https://裸网址 <https://尖括号>",
        "| 项目 | 说明 |\n| :--- | ---: |\n| 字号 | **34** |\n| 行距 | 1.6 |",
        "项目 | 说明\n--- | ---\n只有 | 表头\n\n| 一列 |\n| --- |\n\n| a | b |\n|---|---|",
        "[[image:img_a1]]\n  [[image:img_b2]]  \n文字 [[image:img_c3]] 文字\n- 列表 [[image:img_d4]] 后面\n[[image:有空格 的编号]]\n`[[image:代码里]]`",
        "[[image:img_a|img_b]]\n[[image:img_a|img_b|4x3]]\n[[image:img_a|img_b|4:3]]\n文字 [[image:img_a|img_b]]",
        "![说明](a.png)\n![说明](dir/a.png \"标题\")\n![图](a.png) 文字",
        "第一页\n[[分页]]\n  [[分页]]  \n[[分页]]\n文字[[分页]]\n[[ 分页 ]]\n［［分页］］\n[[分页]]",
        "```js\nconst answer = 42;\n```\n\n````\n```\n````\n\n```\n没有收尾\n~~~\n不是代码\n~~~\n    缩进四格",
        "\\*不转义\\* <b>HTML</b> &amp; _下划线_ __加粗__ [微笑][捂脸]",
        "Windows 换行\r\n第二行\r\n\r\n结尾\r",
        "\t制表符开头\n　全角空格开头　\n行尾空格  \n行尾反斜杠\\",
        "😀 **粗** emoji 与 𠮷 {{color:#abc|𠮷}}\n> **引用里的粗** `码`\n## 标题里 [链](https://x.com)",
        "",
        "\n\n\n",
    ]

    @Test("源码开关（⌘/ 与按钮）：显示纯 Markdown，切回来文本一字不差（每一种写法）")
    func sourceToggleRoundTripsEveryCase() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            const toggle = ui.find("源码", { within: "文字样式" });
            const failures = [];
            let pressedOn = 0;
            for (const [index, text] of corpus.entries()) {
              await setBody(text);
              await mc.editor.focus();
              if (index % 2) press("/", { metaKey: true }); else toggle.click();
              await until(() => toggle.getAttribute("aria-pressed") === "true");
              if (toggle.getAttribute("aria-pressed") === "true") pressedOn += 1;
              const shown = shownLines().join("\\n");
              const inSource = await markdown();
              if (index % 2) toggle.click(); else { await mc.editor.focus(); press("/", { metaKey: true }); }
              await until(() => toggle.getAttribute("aria-pressed") === "false");
              const back = await markdown();
              const sourceOff = toggle.getAttribute("aria-pressed") === "false";
              if (shown !== text || inSource !== text || back !== text || !sourceOff) {
                failures.push({ index, shown, inSource, back, sourceOff });
              }
            }
            return { failures: JSON.stringify(failures), pressedOn, keys: toggle.getAttribute("aria-keyshortcuts") };
        """, arguments: ["corpus": Self.corpus]) as? [String: Any]
        _ = try await harness.evaluate("""
            // update 返回时已经写进本机，不用再等
            await window.mediacraft.drafts.update({ markdown: corpus.join("\\n") });
        """, arguments: ["corpus": Self.corpus])
        try await harness.load()
        let reloaded = try await harness.evaluate("return (await window.mediacraft.drafts.current()).markdown") as? String
        // 再打开时英文记号换成了中文写法（旧稿升级），别的一字不差
        let localized = try await harness.evaluate(
            "return window.MediaCraftEngine.localizeMarkers(corpus.join('\\n'))", arguments: ["corpus": Self.corpus]
        ) as? String
        await harness.tearDown()

        #expect(result?["failures"] as? String == "[]")
        #expect(result?["pressedOn"] as? Int == Self.corpus.count, "源码模式下按钮是按下的")
        #expect(result?["keys"] as? String == "Meta+/")
        #expect(reloaded == localized, "存盘再打开也一字不差（含 \\r），只有英文记号换成了中文")
        #expect(localized != Self.corpus.joined(separator: "\n"), "语料里有英文记号")
        #expect(harness.pageErrors == [])
    }

    @Test("图片是缩略图卡片（点一下裁剪），拼图、分页、找不到的图各有样子；光标一步跨过整个标记，退格整个删掉")
    func imageAndPageBreakWidgets() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "开头\\n[[分页]]\\n结尾" });
            const png = (color) => new Promise((resolve) => {
              const canvas = document.createElement("canvas");
              canvas.width = 40;
              canvas.height = 30;
              const context = canvas.getContext("2d");
              context.fillStyle = color;
              context.fillRect(0, 0, 40, 30);
              canvas.toBlob((blob) => resolve(new File([blob], `${color === "#ff0000" ? "红" : "蓝"}.png`, { type: "image/png" })), "image/png");
            });
            const [red, blue] = await mc.media.import([await png("#ff0000"), await png("#0000ff")], { at: "开头".length });
            const text = await markdown();
            await setBody(`${text}\\n[[image:${red}|${blue}|4x3]]\\n[[image:not_here]]`);
            await caretAt("结尾");
            const card = await until(() => ui.find("编辑图片 红.png", { within: body() }));
            const widgets = {
              card: Boolean(card),
              thumb: card?.querySelector("img")?.src.startsWith("data:image/png") ?? false,
              pair: Boolean(ui.find("调整拼图 红.png + 蓝.png", { within: body() })),
              pageBreak: [...body().querySelectorAll('[role="separator"]')].map((node) => node.getAttribute("aria-label") + ":" + node.textContent),
              missing: [...body().querySelectorAll("*")].some((node) => node.textContent === "找不到这张图片"),
            };
            card.click();
            await until(() => ui.dialogs().some((dialog) => dialog.textContent.includes("裁剪 红.png")));
            const cropOpen = ui.dialogs().some((dialog) => dialog.textContent.includes("裁剪 红.png"));
            ui.click("关闭裁剪");
            // 光标在图片行首：→ 一步跨过整个标记；退格把整个标记删掉
            const current = await markdown();
            const tag = `[[图片:${red}]]`;
            await mc.editor.select(current.indexOf(tag));
            press("ArrowRight");
            const afterArrow = (await mc.editor.selection()).start - current.indexOf(tag);
            press("Backspace");
            await until(async () => (await markdown()) !== current);
            return { widgets, cropOpen, afterArrow, tagLength: tag.length, tagGone: !(await markdown()).includes(tag) };
        """) as? [String: Any]
        await harness.tearDown()

        let widgets = result?["widgets"] as? [String: Any]
        #expect(widgets?["card"] as? Bool == true, "图片显示为可点的卡片")
        #expect(widgets?["thumb"] as? Bool == true, "卡片里是这张图的缩略图")
        #expect(widgets?["pair"] as? Bool == true)
        #expect(widgets?["pageBreak"] as? [String] == ["分页:分页"], "分页是一条写着「分页」的细虚线")
        #expect(widgets?["missing"] as? Bool == true)
        #expect(result?["cropOpen"] as? Bool == true, "点缩略图打开裁剪")
        #expect(result?["afterArrow"] as? Int == result?["tagLength"] as? Int, "→ 一步跨过整个图片标记")
        #expect(result?["tagGone"] as? Bool == true, "退格整个删掉图片标记")
        #expect(harness.pageErrors == [])
    }

    @Test("选中文字弹出浮动条：加粗、斜体、下划线、字色、高亮、链接；「改写」把选中的文字交给 AI 会话")
    func selectionToolbarActions() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let shown = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            await setBody("看看这段文字吧");
            window.bar = () => document.querySelector('[role="toolbar"][aria-label="选中的文字"]');
            window.barButton = (name) => ui.find(name, { within: bar() });
            window.rewrites = [];
            document.addEventListener("mediacraft:rewrite", (event) => rewrites.push(event.detail.text));
            await selectText("这段文字");
            await until(() => visible(bar()));
            return visible(bar()) && Boolean(barButton("加粗"));
        """) as? Bool
        let result = try await harness.evaluate("""
            const steps = [];
            const step = async (action) => {
              const before = await markdown();
              await action();
              steps.push(await until(async () => {
                const after = await markdown();
                return after !== before && after;
              }));
            };
            await step(() => barButton("加粗").click());
            await step(() => barButton("加粗").click());
            await step(() => barButton("斜体").click());
            await step(() => barButton("斜体").click());
            await step(() => barButton("下划线").click());
            await step(() => barButton("下划线").click());
            // 色块跟着配色（新稿子是白主题）：名字是「字色 强调 #色值」，点了写进的就是这个色值
            barButton("字色").click();
            const colorSwatch = ui.find("字色 强调", { within: bar() });
            await step(() => colorSwatch.click());
            await selectText("这段文字");
            await step(() => { barButton("字色").click(); ui.click("去掉字色", { within: bar() }); });
            await selectText("这段文字");
            barButton("高亮").click();
            const highlightSwatch = ui.find("高亮 强调", { within: bar() });
            await step(() => highlightSwatch.click());
            await selectText("这段文字");
            await step(() => { barButton("高亮").click(); ui.click("去掉高亮", { within: bar() }); });
            await selectText("这段文字");
            await step(() => barButton("链接").click());
            await setBody("看看这段文字吧");
            await selectText("文字");
            await until(() => visible(bar()));
            barButton("改写").click();
            await until(() => rewrites.length);
            const hiddenAfterRewrite = !visible(bar());
            await selectText("看看");
            const shownAgain = Boolean(await until(() => visible(bar())));
            await mc.editor.select(0);
            await until(() => !visible(bar()));
            const hex = (swatch) => ui.name(swatch).split(" ").pop();
            return {
              steps, rewrites, unchanged: await markdown(), hiddenAfterRewrite, shownAgain, hiddenOnCaret: !visible(bar()),
              color: hex(colorSwatch), highlight: hex(highlightSwatch),
            };
        """) as? [String: Any]
        await harness.tearDown()

        let color = result?["color"] as? String ?? ""
        let highlight = result?["highlight"] as? String ?? ""
        #expect(shown == true, "选中文字后浮动条出现")
        #expect(color == "#966b00", "备忘的强调色（黄色调深到对白底够清楚）")
        #expect(highlight.hasPrefix("#") && highlight.count == 7)
        #expect(result?["steps"] as? [String] == [
            "看看**这段文字**吧", "看看这段文字吧",
            "看看*这段文字*吧", "看看这段文字吧",
            "看看{{下划线:实线|这段文字}}吧", "看看这段文字吧",
            "看看{{字色:\(color)|这段文字}}吧", "看看这段文字吧",
            "看看{{高亮:\(highlight)|这段文字}}吧", "看看这段文字吧",
            "看看[这段文字]()吧",
        ])
        #expect(result?["rewrites"] as? [String] == ["文字"], "改写把选中的文字交出去")
        #expect(result?["unchanged"] as? String == "看看这段文字吧", "改写本身不改稿子")
        #expect(result?["hiddenAfterRewrite"] as? Bool == true)
        #expect(result?["shownAgain"] as? Bool == true)
        #expect(result?["hiddenOnCaret"] as? Bool == true, "没有选中文字时不显示")
        #expect(harness.pageErrors == [])
    }

    @Test("行首输入 / 弹出插入菜单：打字筛选、↑↓ 选、回车插入，/ 与筛选词不留在正文里；行中间的 / 只是字")
    func slashMenuInserts() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            await setBody("第一段\\n");
            window.menu = () => document.querySelector('[role="listbox"][aria-label="快速插入"]');
            window.options = () => visible(menu()) ? [...menu().querySelectorAll('[role="option"]')].map(ui.name) : [];
            await mc.editor.select("第一段\\n".length);
            await type("/");
            const all = options();
            await type("fy");
            const filtered = options();
            press("Enter");
            await until(() => !visible(menu()));
            const pageBreak = await markdown();

            await setBody("标题行\\n");
            await mc.editor.select("标题行\\n".length);
            await type("/");
            press("ArrowDown");
            const selected = [...menu().querySelectorAll('[aria-selected="true"]')].map(ui.name);
            press("Escape");
            await until(() => !visible(menu()));
            const escaped = [await markdown(), visible(menu())];
            press("Backspace");
            await type("/");
            ui.click("小标签", { within: menu() });
            await until(() => !visible(menu()));
            await type("引用的话");
            const quote = await markdown();

            await setBody("中间");
            await mc.editor.select(1);
            await type("/");
            const midLine = visible(menu());

            await setBody("前文\\n");
            await mc.editor.select("前文\\n".length);
            await type("/");
            await type("xbq");
            press("Enter");
            await until(() => !visible(menu()));
            await type("核心动作");
            const component = await markdown();
            return { all, filtered, pageBreak, selected, escaped, quote, midLine, component };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["all"] as? [String] == ["图片或 PDF", "实况视频", "分割线", "分页", "结尾页", "代码块", "小标签", "提示", "页尾", "等宽", "标签列表", "步骤"])
        #expect(result?["filtered"] as? [String] == ["分页"], "拼音缩写 fy 筛出「分页」")
        #expect(result?["pageBreak"] as? String == "第一段\n[[分页]]\n")
        #expect(result?["selected"] as? [String] == ["实况视频"], "↓ 选中下一项")
        #expect(result?["escaped"] as? [Any] as? NSArray == ["标题行\n/", false] as NSArray, "Esc 收起菜单，留下打的 /")
        #expect(result?["quote"] as? String == "标题行\n:::小标签\n引用的话\n:::\n", "点菜单项插入（中文写法）")
        #expect(result?["midLine"] as? Bool == false)
        #expect(result?["component"] as? String == "前文\n:::小标签\n核心动作\n:::\n", "组件：插入开头与收尾两行，光标在中间")
        #expect(harness.pageErrors == [])
    }

    @Test("快捷键：⌘I 斜体、⇧⌘X 删除线、⌘↩ 分页、⌘/ 源码；回车续写列表与引用，空项回车结束列表")
    func moreShortcutsAndListContinuation() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            await setBody("一段话");
            const steps = [];
            await selectText("一段");
            cmd("i"); steps.push(await markdown());
            cmd("i"); steps.push(await markdown());
            cmd("x", { shiftKey: true }); steps.push(await markdown());
            await caretAt("话", 1);
            cmd("Enter"); steps.push(await markdown());
            cmd("/");
            const source = ui.find("源码", { within: "文字样式" }).getAttribute("aria-pressed");
            cmd("/");

            await setBody("- 第一项");
            await mc.editor.select("- 第一项".length);
            press("Enter");
            await type("第二项");
            press("Enter");
            press("Enter");
            const list = await markdown();
            await setBody("9. 九");
            await mc.editor.select("9. 九".length);
            press("Enter");
            await type("十");
            const ordered = await markdown();
            await setBody("> 引用");
            await mc.editor.select("> 引用".length);
            press("Enter");
            await type("续写");
            const quote = await markdown();
            return { steps, source, list, ordered, quote };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["steps"] as? [String] == ["*一段*话", "一段话", "~~一段~~话", "~~一段~~话\n[[分页]]\n"])
        #expect(result?["source"] as? String == "true")
        #expect(result?["list"] as? String == "- 第一项\n- 第二项\n", "空的列表项回车就结束列表")
        #expect(result?["ordered"] as? String == "9. 九\n10. 十", "编号接着往下数")
        #expect(result?["quote"] as? String == "> 引用\n> 续写")
        #expect(harness.pageErrors == [])
    }

    @Test("撤销 / 重做走编辑器的历史：连续打字是一步，每个格式命令、插入各是一步；换一篇稿子后撤销不到上一篇")
    func undoRedoHistory() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            await setBody("开头");
            await mc.editor.select(2);
            await type("，接着");
            await type("往下写");
            await selectText("开头");
            cmd("b");
            await caretAt("往下写", 3);
            cmd("Enter");
            const done = await markdown();
            const undone = [];
            for (let index = 0; index < 4; index += 1) {
              cmd("z");
              undone.push(await markdown());
            }
            cmd("z", { shiftKey: true });
            const redone = await markdown();
            const apiRedo = (await mc.drafts.redo()).markdown;
            const apiUndo = (await mc.drafts.undo()).markdown;

            const { id } = await mc.drafts.current();
            await mc.drafts.create({ markdown: "另一篇" });
            await mc.drafts.open(id);
            await mc.editor.focus();
            cmd("z");
            const reopened = await markdown();
            return { done, undone, redone, apiRedo, apiUndo, reopened };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["done"] as? String == "**开头**，接着往下写\n[[分页]]\n")
        #expect(result?["undone"] as? [String] == ["**开头**，接着往下写", "开头，接着往下写", "开头", ""], "⌘Z 一步步退回")
        #expect(result?["redone"] as? String == "开头")
        #expect(result?["apiRedo"] as? String == "开头，接着往下写")
        #expect(result?["apiUndo"] as? String == "开头")
        #expect(result?["reopened"] as? String == "开头", "切换稿子后撤销历史从头开始，撤销不到切换之前")
        #expect(harness.pageErrors == [])
    }

    @Test("输入法组字：组字途中编辑器不打断，组完的字只写进一次；粘贴的 [微笑] 换成 Emoji")
    func imeCompositionAndWechatPaste() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            await setBody("# 标题\\n正文");
            await mc.editor.select("# 标题".length);
            const target = body();
            target.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true, data: "" }));
            document.execCommand("insertText", false, "ni");
            target.dispatchEvent(new CompositionEvent("compositionupdate", { bubbles: true, data: "ni" }));
            await until(() => lineOf("标题")?.textContent.includes("ni"));
            const during = lineOf("标题").textContent;
            // 选字：组字时的拼音被换成选中的汉字
            getSelection().modify("extend", "backward", "character");
            getSelection().modify("extend", "backward", "character");
            document.execCommand("insertText", false, "你好");
            target.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: "你好" }));
            await until(async () => (await markdown()).includes("你好"));
            const composed = await markdown();

            await caretAt("正文", 2);
            const transfer = new DataTransfer();
            transfer.setData("text/plain", "[微笑]收到[捂脸][不认识]");
            body().dispatchEvent(new ClipboardEvent("paste", { clipboardData: transfer, bubbles: true, cancelable: true }));
            await until(async () => (await markdown()).includes("收到"));
            return { during, composed, pasted: await markdown() };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["during"] as? String == "# 标题ni", "组字时这一行照常显示（光标行露出标记）")
        #expect(result?["composed"] as? String == "# 标题你好\n正文")
        #expect(result?["pasted"] as? String == "# 标题你好\n正文🙂收到🤦[不认识]")
        #expect(harness.pageErrors == [])
    }

    @Test("两万字的稿子：打字、加粗、移动光标都在一帧左右完成")
    func largeDraftStaysFast() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            const block = "## 小标题\\n这是一段**加粗**和{{color:#d9480f|颜色}}混排的正文，用来撑到两万字。\\n- 列表项\\n> 引用\\n[[分页]]\\n\\n";
            const text = block.repeat(Math.ceil(20000 / block.length));
            await setBody(text);
            await mc.editor.select(text.length);
            await mc.render.pages(); // 计时之前让出图等排着的事做完
            const timings = { type: [], bold: [], move: [] };
            for (let index = 0; index < 20; index += 1) {
              let start = performance.now();
              document.execCommand("insertText", false, "字");
              await Promise.resolve();
              body().getBoundingClientRect();
              timings.type.push(performance.now() - start);
            }
            await until(async () => (await markdown()).endsWith("字".repeat(20)));
            for (let index = 0; index < 10; index += 1) {
              const at = Math.floor((text.length / 10) * index);
              let start = performance.now();
              await mc.editor.select(at, at + 4);
              body().getBoundingClientRect();
              timings.move.push(performance.now() - start);
              start = performance.now();
              cmd("b");
              body().getBoundingClientRect();
              timings.bold.push(performance.now() - start);
            }
            const stat = (list) => ({ average: list.reduce((a, b) => a + b, 0) / list.length, max: Math.max(...list) });
            const final = await markdown();
            return {
              length: text.length,
              typed: final.endsWith("字".repeat(20)),
              type: stat(timings.type), bold: stat(timings.bold), move: stat(timings.move),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect((result?["length"] as? Int ?? 0) >= 20000)
        #expect(result?["typed"] as? Bool == true)
        for key in ["type", "bold", "move"] {
            let stat = result?[key] as? [String: Double] ?? [:]
            #expect((stat["average"] ?? .infinity) < 30, "\(key) 平均 \(stat["average"] ?? -1) ms")
            #expect((stat["max"] ?? .infinity) < 120, "\(key) 最慢 \(stat["max"] ?? -1) ms")
        }
        #expect(harness.pageErrors == [])
    }
}
