import Foundation
import Testing

/// 图片与 PDF（ticket 09）：拖放到编辑区 / 预览的插入位置、多文件顺序、PDF 每页一张、裁剪、拼图、
/// 预览里拖动 / 拼图 / 缩放 / 删除，每一步都能 ⌘Z。只通过 App API、界面（可访问名称、指针与拖放事件）和原生桥说话。
@MainActor
struct ImageEditingTests {
    static let helpers = """
        const mc = window.mediacraft;
        window.mc = mc;
        window.settle = (ms = 80) => new Promise((resolve) => setTimeout(resolve, ms));
        window.markdown = async () => (await mc.drafts.current()).markdown;
        // 正文里的图片编号换成图片名，断言读起来像稿子
        window.shape = async () => {
          let text = await markdown();
          for (const image of await mc.media.list()) text = text.split(image.id).join(image.name);
          return text;
        };
        window.idOf = async (name) => (await mc.media.list()).find((image) => image.name === name)?.id;
        // 一张 PNG：colors 从左到右平分成几条竖条
        window.pngBlob = (width, height, colors) => new Promise((resolve) => {
          const canvas = document.createElement("canvas");
          canvas.width = width;
          canvas.height = height;
          const context = canvas.getContext("2d");
          colors.forEach((color, index) => {
            context.fillStyle = color;
            context.fillRect((index * width) / colors.length, 0, width / colors.length, height);
          });
          canvas.toBlob(resolve, "image/png");
        });
        window.pngFile = async (name, width = 40, height = 30, colors = ["#e03131"]) => new File([await pngBlob(width, height, colors)], name, { type: "image/png" });
        // 从 Finder 拖文件进来：先 dragover 再在 (x, y) 松手
        window.dropFiles = (target, files, x, y) => {
          const transfer = new DataTransfer();
          files.forEach((file) => transfer.items.add(file));
          const init = { bubbles: true, cancelable: true, dataTransfer: transfer, clientX: x, clientY: y };
          target.dispatchEvent(new DragEvent("dragover", init));
          target.dispatchEvent(new DragEvent("drop", init));
        };
        // 鼠标的指针事件（WebKit 里鼠标的 pointerId 是 1）
        window.pointer = (type, target, x, y) => target.dispatchEvent(new PointerEvent(type, {
          bubbles: true, cancelable: true, button: 0, buttons: type === "pointerup" ? 0 : 1,
          pointerId: 1, pointerType: "mouse", isPrimary: true, clientX: x, clientY: y,
        }));
        window.middle = (element) => {
          const rect = element.getBoundingClientRect();
          return [rect.left + rect.width / 2, rect.top + rect.height / 2];
        };
        // 按住 element 拖到 (x, y) 松手；move 事件发给 moveTarget（舞台监听整个窗口）
        window.dragTo = async (element, from, to, moveTarget = window) => {
          pointer("pointerdown", element, ...from);
          pointer("pointermove", moveTarget, from[0] + 8, from[1] + 8);
          pointer("pointermove", moveTarget, ...to);
          pointer("pointerup", moveTarget, ...to);
          await settle();
        };
        // 卡片上的逻辑坐标 → 屏幕坐标（先把那一页滚进来）
        window.cardPoint = async (pageIndex, x, y) => {
          const canvas = (await mc.render.canvases())[pageIndex];
          canvas.scrollIntoView({ block: "center" });
          await settle(30);
          const rect = canvas.getBoundingClientRect();
          return [rect.left + (x / 864) * rect.width, rect.top + (y / 1152) * rect.height];
        };
        window.pageWith = async (predicate) => {
          const pages = await mc.render.pages();
          const index = pages.findIndex(predicate);
          return { index, page: pages[index] };
        };
        window.box = (label) => ui.find(label);
        window.dialog = (text) => ui.dialogs().find((element) => element.textContent.includes(text)) ?? null;
    """

    @Test("拖进编辑区：落在一行开头的上半截插在这一行前面，落在字中间插在这一行后面（不拆开），落在空行就占这一行")
    func dropIntoEditorAtTheReleasedLine() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "第一行\\n第二行\\n\\n第三行" });
            await settle(200);
            const body = document.querySelector('[role="textbox"][aria-label="正文"]');
            const line = (text) => [...body.children].find((element) => element.textContent === text);
            const textRect = (element) => {
              const range = document.createRange();
              range.selectNodeContents(element);
              return range.getBoundingClientRect();
            };
            const second = textRect(line("第二行"));
            dropFiles(body, [await pngFile("前.png")], second.left + 1, second.top + 2);
            await settle(300);
            const first = textRect(line("第一行"));
            dropFiles(body, [await pngFile("后.png")], first.left + first.width / 2, first.top + first.height / 2);
            await settle(300);
            const blank = [...body.children].find((element) => element.textContent === "" && element.getBoundingClientRect().top > textRect(line("第二行")).top);
            const blankRect = blank.getBoundingClientRect();
            dropFiles(body, [await pngFile("空行.png")], blankRect.left + 20, blankRect.top + blankRect.height / 2);
            await settle(300);
            return await shape();
        """) as? String
        await harness.tearDown()

        #expect(result == "第一行\n[[图片:后.png]]\n[[图片:前.png]]\n第二行\n[[图片:空行.png]]\n第三行")
        #expect(harness.pageErrors == [])
    }

    @Test("拖到预览的卡片上：落在一段字的上半截插在它前面，下半截插在它后面；多个文件按文件名自然排序")
    func dropOntoPreviewBetweenBlocks() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "第一段\\n\\n第二段\\n\\n第三段" });
            const dropAround = async (text, fraction, files) => {
              const content = await markdown();
              const { index, page } = await pageWith((candidate) => candidate.dropTargets.some((target) => content.slice(...target.source).includes(text)));
              const target = page.dropTargets.find((candidate) => content.slice(...candidate.source).includes(text));
              const [x, y] = await cardPoint(index, 432, target.y + target.height * fraction);
              dropFiles((await mc.render.canvases())[index], files, x, y);
              const count = files.length + (await mc.media.list()).length;
              for (let tries = 0; tries < 100 && (await mc.media.list()).length < count; tries += 1) await settle(50);
              await mc.render.pages();
            };
            await dropAround("第二段", 0.25, [await pngFile("上.png")]);
            await dropAround("第二段", 0.75, [await pngFile("图10.png"), await pngFile("图2.png"), await pngFile("图1.png")]);
            return await shape();
        """) as? String
        await harness.tearDown()

        #expect(result == "第一段\n\n[[图片:上.png]]\n第二段\n[[图片:图1.png]]\n[[图片:图2.png]]\n[[图片:图10.png]]\n\n第三段")
        #expect(harness.pageErrors == [])
    }

    @Test("PDF 每页一张图（原生桥按页渲染）；浏览器里没有原生桥时说明原因，同批的图片照常插入")
    func pdfPagesThroughTheNativeBridge() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "开头" });
            const native = window.MediaCraftNative;
            const pdf = new File([new Uint8Array([37, 80, 68, 70])], "讲义.pdf", { type: "application/pdf" });
            // 假的原生桥：这份 PDF 有三页
            const pages = [await pngBlob(30, 40, ["#e03131"]), await pngBlob(30, 40, ["#2f9e44"]), await pngBlob(30, 40, ["#1971c2"])];
            window.MediaCraftNative = { ...native, pdfToImages: async () => pages };
            const fromPdf = await mc.media.import([pdf], { at: 2 });
            const names = await Promise.all(fromPdf.map(async (id) => (await mc.media.get(id)).name));
            // 浏览器里：没有原生桥
            window.MediaCraftNative = null;
            const alone = await mc.media.import([pdf]).then(() => "imported", (error) => error.message);
            const mixed = await mc.media.import([pdf, await pngFile("封面.png")], { at: 2 });
            const status = [...document.querySelectorAll('[role="status"]')].map((element) => element.textContent).join(" ");
            window.MediaCraftNative = native;
            return {
              names,
              alone,
              mixed: await Promise.all(mixed.map(async (id) => (await mc.media.get(id)).name)),
              status,
              shape: await shape(),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["names"] as? [String] == ["讲义-第1页.png", "讲义-第2页.png", "讲义-第3页.png"])
        #expect((result?["alone"] as? String ?? "").contains("MediaCraft App"), "浏览器里导入 PDF 说明要在 App 里做")
        #expect(result?["mixed"] as? [String] == ["封面.png"])
        #expect((result?["status"] as? String ?? "").contains("PDF"))
        #expect(result?["shape"] as? String == "开头\n[[图片:封面.png]]\n[[图片:讲义-第1页.png]]\n[[图片:讲义-第2页.png]]\n[[图片:讲义-第3页.png]]\n")
        #expect(harness.pageErrors == [])
    }

    @Test("裁剪：选 1:1 得到正方形，卡片上只剩选框里的画面；拖动选框换一块；⌘Z 一步步退回")
    func cropPicksTheFramedPixels() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "开头" });
            // 左红右蓝的 200 × 100 图
            const [id] = await mc.media.import([await pngFile("红蓝.png", 200, 100, ["#e03131", "#1971c2"])], { at: 2 });
            await mc.media.update(id, { layout: { widthPercent: 50, align: "center" } });
            await mc.render.pages();
            const colorsOnCard = async () => {
              const { index, page } = await pageWith((candidate) => candidate.imageHits.length > 0);
              const [hit] = page.imageHits;
              const context = (await mc.render.canvases())[index].getContext("2d");
              const at = (fraction) => {
                const [r, , b] = context.getImageData(Math.round((hit.x + hit.width * fraction) * 2), Math.round((hit.y + hit.height / 2) * 2), 1, 1).data;
                return r > 180 && b < 120 ? "red" : b > 150 && r < 120 ? "blue" : `${r},${b}`;
              };
              return { aspect: Math.round((hit.width / hit.height) * 100) / 100, left: at(0.2), right: at(0.8) };
            };
            const openCrop = async () => {
              ui.click("编辑图片 红蓝.png", { within: document.querySelector('[role="textbox"][aria-label="正文"]') });
              for (let tries = 0; tries < 50 && !dialog("裁剪 红蓝.png"); tries += 1) await settle(40);
              return dialog("裁剪 红蓝.png");
            };
            let crop = await openCrop();
            ui.click("1:1", { within: crop });
            ui.click("完成", { within: crop });
            await settle();
            const square = { crop: (await mc.media.get(id)).crop, card: await colorsOnCard() };
            crop = await openCrop();
            const pressed = ui.find("1:1", { within: crop }).getAttribute("aria-pressed");
            const frame = crop.querySelector('[aria-label^="裁剪框"]');
            const [x, y] = middle(frame);
            await dragTo(frame, [x, y], [x + 600, y], frame);
            ui.click("完成", { within: crop });
            await settle();
            const moved = { crop: (await mc.media.get(id)).crop, card: await colorsOnCard() };
            await mc.drafts.undo();
            const undoOnce = (await mc.media.get(id)).crop;
            await mc.drafts.undo();
            const undoTwice = (await mc.media.get(id)).crop;
            // 取消不改
            crop = await openCrop();
            ui.click("16:9", { within: crop });
            ui.click("取消", { within: crop });
            await settle();
            return { square, pressed, moved, undoOnce, undoTwice, afterCancel: (await mc.media.get(id)).crop, cropOpen: Boolean(dialog("裁剪 红蓝.png")) };
        """) as? [String: Any]
        await harness.tearDown()

        let square = result?["square"] as? [String: Any]
        #expect(square?["crop"] as? [String: Int] == ["x": 50, "y": 0, "width": 100, "height": 100])
        #expect(square?["card"] as? [String: AnyHashable] == ["aspect": 1, "left": "red", "right": "blue"], "卡片上是正中间一块：左半红、右半蓝")
        #expect(result?["pressed"] as? String == "true", "再打开时比例还是 1:1")
        let moved = result?["moved"] as? [String: Any]
        #expect(moved?["crop"] as? [String: Int] == ["x": 100, "y": 0, "width": 100, "height": 100], "选框拖到最右边")
        #expect(moved?["card"] as? [String: AnyHashable] == ["aspect": 1, "left": "blue", "right": "blue"])
        #expect(result?["undoOnce"] as? [String: Int] == ["x": 50, "y": 0, "width": 100, "height": 100])
        #expect(result?["undoTwice"] is NSNull, "再撤销一步回到没裁剪")
        #expect(result?["afterCancel"] is NSNull)
        #expect(result?["cropOpen"] as? Bool == false, "取消后对话框关上")
        #expect(harness.pageErrors == [])
    }

    @Test("拼图对话框：比例点选或拖下边、左右对调、取消不改，完成写回拼图标记；拆成两张；都能撤销")
    func pairDialogRoundTripsThroughMarkdown() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "开头" });
            const [red, blue] = await mc.media.import([await pngFile("红.png", 60, 60, ["#e03131"]), await pngFile("蓝.png", 60, 60, ["#1971c2"])]);
            await mc.drafts.update({ markdown: `开头\\n[[图片:${red}|${blue}]]\\n结尾` });
            await settle(200);
            const body = document.querySelector('[role="textbox"][aria-label="正文"]');
            const openPair = async (names) => {
              ui.click(`调整拼图 ${names}`, { within: body });
              for (let tries = 0; tries < 50 && !dialog("左右对调"); tries += 1) await settle(40);
              return dialog("左右对调");
            };
            const pairRatio = async () => {
              const { page } = await pageWith((candidate) => candidate.items.some((item) => item.kind === "imagePair"));
              const pair = page.items.find((item) => item.kind === "imagePair");
              return Math.round((pair.width / pair.height) * 100) / 100;
            };
            let pair = await openPair("红.png + 蓝.png");
            ui.click("4:3", { within: pair });
            ui.click("完成", { within: pair });
            await settle();
            const fourThree = { text: await shape(), ratio: await pairRatio() };
            pair = await openPair("红.png + 蓝.png");
            const pressed = ui.find("4:3", { within: pair }).getAttribute("aria-pressed");
            // 拖预览的下边往下，拉成方的
            const handle = ui.find("拖动改变拼图比例", { within: pair }) ?? pair.querySelector('[role="slider"]');
            const [x, y] = middle(handle);
            await dragTo(handle, [x, y], [x, y + 400], handle);
            const dragged = handle.getAttribute("aria-valuetext");
            ui.click("左右对调", { within: pair });
            ui.click("取消", { within: pair });
            await settle();
            const cancelled = await shape();
            pair = await openPair("红.png + 蓝.png");
            await dragTo(handle, middle(handle), [middle(handle)[0], middle(handle)[1] + 400], handle);
            ui.click("左右对调", { within: pair });
            ui.click("完成", { within: pair });
            await settle();
            const swapped = { text: await shape(), ratio: await pairRatio() };
            pair = await openPair("蓝.png + 红.png");
            ui.click("拆成两张", { within: pair });
            await settle();
            const split = await shape();
            await mc.drafts.undo();
            const undoSplit = await shape();
            await mc.drafts.undo();
            const undoSwap = await shape();
            return { fourThree, pressed, dragged, cancelled, swapped, split, undoSplit, undoSwap };
        """) as? [String: Any]
        await harness.tearDown()

        let fourThree = result?["fourThree"] as? [String: Any]
        #expect(fourThree?["text"] as? String == "开头\n[[图片:红.png|蓝.png|4x3]]\n结尾")
        #expect(fourThree?["ratio"] as? Double == 1.33, "卡片上整组 4:3")
        #expect(result?["pressed"] as? String == "true", "再打开时是 4:3")
        #expect(result?["dragged"] as? String == "1:1", "下边往下拖到头吸附到 1:1")
        #expect(result?["cancelled"] as? String == "开头\n[[图片:红.png|蓝.png|4x3]]\n结尾", "取消什么都不改")
        let swapped = result?["swapped"] as? [String: Any]
        #expect(swapped?["text"] as? String == "开头\n[[图片:蓝.png|红.png|1x1]]\n结尾")
        #expect(swapped?["ratio"] as? Double == 1)
        #expect(result?["split"] as? String == "开头\n[[图片:蓝.png]]\n[[图片:红.png]]\n结尾")
        #expect(result?["undoSplit"] as? String == "开头\n[[图片:蓝.png|红.png|1x1]]\n结尾")
        #expect(result?["undoSwap"] as? String == "开头\n[[图片:红.png|蓝.png|4x3]]\n结尾")
        #expect(harness.pageErrors == [])
    }

    @Test("预览里拖图片：拖到一段字前面就挪过去，拖到另一张图上拼成一组；⌘Z 一步步退回")
    func dragImagesOnTheStage() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "第一段\\n\\n第二段" });
            const ids = await mc.media.import([await pngFile("甲.png", 80, 60), await pngFile("乙.png", 80, 60, ["#1971c2"])], { at: "第一段\\n\\n第二段".length });
            for (const id of ids) await mc.media.update(id, { layout: { widthPercent: 30, align: "center" } });
            await mc.render.pages();
            await settle(100);
            const content = await markdown();
            const { index, page } = await pageWith((candidate) => candidate.dropTargets.some((target) => content.slice(...target.source).includes("第一段")));
            const first = page.dropTargets.find((target) => content.slice(...target.source).includes("第一段"));
            const to = await cardPoint(index, 432, first.y + first.height * 0.2);
            await dragTo(box("选择图片 乙.png"), middle(box("选择图片 乙.png")), to);
            await mc.render.pages();
            await settle(100);
            const moved = await shape();
            // 甲拖到乙上、停在乙的左半边：甲在左
            const target = box("选择图片 乙.png");
            const rect = target.getBoundingClientRect();
            await dragTo(box("选择图片 甲.png"), middle(box("选择图片 甲.png")), [rect.left + rect.width * 0.35, rect.top + rect.height / 2]);
            await mc.render.pages();
            await settle(100);
            const paired = { text: await shape(), selected: ui.find("选择拼图 甲.png + 乙.png")?.getAttribute("aria-pressed") };
            await mc.drafts.undo();
            const undoPair = await shape();
            await mc.drafts.undo();
            const undoMove = await shape();
            return { moved, paired, undoPair, undoMove };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["moved"] as? String == "[[图片:乙.png]]\n第一段\n\n第二段\n[[图片:甲.png]]\n")
        let paired = result?["paired"] as? [String: Any]
        #expect(paired?["text"] as? String == "[[图片:甲.png|乙.png]]\n第一段\n\n第二段\n", "甲的那一行删掉，和乙拼在乙的位置")
        #expect(paired?["selected"] as? String == "true", "拼好后选中这组")
        #expect(result?["undoPair"] as? String == "[[图片:乙.png]]\n第一段\n\n第二段\n[[图片:甲.png]]\n")
        #expect(result?["undoMove"] as? String == "第一段\n\n第二段\n[[图片:甲.png]]\n[[图片:乙.png]]\n")
        #expect(harness.pageErrors == [])
    }

    @Test("缩放：拖选中图片的角改宽度，检查器里同步显示并可改，也能一次用到全部图片；每一步都能撤销")
    func resizeWithHandlesAndInspector() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "开头" });
            await mc.media.import([await pngFile("照片.png", 400, 300), await pngFile("另一张.png", 400, 300)], { at: 2 });
            const photo = await idOf("照片.png");
            const other = await idOf("另一张.png");
            await mc.render.pages();
            const widthOf = async (id) => (await mc.media.get(id)).layout?.widthPercent ?? null;
            const hitOf = async (id) => (await mc.render.pages()).flatMap((page) => page.imageHits).find((hit) => hit.imageId === id);
            const selected = box("选择图片 照片.png");
            selected.scrollIntoView({ block: "center" });
            await settle(50);
            const [cx, cy] = middle(selected);
            pointer("pointerdown", selected, cx, cy);
            pointer("pointerup", window, cx, cy);
            await settle();
            const handle = selected.querySelector('[data-handle="se"]');
            const frame = selected.getBoundingClientRect();
            const canvasWidth = selected.parentElement.getBoundingClientRect().width;
            const [hx, hy] = middle(handle);
            // 居中的图两边一起缩：右下角往左拖卡片宽度的 1/4，宽度少一半卡宽
            await dragTo(handle, [hx, hy], [hx - canvasWidth / 4 + 8, hy]);
            await mc.render.pages();
            await settle(100);
            const dragged = await widthOf(photo);
            const hit = await hitOf(photo);
            const slider = ui.find("图片宽度（百分比）");
            const shown = slider.value;
            slider.value = "60";
            slider.dispatchEvent(new Event("input", { bubbles: true }));
            slider.dispatchEvent(new Event("change", { bubbles: true }));
            await mc.render.pages();
            const fromInspector = await widthOf(photo);
            // 不选图时「宽度用到全部图片」
            ui.click("取消选中图片");
            await settle();
            slider.value = "45";
            slider.dispatchEvent(new Event("input", { bubbles: true }));
            ui.click("宽度用到全部图片");
            await mc.render.pages();
            const all = [await widthOf(photo), await widthOf(other)];
            await mc.drafts.undo();
            const undoAll = [await widthOf(photo), await widthOf(other)];
            await mc.drafts.undo();
            const undoInspector = await widthOf(photo);
            await mc.drafts.undo();
            const undoDrag = await widthOf(photo);
            return { dragged, hitWidth: Math.round(hit.width), base: Math.round(hit.baseWidth), shown, fromInspector, all, undoAll, undoInspector, undoDrag };
        """) as? [String: Any]
        await harness.tearDown()

        let dragged = result?["dragged"] as? Int ?? 0
        #expect((40...60).contains(dragged), "拖到大约一半宽：\(dragged)%")
        #expect(result?["hitWidth"] as? Int == Int((Double(result?["base"] as? Int ?? 0) * Double(dragged) / 100).rounded()))
        #expect(result?["shown"] as? String == String(dragged), "检查器显示选中图片的宽度")
        #expect(result?["fromInspector"] as? Int == 60)
        #expect(result?["all"] as? [Int] == [45, 45])
        #expect(result?["undoAll"] as? [Int] == [60, 100])
        #expect(result?["undoInspector"] as? Int == dragged)
        #expect(result?["undoDrag"] as? Int == 100)
        #expect(harness.pageErrors == [])
    }

    @Test("预览里删掉一组拼图：两张图的标记与画面一起没了，⌘Z 一起回来")
    func deletePairAndUndo() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "开头" });
            await mc.media.import([await pngFile("左.png"), await pngFile("右.png")]);
            const left = await idOf("左.png");
            const right = await idOf("右.png");
            await mc.drafts.update({ markdown: `开头\\n\\n[[image:${left}|${right}|1x1]]\\n\\n结尾` });
            await mc.render.pages();
            const pair = box("选择拼图 左.png + 右.png");
            pair.focus();
            pair.dispatchEvent(new KeyboardEvent("keydown", { key: "Backspace", bubbles: true, cancelable: true }));
            await mc.render.pages();
            const gone = { text: await shape(), left: await mc.media.get(left), right: await mc.media.get(right), box: Boolean(box("选择拼图 左.png + 右.png")) };
            document.activeElement?.blur?.();
            document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "z", metaKey: true, bubbles: true, cancelable: true }));
            await mc.render.pages();
            await settle(100);
            return {
              gone,
              back: await shape(),
              srcs: Boolean((await mc.media.src(left))?.startsWith("data:image/png") && (await mc.media.src(right))?.startsWith("data:image/png")),
              box: Boolean(box("选择拼图 左.png + 右.png")),
            };
        """) as? [String: Any]
        await harness.tearDown()

        let gone = result?["gone"] as? [String: Any]
        #expect(gone?["text"] as? String == "开头\n\n结尾")
        #expect(gone?["left"] is NSNull && gone?["right"] is NSNull)
        #expect(gone?["box"] as? Bool == false)
        #expect(result?["back"] as? String == "开头\n\n[[image:左.png|右.png|1x1]]\n\n结尾")
        #expect(result?["srcs"] as? Bool == true)
        #expect(result?["box"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }

    @Test("应用自己的 [[image:…]] 图片、拼图与标准 Markdown 图片都能渲染")
    func internalImageSyntaxStillRenders() async throws {
        let harness = ShellHarness()
        try await harness.load()

        let rendered = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create();
            const png = (name) => new Promise((resolve) => {
              const canvas = document.createElement("canvas");
              canvas.width = 120;
              canvas.height = 65;
              canvas.getContext("2d").fillRect(0, 0, 60, 65);
              canvas.toBlob((blob) => resolve(new File([blob], name, { type: "image/png" })), "image/png");
            });
            const idOf = {};
            for (const id of await mc.media.import([await png("left.png"), await png("right.png")])) {
              idOf[(await mc.media.get(id)).name] = id;
            }
            const markdown = `[[image:${idOf["left.png"]}]]\\n\\n[[image:${idOf["left.png"]}|${idOf["right.png"]}|1x1]]\\n\\n![图](left.png)`;
            await mc.drafts.update({ markdown });
            const items = (await mc.render.pages()).flatMap((page) => page.items);
            return {
              items: items.map((item) => item.kind),
              markdownImage: items
                .filter((item) => item.kind === "image" && markdown.slice(item.source[0], item.source[1]).startsWith("![图]"))
                .map((item) => item.imageId).join(","),
              left: idOf["left.png"],
            };
        """) as? [String: Any]
        await harness.tearDown()

        let items = rendered?["items"] as? [String] ?? []
        #expect(items.contains("image"))
        #expect(items.contains("imagePair"))
        #expect(rendered?["markdownImage"] as? String == rendered?["left"] as? String, "标准 Markdown 图片仍按文件名找回已上传的图")
        #expect(harness.pageErrors == [])
    }
}
