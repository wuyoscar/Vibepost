import Foundation
import Testing

/// 片段（src/engine/snippets.js）：10 个写好的示范段落登记在一张表里，「插入」与「/」菜单各有一组「片段」照它列；
/// 点一下整段插到光标处、一次 ⌘Z 撤回；插在非空行后隔开空行；首尾的 [[分页]] 挨着已有的分页或稿子头尾时去掉，不叠出空页；
/// 含 [[结尾]] 的「结尾引导」只能插在末尾、一篇只能有一个；操作手册末尾有「片段」一节。
@MainActor
struct SnippetTests {
    static let helpers = LivePreviewEditorTests.helpers + """
        window.snippets = window.MediaCraftSnippets;
        window.manual = window.MediaCraftManual;
        window.insertPanel = () => document.querySelector("[data-insert-items]");
        window.insertMenu = () => insertPanel().closest("details");
        // 从格式条的「插入」菜单里插一个片段（展开菜单再点；点完菜单自己收起）
        window.pickSnippet = (name) => {
          ui.expand("插入", { within: "文字样式" });
          ui.click(name, { within: insertPanel() });
        };
        window.statusText = () => document.getElementById("statusText").textContent;
        window.slash = () => document.querySelector('[role="listbox"][aria-label="快速插入"]');
        window.options = () => visible(slash()) ? [...slash().querySelectorAll('[role="option"]')].map(ui.name) : [];
    """

    @Test("「插入」与「/」菜单最后都有「片段」一组：10 个片段的名字、说明来自登记表；「/」菜单按拼音缩写筛出片段；登记表里的记号都是中文写法")
    func menusListTheRegistry() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "第一段\\n" });
            const names = snippets.list.map((snippet) => snippet.name);
            ui.expand("插入", { within: "文字样式" });
            const panel = insertPanel();
            const items = [...panel.querySelectorAll('[data-insert^="snippet-"]')]
              .map((item) => [ui.name(item), item.querySelector(".menu-hint")?.textContent ?? "", item.title, item.dataset.insert]);
            // 「片段」小标题在第二条线之后、第一个片段之前，片段是菜单的最后一组
            const children = [...panel.children];
            const headingAt = children.findIndex((node) => node.classList.contains("menu-heading"));
            const structure = {
              heading: children[headingAt]?.textContent ?? "",
              ruleBefore: children[headingAt - 1]?.classList.contains("menu-rule") ?? false,
              firstAfter: children[headingAt + 1]?.dataset.insert ?? "",
              last: children.at(-1)?.dataset.insert ?? "",
              rules: children.filter((node) => node.classList.contains("menu-rule")).length,
            };
            insertMenu().open = false;

            body().focus();
            await mc.editor.select("第一段\\n".length);
            await type("/");
            await until(() => visible(slash()));
            const all = options();
            const titles = [...slash().querySelectorAll('[role="option"]')].slice(-names.length).map((option) => option.title);
            await type("sjk");
            const filtered = options();
            press("Escape");
            await until(() => !visible(slash()));

            const engine = window.MediaCraftEngine;
            const english = snippets.list.filter((snippet) => engine.localizeMarkers(snippet.markdown) !== snippet.markdown).map((snippet) => snippet.id);
            const byName = names.map((name) => snippets.get(name)?.id);
            const byId = snippets.list.map((snippet) => snippets.get(snippet.id)?.name);
            return {
              names, items, structure, all, titles, filtered, english, byName, byId,
              ids: snippets.list.map((snippet) => snippet.id),
              summaries: snippets.list.map((snippet) => snippet.summary),
              expectedAll: [...manual.inserts.map((item) => item.name), ...manual.styles.filter((style) => style.component).map((style) => style.name), ...names],
            };
        """) as? [String: Any]
        await harness.tearDown()

        let names = result?["names"] as? [String] ?? []
        #expect(names == ["三步教程", "对比", "金句页", "论文卡", "时间线", "FAQ", "清单", "前后对比", "数据卡", "结尾引导"])
        let items = result?["items"] as? [[String]] ?? []
        #expect(items.map { $0[0] } == names, "「插入」菜单里的片段就是登记表里的 10 个")
        #expect(items.map { $0[1] } == result?["summaries"] as? [String], "每项名字下面是登记表里的一句说明")
        #expect(zip(items, result?["summaries"] as? [String] ?? []).allSatisfy { $0[2].hasPrefix($1) }, "悬停也是那句说明")
        #expect(items.map { $0[3] } == (result?["ids"] as? [String] ?? []).map { "snippet-\($0)" })
        let structure = result?["structure"] as? [String: Any]
        #expect(structure?["heading"] as? String == "片段")
        #expect(structure?["ruleBefore"] as? Bool == true, "片段一组前面一条线")
        #expect(structure?["firstAfter"] as? String == "snippet-tutorial")
        #expect(structure?["last"] as? String == "snippet-ending", "片段是最后一组")
        #expect(structure?["rules"] as? Int == 2, "组件、片段各一条线隔开")
        #expect(result?["all"] as? [String] == result?["expectedAll"] as? [String], "「/」菜单：插入项、组件之后是片段")
        #expect(result?["titles"] as? [String] == result?["summaries"] as? [String], "「/」菜单里悬停是那句说明")
        #expect(result?["filtered"] as? [String] == ["数据卡"], "拼音缩写 sjk 筛出「数据卡」")
        #expect(result?["english"] as? [String] == [], "登记表里的记号都是中文写法")
        #expect(result?["byName"] as? [String] == result?["ids"] as? [String], "中文名能查到")
        #expect(result?["byId"] as? [String] == names, "id 能查到")
        #expect(harness.pageErrors == [])
    }

    @Test("插入片段：「插入」菜单与「/」菜单插进来的都是登记表里的示范文字，前后隔开空行；光标停在片段末尾；一次 ⌘Z 整段撤回")
    func insertsRegistryMarkdownInOneStep() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const tutorial = snippets.get("tutorial").markdown;
            await mc.drafts.create({ markdown: "第一段" });
            await mc.editor.select("第一段".length);
            pickSnippet("三步教程");
            const inserted = await markdown();
            const { start, end } = await mc.editor.selection();
            const caretAtEnd = start === end && end === inserted.length;
            const menuClosed = !insertMenu().open;
            body().focus();
            cmd("z");
            await until(async () => (await markdown()) === "第一段");
            const undone = await markdown();
            // 重做走 App API（合成的键盘事件没有 keyCode，⇧⌘Z 会先被当成 ⌘Z）
            const redone = (await mc.drafts.redo()).markdown;

            // 非空行的行尾、行中间都插在这一行后面，和下一段之间也隔一个空行；已经隔着空行时不再多空
            await setBody("第一段\\n第二段");
            await mc.editor.select(1);
            pickSnippet("三步教程");
            const midLine = await markdown();
            await setBody("第一段\\n\\n第二段");
            await mc.editor.select("第一段".length);
            pickSnippet("三步教程");
            const spaced = await markdown();
            await setBody("");
            await mc.editor.select(0);
            pickSnippet("三步教程");
            const empty = await markdown();

            // 「/」菜单：行首打 / 和拼音缩写，回车；/ 与缩写不留在正文里
            await setBody("第一段\\n");
            await mc.editor.select("第一段\\n".length);
            await type("/");
            await type("sbjc");
            press("Enter");
            await until(() => !visible(slash()));
            const viaSlash = await markdown();
            const slashSelection = await mc.editor.selection();
            const slashCaretAtEnd = slashSelection.start === slashSelection.end && slashSelection.end === viaSlash.length;
            cmd("z");
            await until(async () => (await markdown()) !== viaSlash);
            const slashUndone = await markdown();
            return { tutorial, inserted, caretAtEnd, menuClosed, undone, redone, midLine, spaced, empty, viaSlash, slashCaretAtEnd, slashUndone };
        """) as? [String: Any]
        await harness.tearDown()

        let tutorial = result?["tutorial"] as? String ?? ""
        #expect(tutorial.hasPrefix("## 三步把一篇论文读薄\n\n:::步骤\n- ") && tutorial.hasSuffix("\n:::"), "三步教程是写好的步骤组件")
        #expect(result?["inserted"] as? String == "第一段\n\n\(tutorial)", "插在非空行后：隔一个空行")
        #expect(result?["caretAtEnd"] as? Bool == true, "光标停在片段末尾")
        #expect(result?["menuClosed"] as? Bool == true)
        #expect(result?["undone"] as? String == "第一段", "一次 ⌘Z 整段撤回")
        #expect(result?["redone"] as? String == "第一段\n\n\(tutorial)", "重做又整段回来")
        #expect(result?["midLine"] as? String == "第一段\n\n\(tutorial)\n\n第二段", "行中间插在这一行后面，两边各隔一个空行")
        #expect(result?["spaced"] as? String == "第一段\n\n\(tutorial)\n\n第二段", "已经隔着空行时不再多空")
        #expect(result?["empty"] as? String == tutorial, "空稿子里就是片段本身")
        #expect(result?["viaSlash"] as? String == "第一段\n\n\(tutorial)", "「/」菜单插的一样，/sbjc 不留在正文里")
        #expect(result?["slashCaretAtEnd"] as? Bool == true)
        #expect(result?["slashUndone"] as? String == "第一段\n", "「/」菜单插的也是一步撤回（删掉 / 的那步不进历史）")
        #expect(harness.pageErrors == [])
    }

    @Test("金句页首尾的 [[分页]]：挨着已有的分页、稿子末尾时去掉，不叠出空页；插在两段之间时两个分页都留着，自成一页")
    func pageBreaksDoNotStack() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const quote = snippets.get("金句页").markdown;
            // 去掉两头分页的金句页正文
            const inner = quote.replace(/^\\[\\[分页\\]\\]\\n+/, "").replace(/\\n+\\[\\[分页\\]\\]$/, "");
            await mc.drafts.create({ markdown: "第一页\\n\\n[[分页]]\\n" });
            await mc.editor.select("第一页\\n\\n[[分页]]\\n".length);
            pickSnippet("金句页");
            const afterBreak = await markdown();
            const afterBreakPages = (await mc.render.pages()).length;

            await setBody("");
            await mc.editor.select(0);
            pickSnippet("金句页");
            const atStart = await markdown();
            const atStartPages = (await mc.render.pages()).length;

            await setBody("甲\\n\\n乙");
            await mc.editor.select(1);
            pickSnippet("金句页");
            const between = await markdown();
            const betweenPages = (await mc.render.pages()).length;

            await setBody("甲\\n\\n[[分页]]\\n乙");
            await mc.editor.select(1);
            pickSnippet("金句页");
            const beforeBreak = await markdown();
            const beforeBreakPages = (await mc.render.pages()).length;
            return { quote, inner, afterBreak, afterBreakPages, atStart, atStartPages, between, betweenPages, beforeBreak, beforeBreakPages };
        """) as? [String: Any]
        await harness.tearDown()

        let quote = result?["quote"] as? String ?? ""
        let body = result?["inner"] as? String ?? ""
        #expect(quote.hasPrefix("[[分页]]\n\n# ") && quote.hasSuffix("\n\n[[分页]]") && quote.contains("\n\n> "), "金句页：分页、大标题、引用、分页")
        #expect(result?["afterBreak"] as? String == "第一页\n\n[[分页]]\n\n\(body)", "紧接着已有的分页：开头的分页去掉；在稿子末尾：结尾的分页去掉")
        #expect(result?["afterBreakPages"] as? Int == 2, "两页，没有空页")
        #expect(result?["atStart"] as? String == body, "稿子开头：两头的分页都去掉")
        #expect(result?["atStartPages"] as? Int == 1)
        #expect(result?["between"] as? String == "甲\n\n\(quote)\n\n乙", "两段之间：两个分页都留着")
        #expect(result?["betweenPages"] as? Int == 3, "金句页自成一页")
        #expect(result?["beforeBreak"] as? String == "甲\n\n[[分页]]\n\n\(body)\n\n[[分页]]\n乙", "后面紧跟着分页：结尾的分页去掉")
        #expect(result?["beforeBreakPages"] as? Int == 3)
        #expect(harness.pageErrors == [])
    }

    @Test("结尾引导：只能插在稿子末尾（中间拒绝、状态栏说明、稿子不动）；插了以后排成结尾页；已有结尾页时再插也拒绝")
    func endingOnlyAtTheEnd() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const ending = snippets.get("ending").markdown;
            await mc.drafts.create({ markdown: "甲\\n\\n乙" });
            await mc.editor.select(1);
            pickSnippet("结尾引导");
            const refused = { text: await markdown(), status: statusText() };
            await mc.editor.select("甲\\n\\n乙".length);
            pickSnippet("结尾引导");
            const allowed = await markdown();
            const roles = (await mc.render.pages()).map((page) => page.role);
            await mc.editor.select(allowed.length);
            pickSnippet("结尾引导");
            const again = { text: await markdown(), status: statusText() };
            // 结尾处有空行也算末尾；直接用登记表的插入规则也是同样的拒绝
            const trailing = snippets.insert("甲\\n\\n乙\\n\\n", 6, ending).text;
            const thrown = [];
            for (const [text, at] of [["甲\\n\\n乙", 1], ["甲\\n\\n[[结尾]]\\n再见", 13]]) {
              try { snippets.insert(text, at, ending); thrown.push(""); } catch (error) { thrown.push(error.message); }
            }
            return { ending, refused, allowed, roles, again, trailing, thrown };
        """) as? [String: Any]
        await harness.tearDown()

        let ending = result?["ending"] as? String ?? ""
        #expect(ending.hasPrefix("[[结尾]]\n\n## 下期预告\n\n"), "结尾引导：结尾页记号、下期预告、关注收藏引导")
        let refused = result?["refused"] as? [String: String]
        #expect(refused?["text"] == "甲\n\n乙", "中间插：稿子不动")
        #expect(refused?["status"] == "结尾引导只能插在稿子末尾：把光标放到最后再插", "状态栏说明原因")
        #expect(result?["allowed"] as? String == "甲\n\n乙\n\n\(ending)", "末尾插：接在最后，隔一个空行")
        #expect(result?["roles"] as? [String] == ["body", "end"], "插了以后排成结尾页")
        let again = result?["again"] as? [String: String]
        #expect(again?["text"] == "甲\n\n乙\n\n\(ending)", "已有结尾页：稿子不动")
        #expect(again?["status"] == "稿子里已经有结尾页了：一篇只能有一个 [[结尾]]")
        #expect(result?["trailing"] as? String == "甲\n\n乙\n\n\(ending)", "末尾的空行不算内容")
        #expect(result?["thrown"] as? [String] == ["结尾引导只能插在稿子末尾：把光标放到最后再插", "稿子里已经有结尾页了：一篇只能有一个 [[结尾]]"])
        #expect(harness.pageErrors == [])
    }

    @Test("操作手册末尾有「片段」一节：每个片段的名字、id、什么时候用与写法；短版说明书一行列出片段的名字")
    func manualListsSnippets() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate("""
            const snippets = window.MediaCraftSnippets;
            const manual = window.MediaCraftManual;
            const text = manual.document();
            const section = text.slice(text.indexOf("\\n## 片段\\n"));
            const missing = snippets.list.flatMap((snippet) => [
              ...(section.includes(`### ${snippet.name}（${snippet.id}）`) ? [] : [`标题 ${snippet.name}`]),
              ...(section.includes(`${snippet.summary}。用在${snippet.when}。`) ? [] : [`说明 ${snippet.name}`]),
              ...(section.includes("```\\n" + snippet.markdown + "\\n```") ? [] : [`写法 ${snippet.name}`]),
            ]);
            const briefLine = manual.brief().split("\\n").find((line) => line.startsWith("- 片段")) ?? "";
            // 片段的写法在代码块里，里面的「## 」不算节标题
            const outside = text.replace(/```[\\s\\S]*?```/g, "");
            return {
              last: outside.trimEnd().split("\\n## ").pop().split("\\n")[0],
              sectionIsLast: outside.lastIndexOf("\\n## ") === outside.indexOf("\\n## 片段\\n"),
              own: snippets.document().startsWith("## 片段\\n"),
              missing, briefLine,
              names: snippets.list.map((snippet) => snippet.name),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["last"] as? String == "片段", "「片段」是手册的最后一节")
        #expect(result?["sectionIsLast"] as? Bool == true)
        #expect(result?["own"] as? Bool == true)
        #expect(result?["missing"] as? [String] == [], "每个片段的名字、说明与写法都在")
        let briefLine = result?["briefLine"] as? String ?? ""
        let names = result?["names"] as? [String] ?? []
        #expect(names.allSatisfy { briefLine.contains($0) } && !names.isEmpty, "短版一行列出片段：\(briefLine)")
        #expect(harness.pageErrors == [])
    }
}
