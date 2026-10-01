import Foundation
import Testing

/// 动效（docs/design/motion.md）：窗口看不见时不播；减少动态效果时不位移、只留透明度；
/// 状态从不等动画（抽屉、对话框、标签、菜单、手机预览）；拖到吸附点时触控板震一下。
/// harness 的窗口在屏幕外，WebKit 停住了动画时间线：打开动效（data-motion="full"）后动画都停在第一帧，正好是最坏的情况。
@MainActor
struct MotionTests {
    static let helpers = """
        window.mc = window.mediacraft;
        window.root = document.documentElement;
        // 元素（或它的 ::before / ::after）上声明的过渡：[属性, 时长（秒）]
        window.transitions = (element, pseudo = null) => {
          const style = getComputedStyle(element, pseudo);
          const durations = style.transitionDuration.split(",").map((value) => parseFloat(value));
          return style.transitionProperty.split(",").map((property, index) => [property.trim(), durations[index % durations.length]]);
        };
        // 会动起来的（时长不是 0、也不只是透明度）
        window.moving = (element, pseudo = null) => transitions(element, pseudo).filter(([property, duration]) => duration > 0 && property !== "opacity");
        window.animated = (element, pseudo = null) => getComputedStyle(element, pseudo).animationName !== "none";
        // 抽查的一组：按钮、分段控件与滑块、胶片与当前页的框、主题格、对话框、浮层、检查器、抽屉、手机预览、进度卡
        window.samples = () => [
          ...[
            ".pill-button", ".icon-button", ".primary-button", "#layoutModeSwitch > button", ".film-thumb", ".theme-option",
            ".draft-row", ".modal", ".modal > .dialog", ".inspector-panel", ".pop-menu-panel", ".floating-bar",
            ".activity", ".phone-stage", ".phone-fit", ".drawer", ".drawer > *", ".find-bar", ".ai-permission",
          ].map((selector) => [selector, document.querySelector(selector), null]),
          ["#layoutModeSwitch::after", document.querySelector("#layoutModeSwitch"), "::after"],
          ["#filmstrip::after", document.querySelector("#filmstrip"), "::after"],
          ["#themeOptions::before", document.querySelector("#themeOptions"), "::before"],
        ];
    """

    static let twoPages = "# 第一张\n\n正文一段。\n\n[[分页]]\n\n## 第二张\n\n正文两段。"

    @Test("窗口看不见时动效暂停；减少动态效果时不位移，只留透明度的淡入淡出")
    func reducedMotionAndPaused() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: md });
            ui.expand("稿件列表");
            await new Promise((resolve) => setTimeout(resolve, 600));
            const missing = samples().filter(([, element]) => !element).map(([name]) => name);
            const paused = root.dataset.motion;
            const pausedMoving = samples().filter(([, element, pseudo]) => element && transitions(element, pseudo).some(([, duration]) => duration > 0)).map(([name]) => name);
            root.dataset.motion = "full";
            const fullMoving = samples().filter(([, element, pseudo]) => element && moving(element, pseudo).length).map(([name]) => name);
            root.dataset.motion = "reduced";
            const reducedMoving = samples().filter(([, element, pseudo]) => element && moving(element, pseudo).length).map(([name]) => name);
            const reducedAnimated = samples().filter(([, element, pseudo]) => element && animated(element, pseudo)).map(([name]) => name);
            const modalFades = transitions(document.querySelector(".modal")).some(([property, duration]) => property === "opacity" && duration > 0);
            // 脚本动画（翻页、换排版）也只剩透明度
            ui.click("下一张");
            ui.click("长文");
            await new Promise((resolve) => setTimeout(resolve, 600));
            const scripted = document.getAnimations().filter((animation) => !(animation instanceof CSSTransition) && !(animation instanceof CSSAnimation));
            const scriptedMoving = scripted.filter((animation) => animation.effect.getKeyframes().some((frame) => frame.transform || frame.translate || frame.scale)).length;
            return { missing, paused, pausedMoving, fullMoving, reducedMoving, reducedAnimated, modalFades, scripted: scripted.length, scriptedMoving };
        """, arguments: ["md": Self.twoPages]) as? [String: Any]
        await harness.tearDown()

        #expect(result?["missing"] as? [String] == [], "抽查的元素都在页面上")
        #expect(result?["paused"] as? String == "paused", "harness 的窗口看不见")
        #expect(result?["pausedMoving"] as? [String] == [], "看不见时没有任何过渡")
        let fullMoving = Set(result?["fullMoving"] as? [String] ?? [])
        for name in [".pill-button", "#layoutModeSwitch::after", "#filmstrip::after", "#themeOptions::before", ".modal > .dialog", ".inspector-panel", ".phone-fit"] {
            #expect(fullMoving.contains(name), "动效打开时 \(name) 会动（抽查不是空的）")
        }
        #expect(result?["reducedMoving"] as? [String] == [], "减少动态效果时只剩透明度的过渡")
        #expect(result?["reducedAnimated"] as? [String] == [], "减少动态效果时没有关键帧动画")
        #expect(result?["modalFades"] as? Bool == true, "对话框仍然淡入淡出")
        #expect((result?["scripted"] as? Int ?? 0) > 0, "翻页、换排版仍有淡入")
        #expect(result?["scriptedMoving"] as? Int == 0, "脚本动画里没有位移")
        #expect(harness.pageErrors == [])
    }

    @Test("动效开着也不等动画：抽屉、对话框、标签、菜单、手机预览的状态当下就变，退场中的对话框不接鼠标")
    func stateIsSynchronous() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "动效", markdown: md });
            await new Promise((resolve) => setTimeout(resolve, 600));
            root.dataset.motion = "full";
            const shown = (element) => element.getClientRects().length > 0;
            const out = {};

            const toggle = ui.find("稿件列表");
            const drawer = document.querySelector('[aria-label="稿件"]');
            toggle.click();
            out.drawerOpen = [toggle.getAttribute("aria-expanded"), shown(drawer)];
            toggle.click();
            out.drawerClosed = [toggle.getAttribute("aria-expanded"), shown(drawer)];

            toggle.click();
            await new Promise((resolve) => setTimeout(resolve, 100));
            ui.click("删除 动效");
            const modal = ui.alert();
            out.dialogOpen = [Boolean(modal), modal && ui.name(document.activeElement)];
            ui.click("取消", { within: modal });
            const box = modal.querySelector(".dialog").getBoundingClientRect();
            const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
            out.dialogClosed = [modal.classList.contains("hidden"), getComputedStyle(modal).pointerEvents, modal.contains(hit), modal.contains(document.activeElement)];
            toggle.click();

            ui.click("AI 助手");
            out.tab = [
              document.getElementById("aiTab").getAttribute("aria-selected"),
              document.getElementById("aiPanel").hidden,
              document.getElementById("stylePanel").hidden,
              ui.find("AI").getAttribute("aria-pressed"),
            ];
            ui.click("样式");

            const summary = ui.expand("插入");
            const menu = summary.parentElement;
            out.menuOpen = [menu.open, getComputedStyle(menu.querySelector(".pop-menu-panel")).pointerEvents];
            menu.querySelector(".menu-item").focus();
            document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
            out.menuClosed = [menu.open, document.activeElement === summary];

            const phone = ui.find("手机预览");
            const stage = document.getElementById("phonePreview");
            phone.click();
            out.phoneOpen = [phone.getAttribute("aria-pressed"), stage.hidden];
            phone.click();
            out.phoneClosed = [phone.getAttribute("aria-pressed"), stage.hidden, getComputedStyle(stage).pointerEvents];
            return out;
        """, arguments: ["md": Self.twoPages]) as? [String: [Any]]
        await harness.tearDown()

        #expect(result?["drawerOpen"]?[0] as? String == "true")
        #expect(result?["drawerOpen"]?[1] as? Bool == true, "抽屉打开当下就在")
        #expect(result?["drawerClosed"]?[0] as? String == "false")
        #expect(result?["drawerClosed"]?[1] as? Bool == false, "抽屉收起当下就让出位置")
        #expect(result?["dialogOpen"]?[0] as? Bool == true, "确认框当下就出来")
        #expect(result?["dialogOpen"]?[1] as? String == "取消", "焦点当下就在「取消」上")
        #expect(result?["dialogClosed"]?[0] as? Bool == true, "点「取消」当下就关上")
        #expect(result?["dialogClosed"]?[1] as? String == "none", "退场中的对话框不接鼠标")
        #expect(result?["dialogClosed"]?[2] as? Bool == false, "点在退场中的对话框上，点到的是底下的界面")
        #expect(result?["dialogClosed"]?[3] as? Bool == false, "焦点已经离开对话框")
        #expect(result?["tab"]?[0] as? String == "true")
        #expect(result?["tab"]?[1] as? Bool == false, "AI 助手当下就显示")
        #expect(result?["tab"]?[2] as? Bool == true, "样式当下就藏起")
        #expect(result?["tab"]?[3] as? String == "true", "顶栏的 AI 按钮当下就按下")
        #expect(result?["menuOpen"]?[0] as? Bool == true)
        #expect(result?["menuOpen"]?[1] as? String == "auto", "展开的菜单马上能点")
        #expect(result?["menuClosed"]?[0] as? Bool == false, "Esc 当下就收起菜单")
        #expect(result?["menuClosed"]?[1] as? Bool == true, "焦点当下就回到菜单按钮")
        #expect(result?["phoneOpen"]?[0] as? String == "true")
        #expect(result?["phoneOpen"]?[1] as? Bool == false, "手机预览当下就打开")
        #expect(result?["phoneClosed"]?[1] as? Bool == true, "手机预览当下就关上")
        #expect(result?["phoneClosed"]?[2] as? String == "none", "退场中的手机预览不接鼠标")
        #expect(harness.pageErrors == [])
    }

    @Test("把编辑区宽度拖到默认宽度附近会吸住，触控板轻轻一震；已经在默认宽度上不再震")
    func panelSnapHaptic() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let widths = try await harness.evaluate(Self.helpers + """
            const handle = () => document.querySelector('[role="separator"][aria-label="编辑区宽度"]');
            const value = () => Number(handle().getAttribute("aria-valuenow"));
            const drag = (dx) => {
              const box = handle().getBoundingClientRect();
              const x = box.left + box.width / 2;
              const pointer = (type, clientX, target) => target.dispatchEvent(new PointerEvent(type, { clientX, clientY: 300, bubbles: true, pointerId: 1, button: 0 }));
              pointer("pointerdown", x, handle());
              pointer("pointermove", x + dx / 2, window);
              pointer("pointermove", x + dx, window);
              pointer("pointerup", x + dx, window);
              return value();
            };
            return [drag(-60), drag(57), drag(3), drag(30), drag(-28)];
        """) as? [Int]
        let deadline = ContinuousClock.now + .seconds(5)
        while harness.haptics.patterns.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300)) // 多出来的一下也等它到
        await harness.tearDown()

        #expect(widths == [440, 500, 500, 530, 500], "497 与 502 吸到默认的 500，503 留在 500")
        #expect(harness.haptics.patterns == [.alignment, .alignment], "每吸住一次震一下，本来就在默认宽度上不震")
        #expect(harness.pageErrors == [])
    }

    /// 触感是经脚本消息异步到壳的：等到有 count 下（多出来的一下也等它到）
    private static func settleHaptics(_ harness: ShellHarness, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while harness.haptics.patterns.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test("裁剪自由比例下拖角：比例到 4:3 附近吸住时震一下，没吸住的地方不震")
    func cropSnapHaptic() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let widths = try await harness.evaluate(ImageEditingTests.helpers + """
            await mc.drafts.create({ markdown: "开头" });
            await mc.media.import([await pngFile("宽.png", 200, 100, ["#e03131", "#1971c2"])], { at: 2 });
            await mc.render.pages();
            ui.click("编辑图片 宽.png", { within: document.querySelector('[role="textbox"][aria-label="正文"]') });
            for (let tries = 0; tries < 50 && !dialog("裁剪 宽.png"); tries += 1) await settle(40);
            const crop = dialog("裁剪 宽.png");
            const frame = crop.querySelector('[aria-label^="裁剪框"]');
            const corner = frame.querySelector('[data-crop-handle="se"]');
            const box = frame.getBoundingClientRect();
            const perPixel = 200 / box.width; // 选框是整张图（200 像素宽）
            const [x, y] = [box.right - 1, box.bottom - 1];
            const widthAt = (target) => x - (200 - target) / perPixel;
            pointer("pointerdown", corner, x, y);
            pointer("pointermove", frame, widthAt(160), y); // 1.6：离哪个比例都远
            pointer("pointermove", frame, widthAt(150), y); // 1.5
            pointer("pointermove", frame, widthAt(134), y); // 1.34：吸到 4:3
            pointer("pointermove", frame, widthAt(133.6), y); // 还在 4:3 上，不再震
            pointer("pointerup", frame, widthAt(133.6), y);
            const size = document.getElementById("cropSize").textContent;
            ui.click("取消", { within: crop });
            return size;
        """) as? String
        try await Self.settleHaptics(harness, count: 1)
        await harness.tearDown()

        #expect(widths?.hasPrefix("13") == true, "吸成 4:3 的宽：\(widths ?? "")")
        #expect(harness.haptics.patterns == [.alignment], "吸住的那一下震一次")
        #expect(harness.pageErrors == [])
    }

    @Test("拼图拖下边改比例：每吸到下一档比例震一下（level-change），同一档里不震")
    func pairRatioHaptic() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let steps = try await harness.evaluate(ImageEditingTests.helpers + """
            await mc.drafts.create({ markdown: "开头" });
            const [red, blue] = await mc.media.import([await pngFile("红.png", 60, 60, ["#e03131"]), await pngFile("蓝.png", 60, 60, ["#1971c2"])]);
            await mc.drafts.update({ markdown: `开头\\n[[image:${red}|${blue}]]\\n结尾` });
            await settle(200);
            ui.click("调整拼图 红.png + 蓝.png", { within: document.querySelector('[role="textbox"][aria-label="正文"]') });
            for (let tries = 0; tries < 50 && !dialog("左右对调"); tries += 1) await settle(40);
            const pair = dialog("左右对调");
            const handle = ui.find("拖动改变拼图比例", { within: pair }) ?? pair.querySelector('[role="slider"]');
            const [x, y] = middle(handle);
            const seen = [handle.getAttribute("aria-valuetext")];
            pointer("pointerdown", handle, x, y);
            for (let dy = 4; dy <= 400; dy += 4) {
              pointer("pointermove", handle, x, y + dy);
              const now = handle.getAttribute("aria-valuetext");
              if (now !== seen.at(-1)) seen.push(now);
            }
            pointer("pointerup", handle, x, y + 400);
            ui.click("取消", { within: pair });
            return seen;
        """) as? [String] ?? []
        try await Self.settleHaptics(harness, count: max(0, steps.count - 1))
        await harness.tearDown()

        #expect(steps.count >= 3, "一路拖过好几档：\(steps)")
        #expect(harness.haptics.patterns == Array(repeating: .levelChange, count: max(0, steps.count - 1)), "每换一档震一下：\(harness.haptics.patterns)")
        #expect(harness.pageErrors == [])
    }

    @Test("预览里把一张图拖到另一张图上（松手就拼成一组）的那一下震一次")
    func dropOntoImageHaptic() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let paired = try await harness.evaluate(ImageEditingTests.helpers + """
            await mc.drafts.create({ markdown: "第一段" });
            const ids = await mc.media.import([await pngFile("甲.png", 80, 60), await pngFile("乙.png", 80, 60, ["#1971c2"])], { at: "第一段".length });
            for (const id of ids) await mc.media.update(id, { layout: { widthPercent: 30, align: "center" } });
            await mc.render.pages();
            await settle(100);
            const target = box("选择图片 乙.png");
            const rect = target.getBoundingClientRect();
            await dragTo(box("选择图片 甲.png"), middle(box("选择图片 甲.png")), [rect.left + rect.width * 0.35, rect.top + rect.height / 2]);
            await mc.render.pages();
            return (await mc.drafts.current()).markdown.includes("|");
        """) as? Bool
        try await Self.settleHaptics(harness, count: 1)
        await harness.tearDown()

        #expect(paired == true, "拼成了一组")
        #expect(harness.haptics.patterns == [.alignment], "拖到另一张图上震一下")
        #expect(harness.pageErrors == [])
    }
}
