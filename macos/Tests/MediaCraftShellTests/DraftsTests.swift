import Foundation
import Testing

/// 稿件抽屉与标题：最近改过的在前、搜索与筛选、新建、删除当前这篇、上千篇照常用；切换稿子时标题与字数跟着换。
@MainActor
struct DraftsTests {
    static let helpers = """
        const mc = window.mediacraft;
        window.region = (name) => document.querySelector(`[aria-label="${name}"]`);
        // 抽屉里从上到下的稿件名（打开按钮的可访问名称以稿件名开头，后面是类型与时间）
        window.drawerTitles = (known) => [...region("稿件").querySelectorAll('[role="listitem"] > button:first-of-type')]
          .map((button) => known.find((title) => ui.name(button).startsWith(title)) ?? ui.name(button));
        window.search = (text) => {
          const input = ui.find("搜索稿件");
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        };
        window.typeTitle = (text) => {
          const input = ui.find("标题");
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        };
        window.wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    """

    @Test("稿件抽屉：最近改过的在前，内置说明书垫底；只是打开一篇不改变顺序，当前这篇有标记")
    func drawerSortsByRecent() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const known = ["甲稿", "乙稿", "丙稿", "图文卡片说明书", "样式与写法", "长文说明书"];
            const a = await mc.drafts.create({ markdown: "甲稿" });
            const b = await mc.drafts.create({ markdown: "乙稿" });
            await mc.drafts.create({ markdown: "丙稿" });
            await mc.drafts.open(a.id);
            await mc.drafts.update({ markdown: "甲稿改了一个字" });
            ui.expand("稿件列表");
            const edited = drawerTitles(known);
            await mc.drafts.open(b.id);
            await wait(50);
            return {
              edited,
              opened: drawerTitles(known),
              current: ui.name(region("稿件").querySelector('[aria-current="true"]')).startsWith("乙稿"),
              api: (await mc.drafts.list()).map((draft) => [draft.title, draft.builtIn, draft.current]),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["edited"] as? [String] == ["甲稿", "丙稿", "乙稿", "图文卡片说明书", "样式与写法", "长文说明书"])
        #expect(result?["opened"] as? [String] == ["甲稿", "丙稿", "乙稿", "图文卡片说明书", "样式与写法", "长文说明书"], "只是打开不算修改")
        #expect(result?["current"] as? Bool == true)
        let api = result?["api"] as? [[Any]] ?? []
        #expect(api.map { $0[0] as? String ?? "" } == ["图文卡片说明书", "样式与写法", "长文说明书", "甲稿改了一个字", "丙稿", "乙稿"], "App API 里内置说明书在前，自己的按最近修改")
        #expect(api.map { $0[2] as? Bool ?? false } == [false, false, false, false, false, true])
        #expect(harness.pageErrors == [])
    }

    @Test("搜索按名字和正文，不分大小写；可只看图文或长文；搜不到时说一声")
    func drawerSearchesTitleAndBody() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const known = ["Spring 书单", "夏天的菜单", "长文：秋天", "图文卡片说明书", "样式与写法", "长文说明书"];
            await mc.drafts.create({ title: "Spring 书单", markdown: "春天读的书" });
            await mc.drafts.create({ markdown: "夏天的菜单\\n番茄炒蛋" });
            await mc.drafts.create({ title: "长文：秋天", mode: "article", markdown: "落叶" });
            ui.expand("稿件列表");
            const empty = () => region("稿件").querySelector("p:not([hidden])")?.textContent ?? "";
            const filter = (name) => ui.click(name, { within: "稿件类型" });
            search("SPRING");
            const byTitle = drawerTitles(known);
            search("番茄");
            const byBody = drawerTitles(known);
            search("");
            filter("长文");
            const articles = drawerTitles(known);
            search("番茄");
            const none = [drawerTitles(known), empty()];
            filter("全部");
            const all = drawerTitles(known);
            search("");
            return { byTitle, byBody, articles, none, all, cleared: drawerTitles(known) };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["byTitle"] as? [String] == ["Spring 书单"], "不分大小写")
        #expect(result?["byBody"] as? [String] == ["夏天的菜单"], "正文里的字也搜得到")
        #expect(result?["articles"] as? [String] == ["长文：秋天", "长文说明书"])
        #expect(result?["none"] as? [AnyHashable] == [[String](), "没有找到这篇稿件"] as [AnyHashable])
        #expect(result?["all"] as? [String] == ["夏天的菜单"])
        #expect(result?["cleared"] as? [String] == ["长文：秋天", "夏天的菜单", "Spring 书单", "图文卡片说明书", "样式与写法", "长文说明书"])
        #expect(harness.pageErrors == [])
    }

    @Test("新建稿件打开一篇空白稿子、光标在正文里；删掉正在编辑的这篇后打开最近改过的另一篇")
    func newAndDeleteCurrent() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "早一点的" });
            await mc.drafts.create({ markdown: "最近的" });
            window.before = (await mc.drafts.list()).length;
            ui.expand("稿件列表");
            ui.click("新建稿件");
        """)
        let created = try await harness.waitForPage(
            "document.querySelector('[role=\"status\"]').textContent === '已新建稿子' && (await window.mediacraft.drafts.list()).length === before + 1"
        )
        let fresh = try await harness.evaluate("""
            const draft = await window.mediacraft.drafts.current();
            return [draft.title, draft.markdown, ui.find("标题").value, document.querySelector('[role="status"]').textContent, ui.name(document.activeElement)];
        """) as? [String]
        _ = try await harness.evaluate("ui.click('删除 未命名稿件')")
        _ = try await harness.waitForPage("ui.alert() !== null")
        _ = try await harness.evaluate("ui.click('删除', { within: ui.alert() })")
        let reopened = try await harness.waitForPage(
            "(await window.mediacraft.drafts.current()).markdown === '最近的' && (await window.mediacraft.drafts.list()).length === before"
        )
        await harness.tearDown()

        #expect(created)
        #expect(fresh == ["", "", "", "已新建稿子", "正文"], "空白稿子，光标在正文里")
        #expect(reopened, "删掉当前这篇后打开最近改过的另一篇")
        #expect(harness.pageErrors == [])
    }

    @Test("上千篇稿子：抽屉照常列出、搜索即时、最新的在最上面")
    func drawerHandlesManyDrafts() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(DataSafetyTests.seedDrafts + "await seedDrafts(1000);")
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const items = () => [...region("稿件").querySelectorAll('[role="listitem"] > button:first-of-type')].map(ui.name);
            let started = performance.now();
            ui.expand("稿件列表");
            const openMs = performance.now() - started;
            const all = items();
            started = performance.now();
            search("第 537 篇");
            const searchMs = performance.now() - started;
            const found = items();
            search("篇");
            const everything = items().filter((name) => name.startsWith("第 ")).length;
            return { count: all.length, first: all[0], last: all.at(-1), openMs, searchMs, found, everything };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["count"] as? Int == 1003, "1000 篇加三本说明书")
        #expect((result?["first"] as? String ?? "").hasPrefix("第 1000 篇"), "最近改过的在最上面")
        #expect((result?["last"] as? String ?? "").hasPrefix("长文说明书"))
        #expect((result?["found"] as? [String] ?? []).map { $0.hasPrefix("第 537 篇") } == [true])
        #expect(result?["everything"] as? Int == 1000)
        #expect((result?["openMs"] as? Double ?? 1000) < 300, "打开抽屉 \(result?["openMs"] ?? "") 毫秒")
        #expect((result?["searchMs"] as? Double ?? 1000) < 300, "搜一次 \(result?["searchMs"] ?? "") 毫秒")
        #expect(harness.pageErrors == [])
    }

    @Test("切换稿子时标题、正文栏与两个字数跟着换；改标题后抽屉里的名字随即更新，重新打开还在")
    func titleAndCountsFollowTheDraft() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const counts = () => [ui.find("标题").value, document.querySelector("#titleCount").textContent, document.querySelector("#bodyCount").textContent,
                                  document.querySelector("#captionInput").value];
            const settle = async () => {
              await mc.render.pages();
              await wait(50);
            };
            const short = await mc.drafts.create({ title: "短标题", markdown: "卡片上的字不计", caption: "五个字正文" });
            const long = await mc.drafts.create({ title: "一二三四五六七八九十一二三四五六七八九十多", markdown: "短", caption: "字".repeat(1001) });
            await settle();
            const longCounts = [...counts(), document.querySelector("#titleCount").classList.contains("is-over"), document.querySelector("#bodyCount").classList.contains("is-over")];
            await mc.drafts.open(short.id);
            await settle();
            const shortCounts = counts();
            ui.expand("稿件列表");
            typeTitle("改过的短标题");
            const live = counts()[1];
            await wait(500);
            return {
              longCounts, shortCounts, live,
              drawer: drawerTitles(["改过的短标题"]).includes("改过的短标题"),
              longId: long.id,
            };
        """) as? [String: Any]
        try await harness.load()
        let reopened = try await harness.evaluate("return (await window.mediacraft.drafts.list()).find((draft) => draft.title === '改过的短标题') !== undefined") as? Bool
        await harness.tearDown()

        #expect(result?["longCounts"] as? [AnyHashable] == ["一二三四五六七八九十一二三四五六七八九十多", "21/20", "1001/1000", String(repeating: "字", count: 1001), true, true] as [AnyHashable])
        #expect(result?["shortCounts"] as? [String] == ["短标题", "3/20", "5/1000", "五个字正文"])
        #expect(result?["live"] as? String == "6/20", "边打字边计数")
        #expect(result?["drawer"] as? Bool == true, "抽屉里的名字随即更新")
        #expect(reopened == true)
        #expect(harness.pageErrors == [])
    }

    @Test("标题框、卡片编辑区不放提示文字，正文栏有占位提示；20 / 1000 字的小红书字数与正文栏只在图文卡片模式下显示，长文不显示")
    func publishCountsOnlyForCards() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "" });
            await mc.render.pages();
            const shown = () => ["#titleCount", "#bodyCount", "#captionField"].map((selector) => document.querySelector(selector).checkVisibility());
            const hints = {
              title: ui.find("标题").getAttribute("placeholder"),
              editor: document.querySelector("#markdownEditor .cm-placeholder") !== null,
              caption: document.querySelector("#captionInput").getAttribute("placeholder"),
            };
            const cards = shown();
            await mc.drafts.update({ mode: "article" });
            await mc.render.articleHtml();
            await wait(100);
            const article = shown();
            await mc.drafts.update({ mode: "cards" });
            await mc.render.pages();
            await wait(100);
            return { hints, cards, article, back: shown() };
        """) as? [String: Any]
        await harness.tearDown()

        let hints = result?["hints"] as? [String: Any]
        #expect(hints?["title"] is NSNull || hints?["title"] == nil, "标题框没有提示文字")
        #expect(hints?["editor"] as? Bool == false, "卡片编辑区没有提示文字")
        #expect(hints?["caption"] as? String == "写发布时图片下面的正文，#话题 也写在这里")
        #expect(result?["cards"] as? [Bool] == [true, true, true], "图文卡片：标题与正文字数、正文栏都显示")
        #expect(result?["article"] as? [Bool] == [false, false, false], "长文：都不显示")
        #expect(result?["back"] as? [Bool] == [true, true, true], "切回图文又显示")
        #expect(harness.pageErrors == [])
    }

    @Test("草稿只存在本机（IndexedDB），重新打开后还在")
    func draftPersistsInSingleLocalStore() async throws {
        let harness = ShellHarness()
        try await harness.load()

        let stored = try await harness.evaluate(StorageScripts.read + """
            const { id } = await window.mediacraft.drafts.create({ markdown: "只存本机的草稿" });
            return {
              local: (await readStore("drafts", id))?.markdown === "只存本机的草稿",
              session: sessionStorage.length,
            };
        """) as? [String: Any]
        try await harness.load()
        let restored = try await harness.evaluate("return (await window.mediacraft.drafts.current()).markdown") as? String
        await harness.tearDown()

        #expect(stored?["local"] as? Bool == true)
        #expect(stored?["session"] as? Int == 0)
        #expect(restored == "只存本机的草稿")
        #expect(harness.pageErrors == [])
    }
}
