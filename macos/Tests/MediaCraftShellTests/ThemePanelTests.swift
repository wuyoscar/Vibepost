import Foundation
import Testing

/// 主题面板：每个主题一格，缩略图是当前稿子第一页换成这个主题的样子，并预告换过去是几页；
/// 缩略图停手后才逐个生成、按稿子缓存，不跟打字抢主线程。
@MainActor
struct ThemePanelTests {
    /// 窗口在屏幕外时连环定时器会被节流到一秒一次；要准时的等待用消息来回转。
    static let pause = """
        window.pause = (ms) => new Promise((resolve) => {
          const until = performance.now() + ms;
          const channel = new MessageChannel();
          channel.port1.onmessage = () => (performance.now() >= until ? resolve() : channel.port2.postMessage(0));
          channel.port2.postMessage(0);
        });
    """

    static let helpers = ThemeTests.helpers + pause + """
        window.waitFor = async (condition, timeout = 20000) => {
          const start = performance.now();
          while (!condition()) {
            if (performance.now() - start > timeout) throw new Error("等不到：" + condition);
            await pause(50);
          }
        };
        window.tile = (id) => themeGroup().querySelector(`[data-theme="${id}"]`);
        // 格子的描述：主题说明 + 换过去的页数
        window.tilePages = (option) => document.getElementById(option.getAttribute("aria-describedby").split(" ")[1]).textContent;
        window.busy = () => themeGroup().getAttribute("aria-busy") === "true";
        window.thumbnailsReady = async () => {
          ui.click("样式");
          await waitFor(() => themeGroup().getAttribute("aria-busy") === "false");
        };
        window.thumbPixels = (option) => {
          const canvas = option.querySelector("canvas");
          return [...canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data];
        };
        // 把一张卡片缩成和格子里一样大，逐像素比
        window.shrinkLike = (option, source) => {
          const size = option.querySelector("canvas");
          const canvas = document.createElement("canvas");
          canvas.width = size.width;
          canvas.height = size.height;
          const context = canvas.getContext("2d");
          context.imageSmoothingQuality = "high";
          context.drawImage(source, 0, 0, canvas.width, canvas.height);
          return [...context.getImageData(0, 0, canvas.width, canvas.height).data];
        };
        window.meanDiff = (a, b) => a.reduce((sum, value, index) => sum + Math.abs(value - b[index]), 0) / a.length;
    """

    @Test("缩略图是当前稿子第一页换成各主题的样子，页数预告与真正换过去一致；当前主题带着颜色微调；改稿后跟着更新")
    func thumbnailsAndPageCountsFollowTheDraft() async throws {
        try BundledFontsTests.requireBundledFonts()
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "# 缩略图\\n\\n" + longDraft(30) });
            await thumbnailsReady();
            const themes = await mc.themes.list();
            const now = (await mc.render.pages()).length;
            const shown = Object.fromEntries(themes.map((theme) => [theme.id, { pages: tilePages(tile(theme.id)), pixels: thumbPixels(tile(theme.id)) }]));
            // 真正换过去：页数与第一页
            const actual = {};
            for (const theme of themes) {
              await mc.themes.apply(theme.id);
              const count = (await mc.render.pages()).length;
              const [first] = await mc.render.canvases();
              actual[theme.id] = { count, diff: meanDiff(shown[theme.id].pixels, shrinkLike(tile(theme.id), first)) };
            }
            const whiteVsNight = meanDiff(shown.notes.pixels, shown.ink.pixels);

            // 当前主题（陶土）微调底色：只有它的缩略图跟着变
            await mc.themes.apply("clay");
            await mc.drafts.update({ colors: { bg: "#ffe0e0" } });
            await thumbnailsReady();
            const tunedCorner = thumbPixels(tile("clay")).slice(0, 3);
            const whiteCorner = thumbPixels(tile("notes")).slice(0, 3);

            // 改稿：页数与缩略图跟着换
            await mc.drafts.update({ markdown: "# 改过了\\n\\n短短一段。" });
            await thumbnailsReady();
            const edited = themes.map((theme) => ({
              pages: tilePages(tile(theme.id)),
              changed: meanDiff(shown[theme.id].pixels, thumbPixels(tile(theme.id))) > 3,
            }));
            return { now, shown: Object.fromEntries(Object.entries(shown).map(([id, value]) => [id, value.pages])), actual, whiteVsNight, tunedCorner, whiteCorner, edited };
        """) as? [String: Any]
        await harness.tearDown()

        let now = result?["now"] as? Int ?? 0
        let shown = result?["shown"] as? [String: String] ?? [:]
        let actual = result?["actual"] as? [String: [String: Double]] ?? [:]
        #expect(now >= 4, "稿子要排好几页")
        #expect(actual.count == ThemeTests.ids.count)
        for (id, truth) in actual {
            let count = Int(truth["count"] ?? 0)
            let expected = id == "notes" || count == now ? "\(now) 页" : "\(now) → \(count) 页"
            #expect(shown[id] == expected, "\(id)：预告「\(shown[id] ?? "")」，换过去是 \(count) 页")
            #expect((truth["diff"] ?? 99) < 1.5, "\(id)：缩略图就是换过去的第一页（平均差 \(truth["diff"] ?? 0)）")
        }
        #expect(shown.values.contains { $0.contains("→") }, "这篇稿子换主题后页数会变：\(shown)")
        #expect((result?["whiteVsNight"] as? Double ?? 0) > 40, "备忘与纯黑的缩略图明显不同")
        #expect(result?["tunedCorner"] as? [Int] == [255, 224, 224], "当前主题的缩略图带着颜色微调")
        #expect(result?["whiteCorner"] as? [Int] == [255, 255, 255], "别的主题换过去会重置微调，缩略图用主题配色")
        let edited = result?["edited"] as? [[String: Any]] ?? []
        #expect(edited.count == ThemeTests.ids.count && edited.allSatisfy { $0["pages"] as? String == "1 页" }, "\(edited)")
        #expect(edited.allSatisfy { $0["changed"] as? Bool == true }, "改稿后缩略图都换了")
        #expect(harness.pageErrors == [])
    }

    @Test("缩略图停手后才逐个生成：按键时停下；生成时每次只占主线程一小会；生成到一半改稿，出图照常不用等")
    func thumbnailsNeverBlockTyping() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            // 一篇重稿子：长文、表格、代码与三张大图
            await mc.drafts.create({ markdown: "占位" });
            const png = (width, height, hue) => new Promise((resolve) => {
              const canvas = document.createElement("canvas");
              canvas.width = width;
              canvas.height = height;
              const context = canvas.getContext("2d");
              for (let y = 0; y < height; y += 40) {
                context.fillStyle = `hsl(${hue + y / 10}, 60%, 60%)`;
                context.fillRect(0, y, width, 40);
              }
              canvas.toBlob((blob) => resolve(new File([blob], `图${hue}.png`, { type: "image/png" })), "image/png");
            });
            const ids = await mc.media.import([await png(2400, 1800, 10), await png(1800, 2400, 140), await png(2000, 2000, 260)], { at: 0 });
            const images = ids.map((id) => `[[image:${id}]]`);
            const heavy = [
              "# 一篇重稿子", images[0], longDraft(20), "| 列一 | 列二 |\\n| --- | --- |\\n| 甲 | 乙 |", images[1],
              "```\\nconst answer = 42;\\n```", longDraft(20), images[2], longDraft(10),
            ].join("\\n\\n");
            const edit = async (markdown) => {
              const start = performance.now();
              await mc.drafts.update({ markdown });
              return performance.now() - start;
            };
            const filled = () => themeOptions().filter((option) => tilePages(option) !== "").length;
            await edit(heavy);
            await thumbnailsReady();
            const idleEdit = await edit(heavy + "\\n\\n不在生成时改稿。");
            await thumbnailsReady();

            // 一直在按键：一张都不生成；停手后全部补上
            await edit(heavy + "\\n\\n改一下。");
            await waitFor(() => filled() === 1); // 改稿后先只有当前主题（直接用预览的第一页）
            const editor = document.querySelector('[aria-label="正文"]'); // 编辑器的正文区（contenteditable）
            for (let index = 0; index < 12; index += 1) {
              editor.dispatchEvent(new KeyboardEvent("keydown", { key: "Shift", bubbles: true }));
              await pause(120);
            }
            const whileTyping = filled();
            await thumbnailsReady();
            const afterTyping = filled();

            // 生成期间主线程最长被占多久：MessageChannel 一直来回发消息，量相邻两次之间的空档
            await edit(heavy + "\\n\\n再改一下。");
            await waitFor(busy);
            const channel = new MessageChannel();
            let last = performance.now();
            let longest = 0;
            let pinging = true;
            channel.port1.onmessage = () => {
              const now = performance.now();
              longest = Math.max(longest, now - last);
              last = now;
              if (pinging) channel.port2.postMessage(0);
            };
            channel.port2.postMessage(0);
            await thumbnailsReady();
            pinging = false;

            // 生成到一半（第三格刚出来）时改稿：出图用时和平时差不多，改完后缩略图按新稿子重新生成
            await edit(heavy + "\\n\\n又改一下。");
            const midEdit = await new Promise((resolve) => {
              const observer = new MutationObserver(() => {
                if (filled() < 3) return;
                observer.disconnect();
                resolve(edit(heavy + "\\n\\n最后一版，短一点。"));
              });
              observer.observe(themeGroup(), { subtree: true, characterData: true, childList: true });
            });
            const busyAfterMidEdit = busy();
            await thumbnailsReady();
            const final = (await mc.render.pages()).length;
            const current = tilePages(tile("notes"));
            return { idleEdit, whileTyping, afterTyping, longest, midEdit, busyAfterMidEdit, final, current };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["whileTyping"] as? Int == 1, "一直在按键时不生成缩略图")
        #expect(result?["afterTyping"] as? Int == ThemeTests.ids.count, "停手后每个主题都补上")
        let longest = result?["longest"] as? Double ?? 999
        #expect(longest < 120, "生成缩略图时主线程最长只被占 \(Int(longest)) ms")
        let idleEdit = result?["idleEdit"] as? Double ?? 0
        let midEdit = result?["midEdit"] as? Double ?? 999
        #expect(midEdit < idleEdit * 2 + 150, "生成到一半改稿：出图 \(Int(midEdit)) ms，平时 \(Int(idleEdit)) ms")
        #expect(result?["busyAfterMidEdit"] as? Bool == true, "改稿后按新稿子重新生成")
        let final = result?["final"] as? Int ?? 0
        #expect(result?["current"] as? String == "\(final) 页")
        #expect(harness.pageErrors == [])
    }
}
