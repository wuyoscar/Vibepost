import Foundation
import Testing

/// 手机预览：顶栏「手机预览」把舞台换成 iPhone 外框里的信息流帖子（作者、卡片轮播、标题、正文栏里的正文、标签），
/// 不用任何平台的标识；翻页用点按、键盘或横扫；和当前主题、内容实时一致。
@MainActor
struct PhonePreviewTests {
    static let helpers = ThemePanelTests.pause + """
        const mc = window.mediacraft;
        window.phone = () => document.querySelector('[aria-label="手机预览"][role="region"]');
        window.post = () => [...phone().querySelectorAll('[aria-label="帖子"] p')].filter(shown).map((p) => p.textContent);
        window.shown = (element) => Boolean(element) && element.getClientRects().length > 0 && getComputedStyle(element).visibility !== "hidden";
        window.carousel = () => phone().querySelector('[aria-roledescription="轮播"]');
        window.counter = () => carousel().querySelector("[aria-live]").textContent;
        // 轮播下面那一排页码圆点
        window.dots = () => [...carousel().nextElementSibling.children];
        window.slides = () => [...carousel().querySelectorAll('[role="img"]')];
        window.currentSlide = () => slides().find((slide) => slide.getAttribute("aria-hidden") === "false");
        window.pixel = (canvas, x, y) => [...canvas.getContext("2d").getImageData(Math.round(x * canvas.width), Math.round(y * canvas.height), 1, 1).data.slice(0, 3)];
        // 轮播里这一张与预览里同一页缩小后的差别（平均每个通道）
        window.slideDiff = (slide, source) => {
          const canvas = document.createElement("canvas");
          canvas.width = slide.width;
          canvas.height = slide.height;
          const context = canvas.getContext("2d");
          context.imageSmoothingQuality = "high";
          context.drawImage(source, 0, 0, canvas.width, canvas.height);
          const a = context.getImageData(0, 0, canvas.width, canvas.height).data;
          const b = slide.getContext("2d").getImageData(0, 0, slide.width, slide.height).data;
          let sum = 0;
          for (let index = 0; index < a.length; index += 1) sum += Math.abs(a[index] - b[index]);
          return sum / a.length;
        };
        // 等手机预览跟上最新一次出图：张数对上，当前这张就是预览里的那一页
        window.phoneSynced = async () => {
          const pages = await mc.render.pages();
          const canvases = await mc.render.canvases();
          const start = performance.now();
          const synced = () => {
            if (slides().length !== pages.length || !currentSlide()) return false;
            return slideDiff(currentSlide(), canvases[slides().indexOf(currentSlide())]) < 1;
          };
          while (!synced()) {
            if (performance.now() - start > 10000) throw new Error("手机预览没有跟上出图");
            await pause(50);
          }
          return pages.length;
        };
        window.longText = (count) => Array.from({ length: count }, (_, index) =>
          `第 ${index + 1} 段：写得足够长，才能把内容推到后面的页面，看看手机上左右翻页是不是顺手。`).join("\\n\\n");
    """

    @Test("顶栏「手机预览」开合（aria-pressed）：外框里有作者、卡片轮播、页码、标题、正文（正文栏里的，不是卡片上的字）与标签；没有平台标识与假状态栏")
    func togglesAndShowsThePost() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "春日书单", markdown: "# 春日书单\\n\\n" + longText(14) + "\\n\\n#卡片上的话题", caption: "这个春天读完的五本书。\\n读完记得写一句感想 #读书 #春天。 #书单" });
            const button = ui.find("手机预览");
            const before = { pressed: button.getAttribute("aria-pressed"), shown: shown(phone()) };
            button.click();
            const total = await phoneSynced();
            const canvases = await mc.render.canvases();
            const text = phone().textContent.replace(/\\s+/g, " ");
            const opened = {
              pressed: button.getAttribute("aria-pressed"),
              shown: shown(phone()),
              stageNav: shown(document.querySelector('[aria-label="预览"]').querySelector('[aria-label="全部卡片"]')),
              author: text.includes((await mc.profile.get()).name),
              total,
              slides: slides().length,
              counter: counter(),
              dots: dots().length,
              firstDiff: slideDiff(currentSlide(), canvases[0]),
              flips: ["上一张", "下一张"].map((name) => ui.find(name, { within: phone() }) !== null),
              body: post(),
              clock: /\\d{1,2}:\\d{2}/.test(text),
              brand: /小红书|RED|Instagram|抖音|微博/i.test(text),
            };
            button.click();
            const closed = { pressed: button.getAttribute("aria-pressed"), shown: shown(phone()), stage: ui.find("上一张") !== null };
            return { before, opened, closed };
        """) as? [String: Any]
        await harness.tearDown()

        #expect((result?["before"] as? [String: Any])?["pressed"] as? String == "false")
        #expect((result?["before"] as? [String: Any])?["shown"] as? Bool == false)
        let opened = result?["opened"] as? [String: Any] ?? [:]
        #expect(opened["pressed"] as? String == "true")
        #expect(opened["shown"] as? Bool == true)
        #expect(opened["stageNav"] as? Bool == false, "手机预览盖住大卡片与胶片")
        #expect(opened["author"] as? Bool == true, "作者一行写着署名")
        let total = opened["total"] as? Int ?? 0
        #expect(total >= 3, "稿子要排好几页")
        #expect(opened["slides"] as? Int == total)
        #expect(opened["counter"] as? String == "1/\(total)")
        #expect(opened["dots"] as? Int == total, "每页一个圆点")
        #expect((opened["firstDiff"] as? Double ?? 99) < 1, "轮播里是预览里的卡片")
        #expect(opened["flips"] as? [Bool] == [true, true], "卡片左右两侧可以点")
        let body = opened["body"] as? [String] ?? []
        #expect(body.first == "春日书单", "标题来自标题栏：\(body)")
        #expect(body.contains("这个春天读完的五本书。\n读完记得写一句感想"), "正文是正文栏里的那段，去掉标签：\(body)")
        #expect(!body.contains { $0.contains("第 1 段") }, "卡片上的字不进正文：\(body)")
        #expect(body.contains("#读书 #春天 #书单"), "标签从正文栏里的 #标签 挑出来：\(body)")
        #expect(opened["clock"] as? Bool == false, "没有假状态栏的时间")
        #expect(opened["brand"] as? Bool == false, "不用任何平台的标识")
        let closed = result?["closed"] as? [String: Any] ?? [:]
        #expect(closed["pressed"] as? String == "false")
        #expect(closed["shown"] as? Bool == false)
        #expect(closed["stage"] as? Bool == true, "关掉后回到大卡片")
        #expect(harness.pageErrors == [])
    }

    @Test("翻页：点卡片左右两侧、← → 键、触控板横扫、按住拖动；页码与圆点跟着走，两头停住；键盘不再翻底下的大卡片")
    func flipsWithClicksKeysAndSwipes() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# 翻页\\n\\n" + longText(14) });
            ui.click("手机预览");
            const total = await phoneSynced();
            const steps = [];
            const record = (label) => steps.push(`${label} ${counter()} ${currentSlide() === slides()[Number(counter().split("/")[0]) - 1]}`);
            const stageLabel = () => document.querySelector('[aria-label="预览"] [aria-live]').textContent;
            const prevDisabledAtStart = ui.find("上一张", { within: phone() }).disabled;
            ui.click("下一张", { within: phone() });
            record("点右侧");
            ui.click("下一张", { within: phone() });
            record("再点右侧");
            ui.click("上一张", { within: phone() });
            record("点左侧");
            const key = (name) => carousel().dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
            carousel().focus();
            const stageBefore = stageLabel();
            key("ArrowRight");
            record("→");
            key("ArrowLeft");
            key("ArrowLeft");
            record("← ←");
            const stageAfter = stageLabel();
            const wheel = (deltaX) => carousel().dispatchEvent(new WheelEvent("wheel", { deltaX, deltaY: 0, bubbles: true, cancelable: true }));
            wheel(30);
            wheel(30);
            wheel(30);
            record("横扫一次");
            await pause(400);
            wheel(-60);
            record("往回横扫");
            await pause(400);
            const box = carousel().getBoundingClientRect();
            const pointer = (type, x) => (type === "pointerdown" ? carousel() : window).dispatchEvent(
              new PointerEvent(type, { pointerId: 7, clientX: x, clientY: box.top + box.height / 2, button: 0, bubbles: true }));
            const flipButton = ui.find("下一张", { within: phone() });
            pointer("pointerdown", box.right - 20);
            pointer("pointermove", box.right - 60);
            pointer("pointermove", box.right - 120);
            pointer("pointerup", box.right - 120);
            flipButton.click(); // 松手时浏览器跟着发的那一下点按，不再多翻一页
            record("向左拖");
            for (let index = 0; index < total + 2; index += 1) ui.click("下一张", { within: phone() });
            record("翻到最后");
            const nextDisabledAtEnd = ui.find("下一张", { within: phone() }).disabled;
            const colors = dots().map((dot) => getComputedStyle(dot).backgroundColor);
            return { total, steps, prevDisabledAtStart, nextDisabledAtEnd, stageBefore, stageAfter, currentDot: colors.at(-1), otherDot: colors[0] };
        """) as? [String: Any]
        await harness.tearDown()

        let total = result?["total"] as? Int ?? 0
        #expect(total >= 3)
        #expect(result?["steps"] as? [String] == [
            "点右侧 2/\(total) true", "再点右侧 3/\(total) true", "点左侧 2/\(total) true",
            "→ 3/\(total) true", "← ← 1/\(total) true",
            "横扫一次 2/\(total) true", "往回横扫 1/\(total) true",
            "向左拖 2/\(total) true", "翻到最后 \(total)/\(total) true",
        ])
        #expect(result?["prevDisabledAtStart"] as? Bool == true, "第一张不能再往前")
        #expect(result?["nextDisabledAtEnd"] as? Bool == true, "最后一张不能再往后")
        #expect(result?["stageBefore"] as? String == result?["stageAfter"] as? String, "键盘只翻手机里的卡片")
        #expect(result?["currentDot"] as? String != result?["otherDot"] as? String, "当前页的圆点不一样")
        #expect(harness.pageErrors == [])
    }

    @Test("和当前主题、内容实时一致：换主题、改标题与正文后跟着变；长文模式没有卡片，手机预览关掉、按钮停用")
    func staysInSyncWithThemeAndContent() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "第一版", markdown: "# 第一版\\n\\n" + longText(14) });
            ui.click("手机预览");
            await phoneSynced();
            ui.click("下一张", { within: phone() });
            const whiteCorner = pixel(currentSlide(), 0.01, 0.01);

            await mc.themes.apply("ink");
            await phoneSynced();
            const canvases = await mc.render.canvases();
            const night = { corner: pixel(currentSlide(), 0.01, 0.01), counter: counter(), diff: slideDiff(currentSlide(), canvases[1]) };

            await mc.drafts.update({ title: "第二版", markdown: "# 第二版\\n\\n短短一段", caption: "改过的正文 #改过了" });
            const total = await phoneSynced();
            for (let tries = 0; tries < 100 && !post().includes("改过的正文"); tries += 1) await pause(50);
            const edited = { total, counter: counter(), texts: post() };

            await mc.drafts.update({ mode: "article" });
            const button = ui.find("手机预览");
            const article = { pressed: button.getAttribute("aria-pressed"), disabled: button.disabled, shown: shown(phone()) };
            await mc.drafts.update({ mode: "cards" });
            return { whiteCorner, night, edited, article, backToCards: ui.find("手机预览").disabled };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["whiteCorner"] as? [Int] == [255, 255, 255])
        let night = result?["night"] as? [String: Any] ?? [:]
        #expect(night["corner"] as? [Int] == [12, 12, 12], "换成纯黑后轮播里跟着变")
        #expect((night["counter"] as? String)?.hasPrefix("2/") == true, "换主题不跳回第一张")
        #expect((night["diff"] as? Double ?? 99) < 1, "轮播里是换主题后的卡片")
        let edited = result?["edited"] as? [String: Any] ?? [:]
        #expect(edited["total"] as? Int == 1)
        #expect(edited["counter"] as? String == "1/1", "页数变少时停在最后一张")
        #expect(edited["texts"] as? [String] == ["第二版", "改过的正文", "#改过了", "刚刚"], "\(edited["texts"] ?? [])")
        let article = result?["article"] as? [String: Any] ?? [:]
        #expect(article["pressed"] as? String == "false")
        #expect(article["disabled"] as? Bool == true)
        #expect(article["shown"] as? Bool == false)
        #expect(result?["backToCards"] as? Bool == false)
        #expect(harness.pageErrors == [])
    }
}
