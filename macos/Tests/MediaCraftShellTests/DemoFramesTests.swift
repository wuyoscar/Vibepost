import AppKit
import Foundation
import MediaCraftMCP
import Testing
import WebKit
@testable import MediaCraftShell

/// README 的动图和教程视频的素材（不是断言）。设了 `DEMO_FRAMES_DIR=目录` 和 `DEMO_PART=段名` 时，在真实的页面里把那一段走一遍，
/// 每一步存一帧 `<目录>/<段名>/<序号>.png`，另存一份时间线 `timeline.json`（每帧停多久、属于哪一节、字幕、镜头对着哪几栏、
/// 指针要去的位置、这一帧末尾点不点、等 AI 的那些帧快进几倍）。`scripts/make-demo.py` 照时间线合成动图与视频。没设时跳过。
///
/// 段：`basics`（写、排、封面、检查、手机预览、发送；不用 AI）；其余几段用**本机真的 Claude Code**
/// （`DEMO_AGENT_BIN=claude 所在的目录`，用的是这台机器的登录与额度，回复每次不一样）：
/// `polish`（写好的长文一键润色、一键排版）、`paste`（把一篇长文贴进对话框，排成图文）、`topic`（找最近的热点写成一篇）、
/// `tune`（排好的稿子自己换主题、换尺寸、拖字号；不用 AI）、`manuals`（内置写作手册、复制一份来改、把这篇存成我的写作手册）、`agent`（终端里的 Claude Code 经 MCP 连进来写一篇）。
/// 隔空投送的接收端是假的，其余都是页面和 Agent 真实的样子。
@MainActor
struct DemoFramesTests {
    static let width = 1440.0
    static let height = 810.0
    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static func enabled(_ part: String) -> Bool { environment["DEMO_FRAMES_DIR"] != nil && environment["DEMO_PART"] == part }
    nonisolated static var agentBin: URL { URL(fileURLWithPath: environment["DEMO_AGENT_BIN"] ?? "/usr/local/bin") }

    static let helpers = AIReviewTests.helpers + """
        window.sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        // 出图、缩略图、主题格都画完
        window.settle = async (extra = 250) => {
          await mc.render.pages();
          const group = document.querySelector('[role="group"][aria-label="主题"]');
          // 只在主题那一组看得见时等它：检查器切到「AI 助手」后它藏着、一直标着忙；按时刻算，不数次数（离屏窗口的计时器会被降到一秒一次）
          const began = Date.now();
          while (group?.getClientRects().length && group.getAttribute("aria-busy") === "true" && Date.now() - began < 20000) await sleep(100);
          await sleep(extra);
        };
        // 一个控件的中心（指针要去的位置）：名字或元素
        window.spot = (target, options) => {
          const element = typeof target === "string" ? ui.find(target, options) : target;
          if (!element) throw new Error(`界面上找不到「${target}」`);
          const box = element.getBoundingClientRect();
          return [Math.round(box.left + box.width / 2), Math.round(box.top + box.height / 2)];
        };
        window.typeText = async (text) => {
          const before = (await mc.drafts.current()).markdown;
          document.execCommand("insertText", false, text);
          await until(async () => (await mc.drafts.current()).markdown !== before);
        };
        window.caretToEnd = async () => {
          const { markdown } = await mc.drafts.current();
          await mc.editor.focus();
          await mc.editor.select(markdown.length);
        };
        // 对话框和这一轮说完没有：不管这篇用的是 Claude Code 还是 Codex
        window.aiInput = () => document.getElementById("aiInput");
        window.turnDone = async (turns) => {
          const { running, messages } = await mc.ai.history();
          return !running && messages.filter((message) => message.role === "end").length >= turns && !document.getElementById("aiSendBtn").hidden;
        };
        // 到现在说完了几轮（等下一轮时用「这个数 + 1」，不管前面某一轮记了几次收尾）
        window.ends = async () => (await mc.ai.history()).messages.filter((message) => message.role === "end").length;
        // 往对话框里贴一段话（不发送）
        window.paste = (text) => {
          const input = aiInput();
          input.focus();
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
          input.scrollTop = 0;
        };
        window.sendNow = () => aiInput().dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
        // 等 AI 的时候页面在问什么：权限确认、确认对话框
        window.demoState = async (turns) => {
          const permission = document.getElementById("aiPermission");
          const confirm = document.getElementById("confirmDialog");
          return {
            done: turns == null ? false : Boolean(await turnDone(turns)),
            permission: permission.hidden ? null : `${document.getElementById("aiPermissionTitle").textContent}\\n${document.getElementById("aiPermissionDetail").textContent}`,
            confirm: confirm.classList.contains("hidden") ? null : `${document.getElementById("confirmTitle").textContent}\\n${document.getElementById("confirmMessage").textContent}`,
          };
        };
        // 一篇空白的卡片稿子，带署名
        window.blank = async (fields = {}) => {
          await mc.drafts.create();
          await mc.profile.update({ name: "wuyoscar", handle: "@wuyoscar", avatar: "brand/avatar.png" });
          const theme = (await mc.themes.list()).find((item) => item.id === "notes");
          await mc.drafts.update({ mode: "cards", theme: theme.id, colors: theme.colors, tunedColors: [], cover: { enabled: false }, ...fields });
          await settle(500);
        };
        // 合成时镜头要跟的东西（track 里写「@名字」）：舞台上正在看的那张卡片、卡片里最大的那张图、下一张能点的配图候选
        window.demoTargets = {
          page() {
            const view = document.getElementById("previewPanel").getBoundingClientRect();
            let best = null, most = 0;
            for (const frame of document.querySelectorAll("#stageCards .card-frame")) {
              const box = frame.getBoundingClientRect();
              const seen = Math.max(0, Math.min(box.bottom, view.bottom) - Math.max(box.top, view.top));
              if (seen > most) [best, most] = [frame, seen];
            }
            return best;
          },
          photo() {
            const frame = demoTargets.page();
            if (!frame) return null;
            let best = null, most = 0;
            const visit = (node) => {
              for (const image of node.querySelectorAll("img")) {
                const box = image.getBoundingClientRect();
                if (box.width * box.height > most && box.width > 80) [best, most] = [image, box.width * box.height];
              }
              for (const host of node.querySelectorAll("*")) if (host.shadowRoot) visit(host.shadowRoot);
            };
            visit(frame);
            return best;
          },
          candidate: () => document.querySelector("#aiThread .ai-candidate:not(:disabled) img"),
          bubble: () => [...document.querySelectorAll("#aiThread .ai-message.ai-user")].pop() ?? null,
        };
        window.photo = async (name) => new File([await fetch(`docs/guide-assets/${name}`).then((response) => response.blob())], name, { type: "image/jpeg" });
        window.openAssistant = async () => {
          ui.click("AI 助手");
          await until(() => !aiInput().disabled);
          await settle(300);
        };
    """

    /// 一段素材的录制：存帧、记时间线
    @MainActor
    final class Recorder {
        let harness: ShellHarness
        let directory: URL
        /// 录哪个窗口的页面（默认第一个；外部 Agent 新建的稿子开在新窗口里，录到那时换过去）
        var webView: WKWebView
        var frames: [[String: Any]] = []
        var notes: [String] = []
        var chapter = ""
        var caption = ""
        /// 镜头对着哪几栏：write（编辑区 + 舞台）、style（舞台 + 检查器）、full（全景）
        var view = "full"
        /// 这一帧在这一段里是哪一步（合成时按「段 + 步」取帧）
        var step = ""
        /// 每一帧记下这些元素在页面上的位置（合成时据此把面板单独拎出来放大）：名字 → 选择器
        var track: [String: String] = [:]
        /// 每一帧记下离它过了几秒（算真实的快进倍数；终端里的输出和界面对时也用它）
        var clock = Date()
        private var lastData: Data?

        init(_ harness: ShellHarness, part: String) throws {
            self.harness = harness
            webView = harness.webView
            directory = URL(fileURLWithPath: DemoFramesTests.environment["DEMO_FRAMES_DIR"]!).appendingPathComponent(part)
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        @discardableResult
        func run(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
            try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
        }

        /// 存一帧。hold：停多久（秒）；cursor：这一帧里指针走到哪（页面坐标）；click：这一帧末尾点一下；speed：快进几倍（等 AI 的时候）
        func frame(_ hold: Double, cursor: [Double]? = nil, click: Bool = false, speed: Double = 1) async throws {
            let image = try await webView.takeSnapshot(configuration: WKSnapshotConfiguration())
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            // 和上一帧一模一样、也不动指针：只把上一帧停久一点
            if cursor == nil, !click, png == lastData, var last = frames.last,
               last["chapter"] as? String == chapter, last["step"] as? String == step, last["caption"] as? String == caption, last["speed"] as? Double == speed, last["cursor"] == nil {
                last["hold"] = (last["hold"] as? Double ?? 0) + hold
                frames[frames.count - 1] = last
                return
            }
            lastData = png
            let name = String(format: "%04d.png", frames.count)
            try png.write(to: directory.appendingPathComponent(name))
            var entry: [String: Any] = ["file": name, "hold": hold, "chapter": chapter, "caption": caption, "view": view, "click": click, "speed": speed]
            if let cursor { entry["cursor"] = cursor }
            entry["at"] = Date().timeIntervalSince(clock)
            entry["step"] = step
            if !track.isEmpty, let rects = try? await run("""
                const out = {};
                for (const [name, selector] of Object.entries(track)) {
                  const node = selector.startsWith("@") ? demoTargets[selector.slice(1)]() : document.querySelector(selector);
                  if (!node || !node.getClientRects().length) continue;
                  const box = node.getBoundingClientRect();
                  out[name] = [box.left, box.top, box.width, box.height].map((value) => Math.round(value));
                }
                return out;
            """, arguments: ["track": track]) as? [String: Any], !rects.isEmpty {
                entry["rects"] = rects
            }
            frames.append(entry)
            if frames.count % 10 == 0 { try? save(draft: [:]) }  // 边录边写：录到一半也能拿去合成
        }

        func save(draft: [String: Any], regions: [String: Any] = [:]) throws {
            let timeline: [String: Any] = ["width": DemoFramesTests.width, "height": DemoFramesTests.height, "regions": regions, "frames": frames, "notes": notes, "draft": draft]
            try JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("timeline.json"))
        }

        /// 指针走到一个控件上点一下，再存一帧结果。target 是可访问名称；after 是点完以后等什么
        func click(_ target: String, within: String? = nil, lead: Double = 0.9, after: String = "await settle();", hold: Double = 1.4) async throws {
            let arguments: [String: Any] = ["target": target, "within": within ?? NSNull()]
            let point = try await run("return spot(target, within ? { within } : undefined);", arguments: arguments) as? [Double]
            try await frame(lead, cursor: point, click: true)
            try await run("ui.click(target, within ? { within } : undefined);\n" + after, arguments: arguments)
            try await frame(hold, cursor: point)
        }

        /// 点一个用选择器找的元素
        func clickElement(_ selector: String, lead: Double = 0.9, after: String = "await settle();", hold: Double = 1.4) async throws {
            let point = try await run("return spot(document.querySelector(selector));", arguments: ["selector": selector]) as? [Double]
            try await frame(lead, cursor: point, click: true)
            try await run("document.querySelector(selector).click();\n" + after, arguments: ["selector": selector])
            try await frame(hold, cursor: point)
        }

        /// 一个字一个字打：每打几个字存一帧
        func type(_ text: String, chunk: Int = 2, each: Double = 0.09, last: Double = 0.5) async throws {
            let characters = Array(text)
            var index = 0
            while index < characters.count {
                let end = min(index + chunk, characters.count)
                try await run("await typeText(text); await mc.render.pages();", arguments: ["text": String(characters[index..<end])])
                index = end
                try await frame(index == characters.count ? last : each)
            }
        }

        /// 等 AI 的这一轮说完（第 turns 轮；nil 时只等 also），一边等一边存帧（快进）；中间页面问权限、弹确认框时停下来按一下。
        /// 只放行查资料和 App 自己的事；要运行命令、删东西的一律拒绝。
        func watch(turns: Int?, speed: Double = 8, every: Double = 0.8, timeout: Double = 900, also: (() -> Bool)? = nil) async throws {
            let start = Date()
            var last = Date()
            while Date().timeIntervalSince(start) < timeout {
                let state = try await run("return await demoState(turns);", arguments: ["turns": turns ?? NSNull()]) as? [String: Any] ?? [:]
                let now = Date()
                try await frame(now.timeIntervalSince(last), speed: speed)
                last = now
                if let permission = state["permission"] as? String {
                    let risky = ["Bash", "命令", "rm ", "删除", "sudo", "curl", "ssh"].contains { permission.contains($0) }
                    notes.append("权限（\(risky ? "拒绝" : "允许")）：\(permission.prefix(300))")
                    try await frame(1.6)
                    try await clickElement(risky ? "#aiDenyBtn" : "#aiAllowBtn", lead: 0.8, after: "await sleep(300);", hold: 0.5)
                    last = Date()
                } else if let confirm = state["confirm"] as? String {
                    notes.append("确认框：\(confirm.prefix(300))")
                    try await frame(2.6)
                    try await clickElement("#confirmOk", lead: 0.8, after: "await sleep(300);", hold: 0.6)
                    last = Date()
                } else if state["done"] as? Bool == true || also?() == true {
                    return
                }
                try await Task.sleep(for: .milliseconds(Int(every * 1000)))
            }
            notes.append("等了 \(Int(timeout)) 秒还没说完")
        }

        /// 这一轮改了稿子时修改对比会出来：停一下给人看，再全部接受
        func acceptAll(hold: Double = 2.4, step next: String? = nil) async throws {
            let shown = try await run("return Boolean(ui.find('全部接受')) && !reviewBar().hidden;") as? Bool ?? false
            guard shown else { return }
            try await frame(hold)
            if let next { step = next }
            try await click("全部接受", after: "await settle(600);", hold: 2.0)
        }

        func finish() async throws {
            let regions = try await run("""
                const rect = (selector) => { const box = document.querySelector(selector).getBoundingClientRect(); return [box.left, box.top, box.width, box.height]; };
                return { editor: rect(".editor-pane"), stage: rect("#previewPanel"), inspector: rect(".inspector"), send: rect("#sendToIPhoneBtn") };
            """) as? [String: Any] ?? [:]
            let final = try await run("""
                const draft = await mc.drafts.current();
                const history = await mc.ai.history();
                return { title: draft.title, markdown: draft.markdown, caption: draft.caption, said: history.messages.filter((message) => message.role === "assistant").map((message) => message.text) };
            """) as? [String: Any] ?? [:]
            try save(draft: final, regions: regions)
        }
    }

    /// 起一个 harness：窗口 1440 × 810；real 为真时「终端」里是这台机器真的 claude
    static func start(real: Bool, mcp: MCPConfiguration? = nil) async throws -> ShellHarness {
        let harness = ShellHarness(terminalPath: real ? [agentBin] : [], onboarding: false, mcp: mcp)
        harness.webView.window?.setContentSize(NSSize(width: width, height: height))
        try await harness.load()
        return harness
    }

    // MARK: - 基础功能

    static let opening = """
        # 周末去山里看一次日出

        凌晨四点出发，山路上只有车灯。到观景台的时候天还没亮，风很大，但所有人都在等同一件事。

        > 日出只有十几分钟，却能让你记住整个周末。
        """

    @Test("基础功能：写、排、封面、检查、手机预览、发送", .enabled(if: enabled("basics")))
    func recordBasics() async throws {
        let harness = try await Self.start(real: false)
        let recorder = try Recorder(harness, part: "basics")
        try await recorder.run(Self.helpers + """
            await blank();
            // 导入的图片会插在光标处：先导入，再把正文换成只有开头的样子（图片留在这篇的图片里，后面用 / 插进来）
            window.valley = (await mc.media.import([await photo("valley-morning.jpg")]))[0];
            await mc.drafts.update({
              fonts: { zh: "theme", en: "theme", code: "theme" }, fontSize: 34, lineHeight: 1.85, imageMaxHeight: 1048,
              title: "周末去山里看一次日出", markdown: opening,
              caption: "凌晨四点出发，在山顶等了二十分钟。云和光都值得，下次还想再去一次。\\n\\n#日出 #周末去哪儿 #旅行攻略",
            });
            ui.click("样式");
            await caretToEnd();
            await settle(600);
        """, arguments: ["opening": Self.opening])

        recorder.chapter = "write"
        recorder.view = "write"
        recorder.caption = "左边写 Markdown，中间就是排好的卡片"
        try await recorder.frame(1.2)
        try await recorder.type("\n\n## 出发前准备", last: 0.6)
        try await recorder.type("\n\n1. 前一晚查好日出时间，提前四十分钟到", last: 0.3)
        try await recorder.type("\n2. 带一件防风外套，山顶比山下冷 8 度", last: 0.3)
        try await recorder.type("\n3. 手机和充电宝提前充满", last: 1.0)

        recorder.caption = "行首输入 / ，插图片、分页和组件"
        try await recorder.type("\n\n", chunk: 2, last: 0.3)
        try await recorder.type("/", chunk: 1, last: 1.4)
        try await recorder.run("""
            document.activeElement.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
            await sleep(100);
            const { markdown } = await mc.drafts.current();
            await mc.drafts.update({ markdown: markdown.replace(/\\n*\\/$/, "") + `\\n\\n[[图片:${valley}]]` });
            await caretToEnd();
            await settle(500);
        """)
        try await recorder.frame(2.4)

        recorder.chapter = "themes"
        recorder.view = "style"
        recorder.caption = "12 个主题，卡片结构、配色和字体一起换"
        for (name, hold) in [("杂志", 1.5), ("撞色", 1.5), ("纯黑", 1.5), ("清新", 2.4)] {
            try await recorder.click(name, within: "主题", hold: hold)
        }

        recorder.chapter = "cover"
        recorder.caption = "首页做封面，标题取自标题框"
        try await recorder.run("ui.find('首页做封面').scrollIntoView({ block: 'center' }); await sleep(200);")
        try await recorder.click("首页做封面", after: """
            await mc.drafts.update({ cover: { enabled: true, subtitle: "凌晨四点出发，值了", image: valley } });
            await settle(300);
            // 翻回第一张看封面
            for (const previous = ui.find("上一张", { within: "预览" }) ?? document.getElementById("prevPageBtn"); !previous.disabled;) { previous.click(); await sleep(120); }
            await settle(400);
        """, hold: 2.6)

        recorder.chapter = "publish"
        recorder.view = "full"
        recorder.caption = "发之前：检查用词，看看在手机上的样子"
        try await recorder.click("检查", after: "await settle(500);", hold: 2.6)
        try await recorder.click("检查", after: "await settle(300);", hold: 0.5)
        try await recorder.click("手机预览", after: "await settle(700);", hold: 3.0)
        try await recorder.click("手机预览", after: "await settle(400);", hold: 0.6)

        recorder.chapter = "send"
        recorder.caption = "发送到 iPhone：按页序隔空投送，正文进剪贴板"
        try await recorder.click("发送到 iPhone", after: """
            await sleep(400);
            if (ui.find("仍然发送")) ui.click("仍然发送");
            await sleep(1500);
            await settle(300);
        """, hold: 3.2)

        try await recorder.finish()
        await harness.tearDown()
        #expect(harness.pageErrors == [])
        #expect(recorder.frames.count > 40)
    }

    // MARK: - 主视频：你写，Agent 排（App 里真的 Agent）

    static let brunch = """
        周末早午餐，三道 15 分钟能做完的
        上周末朋友来家里，我只有半个小时，最后做了三道，大家都说好吃，记一下做法。
        第一道是牛油果溏心蛋吐司。吐司烤两分钟，牛油果压成泥，加一点盐和柠檬汁抹上去。鸡蛋冷水下锅，水开后煮 6 分半，过冷水剥壳，切开放在上面，撒黑胡椒。
        第二道是番茄芝士烤蛋。小烤碗里放切碎的番茄，打两个蛋，撒马苏里拉，烤箱 200 度烤 10 分钟。蛋白凝固、蛋黄还会流就可以了。
        第三道是酸奶水果碗。希腊酸奶铺底，放蓝莓、草莓、香蕉片和一勺格兰诺拉，最后淋一点蜂蜜。
        顺序很重要：先煮蛋，煮蛋的时候烤番茄，最后做酸奶碗，三道一起上桌。
        我踩过的坑：第一次煮蛋煮了 8 分钟，蛋黄全熟了，没有流心。
        """

    @Test("主视频：一篇没排过的字，App 里的 Agent 排版、生图，人逐处点头；再写卡片样式、存写作手册（真的 Agent）", .enabled(if: enabled("collab")))
    func recordCollab() async throws {
        let harness = try await Self.start(real: true)
        let recorder = try Recorder(harness, part: "collab")
        recorder.track = [
            "editor": ".editor-pane", "stage": "#previewPanel", "inspector": ".inspector", "thread": "#aiThread", "composer": "#aiComposer",
            "review": "#aiReview", "confirm": "#confirmDialog .dialog, #confirmDialog > *", "send": "#sendToIPhoneBtn", "strip": "#filmstrip",
            "page": "@page", "photo": "@photo", "candidate": "@candidate", "bubble": "@bubble",
        ]
        try await recorder.run(Self.helpers + "await blank({ title: '', markdown: text }); ui.click('样式'); await settle(600);", arguments: ["text": Self.brunch])

        // 开头：一整屏没排过的字
        recorder.chapter = "hook"
        recorder.step = "raw"
        try await recorder.frame(2.0)
        recorder.step = "next"
        try await recorder.click("下一张", within: "预览", after: "await settle(300);", hold: 1.2)
        recorder.step = "back"
        try await recorder.click("上一张", within: "预览", after: "await settle(300);", hold: 1.0)

        // 说一句
        recorder.chapter = "ask"
        recorder.step = "open"
        try await recorder.click("AI 助手", after: "await until(() => !aiInput().disabled); await settle(300);", hold: 1.0)
        let ask = "把这篇排成小红书图文：每道菜一页，做法用步骤，踩坑那句用提示。每道菜生成一张俯拍的照片当配图，颜色饱满一点。挑个合适的主题，我的原话不要改。"
        try await recorder.run("aiInput().focus();")
        recorder.step = "type"
        var typed = ""
        for character in ask {
            typed.append(character)
            if typed.count % 3 == 0 || typed.count == ask.count {
                try await recorder.run("paste(text); aiInput().scrollTop = aiInput().scrollHeight;", arguments: ["text": typed])
                try await recorder.frame(0.07)
            }
        }
        recorder.step = "typed"
        try await recorder.frame(0.8)
        recorder.step = "send"
        let base1 = try await recorder.run("return await ends();") as? Int ?? 0
        try await recorder.clickElement("#aiSendBtn", lead: 0.7, after: "await sleep(500);", hold: 0.6)

        // Agent 动手（快进）
        recorder.chapter = "work"
        recorder.step = "wait"
        try await recorder.watch(turns: base1 + 1, speed: 8, every: 0.7, timeout: 1500)
        try await recorder.run("await settle(600);")
        recorder.step = "done"
        try await recorder.frame(1.6)

        // 你点头：修改对比，全部接受
        recorder.chapter = "review"
        recorder.step = "marks"
        try await recorder.acceptAll(hold: 3.0, step: "accept")

        // 配图候选：光标放到哪道菜，图就落在哪一页
        recorder.chapter = "photos"
        let dishes = ["第一道", "第二道", "第三道"]
        let candidates = try await recorder.run("return document.querySelectorAll('#aiThread .ai-candidate:not(:disabled)').length;") as? Int ?? 0
        for index in 0..<min(candidates, dishes.count) {
            // 在编辑器里点那道菜的那一行（舞台跟着翻到那一页）
            recorder.step = "caret-\(index + 1)"
            let point = try await recorder.run("""
                const { markdown } = await mc.drafts.current();
                const at = markdown.indexOf(dish);
                if (at < 0) return null;
                const end = markdown.indexOf("\\n", at);
                await mc.editor.focus();
                await mc.editor.select(end < 0 ? markdown.length : end);
                await sleep(400);
                await settle(300);
                const line = [...document.querySelectorAll(".editor-pane .cm-line")].find((node) => node.textContent.includes(dish));
                if (!line) return null;
                line.scrollIntoView({ block: "center" });
                await sleep(300);
                const box = line.getBoundingClientRect();
                return [Math.round(Math.min(box.right - 12, box.left + 330)), Math.round(box.top + box.height / 2)];
            """, arguments: ["dish": dishes[index]]) as? [Double]
            try await recorder.frame(0.9, cursor: point, click: true)
            try await recorder.frame(0.5, cursor: point)
            recorder.step = "pick-\(index + 1)"
            try await recorder.run("document.querySelector('#aiThread .ai-candidate:not(:disabled)').scrollIntoView({ block: 'center' }); await sleep(250);")
            try await recorder.clickElement("#aiThread .ai-candidate:not(:disabled)", lead: 0.9, after: "await settle(700);", hold: 1.6)
        }
        recorder.notes.append("配图候选 \(candidates) 张")
        recorder.step = "placed"
        try await recorder.frame(1.6)

        // 它会长本事：写一套这篇自己的卡片样式
        recorder.chapter = "style"
        recorder.step = "ask"
        let restyle = "封面再醒目一点。给这篇写一套自己的卡片样式：奶油色底、圆角大一点、标题用番茄红，看起来像一份早午餐菜单。"
        try await recorder.run("paste(text); await sleep(200);", arguments: ["text": restyle])
        try await recorder.frame(1.6)
        recorder.step = "send"
        let base2 = try await recorder.run("return await ends();") as? Int ?? 0
        try await recorder.clickElement("#aiSendBtn", lead: 0.7, after: "await sleep(500);", hold: 0.6)
        recorder.step = "wait"
        try await recorder.watch(turns: base2 + 1, speed: 8, every: 0.7, timeout: 1200)
        try await recorder.run("await settle(600);")
        recorder.step = "marks"
        try await recorder.acceptAll(hold: 2.0, step: "accept")
        // 一页一页翻过去：新样式下每一页的样子
        recorder.step = "first"
        try await recorder.run("while (!ui.find('上一张', { within: '预览' }).disabled) { ui.click('上一张', { within: '预览' }); await sleep(120); } await settle(400);")
        try await recorder.frame(1.6)
        let pages = try await recorder.run("return document.getElementById(\"filmstrip\").children.length;") as? Int ?? 1
        for page in 1..<min(pages, 5) {
            recorder.step = "flip-\(page)"
            try await recorder.click("下一张", within: "预览", lead: 0.6, after: "await settle(400);", hold: 1.2)
        }

        // 存成我的写作手册
        recorder.chapter = "manual"
        recorder.step = "menu"
        try await recorder.run("presetButton('存成我的写作手册'); await sleep(300);")
        try await recorder.frame(0.8)
        recorder.step = "pick"
        let base3 = try await recorder.run("return await ends();") as? Int ?? 0
        try await recorder.click("存成我的写作手册", after: "await sleep(500);", hold: 0.6)
        recorder.step = "wait"
        try await recorder.watch(turns: base3 + 1, speed: 8, every: 0.7, timeout: 1200)
        recorder.step = "done"
        try await recorder.frame(1.6)

        // 发送：收到的卡片 PNG 留给结尾的手机
        recorder.chapter = "send"
        recorder.step = "first"
        try await recorder.run("while (!ui.find('上一张', { within: '预览' }).disabled) { ui.click('上一张', { within: '预览' }); await sleep(120); } await settle(400);")
        try await recorder.frame(1.2)
        recorder.step = "send"
        try await recorder.click("发送到 iPhone", after: """
            await sleep(400);
            if (ui.find("仍然发送")) ui.click("仍然发送");
            const deadline = Date.now() + 120000;
            while (!["success", "error", "cancelled"].includes(document.querySelector("#outputActivity").dataset.state) && Date.now() < deadline) await sleep(100);
            await settle(300);
        """, hold: 2.6)
        let cards = recorder.directory.appendingPathComponent("cards")
        try FileManager.default.createDirectory(at: cards, withIntermediateDirectories: true)
        for (index, file) in (harness.sender.batches.last ?? []).enumerated() {
            try? FileManager.default.copyItem(at: file, to: cards.appendingPathComponent(String(format: "%02d-", index + 1) + file.lastPathComponent))
        }

        try await recorder.finish()
        let folder = harness.aiRoot.appendingPathComponent("写作手册")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []) where name.hasSuffix(".md") {
            try? FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: recorder.directory.appendingPathComponent("手册-" + name))
        }
        await harness.tearDown()
        #expect(recorder.frames.count > 20)
    }

    // MARK: - 主视频：排好以后自己动手调（不用 AI）

    /// collab 那一段排好以后的稿子；`{1}`–`{3}` 换成导入的三张配图（那一段里 Agent 生成的，录之前放在 `docs/demo/assets/brunch-N.png`）
    static let brunchDone = """
        ## 周末早午餐，三道 15 分钟能做完的
        上周末朋友来家里，我只有半个小时，最后做了三道，大家都说好吃，记一下做法。
        ### 第一道是牛油果溏心蛋吐司。
        [[图片:{1}]]

        :::步骤
        - 吐司烤两分钟，牛油果压成泥，加一点盐和柠檬汁抹上去。
        - 鸡蛋冷水下锅，水开后煮 6 分半，过冷水剥壳，切开放在上面，撒黑胡椒。
        :::

        :::提示
        我踩过的坑：第一次煮蛋煮了 8 分钟，蛋黄全熟了，没有流心。
        :::

        [[分页]]

        ### 第二道是番茄芝士烤蛋。
        [[图片:{2}]]

        :::步骤
        - 小烤碗里放切碎的番茄，打两个蛋，撒马苏里拉，烤箱 200 度烤 10 分钟。
        - 蛋白凝固、蛋黄还会流就可以了。
        :::

        [[分页]]

        ### 第三道是酸奶水果碗。
        [[图片:{3}]]

        :::步骤
        - 希腊酸奶铺底，放蓝莓、草莓、香蕉片和一勺格兰诺拉，最后淋一点蜂蜜。
        :::
        顺序很重要：先煮蛋，煮蛋的时候烤番茄，最后做酸奶碗，三道一起上桌。
        """

    @Test("主视频：排好的稿子，自己换主题、换尺寸、拖字号", .enabled(if: enabled("tune")))
    func recordTune() async throws {
        let harness = try await Self.start(real: false)
        let recorder = try Recorder(harness, part: "tune")
        recorder.track = ["stage": "#previewPanel", "inspector": ".inspector", "page": "@page", "photo": "@photo", "control": "@control"]
        try await recorder.run(Self.helpers + """
            demoTargets.control = () => window.demoControl ?? null;  // 正在动的那个控件：镜头跟着它
            await blank();
            const ids = [];
            for (const number of [1, 2, 3]) {
              const blob = await fetch(`docs/demo/assets/brunch-${number}.png`).then((response) => response.blob());
              ids.push((await mc.media.import([new File([blob], `brunch-${number}.png`, { type: "image/png" })]))[0]);
            }
            const theme = (await mc.themes.list()).find((item) => item.name === "清新");
            // 字号和图片高照 collab 那一段里 Agent 定的（26、320），这样分页和那一段一样是三页
            await mc.drafts.update({ theme: theme.id, colors: theme.colors, tunedColors: [], fontSize: 26, imageMaxHeight: 320, markdown: text.replace(/\\{(\\d)\\}/g, (_, number) => ids[number - 1]) });
            ui.click("样式");
            await settle(600);
            while (!ui.find("下一张", { within: "预览" }).disabled) { ui.click("下一张", { within: "预览" }); await sleep(150); }
            await settle(400);
        """, arguments: ["text": Self.brunchDone])

        recorder.chapter = "tune"
        recorder.step = "start"
        try await recorder.frame(1.0)

        // 换两个主题，再换回来
        for (order, name) in ["杂志", "撞色", "清新"].enumerated() {
            recorder.step = "theme-\(order + 1)"
            try await recorder.run("window.demoControl = ui.find(name, { within: '主题' }); demoControl.scrollIntoView({ block: 'center' }); await sleep(150);", arguments: ["name": name])
            try await recorder.click(name, within: "主题", lead: 0.5, hold: 0.9)
        }

        // 图文尺寸：换成竖屏 9:16，再换回 3:4（下拉菜单是系统画的，截不到：这里只记点之前、选之后）
        for (order, value) in ["1536", "1152"].enumerated() {
            recorder.step = "size-\(order + 1)"
            let point = try await recorder.run("window.demoControl = document.getElementById('cardHeightInput'); demoControl.scrollIntoView({ block: 'center' }); await sleep(150); return spot(demoControl);") as? [Double]
            try await recorder.frame(0.5, cursor: point, click: true)
            try await recorder.run("""
                demoControl.value = value;
                demoControl.dispatchEvent(new Event("input", { bubbles: true }));
                demoControl.dispatchEvent(new Event("change", { bubbles: true }));
                await settle(300);
            """, arguments: ["value": value])
            try await recorder.frame(0.9, cursor: point)
        }

        // 字号、图片高：按着滑块拖大，再拖回来
        let thumb = """
            const box = demoControl.getBoundingClientRect();
            const ratio = (demoControl.value - demoControl.min) / (demoControl.max - demoControl.min);
            return [Math.round(box.left + 8 + ratio * (box.width - 16)), Math.round(box.top + box.height / 2)];
        """
        for (name, input, reach, count) in [("font", "fontSizeInput", 8.0, 8.0), ("image", "imageHeightInput", 280.0, 8.0)] {
            recorder.step = name
            let values = try await recorder.run("""
                window.demoControl = document.getElementById(input);
                demoControl.scrollIntoView({ block: "center" });
                await sleep(150);
                const now = Number(demoControl.value), top = Math.min(Number(demoControl.max), now + reach), up = [];
                for (let index = 1; index <= count; index++) up.push(Math.round(now + (top - now) * index / count));
                return [...up, ...up.slice(0, -1).reverse(), now];
            """, arguments: ["input": input, "reach": reach, "count": count]) as? [Double] ?? []
            try await recorder.frame(0.5, cursor: try await recorder.run(thumb) as? [Double], click: true)
            for value in values {
                try await recorder.run("demoControl.value = value; demoControl.dispatchEvent(new Event('input', { bubbles: true })); await mc.render.pages();", arguments: ["value": value])
                try await recorder.frame(0.07, cursor: try await recorder.run(thumb) as? [Double])
            }
            try await recorder.run("demoControl.dispatchEvent(new Event('change', { bubbles: true })); await settle(300);")
            recorder.step = name + "-done"
            try await recorder.frame(1.0, cursor: try await recorder.run(thumb) as? [Double])
        }

        try await recorder.finish()
        await harness.tearDown()
        #expect(harness.pageErrors == [])
        #expect(recorder.frames.count > 20)
    }

    // MARK: - 场景：写好的长文，一键润色、一键排版（真的 Claude Code）

    static let moving = """
        # 一个人搬家，第一周要办的事

        上个月我从浦东搬到了徐汇，一个人搬的。搬之前我以为最麻烦的是打包，结果最麻烦的是搬完之后那一个星期。

        到手当天要做的就三件事：拍照、抄表、换锁芯。拍照是把每个房间的的墙、地板、家电都拍一遍，发给房东留个底。抄表是水电煤三个表的读数都拍下来。换锁芯花了 180，师傅十分钟就弄好了。

        三天内要办的是宽带和水电煤过户。宽带我是第二天才想起来约的，结果师傅要排到第五天，那几天只能开手机热点。水电煤过户在再支付宝里就能办，但是要房东的身份证号，这个最好签合同那天就问好。

        一周内要办的是居住证和快递地址。居住证我拖到了第六天，差点错过社区每周只有周三下午办的时间。快递地址我改了淘宝忘了改京东，有一箱猫砂寄到了旧地址。

        要是重来一次，我会在签合同那天就把房东的身份证号、宽带的预约、社区的办事时间这三件事问清楚。
        """

    @Test("场景：写好的长文一键润色、一键排版（真的 Claude Code）", .enabled(if: enabled("polish")))
    func recordPolish() async throws {
        let harness = try await Self.start(real: true)
        let recorder = try Recorder(harness, part: "polish")
        try await recorder.run(Self.helpers + "await blank({ title: '一个人搬家，第一周要办的事', markdown: text });", arguments: ["text": Self.moving])

        recorder.chapter = "polish"
        recorder.view = "full"
        recorder.caption = "场景一：稿子写好了，让 AI 润色"
        try await recorder.frame(2.2)
        try await recorder.click("AI 助手", after: "await until(() => !aiInput().disabled); await settle(300);", hold: 1.6)
        try await recorder.click("一键润色全文", after: "await sleep(600);", hold: 0.6)
        try await recorder.watch(turns: 1)
        try await recorder.run("await settle(500);")
        recorder.caption = "改动标在正文里，逐处接受或拒绝"
        recorder.view = "write"
        try await recorder.acceptAll(hold: 3.4)

        recorder.chapter = "layout"
        recorder.view = "full"
        recorder.caption = "再点「一键排版」：只动版式，不改字"
        try await recorder.run("presetButton('一键排版'); await sleep(300);")
        try await recorder.click("一键排版", after: "await sleep(600);", hold: 0.6)
        try await recorder.watch(turns: 2)
        try await recorder.run("await settle(600);")
        try await recorder.acceptAll()
        recorder.view = "style"
        try await recorder.run("ui.click('样式'); await settle(600);")
        try await recorder.frame(3.2)

        try await recorder.finish()
        await harness.tearDown()
        #expect(recorder.frames.count > 10)
    }

    // MARK: - 场景：把一篇长文贴进对话框，排成图文（真的 Claude Code）

    static let camping = """
        上周末我第一次一个人去湖边露营，说一下过程，有两件事我做错了。

        我是周六下午四点到的营地，离天黑还有两个多小时，本来以为时间很够。结果搭帐篷就搭了五十分钟。第一次我把门朝着湖，想着早上一拉开就能看到水，刚把四个角钉好，一阵风从湖面过来，整顶帐篷鼓得像个气球，两根地钉直接被拔了出来。旁边一个大哥过来帮我按住，说门要背着风，地钉要斜着往外打。我拆了重搭，这次门朝着树林。

        晚饭是泡面加一根玉米。卡式炉在风里火很小，一锅水烧了快二十分钟，后来我用两个背包把炉子围起来才烧开。

        天黑以后湖边特别安静，对岸只有两三盏灯。我在外面坐到九点多，拍了一张照片。

        第二件做错的事是睡袋。我带的那条标的是舒适温度 10 度，那天夜里湖边只有 4 度，我三点钟冻醒了，把带的衣服全穿上才睡着。

        早上六点我是被鸟吵醒的，出来的时候山谷里全是雾，太阳刚照到对面的山上。

        如果你也想去，我的建议就两条：搭帐篷之前先看风从哪边来，睡袋按当地夜里的最低温度选。
        """

    @Test("场景：把一篇长文贴进对话框，让 AI 排成图文（真的 Claude Code）", .enabled(if: enabled("paste")))
    func recordPaste() async throws {
        let harness = try await Self.start(real: true)
        let recorder = try Recorder(harness, part: "paste")
        try await recorder.run(Self.helpers + """
            await blank();
            await mc.media.import([await photo("night-lake.jpg"), await photo("valley-morning.jpg")]);
            await settle(400);
        """)

        recorder.chapter = "paste"
        recorder.view = "full"
        recorder.caption = "场景二：手上有一篇写好的长文，照片已经拖进稿子"
        try await recorder.frame(1.6)
        try await recorder.click("AI 助手", after: "await until(() => !aiInput().disabled); await settle(300);", hold: 1.2)
        recorder.caption = "整篇贴进对话框，让 AI 排成图文卡片"
        try await recorder.run("paste(text); await sleep(300);", arguments: [
            "text": "把下面这篇排成小红书图文卡片：分好页，起一个标题，稿子里已经有的两张照片（夜里的湖、早上的山谷）放在说到它们的地方，再写好小红书正文。原话不要改。\n\n" + Self.camping,
        ])
        try await recorder.frame(2.8)
        try await recorder.run("sendNow(); await sleep(600);")
        try await recorder.watch(turns: 1)
        try await recorder.run("await settle(600);")
        recorder.caption = "卡片、标题、小红书正文一起出来"
        try await recorder.acceptAll(hold: 3.0)
        recorder.view = "style"
        try await recorder.run("ui.click('样式'); await settle(600);")
        try await recorder.frame(2.0)
        try await recorder.click("杂志", within: "主题", hold: 3.0)

        try await recorder.finish()
        await harness.tearDown()
        #expect(recorder.frames.count > 10)
    }

    // MARK: - 场景：找最近的热点，写成一篇（真的 Claude Code，会联网搜索）

    @Test("场景：让 AI 找最近的热点写成一篇（真的 Claude Code）", .enabled(if: enabled("topic")))
    func recordTopic() async throws {
        let harness = try await Self.start(real: true)
        let recorder = try Recorder(harness, part: "topic")
        try await recorder.run(Self.helpers + "await blank(); await openAssistant();")

        recorder.chapter = "topic"
        recorder.view = "full"
        recorder.caption = "场景三：还没有稿子，让 AI 去找最近的热点"
        try await recorder.frame(1.6)
        try await recorder.clickElement("#aiSkillsToggle", after: "await until(() => document.querySelectorAll('#aiSkillsList input').length >= 4);", hold: 1.6)
        recorder.caption = "点名一份写作手册：论文与技术解读"
        try await recorder.clickElement("#aiSkillsList input[value='论文与技术解读']", after: "await sleep(200);", hold: 1.2)
        try await recorder.clickElement("#aiSkillsDone", after: "await sleep(200);", hold: 0.8)
        recorder.caption = "说一句要什么：最近 AI safety 有什么新消息"
        try await recorder.run("paste(text); await sleep(300);", arguments: [
            "text": "上网看看最近一周 AI safety 方向有什么新的论文或新闻，挑一条有出处的，写成一篇小红书图文：分好页，标题和小红书正文也写好，出处放页尾。",
        ])
        try await recorder.frame(2.6)
        try await recorder.run("sendNow(); await sleep(600);")
        recorder.caption = "联网之前先问你；找到以后自己写成一篇"
        try await recorder.watch(turns: 1, timeout: 1200)
        try await recorder.run("await settle(600);")
        try await recorder.acceptAll(hold: 3.0)
        recorder.view = "style"
        try await recorder.run("ui.click('样式'); await settle(600);")
        try await recorder.frame(3.2)

        try await recorder.finish()
        await harness.tearDown()
        #expect(recorder.frames.count > 10)
    }

    // MARK: - 写作手册：内置的、复制一份来改、把这篇存成我的（真的 Claude Code）

    @Test("写作手册：内置的几份、复制一份来改、把这篇的写法存成我的写作手册（真的 Claude Code）", .enabled(if: enabled("manuals")))
    func recordManuals() async throws {
        let harness = try await Self.start(real: true)
        let recorder = try Recorder(harness, part: "manuals")
        try await recorder.run(Self.helpers + "await blank({ title: '一个人搬家，第一周要办的事', markdown: text }); await openAssistant();", arguments: [
            "text": Self.moving.replacingOccurrences(of: "的的", with: "的").replacingOccurrences(of: "在再", with: "在"),
        ])

        recorder.chapter = "manuals"
        recorder.view = "style"
        recorder.caption = "AI 设置里有两个内置技能和四份内置写作手册"
        try await recorder.frame(1.2)
        try await recorder.clickElement("#aiSettings > summary", after: """
            await until(() => document.querySelectorAll("#writingManualList > li").length >= 4);
            document.getElementById("builtInSkills").scrollIntoView({ block: "start" });
            await sleep(300);
        """, hold: 3.0)
        try await recorder.run("document.getElementById('writingManuals').scrollIntoView({ block: 'start' }); await sleep(300);")
        try await recorder.frame(2.6)
        recorder.caption = "想改成自己的：复制一份来改"
        try await recorder.click("复制一份来改", within: "经验分享", after: """
            await until(() => document.querySelector('#writingManualList [aria-label="经验分享"] .ai-manual-badge')?.textContent === "已定制");
            await sleep(300);
        """, hold: 2.8)
        try await recorder.clickElement("#aiSettings > summary", after: "await sleep(300);", hold: 0.6)

        recorder.caption = "也可以让 AI 把这篇的写法存成你的写作手册"
        try await recorder.run("presetButton('存成我的写作手册'); await sleep(300);")
        try await recorder.click("存成我的写作手册", after: "await sleep(600);", hold: 0.6)
        try await recorder.watch(turns: 1)
        try await recorder.run("await sleep(500);")
        try await recorder.frame(2.0)
        recorder.caption = "保存前给你确认；之后同类的稿子照它写"
        try await recorder.clickElement("#aiSettings > summary", after: """
            await until(() => document.querySelectorAll("#writingManualList > li").length >= 4);
            document.getElementById("writingManuals").scrollIntoView({ block: "start" });
            await sleep(300);
        """, hold: 3.4)

        try await recorder.finish()
        let folder = harness.aiRoot.appendingPathComponent("写作手册")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []) where name.hasSuffix(".md") {
            try? FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: recorder.directory.appendingPathComponent("手册-" + name))
        }
        await harness.tearDown()
        #expect(recorder.frames.count > 8)
    }

    // MARK: - 外部 Agent：终端里的 Claude Code 经 MCP 连进来写一篇（真的 Claude Code）

    @Test("外部 Agent：终端里的 Claude Code 经 MCP 连进 App，新建一篇、排好、换主题（真的 Claude Code）", .enabled(if: enabled("agent")))
    func recordExternalAgent() async throws {
        let config = MCPConfiguration.temporary()
        let harness = try await Self.start(real: false, mcp: config)
        let recorder = try Recorder(harness, part: "agent")
        recorder.track = ["window": "body", "editor": ".editor-pane", "stage": "#previewPanel", "card": "#stageCards", "inspector": ".inspector"]
        try await recorder.run(Self.helpers + "await blank();")
        recorder.chapter = "agent"
        recorder.view = "full"
        recorder.caption = "终端里的 Agent 也能连进来：外部 Agent（MCP）"
        try await recorder.frame(2.0)

        // 仓库里刚构建的 MCP 服务（和 App 包里的是同一个），套接字指向这个 harness
        let server = ShellHarness.repoRoot.appendingPathComponent("macos/.build/debug/mediacraft-mcp").path
        let prompt = "用 mediacraft 这个 MCP 服务在 Vibepost 里新建一篇小红书图文，题目是「第一次做手冲咖啡，我踩过的三个坑」。先读它的操作手册和写作技能，"
            + "写 4–5 页（酸是水温不够、苦是磨太细、先买温度计；我没给的细节留【待补】），分好页、用上步骤或提示这类组件，换一个合适的主题，写好小红书正文，最后看一眼每页排得怎么样。"
        let process = Process()
        let claude = Self.agentBin.appendingPathComponent("claude")
        if FileManager.default.fileExists(atPath: claude.path) {
            let mcpConfig: [String: Any] = ["mcpServers": ["mediacraft": ["command": server, "args": [String](), "env": ["MEDIACRAFT_MCP_SOCKET": config.socketPath]]]]
            let configFile = recorder.directory.appendingPathComponent("mcp.json")
            try JSONSerialization.data(withJSONObject: mcpConfig).write(to: configFile)
            process.executableURL = claude
            process.arguments = ["-p", prompt, "--mcp-config", configFile.path, "--strict-mcp-config", "--allowedTools", "mcp__mediacraft"]
            recorder.notes.append("终端里的 Agent：claude -p")
        } else {
            // Codex：MCP 服务写在这一次调用的配置里；模型自己的命令只读，改稿子只能经 MCP
            process.executableURL = Self.agentBin.appendingPathComponent("codex")
            process.arguments = [
                "exec", "--skip-git-repo-check", "-s", "read-only",
                "-c", "mcp_servers.mediacraft.command=\"\(server)\"",
                "-c", "mcp_servers.mediacraft.env={MEDIACRAFT_MCP_SOCKET=\"\(config.socketPath)\"}",
                // exec 没有人可问：这个服务的工具直接放行（App 那边仍有自己的开关和操作记录）
                "-c", "mcp_servers.mediacraft.default_tools_approval_mode=\"approve\"",
                prompt + "不用读这台电脑上别的文件，直接用这个 MCP 服务。",
            ]
            recorder.notes.append("终端里的 Agent：codex exec")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(Self.agentBin.path):/usr/bin:/bin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.currentDirectoryURL = recorder.directory

        // 终端里的输出：原样存一份，另存一份带时间的（合成时一行行按真实的先后出现）
        let outputFile = recorder.directory.appendingPathComponent("agent-output.txt")
        let timedFile = recorder.directory.appendingPathComponent("agent-output.jsonl")
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        FileManager.default.createFile(atPath: timedFile.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputFile)
        let timed = try FileHandle(forWritingTo: timedFile)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let started = Date()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            output.write(data)
            let entry: [String: Any] = ["t": Date().timeIntervalSince(started), "text": String(decoding: data, as: UTF8.self)]
            if let line = try? JSONSerialization.data(withJSONObject: entry) {
                timed.write(line)
                timed.write(Data("\n".utf8))
            }
        }
        recorder.clock = started
        try process.run()
        recorder.caption = "它读操作手册和写作技能，新建稿子、分页、换主题"
        // 新建的稿子开在新窗口里：先录着第一个窗口，新窗口一开就换过去录它
        recorder.step = "before"
        let waiting = Date()
        var last = Date()
        while harness.windows.isEmpty, process.isRunning, Date().timeIntervalSince(waiting) < 600 {
            try await Task.sleep(for: .milliseconds(700))
            try await recorder.frame(Date().timeIntervalSince(last), speed: 10)
            last = Date()
        }
        if let opened = harness.windows.first {
            try await opened.ready()
            opened.webView.window?.setContentSize(NSSize(width: Self.width, height: Self.height))
            recorder.webView = opened.webView
            try await recorder.run(Self.helpers + "await sleep(400);")
            recorder.step = "window"
            try await recorder.watch(turns: nil, speed: 10, timeout: 900, also: { !process.isRunning })
        } else {
            recorder.notes.append("没有开出新窗口")
        }
        if process.isRunning { process.terminate() }
        try await Task.sleep(for: .milliseconds(500))
        pipe.fileHandleForReading.readabilityHandler = nil
        try? output.close()
        try? timed.close()
        try await recorder.run("await settle(800);")
        recorder.caption = "做了什么都记在「外部 Agent 的操作」里"
        recorder.step = "done"
        try await recorder.frame(2.0)
        // 一页一页翻过去看它排的
        let pages = try await recorder.run("return document.getElementById(\"filmstrip\").children.length;") as? Int ?? 1
        for page in 1..<min(pages, 5) {
            recorder.step = "flip-\(page)"
            try await recorder.click("下一张", within: "预览", lead: 0.6, after: "await settle(400);", hold: 1.2)
        }

        try await recorder.finish()
        await harness.tearDown()
        try? FileManager.default.removeItem(at: config.directory)
        #expect(recorder.frames.count > 5)
    }
}
