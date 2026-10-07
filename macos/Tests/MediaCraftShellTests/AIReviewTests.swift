import Foundation
import Testing

/// AI 的修改对比与版本：改动按段逐处列出（自定义标记不拆开），逐处接受 / 拒绝后一次套用（一步撤销）；
/// 发出后你也改了正文时挪到现在的正文上，重叠的是冲突；每轮之前存版本，撤回恢复正文与卡片，撤回本身可以 ⌘Z，
/// 普通撤销历史不受影响；版本随稿子保存，最多 50 个。claude 换成假的可执行文件（Fixtures/ai/fake-claude）。
@MainActor
struct AIReviewTests {
    static let helpers = AISessionTests.helpers + StorageScripts.read + """
        window.markdown = async () => (await mc.drafts.current()).markdown;
        // 每一页卡片像素的 SHA-256（字体都载入后重新出一次图）
        window.pixels = async () => {
          await document.fonts.ready;
          await mc.render.refresh();
          const hashes = [];
          for (const canvas of await mc.render.canvases()) {
            const data = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
            hashes.push([...new Uint8Array(await crypto.subtle.digest("SHA-256", data))].map((byte) => byte.toString(16).padStart(2, "0")).join(""));
          }
          return hashes.join(",");
        };
        window.cardText = async () => (await mc.render.pages()).flatMap((page) => page.items).filter((item) => item.kind === "text").map((item) => item.text).join("|");
        // 编辑器里每处修改上方那一条的名字，和标出来的删掉 / 加上的字
        window.bars = () => [...document.querySelectorAll('#markdownEditor [role="group"]')].map((bar) => bar.getAttribute("aria-label"));
        window.marked = (kind) => [...document.querySelectorAll(`#markdownEditor .cm-review-${kind}`)].map((node) => node.textContent);
        window.reviewBar = () => document.getElementById("aiReview");
        window.cmdZ = (shift = false) => document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "z", metaKey: true, shiftKey: shift, bubbles: true, cancelable: true }));
    """

    static let base = "# 周末\n\n今天天气很好，我们去公园散步。\n湖边有柳树。\n\n[[图片:a|b]]\n\n[[分页]]\n\n傍晚是{{字色:#d9480f|橘子色}}。"
    static let proposal = "# 周末\n\n天气正好，我们去公园走了走。\n湖边有几棵柳树。\n\n[[图片:b|a]]\n\n新的一段。\n\n[[分页]]\n\n傍晚是{{字色:#2f9e44|橘子色}}。"

    /// 回放脚本里的 `#write`：把整个文件写成 content（像 Write 工具）
    static func write(_ file: String, _ content: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [file, content])) ?? Data()
        return "#write " + String(decoding: data, as: UTF8.self)
    }

    static func proposalScript() -> [String] {
        [write("draft.md", proposal), write("title.txt", "新\n")] + StreamJSON.reply(["改好了。"])
    }

    @Test("改动按段逐处列出，标题单独一处；自定义标记整个在一处之内；审阅时正文不动、只读，舞台是接受后的样子，不能导出、不能发下一轮")
    func hunksPerParagraph() async throws {
        let fake = try FakeClaude(script: Self.proposalScript())
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "旧", markdown: base });
            await openAI();
            ask("润色");
            await until(() => finished(1));
            await until(() => bars().length === 4);
            const review = await mc.ai.review.get();
            const during = {
              markdown: await markdown(),
              editable: document.querySelector("#markdownEditor .cm-content").getAttribute("contenteditable"),
              bars: bars(),
              titleRow: ui.find("接受", { within: "第 1 处修改" })?.closest('[role="group"]')?.id,
              deleted: marked("del"),
              inserted: marked("ins"),
              card: await cardText(),
              summary: reviewBar().querySelector(".ai-review-summary").innerText.replace(/\\s+/g, " ").trim(),
              end: shown().at(-1),
              send: await mc.ai.send("再来").then(() => "", (error) => error.message),
              exportPng: await mc.output.exportPng(0).then(() => "", (error) => error.message),
              sendDisabled: sendButton().disabled,
            };
            ui.click("全部拒绝");
            await until(async () => !(await mc.ai.review.get()).open);
            return {
              review, during,
              after: {
                markdown: await markdown(), title: (await mc.drafts.current()).title, bars: bars(), bar: reviewBar().hidden,
                editable: document.querySelector("#markdownEditor .cm-content").getAttribute("contenteditable"),
                card: await cardText(), end: (await ends()).at(-1),
              },
            };
        """, arguments: ["base": Self.base]) as? [String: Any]
        await harness.tearDown()

        let review = result?["review"] as? [String: Any]
        #expect(review?["open"] as? Bool == true)
        let hunks = review?["hunks"] as? [[String: Any]] ?? []
        #expect(hunks.map { $0["kind"] as? String } == ["title", "text", "text", "text", "text"])
        #expect(hunks.map { [$0["before"] as? String ?? "", $0["after"] as? String ?? ""] } == [
            ["旧", "新"],
            ["今天天气很好，我们去公园散步。\n湖边有柳树。", "天气正好，我们去公园走了走。\n湖边有几棵柳树。"],
            ["[[图片:a|b]]", "[[图片:b|a]]"],
            ["", "新的一段。\n"],
            ["傍晚是{{字色:#d9480f|橘子色}}。", "傍晚是{{字色:#2f9e44|橘子色}}。"],
        ], "同一段里的两行合成一处；标记整个在一处之内")
        #expect(hunks.allSatisfy { $0["decision"] as? String == "pending" && $0["conflict"] as? Bool == false })
        let source = hunks[2]["source"] as? [Int] ?? []
        let base = Array(Self.base.utf16)
        #expect(source.count == 2 && String(utf16CodeUnits: Array(base[source[0]..<source[1]]), count: source[1] - source[0]) == "[[图片:a|b]]")

        let during = result?["during"] as? [String: Any]
        #expect(during?["markdown"] as? String == Self.base, "确认之前正文不动")
        #expect(during?["editable"] as? String == "false", "审阅时编辑器只读")
        #expect(during?["bars"] as? [String] == ["第 2 处修改", "第 3 处修改", "第 4 处修改", "第 5 处修改"], "正文里每处上方一条")
        #expect(during?["titleRow"] as? String == "aiReviewTitle", "标题的修改在编辑器上方那一条里")
        let deleted = during?["deleted"] as? [String] ?? []
        let inserted = during?["inserted"] as? [String] ?? []
        #expect(deleted.contains("{{字色:#d9480f|") && inserted.contains("{{字色:#2f9e44|"), "改了的标记整个标出来：\(deleted) \(inserted)")
        #expect(inserted.contains("新的一段。\n"))
        #expect((during?["card"] as? String ?? "").contains("天气正好"), "舞台是接受后的样子")
        #expect(during?["summary"] as? String == "AI 改了 5 处 逐处接受或拒绝 · 舞台上是全部接受后的样子")
        #expect(during?["end"] as? [String] == ["end", "5 处修改待确认 claude-opus-4-6 · 4.2 秒 · $0.01"])
        #expect((during?["send"] as? String ?? "").contains("先处理完上一轮 AI 的修改"))
        #expect((during?["exportPng"] as? String ?? "").contains("先处理完 AI 的修改"))
        #expect(during?["sendDisabled"] as? Bool == true)

        let after = result?["after"] as? [String: Any]
        #expect(after?["markdown"] as? String == Self.base, "全部拒绝：正文不变")
        #expect(after?["title"] as? String == "旧")
        #expect(after?["bars"] as? [String] == [])
        #expect(after?["bar"] as? Bool == true)
        #expect(after?["editable"] as? String == "true", "审阅结束恢复可写")
        #expect((after?["card"] as? String ?? "").contains("今天天气很好"), "舞台回到正文")
        #expect((after?["end"] as? [String: Any])?["review"] as? [String: Int] == ["count": 5, "accepted": 0])
        #expect(harness.pageErrors == [])
    }

    @Test("接受一部分、拒绝一部分：决定随稿子存（重新打开还在），都决定了才一次套用，结果一字不差；一次 ⌘Z 连标题一起撤回，⇧⌘Z 再回来")
    func acceptSomeRejectSome() async throws {
        let fake = try FakeClaude(script: Self.proposalScript())
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let partial = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "旧", markdown: base });
            await openAI();
            ask("润色");
            await until(() => finished(1));
            await until(() => bars().length === 4);
            ui.click("接受", { within: "第 1 处修改" });
            await until(() => ui.find("接受", { within: "第 1 处修改" }).getAttribute("aria-pressed") === "true");
            ui.click("接受", { within: "第 2 处修改" });
            await until(() => ui.find("接受", { within: "第 2 处修改" })?.getAttribute("aria-pressed") === "true");
            await mc.ai.review.reject(2);
            return await mc.ai.review.accept(3);
        """, arguments: ["base": Self.base]) as? [String: Any]
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await until(() => bars().length === 4);
            const reopened = await mc.ai.review.get();
            const pending = { markdown: await markdown(), title: (await mc.drafts.current()).title, card: await cardText() };
            ui.click("接受", { within: "第 5 处修改" });
            await until(async () => !(await mc.ai.review.get()).open);
            const done = { markdown: await markdown(), title: (await mc.drafts.current()).title };
            cmdZ();
            await mc.render.pages();
            const undone = { markdown: await markdown(), title: (await mc.drafts.current()).title };
            cmdZ(true);
            await mc.render.pages();
            const redone = { markdown: await markdown(), title: (await mc.drafts.current()).title };
            return { reopened, pending, done, undone, redone, end: (await ends()).at(-1) };
        """) as? [String: Any]
        await harness.tearDown()

        let expected = "# 周末\n\n天气正好，我们去公园走了走。\n湖边有几棵柳树。\n\n[[图片:a|b]]\n\n新的一段。\n\n[[分页]]\n\n傍晚是{{字色:#2f9e44|橘子色}}。"
        let decisions: [String?] = ["accepted", "accepted", "rejected", "accepted", "pending"]
        #expect(partial?["open"] as? Bool == true)
        #expect((partial?["hunks"] as? [[String: Any]])?.map { $0["decision"] as? String } == decisions)
        let reopened = result?["reopened"] as? [String: Any]
        #expect(reopened?["turnId"] as? String == partial?["turnId"] as? String)
        #expect((reopened?["hunks"] as? [[String: Any]])?.map { $0["decision"] as? String } == decisions, "重新打开 App 还在，决定也在")
        let pending = result?["pending"] as? [String: Any]
        #expect(pending?["markdown"] as? String == Self.base, "还有没决定的就不套用")
        #expect(pending?["title"] as? String == "旧")
        #expect((pending?["card"] as? String ?? "").contains("天气正好"), "舞台：没拒绝的都接受")
        let done = result?["done"] as? [String: Any]
        #expect(done?["markdown"] as? String == expected)
        #expect(done?["title"] as? String == "新")
        let undone = result?["undone"] as? [String: Any]
        #expect(undone?["markdown"] as? String == Self.base, "一次 ⌘Z 撤回全部接受的")
        #expect(undone?["title"] as? String == "旧", "标题在同一步里")
        let redone = result?["redone"] as? [String: Any]
        #expect(redone?["markdown"] as? String == expected)
        #expect(redone?["title"] as? String == "新")
        let end = result?["end"] as? [String: Any]
        #expect(end?["review"] as? [String: Int] == ["count": 5, "accepted": 4])
        #expect(end?["edited"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("发出后你也改了正文：不重叠的修改挪到现在的正文上，重叠的是冲突——接受换成 AI 的整段，拒绝留你的")
    func concurrentEditRebases() async throws {
        let fake = try FakeClaude(script: ["#wait-file go", Self.write("draft.md", "第一段改。\n\n第二段。\n\n第三段改。")] + StreamJSON.reply(["好了。"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "第一段。\\n\\n第二段。\\n\\n第三段。" });
            await openAI();
            ask("改第一段和第三段");
            await until(async () => (await mc.ai.history()).running);
            await mc.drafts.update({ markdown: "第一段，我改的。\\n\\n第二段。\\n\\n第三段。\\n\\n我加的一段。" });
        """)
        fake.release("go")
        let result = try await harness.evaluate("""
            await until(() => finished(1));
            await until(() => bars().length === 2);
            const review = await mc.ai.review.get();
            const text = await markdown();
            const conflict = document.querySelector('#markdownEditor [aria-label="第 1 处修改"]').innerText.replace(/\\s+/g, " ");
            const card = await cardText();
            await mc.ai.review.accept(1);
            const final = await mc.ai.review.reject(0);
            return { review, text, conflict, card, final, markdown: await markdown() };
        """) as? [String: Any]
        await harness.tearDown()

        let mine = "第一段，我改的。\n\n第二段。\n\n第三段。\n\n我加的一段。"
        let hunks = (result?["review"] as? [String: Any])?["hunks"] as? [[String: Any]] ?? []
        #expect(hunks.map { $0["conflict"] as? Bool } == [true, false])
        #expect(hunks.map { [$0["before"] as? String ?? "", $0["after"] as? String ?? ""] } == [
            ["第一段，我改的。", "第一段改。"],
            ["第三段。", "第三段改。"],
        ])
        let source = hunks.last?["source"] as? [Int] ?? []
        let text = Array((result?["text"] as? String ?? "").utf16)
        #expect(source.count == 2 && String(utf16CodeUnits: Array(text[source[0]..<source[1]]), count: source[1] - source[0]) == "第三段。", "挪到现在的正文上的位置")
        #expect(result?["text"] as? String == mine, "你的改动还在")
        #expect((result?["conflict"] as? String ?? "").contains("你在 AI 修改时也改了这里"))
        #expect((result?["card"] as? String ?? "").contains("第一段改。"), "舞台：冲突也按接受 AI 的整段预览")
        #expect((result?["final"] as? [String: Any])?["applied"] as? Int == 1)
        #expect(result?["markdown"] as? String == "第一段，我改的。\n\n第二段。\n\n第三段改。\n\n我加的一段。")
        #expect(harness.pageErrors == [])
    }

    @Test("每轮 AI 之前存一个版本：正文、标题、主题都记下，新的在前；重新打开 App 还在，会话记录里每轮都能撤回")
    func versionPerTurn() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        try fake.script([Self.write("draft.md", "第二版")] + StreamJSON.reply(["改好了。"]), call: 1)
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let before = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "春天", markdown: "第一版" });
            await mc.themes.apply("ink");
            await openAI();
            const first = await mc.ai.send("改一下");
            await mc.ai.review.acceptAll();
            const second = await mc.ai.send("聊聊");
            await until(() => ui.all("撤回到这一轮之前").length === 2);
            return { first: first.turnId, second: second.turnId, versions: await mc.ai.versions.list() };
        """) as? [String: Any]
        try await harness.load()
        let after = try await harness.evaluate(Self.helpers + """
            await openAI();
            await until(() => ui.all("撤回到这一轮之前").length === 2);
            return { versions: await mc.ai.versions.list() };
        """) as? [String: Any]
        await harness.tearDown()

        let versions = before?["versions"] as? [[String: Any]] ?? []
        #expect(versions.map { $0["id"] as? String } == [before?["second"] as? String, before?["first"] as? String], "id 是那一轮的 id，新的在前")
        #expect(versions.map { $0["label"] as? String } == ["聊聊", "改一下"])
        let drafts = versions.map { $0["draft"] as? [String: Any] ?? [:] }
        #expect(drafts.map { $0["markdown"] as? String } == ["第二版", "第一版"], "存的是这一轮之前的正文")
        #expect(drafts.map { $0["title"] as? String } == ["春天", "春天"])
        #expect(drafts.map { $0["theme"] as? String } == ["ink", "ink"])
        #expect(drafts.first?["colors"] as? [String: String] != nil && drafts.first?["fonts"] as? [String: String] != nil)
        let reloaded = after?["versions"] as? [[String: Any]] ?? []
        #expect(reloaded.map { $0["id"] as? String } == versions.map { $0["id"] as? String }, "重新打开 App 还在")
        #expect((reloaded.first?["draft"] as? [String: Any])?["markdown"] as? String == "第二版")
        #expect(harness.pageErrors == [])
    }

    @Test("撤回到这一轮之前：正文、标题、主题、字号与卡片像素都恢复；撤回可以 ⌘Z 撤销、⇧⌘Z 重做")
    func revertRestoresTextAndCards() async throws {
        let fake = try FakeClaude(script: [Self.write("draft.md", "# 夏天\n\nAI 写的新正文，比原来长一些。"), Self.write("title.txt", "AI 标题\n")] + StreamJSON.reply(["改好了。"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "原来的标题", markdown: "# 春天\\n\\n原来的正文。", theme: "notes", fontSize: 30 });
            const original = { draft: await mc.drafts.current(), pixels: await pixels() };
            await openAI();
            ask("重写");
            await until(() => finished(1));
            await mc.ai.review.acceptAll();
            await mc.themes.apply("ink");
            await mc.drafts.update({ fontSize: 36 });
            const changed = { draft: await mc.drafts.current(), pixels: await pixels() };
            ui.click("撤回到这一轮之前");
            const status = await until(() => document.getElementById("statusText").textContent.startsWith("已撤回") && document.getElementById("statusText").textContent);
            const reverted = { draft: await mc.drafts.current(), pixels: await pixels(), status };
            cmdZ();
            await until(async () => (await markdown()) === changed.draft.markdown);
            const undone = { draft: await mc.drafts.current(), pixels: await pixels() };
            cmdZ(true);
            await until(async () => (await markdown()) === original.draft.markdown);
            const redone = { draft: await mc.drafts.current(), pixels: await pixels() };
            return { original, changed, reverted, undone, redone, versions: (await mc.ai.versions.list()).length };
        """) as? [String: Any]
        await harness.tearDown()

        func draft(_ key: String) -> [String: Any] { (result?[key] as? [String: Any])?["draft"] as? [String: Any] ?? [:] }
        func pixels(_ key: String) -> String? { (result?[key] as? [String: Any])?["pixels"] as? String }
        func look(_ value: [String: Any]) -> [String] {
            [value["markdown"], value["title"], value["theme"], value["fontSize"], (value["colors"] as? [String: String])?["bg"]].map { "\($0 ?? "")" }
        }
        #expect(look(draft("changed")) != look(draft("original")))
        #expect(pixels("changed") != pixels("original"))
        #expect(look(draft("reverted")) == look(draft("original")), "正文、标题、主题、字号、配色都回到这一轮之前")
        #expect(pixels("reverted") == pixels("original"), "卡片一个像素都不差")
        #expect((result?["reverted"] as? [String: Any])?["status"] as? String == "已撤回到这一轮之前，⌘Z 可以撤销这次撤回")
        #expect(look(draft("undone")) == look(draft("changed")), "⌘Z 撤销这次撤回")
        #expect(pixels("undone") == pixels("changed"))
        #expect(look(draft("redone")) == look(draft("original")), "⇧⌘Z 再撤回")
        #expect(pixels("redone") == pixels("original"))
        #expect(result?["versions"] as? Int == 1, "撤回不动版本列表")
        #expect(harness.pageErrors == [])
    }

    @Test("撤回与普通 ⌘Z 互不干扰：撤回之前的撤销历史都还在，撤销、重做也不动版本")
    func revertKeepsUndoHistory() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "开头" });
            const { turnId } = await mc.ai.send("聊聊");
            await mc.drafts.update({ markdown: "开头\\n\\n甲" });
            await mc.drafts.update({ markdown: "开头\\n\\n甲\\n\\n乙" });
            const steps = [(await mc.ai.versions.revert(turnId)).markdown];
            for (const action of ["undo", "undo", "redo", "redo"]) steps.push((await mc.drafts[action]()).markdown);
            return { steps, versions: (await mc.ai.versions.list()).map((version) => version.id), turnId };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["steps"] as? [String] == ["开头", "开头\n\n甲\n\n乙", "开头\n\n甲", "开头\n\n甲\n\n乙", "开头"],
                "撤回是一步；再往前的撤销、重做照常")
        #expect(result?["versions"] as? [String] == [result?["turnId"] as? String ?? ""])
        #expect(harness.pageErrors == [])
    }

    @Test("版本用着的图片不删：在预览里删掉图片后，媒体库里还留着；撤回时图片与画面一起回来，重新打开 App 也在")
    func revertBringsBackDeletedImage() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const png = await new Promise((resolve) => {
              const canvas = document.createElement("canvas");
              canvas.width = 120;
              canvas.height = 90;
              const context = canvas.getContext("2d");
              context.fillStyle = "#e03131";
              context.fillRect(0, 0, 60, 90);
              context.fillStyle = "#1971c2";
              context.fillRect(60, 0, 60, 90);
              canvas.toBlob(resolve, "image/png");
            });
            await mc.drafts.create({ markdown: "开头" });
            const [id] = await mc.media.import([new File([png], "红蓝.png", { type: "image/png" })], { at: 2 });
            const original = { markdown: await markdown(), pixels: await pixels() };
            await openAI();
            ask("聊聊");
            await until(() => finished(1));
            await mc.render.pages();
            const box = ui.find("选择图片 红蓝.png");
            box.focus();
            box.dispatchEvent(new KeyboardEvent("keydown", { key: "Backspace", bubbles: true, cancelable: true }));
            await until(async () => (await mc.media.get(id)) === null);
            await mc.render.pages();
            await wait(300);
            const deleted = { marker: (await markdown()).includes("[[图片:"), stored: (await readStore("media")).some((item) => item.id === id) };
            ui.click("撤回到这一轮之前");
            await until(async () => (await mc.media.get(id)) !== null);
            const back = { markdown: await markdown(), pixels: await pixels(), src: (await mc.media.src(id))?.startsWith("data:image/png") };
            return { id, original, deleted, back };
        """) as? [String: Any]
        try await harness.load()
        let reopened = try await harness.evaluate("""
            return (await window.mediacraft.media.src(id))?.startsWith("data:image/png") ?? false;
        """, arguments: ["id": result?["id"] as? String ?? ""]) as? Bool
        await harness.tearDown()

        let original = result?["original"] as? [String: Any]
        let deleted = result?["deleted"] as? [String: Any]
        #expect(deleted?["marker"] as? Bool == false, "预览里删掉了")
        #expect(deleted?["stored"] as? Bool == true, "版本还用着，媒体库里留着")
        let back = result?["back"] as? [String: Any]
        #expect(back?["markdown"] as? String == original?["markdown"] as? String)
        #expect(back?["src"] as? Bool == true)
        #expect(back?["pixels"] as? String == original?["pixels"] as? String, "卡片上的图片也回来了")
        #expect(reopened == true, "撤回后存进本机，重新打开还在")
        #expect(harness.pageErrors == [])
    }

    @Test("每篇最多留 50 个版本：多出来的删最旧的，存下来的也是 50 个")
    func versionsArePruned() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let draftId = try await harness.evaluate(Self.helpers + """
            const draft = await mc.drafts.create({ markdown: "正文" });
            await mc.ai.send("第一轮");
            await wait(300);
            const record = await readStore("drafts", draft.id);
            const [version] = record.versions;
            record.versions = Array.from({ length: 50 }, (_, index) => ({ ...version, id: `old-${index}`, at: version.at + index, label: `旧的第 ${index} 个` }));
            await writeStore("drafts", [record]);
            await wait(300);
            return draft.id;
        """) as? String
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const { turnId } = await mc.ai.send("新的一轮");
            const versions = await mc.ai.versions.list();
            await wait(200);
            return { turnId, ids: versions.map((version) => version.id), stored: (await readStore("drafts", id)).versions.length };
        """, arguments: ["id": draftId ?? ""]) as? [String: Any]
        await harness.tearDown()

        let ids = result?["ids"] as? [String] ?? []
        #expect(ids.count == 50)
        #expect(ids.first == result?["turnId"] as? String, "新的一轮在最前")
        #expect(ids.last == "old-1", "最旧的 old-0 删掉了")
        #expect(!ids.contains("old-0"))
        #expect(result?["stored"] as? Int == 50)
        #expect(harness.pageErrors == [])
    }
}

/// 实况用例都挂在已串行的 SendLivePhotoTests 下：两个 WKWebView 同时解码视频会互相卡住。
@MainActor
extension SendLivePhotoTests {
    @Test("版本用着的实况也不丢：删掉实况、重新打开 App 后撤回，实况与原视频都回来，还能导出")
    func revertBringsBackDeletedLivePhoto() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let before = try await harness.evaluate(AIReviewTests.helpers + DataSafetyTests.helpers + """
            await mc.drafts.create({ markdown: "开头" });
            const video = await (await fetch("/macos/Tests/Fixtures/live-h264.mp4")).blob();
            await mc.media.insertLivePhoto(new File([video], "海边.mp4", { type: "video/mp4" }), { at: "开头".length, duration: 3 });
            await until(async () => (await imageTags()).length === 1);
            const id = (await imageTags())[0];
            const { videoKey } = (await mc.media.get(id)).live;
            const size = (await mc.media.video(videoKey)).memoryBytes;
            const original = await markdown();
            await openAI();
            ask("聊聊");
            await until(() => finished(1));
            await mc.render.pages();
            await deleteInPreview(id);
            await until(async () => (await mc.media.get(id)) === null);
            await wait(300);
            return { id, videoKey, size, original };
        """) as? [String: Any]
        try await harness.load()
        let after = try await harness.evaluate(AIReviewTests.helpers + """
            await openAI();
            ui.click("撤回到这一轮之前");
            await until(async () => (await mc.media.get(id)) !== null);
            const { live } = await mc.media.get(id);
            return {
              markdown: await markdown(),
              live: Boolean(live),
              video: await mc.media.video(videoKey),
              exported: (await mc.output.exportZip()).filename,
            };
        """, arguments: ["id": before?["id"] as? String ?? "", "videoKey": before?["videoKey"] as? String ?? ""]) as? [String: Any]
        await harness.tearDown()

        let size = before?["size"] as? Int
        let video = after?["video"] as? [String: Any]
        #expect(size != nil && size! > 0)
        #expect(after?["markdown"] as? String == before?["original"] as? String, "实况标记回到正文")
        #expect(after?["live"] as? Bool == true)
        #expect(video?["memoryBytes"] as? Int == size, "原视频放回内存（预览、导出用）")
        #expect(video?["storedBytes"] as? Int == size, "本机存储里也在")
        #expect((after?["exported"] as? String)?.hasSuffix(".zip") == true, "撤回后还能导出实况")
        #expect(harness.pageErrors == [])
    }
}
