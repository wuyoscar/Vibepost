import Foundation
import Testing

/// 模板画廊（src/templates/gallery.js）：稿件抽屉「从模板新建」打开，每格是那套模板真实出的第一页、按题材 / 风格筛，
/// 点一格（或方向键 + 回车）复制成自己的稿子并关上；空白稿子的空状态提示；稿件右键菜单「存为模板…」的对话框，
/// 存好的在画廊里排在自带的后面、能在 Finder 中显示、能删（先确认）。API 本身在 TemplatesTests 里测，这里只测界面。
@MainActor
struct GalleryTests {
    static let helpers = """
        const mc = window.mediacraft;
        window.until = async (condition, timeout = 10000) => {
          const deadline = Date.now() + timeout;
          while (Date.now() < deadline) {
            const value = await condition();
            if (value) return value;
            await new Promise((resolve) => setTimeout(resolve, 20));
          }
          throw new Error(`等不到：${condition}`);
        };
        window.press = (key, target = document.activeElement) => target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
        window.region = (name) => document.querySelector(`[aria-label="${name}"]`);
        window.gallery = () => document.getElementById("templateGallery");
        window.galleryOpen = () => !gallery().classList.contains("hidden");
        // 画廊里看得见（没被筛掉）的格子
        window.tiles = () => [...gallery().querySelectorAll(".template-card:not([hidden]) .template-tile")];
        window.tileNames = () => tiles().map((tile) => ui.name(tile));
        window.thumbsReady = () => document.getElementById("templateGalleryGrid").getAttribute("aria-busy") === "false";
        // 画布上画了东西，而且不是一整块纯色
        window.nonBlank = (canvas) => {
          const data = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
          let painted = false;
          let varied = false;
          for (let index = 0; index < data.length; index += 4) {
            if (data[index + 3] > 0) painted = true;
            if (data[index] !== data[0] || data[index + 1] !== data[1] || data[index + 2] !== data[2]) varied = true;
            if (painted && varied) return true;
          }
          return false;
        };
    """

    /// 等 harness 记下来的东西到齐（页面经原生桥要的，主线程上记）
    static func waitFor(_ condition: () -> Bool, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("从稿件抽屉打开画廊：8 套自带模板各一格、缩略图是真实出的第一页；按题材 / 风格筛；方向键 + 回车或点一格就新建一篇照模板的稿子并关上，原来的稿子不变；Esc、点遮罩关上")
    func galleryListsFiltersAndCreates() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const registry = window.MediaCraftTemplateRegistry;
            const original = await mc.drafts.create({ markdown: "原来的稿子" });
            ui.expand("稿件列表");
            await until(() => ui.find("从模板新建"));
            ui.click("从模板新建");
            const opened = galleryOpen() && ui.dialogs().some((dialog) => dialog.id === "templateGallery");
            await until(() => tiles().length === registry.length);
            const names = tileNames();
            const focusedFirst = document.activeElement === tiles()[0];
            await until(thumbsReady, 90000);
            const thumbs = tiles().map((tile) => tile.querySelector(".theme-thumb").classList.contains("is-ready") && nonBlank(tile.querySelector("canvas")));
            const descriptions = tiles().every((tile) => tile.querySelector(".template-tile-description").textContent.length > 0);
            const tags = tiles().map((tile) => [...tile.querySelectorAll(".template-tag")].map((tag) => tag.textContent));

            // 筛选：题材、风格各一组，「全部」在前
            const chips = (group) => [...region(group).querySelectorAll(".chip")].map((chip) => chip.textContent);
            const topicChips = chips("题材");
            const styleChips = chips("风格");
            ui.click("清单", { within: "题材" });
            const byTopic = tileNames();
            ui.click("全部", { within: "题材" });
            ui.click("柔和", { within: "风格" });
            const byStyle = tileNames();
            ui.click("日记", { within: "题材" });
            const byBoth = tileNames();
            ui.click("有态度", { within: "风格" });
            const none = [tileNames().length, document.getElementById("templateGalleryEmpty").hidden];
            ui.click("全部", { within: "题材" });
            ui.click("全部", { within: "风格" });
            const all = tileNames().length;

            // 键盘：第一格 → 右一格 → 下一行（4 列）→ 回车
            tiles()[0].focus();
            press("ArrowRight");
            const afterRight = ui.name(document.activeElement);
            press("ArrowDown");
            const afterDown = ui.name(document.activeElement);
            press("Enter");
            await until(async () => (await mc.drafts.current()).id !== original.id && !galleryOpen(), 20000);
            const picked = await mc.drafts.current();
            const pickedEntry = registry[5];
            const originalAgain = await mc.drafts.get(original.id);

            // 点一格
            ui.click("从模板新建");
            await until(() => tiles().length === registry.length);
            tiles()[2].click();
            await until(async () => (await mc.drafts.current()).id !== picked.id && !galleryOpen(), 20000);
            const clicked = await mc.drafts.current();

            // Esc 与点遮罩都关上，焦点离开画廊
            ui.click("从模板新建");
            await until(() => galleryOpen());
            press("Escape");
            const escClosed = [!galleryOpen(), !gallery().contains(document.activeElement)];
            ui.click("从模板新建");
            await until(() => galleryOpen());
            gallery().click();
            const backdropClosed = !galleryOpen();
            const own = (await mc.drafts.list()).filter((draft) => !draft.builtIn).length;
            return {
              opened, names, focusedFirst, thumbs, descriptions, tags, topicChips, styleChips, byTopic, byStyle, byBoth, none, all,
              afterRight, afterDown,
              picked: { theme: picked.theme, markdown: picked.markdown === pickedEntry.markdown.join("\\n"), readOnly: picked.readOnly, cover: picked.cover.enabled },
              originalAgain: originalAgain.markdown,
              clicked: { theme: clicked.theme, markdown: clicked.markdown === registry[2].markdown.join("\\n") },
              escClosed, backdropClosed, own,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["opened"] as? Bool == true, "画廊是一个对话框")
        #expect(result?["names"] as? [String] == ["干货清单", "踩坑经验", "一周要闻", "论文解读", "工具实测", "读书笔记", "旅行日记", "活动通知"], "8 套自带模板按登记表顺序")
        #expect(result?["focusedFirst"] as? Bool == true, "打开时焦点在第一格")
        #expect(result?["thumbs"] as? [Bool] == Array(repeating: true, count: 8), "每格的缩略图都画出来了：\(result?["thumbs"] ?? [])")
        #expect(result?["descriptions"] as? Bool == true)
        #expect((result?["tags"] as? [[String]])?[2] == ["新闻", "简洁"], "格子下面是题材与风格的标签")
        #expect(result?["topicChips"] as? [String] == ["全部", "清单", "经验", "新闻", "解读", "实测", "读书", "日记", "通知"])
        #expect(result?["styleChips"] as? [String] == ["全部", "简洁", "柔和", "有态度"])
        #expect(result?["byTopic"] as? [String] == ["干货清单"])
        #expect(result?["byStyle"] as? [String] == ["踩坑经验", "旅行日记"])
        #expect(result?["byBoth"] as? [String] == ["旅行日记"], "两组一起筛")
        #expect(result?["none"] as? [AnyHashable] == [0, false] as [AnyHashable], "筛不到时说一声")
        #expect(result?["all"] as? Int == 8)
        #expect(result?["afterRight"] as? String == "踩坑经验" && result?["afterDown"] as? String == "读书笔记", "方向键在格子间走：\(result?["afterRight"] ?? "") / \(result?["afterDown"] ?? "")")
        let picked = result?["picked"] as? [String: Any]
        #expect(picked?["theme"] as? String == "scroll" && picked?["markdown"] as? Bool == true && picked?["readOnly"] as? Bool == false && picked?["cover"] as? Bool == true, "回车新建的稿子照模板：\(picked ?? [:])")
        #expect(result?["originalAgain"] as? String == "原来的稿子", "原来的稿子不变")
        let clicked = result?["clicked"] as? [String: Any]
        #expect(clicked?["theme"] as? String == "press" && clicked?["markdown"] as? Bool == true, "点一格新建的稿子照模板：\(clicked ?? [:])")
        #expect(result?["escClosed"] as? [Bool] == [true, true], "Esc 关上，焦点离开画廊")
        #expect(result?["backdropClosed"] as? Bool == true, "点遮罩关上")
        #expect(result?["own"] as? Int == 3, "原来的一篇加新建的两篇")
        #expect(harness.pageErrors == [])
    }

    @Test("空白稿子的空状态：正文空着、这篇能改时编辑区里浮着「从模板开始」「看看说明书」；一开始打字就收起、这篇不再提示；换一篇空白稿子再提示；说明书里不提示；按钮能用")
    func emptyStateHint() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const hint = () => document.getElementById("editorEmptyHint");
            const visible = () => !hint().hidden && hint().getClientRects().length > 0;
            const onGuide = [(await mc.drafts.current()).readOnly, visible()];
            await mc.drafts.create();
            await until(() => visible());
            const onBlank = visible();
            const buttons = [Boolean(ui.find("从模板开始", { within: hint() })), Boolean(ui.find("看看说明书", { within: hint() }))];
            const insideEditor = Boolean(hint().closest(".editor-pane")) && !document.getElementById("markdownEditor").contains(hint());
            // 打字：输入一来就收起（不等出图）
            document.querySelector("#markdownEditor .cm-content").dispatchEvent(new InputEvent("beforeinput", { bubbles: true, cancelable: true, inputType: "insertText", data: "字" }));
            const afterInput = visible();
            await mc.drafts.update({ markdown: "写了字" });
            const afterText = visible();
            // 又清空：这篇已经开始写过，不再提示
            await mc.drafts.update({ markdown: "" });
            const afterClear = visible();
            // 换到另一篇空白稿子：再提示
            await mc.drafts.create();
            await until(() => visible());
            const secondBlank = visible();
            // 「看看说明书」打开说明书，提示收起
            ui.click("看看说明书", { within: hint() });
            await until(async () => (await mc.drafts.current()).readOnly);
            await until(() => !visible());
            const guideOpened = (await mc.drafts.current()).readOnly && !visible();
            // 空白稿子里「从模板开始」打开画廊
            await mc.drafts.create();
            await until(() => visible());
            ui.click("从模板开始", { within: hint() });
            await until(() => galleryOpen());
            const galleryFromHint = galleryOpen();
            press("Escape");
            return { onGuide, onBlank, buttons, insideEditor, afterInput, afterText, afterClear, secondBlank, guideOpened, galleryFromHint };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["onGuide"] as? [Bool] == [true, false], "说明书里不提示")
        #expect(result?["onBlank"] as? Bool == true, "空白稿子里提示")
        #expect(result?["buttons"] as? [Bool] == [true, true])
        #expect(result?["insideEditor"] as? Bool == true, "浮在编辑区里，但不在 CodeMirror 的 DOM 里")
        #expect(result?["afterInput"] as? Bool == false, "一开始打字就收起")
        #expect(result?["afterText"] as? Bool == false)
        #expect(result?["afterClear"] as? Bool == false, "这篇写过了，清空也不再提示")
        #expect(result?["secondBlank"] as? Bool == true, "换一篇空白稿子再提示")
        #expect(result?["guideOpened"] as? Bool == true, "「看看说明书」打开说明书")
        #expect(result?["galleryFromHint"] as? Bool == true, "「从模板开始」打开画廊")
        #expect(harness.pageErrors == [])
    }

    @Test("存为模板：稿件右键菜单「存为模板…」（说明书没有）弹出名字（预填稿子的名字）、说明、题材与风格；名字空着留在对话框里；存好后在画廊里排在自带的后面，能在 Finder 中显示，删除先确认、取消不删、确认就删")
    func saveAsTemplateDialogAndGalleryDelete() async throws {
        let harness = ShellHarness(onboarding: false)
        let folder = harness.aiRoot.appendingPathComponent("模板")
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const registry = window.MediaCraftTemplateRegistry;
            const blob = await fetch("docs/guide-assets/night-lake.jpg").then((response) => response.blob());
            const draft = await mc.drafts.create({ title: "湖边一晚", markdown: "## 夜湖\\n\\n一句话。\\n\\n" });
            await mc.editor.select(draft.markdown.length);
            const [imageId] = await mc.media.import([new File([blob], "night-lake.jpg", { type: "image/jpeg" })]);
            await mc.drafts.update({ theme: "glow", cover: { enabled: true, subtitle: "副标题", image: imageId } });
            // 另一篇成为正在编辑的：存为模板时要先切回去
            const other = await mc.drafts.create({ markdown: "另一篇" });
            ui.expand("稿件列表");
            const row = (id) => region("稿件").querySelector(`[data-draft-id="${id}"]`);
            await until(() => row(draft.id));
            const contextMenu = (id) => row(id).dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 60, clientY: 200 }));
            const guide = (await mc.drafts.list()).find((item) => item.builtIn);
            contextMenu(guide.id);
            const guideHasItem = Boolean(ui.find("存为模板…"));
            press("Escape");
            contextMenu(draft.id);
            ui.click("存为模板…");
            const dialog = () => document.getElementById("saveTemplateDialog");
            await until(() => !dialog().classList.contains("hidden"));
            const name = ui.find("名字", { within: dialog() });
            const prefilled = name.value;
            const focused = document.activeElement === name;
            const topics = [...ui.find("题材", { within: dialog() }).options].map((option) => option.textContent);
            const styles = [...ui.find("风格", { within: dialog() }).options].map((option) => option.textContent);
            // 名字空着：留在对话框里，说原因
            name.value = "";
            ui.click("存为模板", { within: dialog() });
            await until(() => !document.getElementById("saveTemplateError").hidden);
            const emptyError = [document.getElementById("saveTemplateError").textContent, !dialog().classList.contains("hidden")];
            name.value = "我的湖";
            ui.find("说明", { within: dialog() }).value = "自己存的";
            ui.find("题材", { within: dialog() }).value = "日记";
            ui.find("风格", { within: dialog() }).value = "柔和";
            ui.click("存为模板", { within: dialog() });
            await until(() => dialog().classList.contains("hidden"), 20000);
            const statusAfter = document.getElementById("statusText").textContent;
            const switched = (await mc.drafts.current()).id === draft.id;
            const saved = (await mc.drafts.templates()).find((item) => item.id === "user_template_我的湖");

            // 画廊里：排在自带的后面，有「在 Finder 中显示」「删除」；自带的没有
            ui.click("从模板新建");
            await until(() => tiles().length === registry.length + 1);
            const last = tiles().at(-1);
            const lastName = ui.name(last);
            const card = last.closest(".template-card");
            const userActions = [Boolean(ui.find("在 Finder 中显示", { within: card })), Boolean(ui.find("删除", { within: card }))];
            const builtInActions = tiles().slice(0, -1).filter((tile) => tile.closest(".template-card").querySelector(".template-card-actions")).length;
            await until(thumbsReady, 90000);
            const userThumb = nonBlank(last.querySelector("canvas"));
            ui.click("在 Finder 中显示", { within: card });
            // 删除：先确认；取消不删
            ui.click("删除", { within: card });
            await until(() => ui.alert());
            const alertTitle = ui.alert().querySelector("h3").textContent;
            ui.click("取消", { within: ui.alert() });
            await until(() => !ui.alert());
            const stillThere = tiles().length === registry.length + 1 && (await mc.drafts.templates()).some((item) => item.id === "user_template_我的湖");
            ui.click("删除", { within: card });
            await until(() => ui.alert());
            ui.click("删除", { within: ui.alert() });
            await until(() => tiles().length === registry.length, 20000);
            const removed = !(await mc.drafts.templates()).some((item) => item.id === "user_template_我的湖");
            const galleryStillOpen = galleryOpen() && gallery().contains(document.activeElement);
            press("Escape");
            return {
              guideHasItem, prefilled, focused, topics, styles, emptyError, statusAfter, switched,
              saved: saved ? [saved.name, saved.description, saved.tags.join(","), saved.theme, String(saved.builtIn)] : null,
              lastName, userActions, builtInActions, userThumb, alertTitle, stillThere, removed, galleryStillOpen,
            };
        """) as? [String: Any]
        try await Self.waitFor { harness.revealedFiles.count == 1 }
        // 那一套的文件夹这时已经删掉了，解析不了 /var → /private/var 的符号链接：两边都去掉 /private 再比
        let unprivate = { (path: String) in path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path }
        let revealed = harness.revealedFiles.map { unprivate($0.resolvingSymlinksInPath().path) }
        let expectedReveal = unprivate(folder.appendingPathComponent("我的湖").path)
        let removedOnDisk = !FileManager.default.fileExists(atPath: folder.appendingPathComponent("我的湖").path)
        await harness.tearDown()

        #expect(result?["guideHasItem"] as? Bool == false, "说明书的右键菜单里没有「存为模板…」")
        #expect(result?["prefilled"] as? String == "湖边一晚", "名字预填稿子的名字")
        #expect(result?["focused"] as? Bool == true, "焦点在名字上")
        #expect(result?["topics"] as? [String] == ["不填", "清单", "经验", "新闻", "解读", "实测", "读书", "日记", "通知"], "题材列出已有模板的")
        #expect(result?["styles"] as? [String] == ["不填", "简洁", "柔和", "有态度"])
        #expect(result?["emptyError"] as? [AnyHashable] == ["先给模板起个名字", true] as [AnyHashable], "名字空着留在对话框里")
        #expect((result?["statusAfter"] as? String ?? "").contains("已存为模板「我的湖」"), "\(result?["statusAfter"] ?? "")")
        #expect(result?["switched"] as? Bool == true, "存的是右键的那篇：先切过去")
        #expect(result?["saved"] as? [String] == ["我的湖", "自己存的", "日记,柔和", "glow", "false"], "\(result?["saved"] ?? "")")
        #expect(result?["lastName"] as? String == "我的湖", "画廊里排在自带的后面")
        #expect(result?["userActions"] as? [Bool] == [true, true])
        #expect(result?["builtInActions"] as? Int == 0, "自带的不能删")
        #expect(result?["userThumb"] as? Bool == true, "自己存的也有真实的缩略图")
        #expect(revealed == [expectedReveal], "在 Finder 中显示那一套的文件夹：\(revealed)")
        #expect(result?["alertTitle"] as? String == "删除模板「我的湖」？")
        #expect(result?["stillThere"] as? Bool == true, "取消不删")
        #expect(result?["removed"] as? Bool == true && removedOnDisk, "确认就删，文件夹也没了")
        #expect(result?["galleryStillOpen"] as? Bool == true, "删完画廊还开着，焦点还在里面")
        #expect(harness.pageErrors == [])
    }
}
