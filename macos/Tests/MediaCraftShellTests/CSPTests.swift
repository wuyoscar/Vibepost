import Foundation
import Testing

/// 内容安全策略（index.html 的 CSP）：页面带着它照常启动，一串常用功能（新手引导、编辑器、图片、实况预览、主题、字体、
/// AI 助手、手机预览、导出 PNG / ZIP、长文长图）走下来一次违反都没有；策略确实生效（外链图片、eval 挡得住）。
/// 每个 harness 都把 securitypolicyviolation 记进 pageErrors，所以全部测试的 `pageErrors == []` 也都在查 CSP。
/// 用到实况视频，挂在串行的 SendLivePhotoTests 下。
@MainActor
extension SendLivePhotoTests {
    @Test("CSP：页面带着内容安全策略启动，常用功能一次违反都没有；外链图片与 eval 被挡下")
    func contentSecurityPolicyHoldsDuringSmokeFlow() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const violations = [];
            document.addEventListener("securitypolicyviolation", (event) => violations.push(`${event.effectiveDirective} ${event.blockedURI}`));
            const policy = document.querySelector('meta[http-equiv="Content-Security-Policy"]')?.content ?? "";
            const png = (color, name) => new Promise((resolve) => {
              const canvas = document.createElement("canvas");
              canvas.width = 300;
              canvas.height = 200;
              const context = canvas.getContext("2d");
              context.fillStyle = color;
              context.fillRect(0, 0, 300, 200);
              canvas.toBlob((blob) => resolve(new File([blob], name, { type: "image/png" })), "image/png");
            });

            // 新手引导（新环境会弹）
            const tour = Boolean(ui.dialogs().find((dialog) => dialog.textContent.includes("新手引导")));
            ui.click("跳过");

            // 编辑器打字、图片、主题、字体
            await mc.drafts.create({ title: "CSP", markdown: "# 标题\\n\\n正文 **加粗**\\n" });
            await mc.editor.select(0);
            document.execCommand("insertText", false, "开头");
            await until(async () => (await mc.drafts.current()).markdown.startsWith("开头"));
            await mc.media.import([await png("#2a9d8f", "图.png")], { at: 0 });
            await mc.themes.apply("clay");
            await mc.drafts.update({ fonts: { zh: "noto-serif-sc" } });
            await document.fonts.ready;
            const fonts = [...document.fonts].filter((font) => font.status === "loaded").length;

            // AI 助手（原生桥）、手机预览
            ui.click("AI 助手");
            await until(() => ui.find("重新查找"));
            ui.click("手机预览");
            await until(() => !document.getElementById("phonePreview").hidden);

            // 导出：一页 PNG、整组 ZIP（JSZip）
            const exported = [(await mc.output.exportPng(0)).filename, (await mc.output.exportZip()).filename];

            // 实况：插进去，舞台上的预览视频（blob:）载得出来
            await mc.media.insertLivePhoto(await liveFile(h264), { at: 0 });
            await mc.render.pages();
            await until(() => document.querySelector(".stage-live-video")?.readyState >= 1);

            // 长文长图（html2canvas）
            const long = (await mc.output.exportLongImage()).filename;

            const before = [...violations];

            // 策略确实生效：外链图片与 eval 都被挡下，也报得出来
            const image = new Image();
            image.src = "https://example.com/csp-probe.png";
            let evalBlocked = false;
            try {
              eval("1");
            } catch (error) {
              evalBlocked = error instanceof EvalError;
            }
            await until(() => violations.some((item) => item.startsWith("img-src")));
            return { policy, tour, fonts, exported, long, before, evalBlocked, probes: violations.slice(before.length) };
        """, arguments: ["h264": Self.h264]) as? [String: Any]
        // 最后两次是故意的（外链图片、eval），不算页面的错
        let errorsBeforeProbe = harness.pageErrors.filter {
            !$0.hasPrefix("csp: img-src https://example.com/csp-probe.png") && !$0.hasPrefix("csp: script-src eval")
        }
        await harness.tearDown()

        let policy = result?["policy"] as? String ?? ""
        for directive in [
            "script-src 'self'", "style-src 'self' 'unsafe-inline'", "img-src 'self' data: blob:", "media-src 'self' data: blob:",
            "font-src 'self' data:", "connect-src 'self'", "object-src 'none'", "frame-src 'none'",
        ] {
            #expect(policy.contains(directive), "策略里有 \(directive)")
        }
        #expect(result?["tour"] as? Bool == true, "新手引导照常弹出")
        #expect((result?["fonts"] as? Int ?? 0) > 0, "打包字体载得进来")
        #expect((result?["exported"] as? [String])?.count == 2)
        #expect((result?["long"] as? String)?.hasSuffix(".png") == true, "长文长图照常导出")
        #expect(result?["before"] as? [String] == [], "常用功能一次违反都没有")
        #expect(errorsBeforeProbe == [], "页面没有报错")
        #expect(result?["evalBlocked"] as? Bool == true, "eval 被挡下")
        let probes = result?["probes"] as? [String] ?? []
        #expect(probes.contains { $0.hasPrefix("img-src https://example.com/csp-probe.png") }, "外链图片被挡下并报出来：\(probes)")
    }
}
