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
        window.imageTags = async () => [...(await markdown()).matchAll(/\\[\\[image:([^\\]|]+)\\]\\]/g)].map((match) => match[1]);
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
        #expect(deletedAgain)
        #expect(released == ["cache": false, "stored": false, "back": false], "切换稿子后这次删除不能再撤销，视频随之释放")
        #expect(harness.pageErrors == [])
    }
}
