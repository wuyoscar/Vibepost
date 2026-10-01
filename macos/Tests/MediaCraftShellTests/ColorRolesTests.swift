import Foundation
import Testing

/// 配色的五个颜色角色（v4/05）：叫法只有一种、定义只在一处；「辅助 / 衬底单独调过」用显式标记；
/// 出图的自动对比与配色的对比度保护是同一套（OKLCH 调明度）；公众号换白底时衬底对着白底重新推。
@MainActor
@Suite(.serialized)
struct ColorRolesTests {
    static let helpers = PaletteTests.helpers + """
        // 一块区域里离底色最远的像素（字形完全盖住的地方就是填充色）
        const farthest = async (item, against) => {
          const [canvas] = await mc.render.canvases();
          const { data } = canvas.getContext("2d").getImageData(item.x * 2, item.y * 2, Math.min(400, item.width * 2), item.height * 2);
          let best = against;
          for (let index = 0; index < data.length; index += 4) {
            const hex = `#${[data[index], data[index + 1], data[index + 2]].map((value) => value.toString(16).padStart(2, "0")).join("")}`;
            if (ratio(hex, against) > ratio(best, against)) best = hex;
          }
          return best;
        };
        const pixel = async (x, y) => {
          const [canvas] = await mc.render.canvases();
          const [r, g, b] = canvas.getContext("2d").getImageData(Math.round(x * 2), Math.round(y * 2), 1, 1).data;
          return `#${[r, g, b].map((value) => value.toString(16).padStart(2, "0")).join("")}`;
        };
    """

    @Test("五个角色只有一种叫法：检查器的色块、色轮面板、浮动条的色块与 AI 工具的说明都是 背景 / 文字 / 强调 / 辅助 / 衬底")
    func oneNamePerRole() async throws {
        let fake = try FakeClaude(script: [StreamJSON.initEvent(), StreamJSON.mcp("m1", method: "tools/list")] + [
            StreamJSON.textStart(), StreamJSON.textDelta("好"), StreamJSON.assistantText("好"), StreamJSON.result("好"),
        ])
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await mc.themes.apply("notes");
            const text = (element) => element.textContent.trim();
            const swatches = [...document.querySelectorAll(".color-roles .swatch-tile")];
            ui.expand("色轮");
            await until(() => document.querySelectorAll("[aria-label='五个角色'] .wheel-role-name").length === 5, "色轮面板");
            const wheel = [...document.querySelectorAll("[aria-label='五个角色'] .wheel-role-name")].map(text);
            ui.find("取消").click();
            await mc.ai.send("看看工具");
            return {
              swatches: swatches.map((tile) => text(tile.querySelector(".swatch-name"))),
              titles: swatches.map((tile) => tile.title),
              wheel,
            };
        """) as? [String: [String]]
        let tools = ((fake.response(0, "m1")?["response"] as? [String: Any])?["mcp_response"] as? [String: Any])?["result"] as? [String: Any]
        let setStyle = (tools?["tools"] as? [[String: Any]])?.first { $0["name"] as? String == "set_style" }?["description"] as? String ?? ""
        await harness.tearDown()

        let names = ["背景", "文字", "强调", "辅助", "衬底"]
        #expect(result?["swatches"] == names)
        #expect(result?["wheel"] == names)
        #expect(result?["titles"]?.first == "卡片与长文的底色" && result?["titles"]?[3] == "标题", "色块的说明：\(result?["titles"] ?? [])")
        for (role, name) in zip(["bg", "text", "accent", "secondary", "surface"], names) {
            #expect(setStyle.contains("\(role) \(name)："), "AI 工具的说明里 \(role) 叫「\(name)」：\(setStyle)")
        }
        #expect(!setStyle.contains("bg 底色") && !setStyle.contains("text 文字色") && !setStyle.contains("secondary 辅助色"), "没有另一套叫法")
        #expect(harness.pageErrors == [])
    }

    @Test("「单独调过」是显式标记：把辅助色单独设成和文字色一样，之后改文字色它也不跟着变；标记随稿子存、随 ⌘Z 撤回")
    func tunedRolesAreMarkedExplicitly() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let draftId = try await harness.evaluate(Self.helpers + """
            const { id } = await mc.drafts.create({ markdown: "# 标题\\n\\n正文" });
            await mc.drafts.update({ colors: { bg: "#ffffff", text: "#202938", accent: "#2563eb" } });
            await mc.drafts.update({ colors: { secondary: "#202938" } });
            return id;
        """) as? String ?? ""
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const opened = await mc.drafts.open(draftId);
            const kept = (await mc.drafts.update({ colors: { text: "#3a3a3a" } }));
            await mc.palettes.apply("japanese-01");
            const applied = (await mc.drafts.current()).tunedColors;
            await mc.drafts.undo();
            const undone = await mc.drafts.current();
            await mc.drafts.update({ tunedColors: [] });
            const followed = (await mc.drafts.update({ colors: { text: "#111111" } })).colors;
            return {
              opened: opened.tunedColors,
              kept: [kept.colors.secondary, kept.colors.surface, kept.tunedColors],
              applied, undone: [undone.colors.text, undone.colors.secondary, undone.tunedColors],
              followed: [followed.secondary, followed.surface],
              invalid: await mc.drafts.update({ tunedColors: ["accent"] }).then(() => "resolved", (error) => error.name),
            };
        """, arguments: ["draftId": draftId]) as? [String: Any]
        await harness.tearDown()

        #expect(result?["opened"] as? [String] == ["secondary"], "重新载入后标记还在")
        let kept = result?["kept"] as? [Any]
        #expect(kept?[0] as? String == "#202938", "单独调过的辅助色不跟着文字色走（值和三色规则的一样也不算没调过）")
        #expect(kept?[1] as? String == "#ebebeb", "衬底没调过，跟着新的文字色重新推")
        #expect(kept?[2] as? [String] == ["secondary"])
        #expect(result?["applied"] as? [String] == ["secondary", "surface"], "套一组配色：辅助、衬底都是那组给的")
        let undone = result?["undone"] as? [Any]
        #expect(undone?[0] as? String == "#3a3a3a" && undone?[1] as? String == "#202938", "⌘Z 回到套用之前的颜色")
        #expect(undone?[2] as? [String] == ["secondary"], "标记也一起回来")
        #expect(result?["followed"] as? [String] == ["#111111", "#e7e7e7"], "标记清掉后辅助、衬底按三色规则跟着文字色")
        #expect(result?["invalid"] as? String == "TypeError", "只能标辅助、衬底")
        #expect(harness.pageErrors == [])
    }

    @Test("对比度保护只有一套：出图时自动调的正文色，和配色的对比度保护调出来的是同一个颜色（OKLCH 只调明度）")
    func paintAndPaletteGuardAgree() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文正文正文正文正文正文" });
            await mc.themes.apply("notes");
            // 粘贴的色值做对比度保护：浅灰蓝的文字对白底不够 4.5:1，调暗
            const guarded = (await mc.palettes.apply(["#ffffff", "#8e9aa8", "#b8c3cf"])).colors;
            // 同样的颜色不经保护直接给：出图时自动调
            await mc.drafts.update({ colors: { bg: "#ffffff", text: "#8e9aa8", accent: "#2563eb" } });
            const [page] = await mc.render.pages();
            const line = page.items.find((item) => item.kind === "text");
            const painted = await farthest(line, "#ffffff");
            return { guarded: guarded.text, painted, ratio: ratio(painted, "#ffffff"), hueShift: Math.abs(hue(painted) - hue("#8e9aa8")) };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["painted"] as? String == result?["guarded"] as? String, "出图与配色保护调出同一个颜色")
        #expect((result?["ratio"] as? Double ?? 0) >= 4.5)
        #expect((result?["hueShift"] as? Double ?? 99) < 4, "色相不变，只调明度")
        #expect(harness.pageErrors == [])
    }

    @Test("公众号格式：浅色配色换成白底时，衬底对着白底重新推（引用块、表头的底不再是原来底色上的那个）")
    func wechatSurfaceOnWhite() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "> 引用\\n\\n正文", mode: "article" });
            await mc.themes.apply("journal");
            const quoteBackground = async () => {
              const { html } = await mc.output.copyArticle();
              return new DOMParser().parseFromString(html, "text/html").body.querySelector("blockquote").style.backgroundColor;
            };
            const derived = await quoteBackground();
            await mc.drafts.update({ colors: { surface: "#e0d6c6" } });
            const tuned = await quoteBackground();
            return { derived, tuned };
        """) as? [String: String]
        await harness.tearDown()

        // 手帐：文字 #2a2825、底色 #fbf9f3
        #expect(result?["derived"] == "rgb(234, 234, 233)", "文字色 10% 叠在白底上")
        #expect(result?["tuned"] == "rgb(228, 220, 210)", "调过的衬底保持与底色的差，挪到白底上")
        #expect(harness.pageErrors == [])
    }

    @Test("配色库的格子直接标出深 / 浅，现在用的这组是 aria-current；格子、色轮把手接进共用的按压手感")
    func paletteTilesShowToneAndPress() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await mc.palettes.apply("film-06");
            await openLibrary();
            const list = await mc.palettes.list();
            const shownTiles = tiles();
            const tones = shownTiles.map((tile) => [tile.querySelector(".palette-tone").textContent, list.find((palette) => palette.id === tile.dataset.paletteId).tone]);
            const current = shownTiles.filter((tile) => tile.getAttribute("aria-current") === "true").map((tile) => tile.dataset.paletteId);
            const tile = shownTiles[0];
            // 窗口看不见时（data-motion="paused"）过渡都关掉了：按窗口看得见时的样子查
            document.documentElement.dataset.motion = "full";
            return {
              tonesMatch: tones.every(([badge, tone]) => badge === (tone === "dark" ? "深" : "浅")),
              visible: getComputedStyle(tile.querySelector(".palette-tone")).display !== "none",
              current,
              pressed: shownTiles.some((item) => item.hasAttribute("aria-pressed")),
              tileTransition: getComputedStyle(tile).transitionProperty,
              described: document.getElementById(tile.getAttribute("aria-describedby"))?.textContent,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["tonesMatch"] as? Bool == true, "每一格标的深浅和配色一致")
        #expect(result?["visible"] as? Bool == true, "不只在悬停提示里")
        #expect(result?["current"] as? [String] == ["film-06"])
        #expect(result?["pressed"] as? Bool == false, "套用不是开关，不用 aria-pressed")
        let transition = result?["tileTransition"] as? String ?? ""
        #expect(transition.contains("transform"), "按下缩一点、松开回弹")
        #expect(["深", "浅"].contains(result?["described"] as? String ?? ""), "深浅也读得出来")
        #expect(harness.pageErrors == [])
    }

    @Test("色轮：第一次打开不卡主线程（底图分块画）；把手是滑杆（读出色相与浓淡），拖动时用 translate 摆、光标变成抓着；读屏只在松手时说一次")
    func wheelIsSmoothAndAccessible() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# 标题\\n\\n正文" });
            await mc.themes.apply("notes");
            // 打开色轮的同时量主线程最长被占了多久：一直排着下一个任务（消息通道，窗口在后台也不节流），看两次之间隔了多久
            let longest = 0;
            let last = performance.now();
            let probing = true;
            const channel = new MessageChannel();
            channel.port1.onmessage = () => {
              const now = performance.now();
              longest = Math.max(longest, now - last);
              last = now;
              if (probing) channel.port2.postMessage(null);
            };
            channel.port2.postMessage(null);
            ui.expand("色轮");
            const canvas = document.querySelector(".wheel-canvas");
            await until(() => canvas.classList.contains("is-ready"), "色轮底图画好");
            probing = false;
            const base = ui.find("基准色");
            const stage = base.parentElement;
            const box = stage.getBoundingClientRect();
            const note = document.querySelector(".wheel-note");
            let announcements = 0;
            new MutationObserver((records) => { announcements += records.length; }).observe(note, { childList: true, characterData: true, subtree: true });
            const fire = (target, type, x, y) => target.dispatchEvent(new PointerEvent(type, {
              pointerId: 1, pointerType: "mouse", isPrimary: true, button: 0, buttons: type === "pointerup" ? 0 : 1,
              clientX: box.left + x, clientY: box.top + y, bubbles: true, cancelable: true,
            }));
            fire(base, "pointerdown", 100, 20);
            const cursor = getComputedStyle(base).cursor;
            // 一路拖过几个地方（每一处都重新推一组配色）
            for (const [x, y] of [[100, 60], [100, 95], [100, 99], [30, 100], [100, 180], [170, 100]]) {
              fire(stage, "pointermove", x, y);
              await wait(0);
            }
            const duringDrag = announcements;
            fire(stage, "pointerup", 170, 100);
            await wait(0);
            const afterRelease = announcements - duringDrag;
            return {
              longest, cursor, duringDrag, afterRelease,
              role: base.getAttribute("role"), valuetext: base.getAttribute("aria-valuetext"),
              valuenow: base.getAttribute("aria-valuenow"),
              left: base.style.left, translate: base.style.translate,
              released: getComputedStyle(base).cursor,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect((result?["longest"] as? Double ?? 999) < 40, "主线程最长只被占了这么久（毫秒）：\(result?["longest"] ?? "")")
        #expect(result?["role"] as? String == "slider")
        let valuetext = result?["valuetext"] as? String ?? ""
        #expect(valuetext.hasPrefix("色相 0°，浓淡 "), "\(valuetext)")
        #expect(result?["valuenow"] as? String == "0")
        #expect(result?["left"] as? String == "", "不改 left / top")
        let translate = result?["translate"] as? String ?? ""
        #expect(translate.hasSuffix("px"), "用 translate 摆：\(translate)")
        #expect(result?["cursor"] as? String == "grabbing", "拖动时光标是抓着的")
        #expect(result?["released"] as? String == "grab")
        #expect(result?["duringDrag"] as? Int == 0, "拖动途中不播报")
        #expect(result?["afterRelease"] as? Int == 1, "松手时播报一次")
        #expect(harness.pageErrors == [])
    }
}
