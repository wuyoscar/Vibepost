import Foundation
import Testing

@MainActor
struct DataSafetyTests {
    /// 用户操作的入口：插图、在预览里选中图片按 Delete、焦点不在编辑框时按 ⌘Z；稿子与图片的状态从 App API 读。
    static let helpers = """
        window.makePng = (color) => new Promise((resolve) => {
          const canvas = document.createElement("canvas");
          canvas.width = canvas.height = 8;
          const context = canvas.getContext("2d");
          context.fillStyle = color;
          context.fillRect(0, 0, 8, 8);
          canvas.toBlob(resolve, "image/png");
        });
        window.markdown = async () => (await window.mediacraft.drafts.current()).markdown;
        window.imageTags = async () => [...(await markdown()).matchAll(/\\[\\[(?:图片|image)[:：]([^\\]|]+)\\]\\]/g)].map((match) => match[1]);
        // 预览里图片的选择框，可访问名称是「选择图片 / 选择实况 + 图片名」
        window.previewBox = async (id) => {
          const image = await window.mediacraft.media.get(id);
          return image ? ui.find(`选择${image.kind === "live" ? "实况" : "图片"} ${image.name}`) : null;
        };
        window.anyPreviewBox = () => ui.find("选择图片") ?? ui.find("选择实况");
        window.deleteInPreview = async (id) => {
          const box = await previewBox(id);
          box.focus();
          box.dispatchEvent(new KeyboardEvent("keydown", { key: "Delete", bubbles: true, cancelable: true }));
        };
        window.pressOutsideEditor = (key, modifiers = {}) => {
          document.activeElement?.blur?.();
          document.body.dispatchEvent(new KeyboardEvent("keydown", { key, metaKey: true, bubbles: true, cancelable: true, ...modifiers }));
        };
        window.modalOpen = () => ui.alert() !== null;
    """

    /// 本机存储里那段实况视频真的读得出多少字节（记录里的大小不算数：文件没了，大小照样报）
    static let storedVideoBytes = """
        const db = await new Promise((resolve, reject) => {
          const open = indexedDB.open("mediacraft");
          open.onsuccess = () => resolve(open.result);
          open.onerror = () => reject(open.error);
        });
        const items = await new Promise((resolve) => {
          const all = db.transaction("media").objectStore("media").getAll();
          all.onsuccess = () => resolve(all.result);
        });
        db.close();
        const video = items.find((item) => item.kind === "video");
        return video ? await video.data.arrayBuffer().then((buffer) => buffer.byteLength, (error) => `读不出来：${error.name}`) : "没有视频";
    """

    static let imageShown = "(await previewBox(imageId))"
    static let imageGone = "!(await markdown()).includes(imageId) && !(await window.mediacraft.media.get(imageId)) && !anyPreviewBox()"

    @Test("预览里删掉图片后按 ⌘Z：标记和画面一起回来；⇧⌘Z 再删掉，再 ⌘Z 又回来并存下")
    func undoRestoresImageDeletedInPreview() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            const mc = window.mediacraft;
            await mc.drafts.create({ markdown: "第一段\\n\\n第二段" });
            await mc.media.import([new File([await makePng("#ff0000")], "红.png", { type: "image/png" })], { at: "第一段\\n\\n第二段".length });
        """)
        let inserted = try await harness.waitForPage("(await imageTags()).length === 1 && (await previewBox((await imageTags())[0]))")
        _ = try await harness.evaluate("""
            window.imageId = (await imageTags())[0];
            window.originalSrc = await window.mediacraft.media.src(imageId);
            await deleteInPreview(imageId);
        """)
        let deleted = try await harness.waitForPage(Self.imageGone)
        _ = try await harness.evaluate("pressOutsideEditor('z')")
        let restored = try await harness.waitForPage(Self.imageShown + " && (await window.mediacraft.media.src(imageId)) === originalSrc")
        _ = try await harness.evaluate("pressOutsideEditor('z', { shiftKey: true })")
        let redone = try await harness.waitForPage(Self.imageGone)
        _ = try await harness.evaluate("pressOutsideEditor('z')")
        let restoredAgain = try await harness.waitForPage(Self.imageShown)
        try await harness.load()
        let reopened = try await harness.evaluate(Self.helpers + """
            const [id] = await imageTags();
            const image = id && await window.mediacraft.media.get(id);
            return Boolean(image?.name === "红.png" && (await window.mediacraft.media.src(id))?.startsWith("data:image/png"));
        """) as? Bool
        await harness.tearDown()

        #expect(inserted && deleted)
        #expect(restored, "⌘Z 后图片数据还在，预览重新画出这张图")
        #expect(redone && restoredAgain)
        #expect(reopened == true, "撤销回来的图片随稿子保存")
        #expect(harness.pageErrors == [])
    }

    @Test("删除稿子前要在页面里确认：取消或 Esc 不删，确认才删")
    func deletingADraftAsksFirst() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            const mc = window.mediacraft;
            await mc.drafts.create({ markdown: "要留下的稿子" });
            window.targetId = (await mc.drafts.create({ markdown: "要删掉的稿子" })).id;
            ui.expand("稿件列表");
            window.clickDelete = () => ui.click("删除 要删掉的稿子");
            window.ownDrafts = async () => (await window.mediacraft.drafts.list()).filter((draft) => !draft.builtIn);
            window.stillThere = async () => (await ownDrafts()).some((draft) => draft.id === targetId);
            clickDelete();
        """)
        let asked = try await harness.waitForPage("modalOpen()")
        let question = try await harness.evaluate("return ui.alert().textContent") as? String ?? ""
        _ = try await harness.evaluate("ui.click('取消', { within: ui.alert() })")
        let keptAfterCancel = try await harness.waitForPage("!modalOpen() && (await stillThere())")
        _ = try await harness.evaluate("clickDelete()")
        _ = try await harness.waitForPage("modalOpen()")
        _ = try await harness.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))")
        let keptAfterEscape = try await harness.waitForPage("!modalOpen() && (await stillThere())")
        _ = try await harness.evaluate("clickDelete()")
        _ = try await harness.waitForPage("modalOpen()")
        _ = try await harness.evaluate("ui.click('删除', { within: ui.alert() })")
        let removed = try await harness.waitForPage("!modalOpen() && !(await stillThere()) && (await ownDrafts()).length === 1")
        await harness.tearDown()

        #expect(asked)
        #expect(question.contains("要删掉的稿子"))
        #expect(keptAfterCancel && keptAfterEscape)
        #expect(removed)
        #expect(harness.pageErrors == [])
    }

    /// 按 docs/storage.md 的记录格式造一批稿子（第 1 篇最旧），App 启动着时写进存储，重新载入后生效。
    static let seedDrafts = StorageScripts.read + """
        window.seedDrafts = (count) => writeStore("drafts", Array.from({ length: count }, (_, index) => ({
          id: `draft_seed_${String(index + 1).padStart(4, "0")}`,
          title: "",
          markdown: `第 ${index + 1} 篇`,
          mode: index % 3 === 2 ? "article" : "cards",
          theme: "notes",
          colors: {},
          fonts: { zh: "theme", en: "theme", code: "theme" },
          article: {},
          images: {},
          createdAt: 1_000_000 + index,
          updatedAt: 1_000_000 + index,
        })));
    """

    @Test("稿子数到上限时，新建会提示先删旧稿，不再悄悄删掉最旧的")
    func projectCapTellsInsteadOfDropping() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(Self.seedDrafts + "await seedDrafts(window.mediacraft.drafts.limit);")
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            const mc = window.mediacraft;
            window.ownDrafts = async () => (await window.mediacraft.drafts.list()).filter((draft) => !draft.builtIn);
            window.before = JSON.stringify((await ownDrafts()).map((draft) => draft.id));
            window.currentBefore = (await mc.drafts.current()).id;
            ui.expand("稿件列表");
            ui.click("新建稿件");
        """)
        let told = try await harness.waitForPage("modalOpen()")
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            const own = await ownDrafts();
            const contents = await Promise.all(own.map(async (draft) => (await mc.drafts.get(draft.id)).markdown));
            return {
              count: own.length,
              limit: mc.drafts.limit,
              unchanged: JSON.stringify(own.map((draft) => draft.id)) === before,
              oldestKept: contents.includes("第 1 篇"),
              sameDraft: (await mc.drafts.current()).id === currentBefore,
              message: ui.alert().textContent,
              api: await mc.drafts.create().then(() => "建成了", (error) => error.message),
            };
        """) as? [String: Any]
        _ = try await harness.evaluate("ui.click('知道了', { within: ui.alert() })")
        let closed = try await harness.waitForPage("!modalOpen()")
        await harness.tearDown()

        #expect(told && closed)
        #expect(result?["count"] as? Int == 1000)
        #expect(result?["limit"] as? Int == 1000)
        #expect(result?["unchanged"] as? Bool == true)
        #expect(result?["oldestKept"] as? Bool == true)
        #expect(result?["sameDraft"] as? Bool == true)
        #expect((result?["message"] as? String ?? "").contains("1000"))
        #expect((result?["api"] as? String ?? "").contains("1000"), "App API 新建也明说上限，不删旧稿")
        #expect(harness.pageErrors == [])
    }
}

/// 实况用例都挂在已串行的 SendLivePhotoTests 下：两个 WKWebView 同时解码视频会互相卡住。
@MainActor
extension SendLivePhotoTests {
    @Test("实况也一样：删掉后 ⌘Z，视频回到本机存储；切换稿子后撤销不了了，才真正释放")
    func undoRestoresLivePhotoVideo() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(DataSafetyTests.helpers + """
            const mc = window.mediacraft;
            await mc.drafts.create({ markdown: "第一段" });
            const video = await (await fetch("/macos/Tests/Fixtures/live-h264.mp4")).blob();
            await mc.media.insertLivePhoto(new File([video], "海边.mp4", { type: "video/mp4" }), { at: "第一段".length, duration: 3 });
        """)
        let inserted = try await harness.waitForPage("(await imageTags()).length === 1 && ui.find('选择实况')")
        let video = try await harness.evaluate("""
            window.imageId = (await imageTags())[0];
            window.videoKey = (await window.mediacraft.media.get(imageId)).live.videoKey;
            window.videoSize = (await window.mediacraft.media.video(videoKey)).memoryBytes;
            await deleteInPreview(imageId);
            return { key: videoKey, size: videoSize };
        """) as? [String: Any]
        let deleted = try await harness.waitForPage(DataSafetyTests.imageGone)
        _ = try await harness.evaluate("pressOutsideEditor('z')")
        let restored = try await harness.waitForPage(DataSafetyTests.imageShown + " && (await window.mediacraft.media.get(imageId)).kind === 'live'")
        let stored = try await harness.waitForPage("(await window.mediacraft.media.video(videoKey)).storedBytes === videoSize")

        try await harness.load()
        _ = try await harness.evaluate(DataSafetyTests.helpers + "window.videoKey = key; window.videoSize = size;", arguments: video ?? [:])
        let reopened = try await harness.waitForPage(
            "(await window.mediacraft.media.video(videoKey)).memoryBytes === videoSize && ui.find('选择实况')"
        )
        let readable = try await harness.evaluate(DataSafetyTests.storedVideoBytes)

        _ = try await harness.evaluate("""
            window.imageId = (await imageTags())[0];
            window.draftId = (await window.mediacraft.drafts.current()).id;
            await deleteInPreview(imageId);
        """)
        let deletedAgain = try await harness.waitForPage(DataSafetyTests.imageGone)
        let released = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create();
            pressOutsideEditor("z");
            await mc.drafts.open(draftId);
            await mc.render.pages();
            const video = await mc.media.video(videoKey);
            return {
              cache: video.memoryBytes !== null,
              stored: video.storedBytes !== null,
              back: (await imageTags()).length > 0 || Boolean(await mc.media.get(imageId)),
            };
        """) as? [String: Bool]
        await harness.tearDown()

        #expect(inserted && deleted)
        #expect(restored && stored, "⌘Z 后实况图回来，视频重新写回本机存储")
        #expect(reopened, "重新打开后实况视频还在")
        #expect(readable as? Int == video?["size"] as? Int, "存回本机的视频读得出来：\(String(describing: readable))")
        #expect(deletedAgain)
        #expect(released == ["cache": false, "stored": false, "back": false], "切换稿子后这次删除不能再撤销，视频随之释放")
        #expect(harness.pageErrors == [])
    }

    @Test("重新打开之后再删实况、再 ⌘Z：写回本机存储的视频读得出来，再打开一次舞台上还能播")
    func undoAfterReopenKeepsVideoReadable() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate(DataSafetyTests.helpers + """
            const mc = window.mediacraft;
            await mc.drafts.create({ markdown: "第一段" });
            const video = await (await fetch("/macos/Tests/Fixtures/live-h264.mp4")).blob();
            await mc.media.insertLivePhoto(new File([video], "海边.mp4", { type: "video/mp4" }), { at: "第一段".length, duration: 3 });
        """)
        _ = try await harness.waitForPage("(await imageTags()).length === 1 && ui.find('选择实况')")
        let video = try await harness.evaluate("""
            window.imageId = (await imageTags())[0];
            window.videoKey = (await window.mediacraft.media.get(imageId)).live.videoKey;
            window.videoSize = (await window.mediacraft.media.video(videoKey)).memoryBytes;
            return { id: imageId, key: videoKey, size: videoSize };
        """) as? [String: Any]
        let saved = try await harness.waitForPage("(await window.mediacraft.media.video(videoKey)).storedBytes === videoSize")

        // 重新打开：这时内存里的那一份是从本机存储读出来的
        let reopen = DataSafetyTests.helpers + "window.imageId = id; window.videoKey = key; window.videoSize = size;"
        try await harness.load()
        _ = try await harness.evaluate(reopen, arguments: video ?? [:])
        let reopened = try await harness.waitForPage(
            "(await window.mediacraft.media.video(videoKey)).memoryBytes === videoSize && ui.find('选择实况')"
        )
        _ = try await harness.evaluate("await deleteInPreview(imageId)")
        let deleted = try await harness.waitForPage(DataSafetyTests.imageGone)
        let removed = try await harness.waitForPage("(await window.mediacraft.media.video(videoKey)).storedBytes === null")
        _ = try await harness.evaluate("pressOutsideEditor('z')")
        let restored = try await harness.waitForPage(DataSafetyTests.imageShown)
        let stored = try await harness.waitForPage("(await window.mediacraft.media.video(videoKey)).storedBytes === videoSize")

        // 再打开一次：存回去的是不是真的视频，看舞台上的预览读不读得出画面
        try await harness.load()
        _ = try await harness.evaluate(reopen, arguments: video ?? [:])
        let playable = try await harness.waitForPage("""
            (() => {
              const video = document.querySelector(".stage-live-video");
              return Boolean(video) && video.readyState >= 1 && video.videoWidth > 0;
            })()
        """)
        await harness.tearDown()

        #expect(saved && reopened)
        #expect(deleted && removed, "预览里删掉后，本机存储里的视频跟着删掉")
        #expect(restored && stored, "⌘Z 后实况图回来，视频重新写回本机存储")
        #expect(playable, "写回去的视频读得出来")
        #expect(harness.pageErrors == [])
    }
}
