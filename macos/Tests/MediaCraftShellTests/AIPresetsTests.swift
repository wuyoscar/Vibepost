import Foundation
import Testing

/// AI 预设命令：「封面标题 5 选 1」不改稿，回复里的候选按显示宽度计字（小红书标题 20 个全角字）、点一个写进标题（可撤销），
/// 回复格式不对时好好说明；「首图文案」「去 AI 味」「按要点重新分页」直接改 draft.md，走修改对比逐处确认。
/// 都进同一个会话，提示词要 Claude 保留自定义标记。claude 换成假的可执行文件（Fixtures/ai/fake-claude）。
@MainActor
struct AIPresetsTests {
    static let helpers = AISessionTests.helpers + """
        window.picker = () => document.getElementById("aiTitlePicker");
        window.options = () => [...picker().querySelectorAll('[role="group"] button')];
        // 每个候选：[标题, 字数, 超出没有, 选中没有]
        window.optionView = () => options().map((option) => [
          option.querySelector(".ai-title-text").textContent,
          option.querySelector(".ai-title-count").textContent,
          option.classList.contains("is-over"),
          option.getAttribute("aria-pressed") === "true",
        ]);
        window.pickerShown = () => !picker().hidden && picker().getClientRects().length > 0;
        window.users = async () => (await mc.ai.history()).messages.filter((message) => message.role === "user")
          .map(({ kind, text, preset }) => ({ kind, text, preset: preset ?? null }));
    """

    static let titles = [
        "周末去公园散步的三个小发现", "citywalk 路线：湖边柳树最出片", "一个人逛公园也可以很开心",
        "春天的公园值得去几次？", "从湖边柳树到傍晚橘子色的天空这一路上我拍到的所有好看的风景",
    ]

    static func titlesReply() -> [String] {
        let array = String(decoding: (try? JSONSerialization.data(withJSONObject: titles)) ?? Data(), as: UTF8.self)
        return StreamJSON.reply(["按你的稿子起了 5 个：\n```json\n", array, "\n```"])
    }

    @Test("封面标题 5 选 1：提示词要 JSON、不改稿；候选按显示宽度计字、超出标红；点一个写进标题，⌘Z 撤回；收起或接着说话后不再显示")
    func coverTitlesPicker() async throws {
        let fake = try FakeClaude(script: Self.titlesReply())
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "旧标题", markdown: "今天天气很好。\\n\\n[[分页]]\\n\\n我们去公园散步。" });
            await openAI();
            ui.click("封面标题 5 选 1");
            await until(() => finished(1));
            await until(pickerShown);
            const shownOptions = optionView();
            const markdown = (await mc.drafts.current()).markdown;
            ui.click("一个人逛公园也可以很开心");
            await until(async () => (await mc.drafts.current()).title === "一个人逛公园也可以很开心");
            await until(() => optionView()[2][3]);
            await until(() => document.getElementById("statusText").textContent.includes("⌘Z"));
            const picked = { pressed: optionView().map((option) => option[3]), status: document.getElementById("statusText").textContent };
            const undone = (await mc.drafts.undo()).title;
            await until(() => !optionView()[2][3]);
            const redone = (await mc.drafts.redo()).title;

            // 经 App API：结果里带读出来的候选
            const viaApi = await mc.ai.preset("coverTitles");
            await until(pickerShown);
            ui.click("收起标题候选");
            const closed = pickerShown();
            await mc.ai.preset("coverTitles");
            await until(pickerShown);
            ask("随便聊聊");
            await until(() => finished(4));
            return { shownOptions, markdown, picked, undone, redone, viaApi, closed, afterChat: pickerShown(), users: await users() };
        """) as? [String: Any]
        await harness.tearDown()

        let prompt = fake.prompt(0)
        #expect(prompt.contains("5 个小红书封面标题") && prompt.contains("```json") && prompt.contains("不要修改 draft.md 和 title.txt"))
        #expect(prompt.contains("不超过 20 个字") && prompt.contains("显示宽度"))
        let calls = fake.calls()
        let session = FakeClaude.option("--session-id", in: calls.first ?? [:])
        #expect(calls.dropFirst().map { FakeClaude.option("--resume", in: $0) } == [session, session, session], "都在同一个会话里")
        #expect(result?["markdown"] as? String == "今天天气很好。\n\n[[分页]]\n\n我们去公园散步。", "不改稿子")
        let shown = result?["shownOptions"] as? [[Any]] ?? []
        #expect(shown.map { $0[0] as? String } == Self.titles)
        #expect(shown.map { $0[1] as? String } == ["13/20", "15/20", "12/20", "11/20", "29/20"], "按显示宽度：汉字 1 字，字母数字半个")
        #expect(shown.map { $0[2] as? Bool } == [false, false, false, false, true], "超出 20 字的标出来")
        #expect(shown.allSatisfy { $0[3] as? Bool == false }, "都不是现在的标题")
        let picked = result?["picked"] as? [String: Any] ?? [:]
        #expect(picked["pressed"] as? [Bool] == [false, false, true, false, false], "用上的那个标为选中")
        #expect((picked["status"] as? String ?? "").contains("⌘Z"))
        #expect(result?["undone"] as? String == "旧标题", "⌘Z 撤回")
        #expect(result?["redone"] as? String == "一个人逛公园也可以很开心")
        let viaApi = result?["viaApi"] as? [String: Any] ?? [:]
        #expect(viaApi["state"] as? String == "done")
        let apiTitles = viaApi["titles"] as? [[String: Any]] ?? []
        #expect(apiTitles.map { $0["text"] as? String } == Self.titles)
        #expect(apiTitles.map { $0["width"] as? Int } == [26, 29, 24, 22, 58])
        #expect(apiTitles.map { $0["over"] as? Bool } == [false, false, false, false, true])
        #expect(result?["closed"] as? Bool == false, "收起")
        #expect(result?["afterChat"] as? Bool == false, "接着说话后不再显示")
        let users = result?["users"] as? [[String: Any]] ?? []
        #expect(users.map { $0["kind"] as? String } == ["command", "command", "command", "chat"])
        #expect(users.map { $0["preset"] as? String } == ["coverTitles", "coverTitles", "coverTitles", nil])
        #expect(users.map { $0["text"] as? String } == ["封面标题 5 选 1", "封面标题 5 选 1", "封面标题 5 选 1", "随便聊聊"])
        #expect(harness.pageErrors == [])
    }

    @Test("封面标题的回复格式不对：读不出时说明、可以再点一次；多了逗号或用了中文引号、写成编号列表的照样读出，最多 5 个、去重")
    func malformedTitleReplies() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        try fake.script(StreamJSON.reply(["抱歉，这篇稿子太短了，我想不出好标题。"]), call: 1)
        try fake.script(StreamJSON.reply(["```json\n[“标题甲”, “标题乙”, 「标题丙」,]\n```"]), call: 2)
        try fake.script(StreamJSON.reply(["1. **春日书单**（4 字）\n2. 标题2：读完这本书我换了工作\n3. 春日书单\n- 第三个"]), call: 3)
        try fake.script(StreamJSON.reply(["[\"一\", \"二\", \"三\", \"四\", \"五\", \"六\", \"七\"]"]), call: 4)
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "今天天气很好。" });
            await openAI();
            ui.click("封面标题 5 选 1");
            await until(() => finished(1));
            await until(pickerShown);
            const prose = {
              note: [...picker().querySelectorAll("p")].filter((node) => !node.hidden).map((node) => node.textContent),
              options: options().length,
              chip: presetButton("封面标题 5 选 1").disabled,
            };
            const lenient = await mc.ai.preset("coverTitles");
            await until(() => options().length === 3);
            const lenientShown = optionView().map((option) => option[0]);
            const list = await mc.ai.preset("coverTitles");
            const many = await mc.ai.preset("coverTitles");
            const unknown = await mc.ai.preset("没有这个").then(() => "", (error) => `${error.name}: ${error.message}`);
            const blank = await mc.ai.useTitle("   ").then(() => "", (error) => error.name);
            return { prose, lenient: lenient.titles.map((title) => title.text), lenientShown, list: list.titles.map((title) => title.text),
                     many: many.titles.map((title) => title.text), unknown, blank };
        """) as? [String: Any]
        await harness.tearDown()

        let prose = result?["prose"] as? [String: Any] ?? [:]
        #expect(prose["note"] as? [String] == ["没从回复里读出标题候选，可以再点一次「封面标题 5 选 1」。"])
        #expect(prose["options"] as? Int == 0)
        #expect(prose["chip"] as? Bool == false, "可以再点一次")
        #expect(result?["lenient"] as? [String] == ["标题甲", "标题乙", "标题丙"], "不合法的 JSON 取引号里的")
        #expect(result?["lenientShown"] as? [String] == ["标题甲", "标题乙", "标题丙"])
        #expect(result?["list"] as? [String] == ["春日书单", "读完这本书我换了工作", "第三个"], "编号列表：去掉加粗、前缀、字数，去重")
        #expect(result?["many"] as? [String] == ["一", "二", "三", "四", "五"], "最多 5 个")
        #expect((result?["unknown"] as? String ?? "").hasPrefix("TypeError: 没有这个预设命令"))
        #expect(result?["blank"] as? String == "TypeError", "空标题不收")
        #expect(harness.pageErrors == [])
    }

    @Test("首图文案、去 AI 味、按要点重新分页：提示词要保留自定义标记；改动都进修改对比逐处确认，接受后一步撤销；审阅时预设命令不可用")
    func editingPresetsGoThroughReview() async throws {
        let base = "今天天气很好。\n\n[[image:abc]]\n\n我们去公园散步，{{color:#d9480f|傍晚}}回家。\n\n#周末"
        let hooked = "# 周末去公园，三个小发现\n\n" + base
        let natural = hooked.replacingOccurrences(of: "今天天气很好。", with: "今天太阳挺好的。")
        let paged = natural.replacingOccurrences(of: "\n\n我们去公园", with: "\n\n[[分页]]\n\n我们去公园")
        let fake = try FakeClaude()
        defer { fake.remove() }
        try fake.script([AIReviewTests.write("draft.md", hooked)] + StreamJSON.reply(["首图写成了一句问句。"]), call: 1)
        try fake.script([AIReviewTests.write("draft.md", natural)] + StreamJSON.reply(["换成了口语。"]), call: 2)
        try fake.script([AIReviewTests.write("draft.md", paged)] + StreamJSON.reply(["分成了两页。"]), call: 3)
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: base });
            await openAI();
            const steps = [];
            for (const name of ["首图文案", "去 AI 味", "按要点重新分页"]) {
              preset(name);
              await until(async () => (await mc.ai.review.get()).open && sendButton());
              const review = await mc.ai.review.get();
              const disabled = ["封面标题 5 选 1", "首图文案", "去 AI 味", "按要点重新分页"].map((chip) => presetButton(chip).disabled);
              const untouched = (await mc.drafts.current()).markdown;
              await mc.ai.review.acceptAll();
              steps.push({ hunks: review.hunks.map(({ before, after }) => [before, after]), disabled, untouched,
                           markdown: (await mc.drafts.current()).markdown, pages: (await mc.render.pages()).length });
            }
            const undone = (await mc.drafts.undo()).markdown;
            return { steps, undone, users: await users() };
        """, arguments: ["base": base]) as? [String: Any]
        await harness.tearDown()

        let prompts = (0..<3).map { fake.prompt($0) }
        #expect(prompts[0].contains("首图") && prompts[0].contains("一级标题") && prompts[0].contains("保留所有自定义标记"))
        #expect(prompts[1].contains("AI 味") && prompts[1].contains("不编造") && prompts[1].contains("保留所有自定义标记"))
        #expect(prompts[2].contains("[[分页]]") && prompts[2].contains("不要用 insert_page_break") && prompts[2].contains("自定义标记"))
        #expect(prompts.allSatisfy { $0.contains("[[图片:") && $0.contains("{{字色:") }, "提示词点名要保留的标记（中文写法）")
        let calls = fake.calls()
        let session = FakeClaude.option("--session-id", in: calls.first ?? [:])
        #expect(calls.dropFirst().map { FakeClaude.option("--resume", in: $0) } == [session, session], "都在同一个会话里")

        let steps = result?["steps"] as? [[String: Any]] ?? []
        try #require(steps.count == 3)
        #expect(steps[0]["hunks"] as? [[String]] == [["", "# 周末去公园，三个小发现\n"]], "首图文案：加在最前面的一级标题")
        #expect(steps[1]["hunks"] as? [[String]] == [["今天天气很好。", "今天太阳挺好的。"]], "去 AI 味：只改措辞，标记不动")
        #expect(steps[2]["hunks"] as? [[String]] == [["", "[[分页]]\n"]], "重新分页：只动分页")
        #expect(steps.map { $0["untouched"] as? String } == [base, hooked, natural], "确认之前正文不动")
        #expect(steps.map { $0["markdown"] as? String } == [hooked, natural, paged], "接受后落进正文")
        #expect(steps.allSatisfy { ($0["disabled"] as? [Bool]) == [true, true, true, true] }, "审阅时预设命令不可用")
        #expect(steps[2]["pages"] as? Int == 2, "分成两页")
        #expect(result?["undone"] as? String == natural, "一次 ⌘Z 撤回整轮改动")
        let users = result?["users"] as? [[String: Any]] ?? []
        #expect(users.map { $0["preset"] as? String } == ["hook", "humanize", "repaginate"])
        #expect(users.map { $0["text"] as? String } == ["首图文案", "去 AI 味", "按要点重新分页"])
        #expect(users.allSatisfy { $0["kind"] as? String == "command" })
        #expect(harness.pageErrors == [])
    }

    @Test("排版一组（收紧留白、按要点重新分页、理版式……）：先看再改，用 restyle_block、set_card_css 等同一套操作；「一键排版」是主按钮，只动版式不改字，提到段距")
    func designPresetsLookThenEdit() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        try fake.script(StreamJSON.reply(["好"]), call: 1)
        try fake.script(StreamJSON.reply(["好"]), call: 2)
        try fake.script(StreamJSON.reply(["好"]), call: 3)
        try fake.script(StreamJSON.reply(["好"]), call: 4)
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "一段" });
            await openAI();
            const labels = [...document.querySelectorAll('[aria-label="排版"] .chip')].map((chip) => chip.textContent);
            ui.click("更醒目");
            await until(() => finished(1));
            preset("更安静");
            await until(() => finished(2));
            ui.click("一键排版");
            await until(() => finished(3));
            preset("收紧留白");
            await until(() => finished(4));
            return { labels, users: await users() };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["labels"] as? [String] == ["收紧留白", "按要点重新分页", "理版式", "调字", "更醒目", "更安静", "精简", "上色"])
        let prompts = (0..<4).map { fake.prompt($0) }
        #expect([prompts[0], prompts[1], prompts[3]].allSatisfy { $0.contains("view_page") && $0.contains("restyle_block") && $0.contains("set_card_css") })
        #expect(prompts[0].contains("「更醒目」") && prompts[1].contains("「更安静」"))
        #expect(prompts[2].contains("get_pages") && prompts[2].contains("blockGap") && prompts[2].contains("不改措辞"), "一键排版：先看每页，用段距收紧，不改字")
        #expect(prompts[3].contains("blockGap") && prompts[3].contains("「收紧留白」"))
        #expect((result?["users"] as? [[String: Any]] ?? []).map { $0["preset"] as? String } == ["bolder", "quieter", "autoLayout", "tighten"])
        #expect(harness.pageErrors == [])
    }

    @Test("写小红书正文：照着卡片内容写 caption.txt，改动在修改对比里单独一处（编辑器上方那一条），接受后进正文栏；加话题标签加到正文栏最后；一步撤销，版本撤回时正文栏也回去")
    func captionPresetGoesThroughReview() async throws {
        let written = "周末去公园散步，湖边的柳树发芽了。\n\n#周末 #散步"
        let tagged = written + "\n#春天 #公园"
        let fake = try FakeClaude()
        defer { fake.remove() }
        try fake.script([AIReviewTests.write("caption.txt", written)] + StreamJSON.reply(["写好了。"]), call: 1)
        try fake.script([AIReviewTests.write("caption.txt", tagged + "\n")] + StreamJSON.reply(["加了两个话题。"]), call: 2)
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "公园", markdown: "今天天气很好。\\n\\n我们去公园散步。" });
            await openAI();
            ui.click("写小红书正文");
            await until(async () => (await mc.ai.review.get()).open && sendButton());
            const review = (await mc.ai.review.get()).hunks.map(({ kind, before, after, source }) => ({ kind, before, after, source }));
            const row = document.getElementById("aiReviewCaption");
            const bar = {
              shown: !row.hidden, label: row.getAttribute("aria-label"),
              inserted: [...row.querySelectorAll("ins")].map((node) => node.textContent).join(""),
              editorMarks: document.querySelectorAll('#markdownEditor [role="group"]').length,
            };
            const untouched = (await mc.drafts.current()).caption;
            ui.click("接受", { within: row });
            await until(async () => !(await mc.ai.review.get()).open);
            const accepted = { caption: (await mc.drafts.current()).caption, field: document.querySelector("#captionInput").value };
            preset("加话题标签");
            await until(async () => (await mc.ai.review.get()).open && sendButton());
            const tagReview = (await mc.ai.review.get()).hunks.map(({ kind, before, after }) => [kind, before, after]);
            await mc.ai.review.acceptAll();
            const taggedCaption = (await mc.drafts.current()).caption;
            const undone = (await mc.drafts.undo()).caption;
            const versions = await mc.ai.versions.list();
            await mc.ai.versions.revert(versions.at(-1).id);
            return {
              review, bar, untouched, accepted, tagReview, taggedCaption, undone,
              versionCaptions: versions.map((version) => version.draft.caption),
              reverted: (await mc.drafts.current()).caption, markdown: (await mc.drafts.current()).markdown,
            };
        """) as? [String: Any]
        await harness.tearDown()

        let prompts = (0..<2).map { fake.prompt($0) }
        #expect(prompts[0].contains("caption.txt") && prompts[0].contains("draft.md") && prompts[0].contains("#话题") && prompts[0].contains("不要修改 draft.md 和 title.txt"))
        #expect(prompts[1].contains("caption.txt") && prompts[1].contains("#话题"), "加话题标签写进正文栏")
        #expect(fake.calls().map { $0["caption"] as? String } == ["", written], "每轮开始时 caption.txt 是正文栏现在的样子")
        let review = result?["review"] as? [[String: Any]] ?? []
        #expect(review.count == 1)
        #expect(review.first?["kind"] as? String == "caption")
        #expect(review.first?["before"] as? String == "")
        #expect(review.first?["after"] as? String == written)
        #expect(review.first?["source"] is NSNull)
        let bar = result?["bar"] as? [String: Any] ?? [:]
        #expect(bar["shown"] as? Bool == true, "正文的修改在编辑器上方那一条里")
        #expect(bar["label"] as? String == "第 1 处修改")
        #expect(bar["inserted"] as? String == written)
        #expect(bar["editorMarks"] as? Int == 0, "卡片内容没改，编辑器里没有标注")
        #expect(result?["untouched"] as? String == "", "确认之前正文栏不动")
        #expect(result?["accepted"] as? [String: String] == ["caption": written, "field": written])
        #expect(result?["tagReview"] as? [[String]] == [["caption", written, tagged]], "话题加在正文栏最后，文件末尾的换行不算")
        #expect(result?["taggedCaption"] as? String == tagged)
        #expect(result?["undone"] as? String == written, "一次 ⌘Z 撤回这一轮")
        #expect(result?["versionCaptions"] as? [String] == [written, ""], "版本里存着正文栏")
        #expect(result?["reverted"] as? String == "", "撤回到第一轮之前，正文栏也回去")
        #expect(result?["markdown"] as? String == "今天天气很好。\n\n我们去公园散步。")
        #expect(harness.pageErrors == [])
    }
}
