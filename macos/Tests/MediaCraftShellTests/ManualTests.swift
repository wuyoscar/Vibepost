import Foundation
import Testing

/// 操作手册（src/engine/manual.js）是样式、组件、记号的唯一来源：仓库里的 docs/manual.md、编辑器左上角的「样式」与「插入」、
/// 「/」菜单、卡片上的「换样式」都照它列；中文是规范写法（英文照样认，旧稿打开时换成中文）；页尾只在一页的最后贴底；
/// 出图后每页有排版自检的问题。
@MainActor
struct ManualTests {
    static let helpers = BlockEditingTests.setup + """
        window.until = async (condition, timeout = 8000) => {
          const deadline = Date.now() + timeout;
          while (Date.now() < deadline) {
            const value = await condition();
            if (value) return value;
            await new Promise((resolve) => setTimeout(resolve, 20));
          }
          throw new Error(`等不到：${condition}`);
        };
        window.manual = window.MediaCraftManual;
        window.body = () => document.querySelector('[role="textbox"][aria-label="正文"]');
        window.stylePanel = () => document.querySelector("#styleMenu .style-menu-panel");
        window.styleLabel = () => document.querySelector("#styleMenu [data-style-current]").textContent;
        // 在左上角「样式」里点一项（展开菜单再点）
        window.pickStyle = async (name) => {
          ui.expand("段落样式");
          ui.click(name, { within: stylePanel() });
          await settle();
        };
    """

    @Test("仓库里的 docs/manual.md 与操作手册登记表写出的一字不差（改了登记表要重新运行 node scripts/build-manual.mjs）")
    func committedManualMatchesRegistry() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate("""
            const committed = await fetch("docs/manual.md").then((response) => response.text());
            const written = window.MediaCraftManual.document();
            return { same: committed === written, title: written.split("\\n")[0], escaped: written.includes("\\\\|") };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["same"] as? Bool == true, "docs/manual.md 过期了：运行 node scripts/build-manual.mjs")
        #expect(result?["title"] as? String == "# Vibepost 操作手册")
        #expect(result?["escaped"] as? Bool == false, "手册里没有转义的竖线（Agent 照抄会写坏记号）")
    }

    @Test("「样式」「插入」「/」菜单与卡片上的「换样式」都照操作手册列：同一个名字、同一句说明")
    func menusFollowTheManual() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "第一段\\n\\n- 甲\\n- 乙\\n\\n" });
            await settle();
            const family = (name) => manual.styles.filter((style) => style.family === name).map((style) => style.name);
            const components = manual.styles.filter((style) => style.component);
            const styleMenu = [...stylePanel().querySelectorAll("[data-style]")].map((item) => [ui.name(item), item.querySelector(".menu-hint").textContent]);
            const insertMenu = [...document.querySelectorAll("[data-insert-items] [data-insert]")].map((item) => [ui.name(item), item.title]);
            // 「/」菜单：在最后的空行打 /
            body().focus();
            await mc.editor.select((await markdown()).length);
            document.execCommand("insertText", false, "/");
            const slashMenu = await until(() => document.querySelector('[aria-label="快速插入"]:not([hidden])'));
            const slash = [...slashMenu.querySelectorAll('[role="option"]')].map((option) => ui.name(option));
            document.activeElement.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
            // 卡片上的「换样式」：段落一块、列表一块
            const stageMenu = async (index) => {
              boxes()[index].focus();
              ui.click("换样式");
              const items = [...document.querySelectorAll(".stage-block-menu-item")].map((item) => [item.textContent, item.title]);
              ui.click("换样式");
              return items;
            };
            const paragraph = await stageMenu(0);
            const list = await stageMenu(1);
            const summary = (name) => manual.style(name).summary;
            return {
              styleMenu: JSON.stringify(styleMenu) === JSON.stringify(manual.styles.filter((style) => style.family === "text").concat(manual.styles.filter((style) => style.family === "list")).map((style) => [style.name, style.summary])),
              insertMenu: insertMenu.map(([name]) => name),
              insertTitles: insertMenu.every(([name, title]) => title.startsWith(manual.inserts.find((item) => item.name === name)?.summary ?? summary(name))),
              slash,
              expectedSlash: [...manual.inserts.map((item) => item.name), ...components.map((style) => style.name)],
              paragraph: paragraph.map(([name]) => name), paragraphTitles: paragraph.every(([name, title]) => title === summary(name)),
              list: list.map(([name]) => name), textFamily: family("text"), listFamily: [...family("list"), "正文"],
              kicker: [manual.style("kicker").name, manual.style("小标签").id, manual.style("kicker").summary],
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["styleMenu"] as? Bool == true, "「样式」：段落类、列表类，每项带一句说明")
        #expect(result?["insertMenu"] as? [String] == ["分割线", "分页", "结尾页", "代码块", "小标签", "提示", "页尾", "等宽", "标签列表", "步骤"])
        #expect(result?["insertTitles"] as? Bool == true, "「插入」每项悬停有说明")
        #expect(result?["slash"] as? [String] == result?["expectedSlash"] as? [String])
        #expect(result?["paragraph"] as? [String] == result?["textFamily"] as? [String])
        #expect(result?["paragraphTitles"] as? Bool == true, "卡片上的「换样式」悬停也是同一句说明")
        #expect(result?["list"] as? [String] == result?["listFamily"] as? [String])
        #expect(result?["kicker"] as? [String] == ["小标签", "kicker", "标题上方或旁边的一行小字"], "kicker 就是小标签")
        #expect(harness.pageErrors == [])
    }

    @Test("左上角「样式」：写着光标所在那块的样式；点一项就换（选了几块就一起换）、组件能设对齐；每次都是 ⌘Z 一步撤回")
    func styleMenuRestyles() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# 标题\\n\\n第一段\\n\\n第二段\\n\\n第三段" });
            await settle();
            await mc.editor.select("# 标题\\n\\n第".length);
            const onParagraph = styleLabel();
            await pickStyle("小标签");
            const kicker = await markdown();
            const onKicker = styleLabel();
            ui.expand("段落样式");
            const alignEnabled = !ui.find("居中", { within: stylePanel() }).disabled;
            ui.click("居中", { within: stylePanel() });
            await settle();
            const centered = await markdown();
            const text = await markdown();
            await mc.editor.select(text.indexOf("第二段"), text.indexOf("第三段") + 1);
            await pickStyle("引用");
            const quoted = await markdown();
            await mc.drafts.undo();
            const undone = await markdown();
            await mc.editor.select(2, 2);
            const onHeading = styleLabel();
            ui.expand("段落样式");
            const alignOnHeading = ui.find("居中", { within: stylePanel() }).disabled;
            ui.expand("段落样式");
            return { onParagraph, kicker, onKicker, alignEnabled, centered, quoted, undone, onHeading, alignOnHeading };
        """) as? [String: Any]
        _ = try await harness.evaluate("const menu = document.querySelector('#styleMenu'); menu.open = true; await new Promise((resolve) => setTimeout(resolve, 400));")
        try await harness.screenshot("style-menu", of: ".editor-pane")
        await harness.tearDown()

        #expect(result?["onParagraph"] as? String == "正文")
        #expect(result?["kicker"] as? String == "# 标题\n\n:::小标签\n第一段\n:::\n\n第二段\n\n第三段")
        #expect(result?["onKicker"] as? String == "小标签")
        #expect(result?["alignEnabled"] as? Bool == true, "光标在组件里时能设对齐")
        #expect(result?["centered"] as? String == "# 标题\n\n:::小标签 居中\n第一段\n:::\n\n第二段\n\n第三段")
        #expect(result?["quoted"] as? String == "# 标题\n\n:::小标签 居中\n第一段\n:::\n\n> 第二段\n\n> 第三段", "选中的两块一起换")
        #expect(result?["undone"] as? String == "# 标题\n\n:::小标签 居中\n第一段\n:::\n\n第二段\n\n第三段", "⌘Z 一步撤回")
        #expect(result?["onHeading"] as? String == "大标题")
        #expect(result?["alignOnHeading"] as? Bool == true, "不是组件时对齐按钮不能点")
        #expect(harness.pageErrors == [])
    }

    @Test("中文写法：中文与英文写法画出来一样（全角冒号也认）；英文写法换成中文时只换真正的记号，代码里的不动")
    func chineseAndEnglishRenderTheSame() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate("""
            const english = ":::kicker align=center\\n论文\\n:::\\n\\n{{color:#d9480f|红}} {{bg:#fff3bf|黄}} {{underline:dashed|虚}} {{mark:甲|注}}\\n\\n[[image:a1]]\\n\\n[[image:a1|b2|4x3]]\\n\\n:::rows\\n- [甲] 一\\n:::\\n\\n:::note 居右\\n靠右的提示\\n:::";
            const chinese = ":::小标签 居中\\n论文\\n:::\\n\\n{{字色:#d9480f|红}} {{高亮:#fff3bf|黄}} {{下划线:虚线|虚}} {{标注:甲|注}}\\n\\n[[图片:a1]]\\n\\n[[图片:a1|b2|4x3]]\\n\\n:::标签列表\\n- [甲] 一\\n:::\\n\\n:::提示 靠右\\n靠右的提示\\n:::";
            const engine = window.MediaCraftEngine;
            const html = (text) => window.MediaCraftCardHtml.blocks(engine.parseMarkdown(text, { containers: true }), {})
              .map((block) => `${block.type} ${block.html.replace(/ data-(?:content-src|src|s)="[^"]*"/g, "")}`).join("\\n");
            const code = "```\\n{{color:#fff|代码里}} [[image:x]]\\n```\\n行内 `:::kicker` 与 `{{bg:#fff|行内代码}}`";
            return {
              same: html(english) === html(chinese),
              aligned: html(chinese).includes('data-align="center"') && html(chinese).includes('data-align="right"'),
              fullWidth: html("{{字色：#d9480f|红}}") === html("{{字色:#d9480f|红}}"),
              localized: engine.localizeMarkers(english) === chinese,
              again: engine.localizeMarkers(chinese) === chinese,
              code: engine.localizeMarkers(code) === code,
            };
        """) as? [String: Bool]
        await harness.tearDown()

        #expect(result?["same"] == true, "中英文写法画出来一样")
        #expect(result?["aligned"] == true, "「居中」「靠右」写成一个词也认")
        #expect(result?["fullWidth"] == true, "全角冒号也认")
        #expect(result?["localized"] == true, "英文写法换成中文写法")
        #expect(result?["again"] == true, "已经是中文的不再变")
        #expect(result?["code"] == true, "代码块、行内代码里的不动")
        #expect(harness.pageErrors == [])
    }

    @Test("打开旧稿：英文记号一次换成中文写法（代码里的不动），不算修改、修改时间不变；每轮 AI 之前存的版本也换，写回存储")
    func oldDraftsAreLocalizedOnOpen() async throws {
        let harness = ShellHarness(onboarding: false)
        let english = ":::kicker\n论文名\n:::\n\n{{color:#d9480f|红字}}\n\n```\n{{color:#fff|代码里}}\n```"
        let version: [String: Any] = ["id": "turn-1", "at": 1, "label": "一", "draft": [
            "title": "旧", "markdown": ":::note align=center\n一轮之前\n:::", "mode": "cards", "theme": "notes", "colors": [:], "images": [:],
        ]]
        let seed = ["drafts": [[
            "id": "old_english", "title": "旧稿", "markdown": english, "mode": "cards", "theme": "notes", "colors": [:],
            "fonts": ["zh": "theme", "en": "theme", "code": "theme"], "images": [:], "createdAt": 1, "updatedAt": 1_700_000_000_000, "versions": [version],
        ] as [String: Any]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: seed), as: UTF8.self)
        try await harness.prepareStorage(StorageScripts.seed + """
            await seedStore(\(json));
            localStorage.setItem("mediacraft.prefs.v1", JSON.stringify({ currentDraftId: "old_english" }));
        """)
        try await harness.load()
        let result = try await harness.evaluate(StorageScripts.read + """
            const mc = window.mediacraft;
            const current = await mc.drafts.current();
            const listed = (await mc.drafts.list()).find((item) => item.id === "old_english");
            const stored = await readStore("drafts", "old_english");
            return {
              markdown: current.markdown, updatedAt: listed.updatedAt, stored: stored.markdown,
              version: stored.versions[0].draft.markdown, storedUpdatedAt: stored.updatedAt,
            };
        """) as? [String: Any]
        await harness.tearDown()

        let chinese = ":::小标签\n论文名\n:::\n\n{{字色:#d9480f|红字}}\n\n```\n{{color:#fff|代码里}}\n```"
        #expect(result?["markdown"] as? String == chinese)
        #expect(result?["stored"] as? String == chinese, "换过的写回存储")
        #expect(result?["version"] as? String == ":::提示 居中\n一轮之前\n:::", "版本也换")
        #expect(result?["updatedAt"] as? Double == 1_700_000_000_000, "不算修改，修改时间不变")
        #expect(result?["storedUpdatedAt"] as? Double == 1_700_000_000_000)
        #expect(harness.pageErrors == [])
    }

    @Test("页尾：写在页中间时原地显示（离上一块是正常间距，后面的内容接着排）；是这一页最后一块时贴到底")
    func footnotePinsOnlyWhenLast() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create();
            const measure = async (markdown) => {
              await mc.drafts.update({ markdown });
              const [page] = await mc.render.pages();
              const line = (text) => page.items.find((item) => item.kind === "text" && item.text.includes(text));
              return { page, line };
            };
            const middle = await measure("# 标题\\n\\n:::页尾\\n写在中间的页尾\\n:::\\n\\n后面的一段");
            const title = middle.line("标题");
            const note = middle.line("写在中间的页尾");
            const after = middle.line("后面的一段");
            const last = await measure("# 标题\\n\\n一段正文\\n\\n:::页尾\\n出处：某某\\n:::");
            const pinned = last.line("出处：某某");
            const body = last.line("一段正文");
            return {
              gapBefore: note.y - (title.y + title.height),
              afterBelow: after.y > note.y && after.y - (note.y + note.height) < 120,
              pinnedNearBottom: last.page.contentBounds.bottom - (pinned.y + pinned.height),
              pinnedFar: pinned.y - (body.y + body.height),
            };
        """) as? [String: Double]
        await harness.tearDown()

        #expect((result?["gapBefore"] ?? 999) < 120, "写在中间：紧接着上一块 \(result ?? [:])")
        #expect(result?["afterBelow"] == 1, "后面的一段接在页尾下面")
        #expect((result?["pinnedNearBottom"] ?? 999) < 60, "最后一块：贴在正文区底部 \(result ?? [:])")
        #expect((result?["pinnedFar"] ?? 0) > 300, "最后一块：和上一块之间留出空白")
        #expect(harness.pageErrors == [])
    }

    @Test("排版自检：只有标题的页、太空的页（最后一页不算）、偏挤的页、溢出的页，在页面摘要的 issues 里列出")
    func layoutIssues() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# 只有标题\\n\\n[[分页]]\\n\\n第二页只有一行字\\n\\n[[分页]]\\n\\n最后一页也只有一行" });
            const pages = await mc.render.pages();
            // 偏挤、溢出：直接给页面摘要（真实出图时放不下的会自动换页，很难凑出来）
            const check = (page) => window.MediaCraftLayoutCheck.issues([{ role: "body", fill: 0.8, chars: 20, overflow: false, items: [{ kind: "text", blockType: "p" }], ...page }])[0].map((issue) => issue.id);
            return {
              ids: pages.map((page) => page.issues.map((issue) => issue.id)), text: pages[1].issues[0]?.text ?? "",
              dense: check({ chars: 320 }), overflow: check({ overflow: true }), fine: check({}),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["ids"] as? [[String]] == [["headingOnly"], ["sparse"], []], "\(result?["ids"] ?? "")")
        #expect((result?["text"] as? String)?.hasPrefix("太空：正文只占正文区的") == true)
        #expect(result?["dense"] as? [String] == ["dense"])
        #expect(result?["overflow"] as? [String] == ["overflow"])
        #expect(result?["fine"] as? [String] == [])
        #expect(harness.pageErrors == [])
    }
}
