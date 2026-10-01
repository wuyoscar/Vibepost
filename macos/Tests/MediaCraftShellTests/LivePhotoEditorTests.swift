import Foundation
import Testing

/// 实况编辑器、舞台上的预览播放、导出的取消。要解码视频，挂在已串行的 SendLivePhotoTests 下。
@MainActor
extension SendLivePhotoTests {
    static let editorHelpers = helpers + """
        window.pointer = (type, target, x, y) => target.dispatchEvent(new PointerEvent(type, {
          bubbles: true, cancelable: true, button: 0, buttons: type === "pointerup" ? 0 : 1,
          pointerId: 1, pointerType: "mouse", isPrimary: true, clientX: x, clientY: y,
        }));
        window.markdown = async () => (await mc.drafts.current()).markdown;
        window.imageTags = async () => [...(await markdown()).matchAll(/\\[\\[image:([^\\]|]+)\\]\\]/g)].map((match) => match[1]);
        window.liveDialog = () => ui.dialogs().find((element) => ui.name(element) === "实况") ?? null;
        window.inDialog = (name) => ui.find(name, { within: liveDialog() });
        window.track = () => liveDialog()?.querySelector('[role="slider"][aria-label="选取片段"]');
        window.pressed = (name) => inDialog(name)?.getAttribute("aria-pressed");
        // 从 Finder 把文件拖到编辑区里写着 text 的那一行上
        window.dropOnLine = (file, text) => {
          const body = document.querySelector('[role="textbox"][aria-label="正文"]');
          const line = [...body.children].find((element) => element.textContent === text);
          const rect = line.getBoundingClientRect();
          const transfer = new DataTransfer();
          transfer.items.add(file);
          body.dispatchEvent(new DragEvent("drop", {
            bubbles: true, cancelable: true, dataTransfer: transfer, clientX: rect.right - 2, clientY: rect.top + rect.height / 2,
          }));
        };
        // 编辑器开好：视频与胶片条都读出来了
        window.editorReady = () => liveDialog() && track().getAttribute("aria-valuemax") !== "0";
        // 一张图片（data URL）某一点的颜色
        window.pixel = (src, fx, fy) => new Promise((resolve) => {
          const image = new Image();
          image.onload = () => {
            const canvas = document.createElement("canvas");
            canvas.width = image.naturalWidth;
            canvas.height = image.naturalHeight;
            const context = canvas.getContext("2d");
            context.drawImage(image, 0, 0);
            resolve([...context.getImageData(Math.floor(image.naturalWidth * fx), Math.floor(image.naturalHeight * fy), 1, 1).data.slice(0, 3)]);
          };
          image.src = src;
        });
        window.coverSize = (src) => new Promise((resolve) => {
          const image = new Image();
          image.onload = () => resolve([image.naturalWidth, image.naturalHeight]);
          image.src = src;
        });
    """

    @Test("实况编辑器：视频拖进编辑区弹出编辑器，取消什么都不插；时长、倍速、取景、声音、片段、封面都按选的存下，再打开还是这些，改了能撤销")
    func liveEditorRoundTripsItsOptions() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let cancelled = try await harness.evaluate(Self.editorHelpers + """
            await mc.drafts.create({ markdown: "第一段\\n\\n第二段" });
            window.video = await liveFile(path, "海边.mp4");
            dropOnLine(video, "第一段");
            await until(editorReady);
            const opened = {
              duration: pressed("3 秒"), speed: pressed("1×"), aspect: pressed("原视频"), sound: pressed("声音"),
              summary: liveDialog().querySelector("[aria-live]").textContent, confirm: Boolean(inDialog("插入")),
            };
            inDialog("取消").click();
            await until(() => !liveDialog());
            return { opened, markdown: await markdown() };
        """, arguments: ["path": Self.h264]) as? [String: Any]

        let inserted = try await harness.evaluate("""
            dropOnLine(video, "第一段");
            await until(editorReady);
            inDialog("2×").click();
            inDialog("1:1").click();
            inDialog("声音").click();
            // 片段往后挪 0.5 秒
            track().focus();
            for (let step = 0; step < 5; step += 1) track().dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
            // 点胶片条上第 4.4 秒看那一刻，设为封面
            const rect = track().getBoundingClientRect();
            const x = rect.left + rect.width * 0.44;
            pointer("pointerdown", track(), x, rect.top + rect.height / 2);
            pointer("pointerup", track(), x, rect.top + rect.height / 2);
            const preview = liveDialog().querySelector("video");
            await until(() => Math.abs(preview.currentTime - 4.4) < 0.05 && preview.paused);
            inDialog("设为封面").click();
            const summary = liveDialog().querySelector("[aria-live]").textContent;
            inDialog("插入").click();
            await until(async () => !liveDialog() && (await imageTags()).length === 1);
            window.imageId = (await imageTags())[0];
            await mc.render.pages();
            const src = await mc.media.src(imageId);
            return {
              summary,
              live: (await mc.media.get(imageId)).live,
              shape: (await markdown()).replace(/\\[\\[image:[^\\]]+\\]\\]/g, "[[图]]"),
              cover: await coverSize(src),
              coverTop: await pixel(src, 0.5, 0.25),
            };
        """) as? [String: Any]

        let reopened = try await harness.evaluate("""
            ui.find("选择实况 海边.mp4 · 实况").dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
            await until(editorReady);
            const state = {
              pressed: ["3 秒", "2×", "1:1", "声音"].map(pressed),
              start: track().getAttribute("aria-valuenow"),
              confirm: Boolean(inDialog("完成")),
            };
            inDialog("5 秒").click();
            inDialog("完成").click();
            await until(async () => !liveDialog() && (await mc.media.get(imageId)).live.duration === 5);
            const changed = (await mc.media.get(imageId)).live;
            document.activeElement?.blur?.();
            document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "z", metaKey: true, bubbles: true, cancelable: true }));
            await until(async () => (await mc.media.get(imageId)).live.duration === 3);
            return { state, changed: changed.duration, undone: (await mc.media.get(imageId)).live.duration };
        """) as? [String: Any]
        await harness.tearDown()

        let opened = cancelled?["opened"] as? [String: Any]
        #expect(opened?["duration"] as? String == "true" && opened?["speed"] as? String == "true", "默认 3 秒、原速")
        #expect(opened?["aspect"] as? String == "true" && opened?["sound"] as? String == "true", "默认整幅画面、带声音")
        #expect((opened?["summary"] as? String ?? "").hasPrefix("成片 3 秒"))
        #expect(opened?["confirm"] as? Bool == true)
        #expect(cancelled?["markdown"] as? String == "第一段\n\n第二段", "取消什么都不插")

        let live = inserted?["live"] as? [String: Any]
        #expect(live?["duration"] as? Int == 3)
        #expect(live?["speed"] as? Int == 2)
        #expect(abs((live?["start"] as? Double ?? -1) - 0.5) < 0.01, "片段从 0.5 秒起")
        #expect(abs((live?["coverOffset"] as? Double ?? -1) - 3.9) < 0.05, "封面在起点后 3.9 秒（原视频 4.4 秒）")
        #expect(live?["sound"] as? Bool == false)
        #expect(live?["videoName"] as? String == "海边.mp4")
        #expect((inserted?["summary"] as? String ?? "").hasPrefix("成片 3 秒 · 原视频 0.5–6.5 秒"))
        #expect(inserted?["shape"] as? String == "第一段\n[[图]]\n\n第二段", "插在松手的那一行后面")
        let cover = inserted?["cover"] as? [Int] ?? []
        #expect(cover.count == 2 && cover[0] == cover[1], "1:1 取景的封面是正方形：\(cover)")
        let top = inserted?["coverTop"] as? [Int] ?? []
        #expect(top.count == 3 && top[0] > 110 && top[1] < 80 && top[2] > 130, "封面是第 4.4 秒（紫）：\(top)")

        let state = reopened?["state"] as? [String: Any]
        #expect(state?["pressed"] as? [String] == ["true", "true", "true", "false"], "再打开还是 3 秒、2×、1:1、没有声音")
        #expect(state?["start"] as? String == "0.5")
        #expect(state?["confirm"] as? Bool == true, "改已有的实况，按钮是「完成」")
        #expect(reopened?["changed"] as? Int == 5)
        #expect(reopened?["undone"] as? Int == 3, "改实况设置是撤销历史里的一步")
        #expect(harness.pageErrors == [])
    }

    /// 测试里的窗口在屏幕外，页面处于隐藏状态，WebKit 不让隐藏的页面真的播放视频（play() 被拒）：
    /// 这里核对预览接得对——视频挂在图片框里、按取景铺满、静音、每次播放都先对到这一段的起点、按倍速；被拒时安静地停在封面。
    @Test("舞台上的实况卡片：图片框里挂着这段视频（按取景铺满、静音、角标 LIVE），翻到这张和指针停在图上时对到剪好的起点按倍速播放")
    func stagePreviewPlaysTheClip() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.editorHelpers + """
            await mc.drafts.create({ markdown: "实况在下面：" });
            // 640 × 360 的视频取中间一块正方形
            const crop = { x: 0.21875, y: 0, width: 0.5625, height: 1 };
            await mc.media.insertLivePhoto(await liveFile(path), { duration: 3, speed: 2, start: 1, coverOffset: 1, crop });
            const [page] = await mc.render.pages();
            const stage = document.querySelector('[aria-label="预览"]');
            const video = () => stage.querySelector("video");
            await until(() => video()?.readyState >= 1 && video().style.width);
            await until(() => Math.abs(video().currentTime - 1) < 0.01);
            const well = video().parentElement;
            const frame = well.closest(".card-frame");
            const hit = page.imageHits.find((item) => item.live);
            const cued = {
              time: video().currentTime, rate: video().playbackRate, muted: video().muted,
              box: ["width", "height", "left", "top"].map((key) => Math.round(parseFloat(video().style[key]) * 10) / 10),
              square: Math.abs(hit.width - hit.height) <= 1,
              wellWidth: Math.round((well.getBoundingClientRect().width / frame.getBoundingClientRect().width) * 864),
              badge: well.textContent.includes("LIVE"),
            };
            // 挪走以后，指针停到图上又对回起点
            video().currentTime = 5;
            await until(() => Math.abs(video().currentTime - 5) < 0.01);
            const rect = well.getBoundingClientRect();
            pointer("pointermove", frame, rect.left + rect.width / 2, rect.top + rect.height / 2);
            await until(() => Math.abs(video().currentTime - 1) < 0.01);
            return { cued, hitWidth: hit.width, state: well.dataset.state };
        """, arguments: ["path": Self.h264]) as? [String: Any]
        await harness.tearDown()

        let cued = result?["cued"] as? [String: Any]
        #expect(cued?["time"] as? Double == 1, "对到这一段的起点")
        #expect(cued?["rate"] as? Int == 2, "按倍速")
        #expect(cued?["muted"] as? Bool == true)
        #expect(cued?["box"] as? [Double] == [177.8, 100, -38.9, 0], "取景的正方形铺满图片框")
        #expect(cued?["square"] as? Bool == true)
        #expect(abs(Double(cued?["wellWidth"] as? Int ?? 0) - (result?["hitWidth"] as? Double ?? -99)) <= 1, "视频框和卡片上的图片框一样大")
        #expect(cued?["badge"] as? Bool == true, "角上标 LIVE")
        #expect(result?["state"] as? String == "resting", "放不了时停在封面")
        #expect(harness.pageErrors == [])
    }

    @Test("导出实况可以取消：壳停下合成、报「已取消」，之后照常导出；用 App API 改了时长后成片跟着变；浏览器里说明要在 App 里导出")
    func liveExportCancelsAndExplains() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.editorHelpers + """
            await mc.drafts.create({ title: "取消", markdown: "实况" });
            const id = await mc.media.insertLivePhoto(await liveFile(path), { duration: 8, speed: 1 });
            const progress = document.querySelector('[role="progressbar"][aria-label="进度"]');
            const started = Date.now();
            const outcome = mc.output.exportPng(0).then(() => "完成", (error) => error.message);
            await until(() => Number(progress.getAttribute("aria-valuenow")) >= 20, 30000);
            ui.click("取消导出");
            const cancelled = await outcome;
            const cancelMs = Date.now() - started;

            await mc.media.update(id, { live: { duration: 3 } });
            const { filename } = await mc.output.exportPng(0);

            const native = window.MediaCraftNative;
            window.MediaCraftNative = null;
            const browser = await mc.output.exportZip().then(() => "完成", (error) => error.message);
            window.MediaCraftNative = native;
            return { cancelled, cancelMs, filename, live: (await mc.media.get(id)).live.duration, browser };
        """, arguments: ["path": Self.h264]) as? [String: Any]
        let saved = try FileManager.default.contentsOfDirectory(atPath: harness.downloadsDirectory.path)
        let entries = try await ExportTests.zipEntries(harness, harness.downloadsDirectory.appendingPathComponent("取消-01.zip"))
        await harness.tearDown()

        #expect(result?["cancelled"] as? String == "已取消")
        #expect(result?["filename"] as? String == "取消-01.zip", "取消后照常导出")
        #expect(saved == ["取消-01.zip"], "取消的那次没存下文件")
        #expect(entries == ["取消-01.pvt/取消-01.MOV", "取消-01.pvt/取消-01.JPG", "取消-01.pvt/metadata.plist"])
        #expect(result?["live"] as? Int == 3)
        #expect((result?["browser"] as? String ?? "").contains("MediaCraft App"), "浏览器里明说要在 App 里导出实况")
        #expect(harness.pageErrors == [])
    }
}
