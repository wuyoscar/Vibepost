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

    @Test("内置说明书：三篇只读，改稿子的控件停用、离开后恢复；图文卡片说明书在每个主题下都按分页排、不溢出；演示素材载得出来")
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

            const styles = await mc.drafts.open("guide_styles");
            const article = await mc.drafts.open("guide_article");
            await mc.render.pages();
            const stage = document.getElementById("stageCards");
            const wide = [...stage.querySelectorAll("*")].filter((element) => element.scrollWidth > element.clientWidth + 1 && getComputedStyle(element).overflowX !== "visible").length;

            await mc.drafts.create({ markdown: "自己的稿子" });
            const unlocked = ["加粗", "标题", "查找替换"].every((name) => !ui.find(name).disabled && ui.find(name).getAttribute("aria-disabled") !== "true");
            return {
              guides, readOnly: cards.readOnly && styles.readOnly && article.readOnly, locked, rejected, fits,
              live: items.filter((item) => item.kind === "image" && item.live).length,
              pairs: items.filter((item) => item.kind === "imagePair").length,
              loaded, video: [Math.round(video.duration), video.videoWidth, video.videoHeight], wide, unlocked,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["guides"] as? [[String]] == [["图文卡片说明书", "cards"], ["样式与写法", "cards"], ["长文说明书", "article"]], "样式与写法排在图文卡片说明书后面")
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

    @Test("内置说明书「样式与写法」：照操作手册登记表写出，每种样式、组件、对齐、记号、行内格式与排版经验都在；组件与记号在卡片上排出来；默认主题按分页排、没有溢出与只有标题的页，每个主题都不出正文区")
    func stylesGuideFollowsTheManual() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const manual = window.MediaCraftManual;
            const guide = await mc.drafts.open("guide_styles");
            const text = guide.markdown;
            let rejected = "";
            try { await mc.drafts.update({ markdown: "改说明书" }); } catch (error) { rejected = error.message; }

            // 登记表里的每一项都写进来了：样式的名字、组件的开头一行、不是默认的对齐、记号的每种写法（放在行内代码里）、行内格式、排版经验
            const components = manual.styles.filter((style) => style.component);
            const note = manual.component("提示");
            const aligned = manual.aligns.filter((align) => align.id !== "left");
            const missing = [
              ...manual.styles.filter((style) => !text.includes(style.name)).map((style) => style.name),
              ...components.map((style) => manual.opener(style.name)).filter((line) => !text.includes(`\\n${line}\\n`)),
              ...aligned.map((align) => manual.opener(note.name, { align: align.id })).filter((line) => !text.includes(`\\n${line}\\n`)),
              ...manual.markers.flatMap((marker) => marker.syntax.split("　")).filter((syntax) => !text.includes(`\\`${syntax}\\``)),
              ...manual.inline.map(([syntax]) => syntax).filter((syntax) => !text.includes(syntax)),
              ...manual.lessons.filter((lesson) => !text.includes(lesson)),
            ];
            // 行内代码以外没有英文写法
            const english = /\\{\\{(?:color|bg|underline|mark)[:：]|\\[\\[image[:：]|^:::(?:kicker|note|footnote|mono|rows|steps)\\b/m.test(text.replace(/`[^`\\n]*`/g, ""));

            // 默认主题：页数就是 [[分页]] 分出的节数，每页的排版自检没有溢出、只有标题、偏挤
            const sections = text.split("\\n").filter((line) => line.trim() === "[[分页]]").length + 1;
            const pages = await mc.render.pages();
            const issues = pages.flatMap((page) => page.issues.filter((issue) => issue.id !== "sparse").map((issue) => `第 ${page.index + 1} 页 ${issue.id}`));
            const blocks = (await mc.render.canvases()).flatMap((canvas) => window.MediaCraftRender.pageOf(canvas).blocks);
            const rendered = [...new Set(blocks.filter((block) => block.kind === "component").map((block) => `${block.name}:${block.align}`))].sort();
            const runs = pages.flatMap((page) => page.items.filter((item) => item.kind === "text").flatMap((item) => item.runs));
            const mark = (word, key) => runs.find((piece) => piece.text === word && piece[key])?.[key] ?? null;

            // 每个主题的卡片结构：没有放不下的块，每一项都在正文区里
            const outside = {};
            for (const theme of await mc.themes.list()) {
              const { pages: themed } = await mc.render.offscreen({ structure: theme.structure });
              const count = themed.filter((page) => page.overflow || page.items.some((item) => {
                const box = page.contentBounds;
                return item.x < box.left - 1 || item.x + item.width > box.right + 1 || item.y < box.top - 1 || item.y + item.height > box.bottom + 1;
              })).length;
              if (count) outside[theme.id] = count;
            }
            return {
              readOnly: guide.readOnly, rejected, missing, english, sections, pages: pages.length, issues, rendered, outside,
              expected: [...components.map((style) => `${style.id}:left`), ...aligned.map((align) => `${note.id}:${align.id}`)].sort(),
              marks: [mark("字色", "color"), mark("实线", "underline"), mark("虚线", "underline")],
              highlighted: Boolean(mark("高亮", "bg")), bold: Boolean(mark("加粗", "bold")), strike: Boolean(mark("删除线", "strike")),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["readOnly"] as? Bool == true)
        #expect((result?["rejected"] as? String ?? "").contains("说明书"), "只读：改它被拒绝")
        #expect(result?["missing"] as? [String] == [], "登记表里的每一项都写进这篇")
        #expect(result?["english"] as? Bool == false, "只用中文的规范写法（行内代码里举例的英文写法除外）")
        let sections = result?["sections"] as? Int ?? 0
        #expect(sections >= 10, "一种写法一张卡片：\(sections) 张")
        #expect(result?["pages"] as? Int == sections, "默认主题按 [[分页]] 排，没有放不下挤到下一张的")
        #expect(result?["issues"] as? [String] == [], "没有溢出、只有标题、偏挤的页")
        #expect(result?["rendered"] as? [String] == result?["expected"] as? [String], "每个组件都排出来，提示框排了居中与靠右")
        #expect(result?["marks"] as? [String] == ["#d9480f", "solid", "dashed"], "字色、下划线排出来了")
        #expect(result?["highlighted"] as? Bool == true && result?["bold"] as? Bool == true && result?["strike"] as? Bool == true, "高亮、加粗、删除线排出来了")
        #expect(result?["outside"] as? [String: Int] == [:], "每个主题都没有出正文区的")
        #expect(harness.pageErrors == [])
    }
}
