import AppKit
import Foundation
import Testing

/// 窗口缩到最小时界面还排得下：Mac 的最小窗口是 1100 × 720（`main.swift`），Windows 的是 900 × 650（`windows/main.cjs`，
/// 顶栏还多两个导出按钮）。顶栏的按钮不互相压住，格式条的字号按钮加减号在字母右上，检查器的分段控件不被截断，
/// AI 助手还没有对话时说明、快捷命令、输入框都留在面板里。
@MainActor
struct MinWindowLayoutTests {
    /// 量一遍界面：按钮有没有压在一起、有没有跑出窗口
    static let measure = AISessionTests.helpers + """
        window.box = (node) => { const r = node.getBoundingClientRect(); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height }; };
        window.shownIn = (selector) => [...document.querySelectorAll(selector)].filter((node) => node.getClientRects().length > 0);
        window.overlaps = (nodes) => {
          const boxes = nodes.map(box);
          const pairs = [];
          for (let a = 0; a < boxes.length; a += 1) for (let b = a + 1; b < boxes.length; b += 1) {
            if (nodes[a].contains(nodes[b]) || nodes[b].contains(nodes[a])) continue;
            const wide = Math.min(boxes[a].right, boxes[b].right) - Math.max(boxes[a].left, boxes[b].left);
            const tall = Math.min(boxes[a].bottom, boxes[b].bottom) - Math.max(boxes[a].top, boxes[b].top);
            if (wide > 1 && tall > 1) pairs.push(`${nodes[a].id || nodes[a].textContent.trim()} × ${nodes[b].id || nodes[b].textContent.trim()}`);
          }
          return pairs;
        };
        window.layout = async () => {
          await mc.render.pages();
          await wait(300);
          const titlebar = shownIn(".titlebar-leading > *, .layout-mode-switch, .titlebar-trailing > button, #exportActions > button");
          const sign = document.querySelector(".format-size .format-size-sign");
          const letter = box(sign.parentElement);
          const density = document.querySelector('[aria-label="排版密度"]');
          return {
            width: innerWidth, height: innerHeight,
            titlebarOverlaps: overlaps(titlebar),
            titlebarOutside: titlebar.filter((node) => box(node).right > innerWidth + 1 || box(node).left < -1).map((node) => node.id),
            formatBarHeight: box(document.querySelector(".format-bar")).height,
            // 加减号在字母右上：比按钮的中线高，在按钮右半边
            signAbove: box(sign).bottom <= letter.top + letter.height / 2 + 2,
            signRight: box(sign).left >= letter.left + letter.width / 2 - 2,
            densityClipped: density.scrollWidth > density.clientWidth + 1
              || [...density.children].some((button) => box(button).right > box(density).right + 1),
          };
        };
        window.aiLayout = async () => {
          await openAI();
          await wait(400);
          const panel = box(document.querySelector("#aiPanel"));
          const empty = document.querySelector("#aiEmpty");
          const parts = shownIn("#aiPanel .ai-session-head, #aiEmpty > *, #aiPresets .ai-presets-bar, #aiPresets .ai-presets-body, #aiComposer");
          return {
            composerBottom: box(document.querySelector("#aiComposer")).bottom,
            panelBottom: panel.bottom,
            emptyOverflows: empty.scrollHeight > empty.clientHeight + 1,
            overlaps: overlaps(parts),
            presetsShown: shownIn("#aiPresets .ai-presets-body button").length,
            polish: box(ui.find("一键润色全文")).height > 0,
          };
        };
    """

    private func check(_ result: [String: Any]?, _ ai: [String: Any]?, oneRowFormatBar: Bool) {
        #expect(result?["titlebarOverlaps"] as? [String] == [], "顶栏的按钮不互相压住")
        #expect(result?["titlebarOutside"] as? [String] == [], "顶栏的按钮都在窗口里")
        if oneRowFormatBar {
            #expect((result?["formatBarHeight"] as? Double ?? .infinity) < 56, "格式条是一行：\(result?["formatBarHeight"] ?? "")")
        }
        #expect(result?["signAbove"] as? Bool == true && result?["signRight"] as? Bool == true, "字号按钮的加减号在字母右上")
        #expect(result?["densityClipped"] as? Bool == false, "「排版密度」三段都看得全")
        let composerBottom = ai?["composerBottom"] as? Double ?? .infinity
        #expect(composerBottom <= (result?["height"] as? Double ?? 0), "输入框在窗口里：\(composerBottom)")
        #expect(ai?["emptyOverflows"] as? Bool == false, "说明放不下时让位，不溢出")
        #expect(ai?["overlaps"] as? [String] == [], "会话栏、说明、快捷命令、输入框不互相压住")
        #expect((ai?["presetsShown"] as? Int ?? 0) > 0 && ai?["polish"] as? Bool == true, "快捷命令还在")
    }

    @Test("Mac 的最小窗口 1100 × 720：顶栏、一行的格式条、检查器、还没有对话的 AI 助手都排得下")
    func macMinimumWindow() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["好"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        harness.webView.window?.setContentSize(NSSize(width: 1100, height: 720))
        try await harness.load()
        let result = try await harness.evaluate(Self.measure + """
            await mc.drafts.create({ title: "周末去湖边", markdown: "# 周末去湖边\\n\\n早上七点出门。" });
            return await layout();
        """) as? [String: Any]
        let ai = try await harness.evaluate("return await aiLayout();") as? [String: Any]
        await harness.tearDown()

        #expect(result?["width"] as? Double == 1100 && result?["height"] as? Double == 720)
        check(result, ai, oneRowFormatBar: true)
        #expect(harness.pageErrors == [])
    }

    @Test("Windows 的最小窗口 900 × 650、顶栏多两个导出按钮：按钮不压在一起，AI 助手的输入框还在窗口里")
    func windowsMinimumWindow() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["好"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        harness.webView.window?.setContentSize(NSSize(width: 900, height: 650))
        try await harness.load()
        let result = try await harness.evaluate(Self.measure + """
            // Windows 的壳往顶栏加的两个按钮（windows/renderer/media-ui.js）
            const send = document.getElementById("sendToIPhoneBtn");
            for (const format of ["MP4", "GIF"]) {
              const button = Object.assign(document.createElement("button"), { type: "button", className: "pill-button", id: `motion${format}` });
              button.append(Object.assign(document.createElement("span"), { textContent: "导出 " }), format);
              send.before(button);
            }
            await mc.drafts.create({ title: "周末去湖边", markdown: "# 周末去湖边\\n\\n早上七点出门。" });
            return await layout();
        """) as? [String: Any]
        let ai = try await harness.evaluate("return await aiLayout();") as? [String: Any]
        await harness.tearDown()

        #expect(result?["width"] as? Double == 900 && result?["height"] as? Double == 650)
        check(result, ai, oneRowFormatBar: false)
        #expect(harness.pageErrors == [])
    }
}
