import Foundation
import Testing

/// 内置说明书（src/guides/）与第一次打开时的新手引导（src/onboarding.js）。
@MainActor
struct GuidesTests {
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
        window.tour = () => ui.dialogs().find((dialog) => dialog.getAttribute("role") === "dialog" && dialog.textContent.includes("新手引导")) ?? null;
        window.tourTitle = () => tour()?.querySelector("h2")?.textContent ?? null;
        window.press = (key) => document.activeElement.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    """

    @Test("新手引导：新环境弹出四步，焦点在「下一步」，能上一步、方向键翻；看完记住，重新打开不再弹")
    func tourStepsAndRemembered() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const titles = [tourTitle()];
            const focused = document.activeElement === ui.find("下一步", { within: tour() });
            const firstHasBack = Boolean(ui.find("上一步", { within: tour() }));
            ui.click("下一步", { within: tour() });
            titles.push(tourTitle());
            ui.click("上一步", { within: tour() });
            const back = tourTitle();
            press("ArrowRight");
            press("ArrowRight");
            press("ArrowRight");
            titles.push(tourTitle());
            const finish = ui.find("开始使用", { within: tour() });
            finish.click();
            return { titles, focused, firstHasBack, back, finish: Boolean(finish), closed: tour() === null };
        """) as? [String: Any]
        try await harness.load() // 重新打开：等页面报告启动完成（这时该弹的引导已经弹出）
        let reopened = try await harness.evaluate(Self.helpers + "return tour() !== null;") as? Bool
        await harness.tearDown()

        #expect(result?["titles"] as? [String] == ["先新建一篇稿子", "像写文档一样写", "发到 iPhone，或让 AI 帮忙"])
        #expect(result?["focused"] as? Bool == true, "打开时焦点在「下一步」，回车就能往下走")
        #expect(result?["firstHasBack"] as? Bool == false, "第一步没有「上一步」")
        #expect(result?["back"] as? String == "先新建一篇稿子")
        #expect(result?["finish"] as? Bool == true, "最后一步的按钮是「开始使用」")
        #expect(result?["closed"] as? Bool == true)
        #expect(reopened == false, "看完了，重新打开不再弹")
        #expect(harness.pageErrors == [])
    }

    @Test("新手引导：Esc 跳过并记住；第一步点「新建稿件」直接进入下一步；已经有自己的稿子时不弹")
    func tourSkipAndFirstRunOnly() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            ui.click("稿件列表");
            await until(() => ui.find("新建稿件"));
            ui.click("新建稿件");
            await until(async () => tourTitle() !== "先新建一篇稿子" && (await mc.drafts.list()).some((draft) => !draft.builtIn));
            const afterNew = { title: tourTitle(), drafts: (await mc.drafts.list()).filter((draft) => !draft.builtIn).length };
            ui.find("下一步", { within: tour() }).focus();
            press("Escape");
            const skipped = tour() === null;
            localStorage.removeItem("mediacraft.onboarding.v1");
            return { afterNew, skipped };
        """) as? [String: Any]
        try await harness.load() // 重新打开：等页面报告启动完成（这时该弹的引导已经弹出）
        let reopened = try await harness.evaluate(Self.helpers + "return tour() !== null;") as? Bool
        await harness.tearDown()

        let afterNew = result?["afterNew"] as? [String: Any]
        #expect(afterNew?["title"] as? String == "像写文档一样写", "点了「新建稿件」就翻到下一步")
        #expect(afterNew?["drafts"] as? Int == 1, "新建照常生效")
        #expect(result?["skipped"] as? Bool == true, "Esc 跳过")
        #expect(reopened == false, "这台 Mac 上已经有自己的稿子，不再弹引导")
        #expect(harness.pageErrors == [])
    }

    @Test("内置说明书：两篇只读，改稿子的控件停用、离开后恢复；图文卡片说明书在每个主题下都按分页排、不溢出；演示素材载得出来")
    func guidesAreReadOnlyAndFitEveryTheme() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const guides = (await mc.drafts.list()).filter((draft) => draft.builtIn).map((draft) => [draft.title, draft.mode]);
            const cards = await mc.drafts.open("guide_cards");
            const locked = ["加粗", "标题", "长文", "查找替换"].map((name) => ui.find(name)).filter((control) => control && !control.disabled && control.getAttribute("aria-disabled") !== "true").map(ui.name);
            let rejected = "";
            try { await mc.drafts.update({ markdown: "改说明书" }); } catch (error) { rejected = error.message; }

            // 每个主题的卡片结构：页数就是 [[分页]] 分出的节数（没有放不下挤到下一张的），每一项都在正文区里
            const sections = cards.markdown.split("\\n").filter((line) => line.trim() === "[[分页]]").length + 1;
            const fits = {};
            for (const theme of await mc.themes.list()) {
              const { pages } = await mc.render.offscreen({ structure: theme.structure });
              const outside = pages.flatMap((page) => page.items.filter((item) => {
                const box = page.contentBounds;
                return item.x < box.left - 1 || item.x + item.width > box.right + 1 || item.y < box.top - 1 || item.y + item.height > box.bottom + 1;
              }));
              fits[theme.id] = pages.length === sections && outside.length === 0;
            }
            const items = (await mc.render.pages()).flatMap((page) => page.items);
            const media = await mc.media.list();
            const loaded = await Promise.all(media.map(async (info) => {
              const image = new Image();
              image.src = await mc.media.src(info.id);
              await image.decode();
              return image.naturalWidth > 0;
            }));
            const video = document.createElement("video");
            video.muted = true;
            video.src = "docs/guide-assets/sunset-live.mp4";
            await new Promise((resolve, reject) => { video.onloadedmetadata = resolve; video.onerror = reject; });

            const article = await mc.drafts.open("guide_article");
            await mc.render.pages();
            const stage = document.getElementById("stageCards");
            const wide = [...stage.querySelectorAll("*")].filter((element) => element.scrollWidth > element.clientWidth + 1 && getComputedStyle(element).overflowX !== "visible").length;

            await mc.drafts.create({ markdown: "自己的稿子" });
            const unlocked = ["加粗", "标题", "查找替换"].every((name) => !ui.find(name).disabled && ui.find(name).getAttribute("aria-disabled") !== "true");
            return {
              guides, readOnly: cards.readOnly && article.readOnly, locked, rejected, fits,
              live: items.filter((item) => item.kind === "image" && item.live).length,
              pairs: items.filter((item) => item.kind === "imagePair").length,
              loaded, video: [Math.round(video.duration), video.videoWidth, video.videoHeight], wide, unlocked,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["guides"] as? [[String]] == [["图文卡片说明书", "cards"], ["长文说明书", "article"]])
        #expect(result?["readOnly"] as? Bool == true)
        #expect(result?["locked"] as? [String] == [], "打开说明书时格式条、标题、排版模式、查找都停用")
        #expect((result?["rejected"] as? String ?? "").contains("说明书"))
        let fits = result?["fits"] as? [String: Bool] ?? [:]
        #expect(fits.count == ThemeTests.ids.count && fits.values.allSatisfy { $0 }, "每个主题都按分页排、不溢出：\(fits)")
        #expect(result?["live"] as? Int == 1, "有一张实况")
        #expect(result?["pairs"] as? Int == 1, "有一组拼图")
        #expect(result?["loaded"] as? [Bool] == [true, true, true], "演示图片都载得出来")
        #expect(result?["video"] as? [Int] == [4, 1280, 960], "实况视频：4 秒、1280 × 960")
        #expect(result?["wide"] as? Int == 0, "长文说明书没有横向溢出")
        #expect(result?["unlocked"] as? Bool == true, "回到自己的稿子，控件恢复")
        #expect(harness.pageErrors == [])
    }
}
