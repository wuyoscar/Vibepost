import AppKit
import Foundation
import Testing
import WebKit

/// 给人看：把写作一侧走一遍，每一步存一张整窗截图（浅色 / 深色 / Mac 最小窗口 / Windows 最小窗口）。
/// 只在设了 `WRITING_WALK_DIR`（存到哪个目录）时跑，不做断言：打磨界面前后各跑一次，对着图看。
///   WRITING_WALK_DIR=/绝对路径 macos/run-tests.sh --filter WritingWalkthroughTests 900
@MainActor
struct WritingWalkthroughTests {
    struct Variant: CustomStringConvertible, Sendable {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let dark: Bool
        var description: String { name }
    }

    static let variants = [
        Variant(name: "light", width: 1440, height: 960, dark: false),
        Variant(name: "dark", width: 1440, height: 960, dark: true),
        Variant(name: "min-mac", width: 1100, height: 720, dark: false),
        Variant(name: "min-win", width: 900, height: 650, dark: true),
    ]

    static let helpers = AISessionTests.helpers + """
        window.press = (key, modifiers = {}, target = document.activeElement || document.body) => {
          const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...modifiers });
          target.dispatchEvent(event);
          return event.defaultPrevented;
        };
        window.png = (width, height, hue) => new Promise((resolve) => {
          const canvas = Object.assign(document.createElement("canvas"), { width, height });
          const context = canvas.getContext("2d");
          const gradient = context.createLinearGradient(0, 0, width, height);
          gradient.addColorStop(0, `hsl(${hue} 60% 62%)`);
          gradient.addColorStop(1, `hsl(${hue + 60} 55% 38%)`);
          context.fillStyle = gradient;
          context.fillRect(0, 0, width, height);
          canvas.toBlob((blob) => resolve(new File([blob], `photo-${hue}.png`, { type: "image/png" })), "image/png");
        });
        window.settle = async () => { await mc.render.pages(); await wait(350); };
        window.closeMenus = () => { for (const menu of document.querySelectorAll("details.pop-menu[open]")) menu.open = false; };
        window.sample = [
          "# 周末去湖边",
          "",
          "早上七点出门，**八点半**到湖边。风很大，水是灰绿色的。",
          "",
          "## 带了什么",
          "",
          "- 一壶热茶",
          "- 两个饭团",
          "- 一本没看完的书",
          "",
          "> 湖边没有信号，正好。",
          "",
          "1. 先绕湖走一圈，大概四十分钟",
          "2. 找一块背风的石头坐下",
          "3. 这是最好的一次出门，加微信 hubian2026 发你路线",
          "",
          "---",
          "",
          "## 下午",
          "",
          "太阳出来以后水变成了蓝色。坐到三点，茶喝完了才走。回程的车上睡了一路，醒来已经进城。",
          "",
          "下次想带上折叠椅，再带一个人。",
        ].join("\\n");
    """

    @Test("写作一侧走一遍，每步存整窗截图", .enabled(if: ProcessInfo.processInfo.environment["WRITING_WALK_DIR"] != nil), arguments: variants)
    func walkthrough(_ variant: Variant) async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WRITING_WALK_DIR"]!).appendingPathComponent(variant.name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let harness = ShellHarness(onboarding: true, inspectorFolded: true)
        harness.webView.window?.setContentSize(NSSize(width: variant.width, height: variant.height))
        harness.setAppearance(dark: variant.dark)
        var index = 0
        var notes: [String] = []
        func shot(_ name: String) async throws {
            index += 1
            let image = try await harness.webView.takeSnapshot(configuration: WKSnapshotConfiguration())
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try png.write(to: directory.appendingPathComponent(String(format: "%02d-%@.png", index, name)))
        }
        /// 一步：跑一段页面脚本（出错只记下来，接着走），再存一张
        func step(_ name: String, _ script: String) async throws {
            do {
                if let note = try await harness.evaluate(Self.helpers + script) as? String { notes.append("\(name): \(note)") }
            } catch {
                notes.append("\(name): ✗ \(error)")
            }
            try await shot(name)
        }

        try await harness.load()
        try await step("onboarding-1", "await wait(400);")
        try await step("onboarding-2", "ui.click('下一步'); await wait(400);")
        try await step("onboarding-3", "ui.click('下一步'); await wait(400);")
        try await step("onboarding-4", "ui.click('下一步'); await wait(400);")
        try await step("guide-after-onboarding", "ui.click('开始使用'); await settle();")
        try await step("drawer-open", "ui.expand('稿件列表'); await wait(400);")
        try await step("gallery", """
            ui.click('从模板新建');
            const grid = document.getElementById('templateGalleryGrid');
            await until(() => grid.querySelectorAll('.template-tile').length > 0);
            await until(() => grid.getAttribute('aria-busy') === 'false', 120000);
            await wait(300);
        """)
        try await step("gallery-filtered", """
            const chips = [...document.querySelectorAll('#templateGallery [aria-pressed]')];
            chips[2]?.click(); await wait(300);
            return chips.map((chip) => chip.textContent.trim()).join(' | ');
        """)
        try await step("blank-draft", """
            press('Escape', {}, document.getElementById('templateGallery')); await wait(200);
            if (!document.getElementById('templateGallery').classList.contains('hidden')) ui.click('关闭', { within: document.getElementById('templateGallery') });
            ui.click('新建稿件'); await settle();
        """)
        try await step("blank-draft-drawer-closed", "ui.click('稿件列表'); await settle();")
        try await step("written", """
            await mc.drafts.update({ title: '周末去湖边的一天，值得再去一次', markdown: sample, caption: '周末去了一趟湖边，风很大。\\n\\n#周末去哪儿 #湖边 #一个人出门' });
            const files = [await png(2400, 1800, 200), await png(1800, 2400, 20)];
            await mc.media.import(files, { at: sample.indexOf('## 下午') });
            await settle();
        """)
        try await step("style-menu", "ui.find('段落样式').click(); await wait(300);")
        try await step("insert-menu", "closeMenus(); ui.find('插入').click(); await wait(300);")
        try await step("emoji-menu", "closeMenus(); ui.find('插入表情').click(); await wait(300);")
        try await step("slash-menu", """
            closeMenus();
            const text = (await mc.drafts.current()).markdown;
            await mc.editor.select(text.length);
            document.querySelector('#markdownEditor [contenteditable]').focus();
            document.execCommand('insertText', false, '\\n\\n');
            await wait(200);
            document.execCommand('insertText', false, '/');
            await wait(500);
        """)
        try await step("selection-bar", """
            press('Escape'); await wait(100);
            await mc.drafts.undo();
            const text = (await mc.drafts.current()).markdown;
            const at = text.indexOf('风很大');
            await mc.editor.select(at, at + 3);
            document.querySelector('#markdownEditor [contenteditable]').focus();
            document.dispatchEvent(new Event('selectionchange'));
            await wait(500);
            return [...document.querySelectorAll('.floating-bar')].map((bar) => `${bar.id || bar.className}:${bar.hidden}`).join(' ');
        """)
        try await step("find-bar", "ui.click('查找替换'); await wait(200); const input = ui.find('查找', { within: '查找替换' }); input.value = '湖'; input.dispatchEvent(new Event('input', { bubbles: true })); await wait(300);")
        try await step("find-replace", "ui.click('展开替换'); await wait(300);")
        try await step("caption-open", "ui.click('完成', { within: '查找替换' }); document.querySelector('#captionField > summary').click(); await wait(300);")
        try await step("source-mode", "document.querySelector('#captionField > summary').click(); ui.click('源码'); await wait(300);")
        try await step("stage-page-2", "ui.click('源码'); ui.click('下一张'); await settle();")
        try await step("check-panel", "ui.click('检查'); await wait(400);")
        try await step("phone-note", "press('Escape', {}, document.getElementById('publishCheck')); ui.click('手机预览'); await wait(600);")
        try await step("phone-feed", "ui.click('发现页'); await wait(600);")
        try await step("phone-profile", "ui.click('主页'); await wait(600);")
        try await step("send-check", "ui.click('手机预览'); await wait(200); ui.click('发送到 iPhone'); await wait(600);")
        try await step("after-send", """
            const dialog = document.getElementById('sendCheckDialog');
            if (!dialog.classList.contains('hidden')) ui.click('仍然发送');
            await wait(1500);
            return document.getElementById('statusText').textContent;
        """)
        try await step("article", "await mc.drafts.update({ mode: 'article' }); await settle();")
        try await step("article-phone", "ui.click('手机预览'); await wait(600);")
        try await step("draft-context-menu", """
            ui.click('手机预览'); await mc.drafts.update({ mode: 'cards' }); await settle();
            ui.expand('稿件列表'); await wait(300);
            const row = document.querySelector('#draftList [aria-current="true"], #draftList .is-current, #draftList [role="listitem"]');
            row.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 80, clientY: 220 }));
            await wait(300);
        """)
        try await step("save-template-dialog", "ui.click('存为模板…'); await wait(400);")
        try await step("delete-confirm", """
            ui.click('取消', { within: document.getElementById('saveTemplateDialog') }); await wait(200);
            const remove = [...document.querySelectorAll('#draftList button')].find((button) => (button.getAttribute('aria-label') || '').startsWith('删除'));
            remove?.click(); await wait(400);
            return remove ? ui.name(remove) : '没有删除按钮';
        """)
        try await step("search-empty", """
            ui.click('取消', { within: ui.alert() }); await wait(200);
            const search = ui.find('搜索稿件'); search.value = '找不到的字'; search.dispatchEvent(new Event('input', { bubbles: true })); await wait(300);
        """)
        await harness.tearDown()
        try (notes + harness.pageErrors.map { "pageError: \($0)" }).joined(separator: "\n")
            .write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    }
}

