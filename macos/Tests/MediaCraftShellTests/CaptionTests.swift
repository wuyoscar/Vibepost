import Foundation
import Testing

/// 小红书正文（稿子的 caption）：发布时图片下面的那段，和卡片内容分开写。标题下面的「正文」栏（收起时一行、展开随内容长高、1000 字计数），
/// 随稿子存（旧稿子为空），App API 读写、可撤销；手机预览标题下面显示它（空时灰色提示，点它跳到正文栏）；
/// 发送到 iPhone 时它进剪贴板；发布检查查它的词、字数与话题，空着时提醒「正文还没写」。
@MainActor
struct CaptionTests {
    static let helpers = StorageScripts.read + """
        window.mc = window.mediacraft;
        window.wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        window.until = async (condition, timeout = 15000) => {
          const deadline = Date.now() + timeout;
          while (Date.now() < deadline) {
            const value = await condition();
            if (value) return value;
            await wait(50);
          }
          throw new Error(`等不到：${condition}`);
        };
        window.field = () => document.querySelector("#captionField");
        window.captionInput = () => ui.find("图片下面的正文") ?? document.querySelector("#captionInput");
        window.captionPreview = () => document.querySelector("#captionPreview");
        window.typeCaption = (text) => {
          const input = captionInput();
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        };
        window.topOf = (selector) => document.querySelector(selector).getBoundingClientRect().top;
        window.stored = async () => (await readStore("drafts", (await mc.drafts.current()).id))?.caption;
    """

    @Test("正文栏在标题下面：收起时一行（第一行字，空着是占位提示）、展开随内容长高；打字自动保存、不重排卡片；换稿子、重新打开都在；搜稿子也搜它")
    func captionFieldEditsAndPersists() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const first = await mc.drafts.create({ markdown: "卡片上的字" });
            const order = [topOf(".title-field"), topOf("#captionField"), topOf("#markdownEditor")];
            const collapsed = {
              open: field().open, preview: captionPreview().textContent, placeholder: captionPreview().classList.contains("is-placeholder"),
              count: document.querySelector("#bodyCount").textContent, ordered: order[0] < order[1] && order[1] < order[2],
            };
            ui.expand("小红书正文");
            const expanded = { open: field().open, input: captionInput() !== null };
            const shortHeight = captionInput().offsetHeight;
            let renders = 0;
            const off = mc.on("rendered", () => { renders += 1; });
            typeCaption("\\n  第一行写这篇讲什么\\n第二行\\n第三行\\n第四行\\n第五行\\n第六行\\n第七行\\n#话题");
            const grew = captionInput().offsetHeight > shortHeight;
            await until(async () => (await stored()) === captionInput().value);
            off();
            ui.click("小红书正文");
            const folded = { open: field().open, preview: captionPreview().textContent, placeholder: captionPreview().classList.contains("is-placeholder") };
            const other = await mc.drafts.create({ markdown: "另一篇", caption: "另一篇的正文" });
            const switched = captionInput().value;
            await mc.drafts.open(first.id);
            return {
              collapsed, expanded, grew, renders, folded, switched, back: captionInput().value,
              api: (await mc.drafts.current()).caption, otherApi: (await mc.drafts.get(other.id)).caption,
            };
        """) as? [String: Any]
        try await harness.load()
        let reopened = try await harness.evaluate(Self.helpers + """
            ui.expand("稿件列表");
            const input = ui.find("搜索稿件");
            input.value = "第五行";
            input.dispatchEvent(new Event("input", { bubbles: true }));
            const found = [...document.querySelectorAll('[aria-label="稿件"] [role="listitem"]')].length;
            return { caption: captionInput().value, preview: captionPreview().textContent, found };
        """) as? [String: Any]
        await harness.tearDown()

        let collapsed = result?["collapsed"] as? [String: Any] ?? [:]
        #expect(collapsed["ordered"] as? Bool == true, "标题、正文栏、卡片编辑区从上到下")
        #expect(collapsed["open"] as? Bool == false, "默认收起")
        #expect(collapsed["preview"] as? String == "写发布时图片下面的正文，#话题 也写在这里")
        #expect(collapsed["placeholder"] as? Bool == true)
        #expect(collapsed["count"] as? String == "0/1000")
        #expect(result?["expanded"] as? [String: Bool] == ["open": true, "input": true])
        #expect(result?["grew"] as? Bool == true, "输入框随内容长高")
        #expect(result?["renders"] as? Int == 0, "改正文栏不重排卡片")
        #expect(result?["folded"] as? [String: AnyHashable] == ["open": false, "preview": "第一行写这篇讲什么", "placeholder": false], "收起时显示第一行有字的")
        #expect(result?["switched"] as? String == "另一篇的正文")
        #expect(result?["back"] as? String == "\n  第一行写这篇讲什么\n第二行\n第三行\n第四行\n第五行\n第六行\n第七行\n#话题")
        #expect(result?["api"] as? String == result?["back"] as? String)
        #expect(result?["otherApi"] as? String == "另一篇的正文")
        #expect(reopened?["caption"] as? String == result?["back"] as? String, "重新打开还在")
        #expect(reopened?["preview"] as? String == "第一行写这篇讲什么")
        #expect(reopened?["found"] as? Int == 1, "搜稿子也搜正文栏")
        #expect(harness.pageErrors == [])
    }

    @Test("App API 的 caption：校验类型、update 可撤销、版本里也有；旧稿子没有这个字段时为空，只是打开不算改动")
    func captionThroughTheApi() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(DataSafetyTests.seedDrafts + "await seedDrafts(1);")
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const old = await mc.drafts.open("draft_seed_0001");
            await mc.render.pages();
            await wait(400);
            const record = await readStore("drafts", "draft_seed_0001");
            const legacy = { api: old.caption, field: captionInput().value, stored: "caption" in record, updatedAt: record.updatedAt };
            const typeError = await mc.drafts.update({ caption: 5 }).then(() => "", (error) => error.name);
            await mc.drafts.update({ caption: "第一版正文" });
            await mc.drafts.update({ caption: "第二版正文", markdown: "第 1 篇改了" }, { undoable: true });
            const edited = captionInput().value;
            const undone = (await mc.drafts.undo()).caption;
            const shown = captionInput().value;
            const redone = (await mc.drafts.redo()).caption;
            return { legacy, typeError, edited, undone, shown, redone, saved: await stored() };
        """) as? [String: Any]
        await harness.tearDown()

        let legacy = result?["legacy"] as? [String: Any] ?? [:]
        #expect(legacy["api"] as? String == "")
        #expect(legacy["field"] as? String == "")
        #expect(legacy["stored"] as? Bool == false, "只是打开不写回")
        #expect(legacy["updatedAt"] as? Int == 1_000_000, "只是打开不算改动")
        #expect(result?["typeError"] as? String == "TypeError")
        #expect(result?["edited"] as? String == "第二版正文")
        #expect(result?["undone"] as? String == "第一版正文", "和卡片内容一起是撤销历史里的一步")
        #expect(result?["shown"] as? String == "第一版正文", "正文栏跟着撤回")
        #expect(result?["redone"] as? String == "第二版正文")
        #expect(result?["saved"] as? String == "第二版正文")
        #expect(harness.pageErrors == [])
    }

    @Test("手机预览：标题下面是正文栏的正文（空着时灰色提示），标签从正文栏里取；点正文跳到正文栏；改正文栏预览跟着变")
    func phonePreviewShowsTheCaption() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            window.phone = () => document.querySelector('[aria-label="手机预览"][role="region"]');
            window.post = () => [...phone().querySelectorAll('[aria-label="帖子"] p')].filter((p) => !p.hidden).map((p) => p.textContent);
            window.body = () => phone().querySelector(".phone-body");
            await mc.drafts.create({ title: "湖边散步", markdown: "# 卡片上的标题\\n\\n卡片上的字 #卡片话题" });
            ui.click("手机预览");
            await until(() => post().length === 3);
            const empty = { texts: post(), placeholder: body().classList.contains("is-placeholder"), color: getComputedStyle(body()).color };
            body().click();
            const jumped = { open: field().open, focused: document.activeElement === captionInput() };
            typeCaption("傍晚去湖边走了一圈，柳树发芽了。\\n#散步 #春天");
            await until(() => post().includes("#散步 #春天"));
            const filled = { texts: post(), placeholder: body().classList.contains("is-placeholder"), color: getComputedStyle(body()).color };
            return { empty, jumped, filled };
        """) as? [String: Any]
        await harness.tearDown()

        let empty = result?["empty"] as? [String: Any] ?? [:]
        #expect(empty["texts"] as? [String] == ["湖边散步", "还没写正文，点这里在「正文」栏里写", "刚刚"], "卡片上的字不进正文，标签也不从卡片里取")
        #expect(empty["placeholder"] as? Bool == true)
        #expect(result?["jumped"] as? [String: Bool] == ["open": true, "focused": true], "点正文展开并聚焦正文栏")
        let filled = result?["filled"] as? [String: Any] ?? [:]
        #expect(filled["texts"] as? [String] == ["湖边散步", "傍晚去湖边走了一圈，柳树发芽了。", "#散步 #春天", "刚刚"])
        #expect(filled["placeholder"] as? Bool == false)
        #expect(filled["color"] as? String != empty["color"] as? String, "空着时是灰色提示")
        #expect(harness.pageErrors == [])
    }

    @Test("发布检查：标题、正文栏、卡片文字都查，按这个顺序列；正文栏的命中跳过去选中、可以替换；超过 1000 字提醒；空着时提醒「正文还没写」，点它展开正文栏")
    func publishCheckCoversTheCaption() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(PublishAssistantTests.helpers + Self.helpers + """
            await mc.drafts.create({ title: "最强攻略", markdown: "卡片上写最佳路线。" });
            await until(() => badge()?.textContent === "检查 · 3");
            ui.click("检查");
            const empty = rows();
            ui.click("跳到正文栏里的「正文还没写」");
            await until(() => field().open);
            const opened = { open: field().open, focused: document.activeElement === captionInput() };
            typeCaption("全网最低价，加微信问我。#攻略");
            await until(() => badge().textContent === "检查 · 4");
            const filled = rows();
            ui.click("跳到正文栏里的「加微信」");
            const input = captionInput();
            const selected = await until(() => input.value.slice(input.selectionStart, input.selectionEnd));
            ui.click("删掉", { within: [...checkPanel().querySelectorAll(".check-item")].find((row) => row.querySelector(".check-label").textContent === "加微信") });
            await until(async () => (await mc.drafts.current()).caption === "全网最低价，问我。#攻略" && badge().textContent === "检查 · 3");
            typeCaption("字".repeat(1001));
            await until(() => rows().some((row) => row[2] === "正文 1001/1000"));
            return { empty, opened, filled, selected, field: captionInput().value, over: rows(), count: document.querySelector("#bodyCount").classList.contains("is-over") };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["empty"] as? [[String]] == [["正文", "提示", "正文还没写"], ["极限词", "警告", "最强"], ["极限词", "警告", "最佳"]])
        #expect(result?["opened"] as? [String: Bool] == ["open": true, "focused": true])
        #expect(result?["filled"] as? [[String]] == [
            ["极限词", "警告", "最强"], ["极限词", "警告", "全网最低"], ["极限词", "警告", "最佳"], ["引流", "警告", "加微信"],
        ], "标题在前、正文栏其次、卡片文字在后")
        #expect(result?["selected"] as? String == "加微信", "跳到正文栏里选中那几个字")
        #expect(result?["over"] as? [[String]] == [["数量上限", "警告", "正文 1001/1000"], ["极限词", "警告", "最强"], ["极限词", "警告", "最佳"]])
        #expect(result?["count"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }
}
