import Foundation
import Testing

/// App API（window.mediacraft）本身的约定：AI 会话与将来的 MCP 服务只靠它，模块重写后也要照旧。
@MainActor
struct AppApiTests {
    @Test("App API：改稿先整体校验、内置说明书只读、撤销重做、删稿，事件在改动与出图后送达")
    func draftsEventsAndGuards() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            const rejects = async (action) => {
              try {
                await action();
                return "";
              } catch (error) {
                return error.message;
              }
            };
            const guide = (await mc.drafts.current()).readOnly;
            const guideEdit = await rejects(() => mc.drafts.update({ markdown: "改说明书" }));
            const keep = await mc.drafts.create({ markdown: "留下" });
            const draft = await mc.drafts.create({ title: "API 稿", markdown: "第一版" });

            const events = [];
            const off = mc.on("change", (detail) => events.push(`change:${detail.draftId === draft.id}`));
            const offRendered = mc.on("rendered", (detail) => events.push(`rendered:${detail.mode}:${detail.pageCount}`));
            await mc.drafts.update({ markdown: "第二版" });
            off();
            offRendered();
            await mc.drafts.update({ markdown: "第三版" });

            const invalid = await rejects(() => mc.drafts.update({ markdown: "不该写进去", colors: { bg: "red" } }));
            const unknown = await rejects(() => mc.drafts.update({ color: "#ffffff" }));
            const afterInvalid = (await mc.drafts.current()).markdown;
            const undone = (await mc.drafts.undo()).markdown;
            const redone = (await mc.drafts.redo()).markdown;

            await mc.drafts.remove(draft.id);
            const remaining = (await mc.drafts.list()).filter((item) => !item.builtIn).map((item) => item.id);
            return {
              version: mc.version,
              guide, guideEdit: guideEdit !== "",
              title: (await mc.drafts.get(keep.id)).title === "" && draft.title === "API 稿",
              events,
              invalid: invalid !== "", unknown: unknown !== "", afterInvalid, undone, redone,
              remaining: JSON.stringify(remaining) === JSON.stringify([keep.id]),
              current: (await mc.drafts.current()).id === keep.id,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["version"] as? String == "5")
        #expect(result?["guide"] as? Bool == true, "新环境打开的是内置说明书")
        #expect(result?["guideEdit"] as? Bool == true, "内置说明书不能改")
        #expect(result?["title"] as? Bool == true)
        #expect(result?["events"] as? [String] == ["change:true", "rendered:cards:1"], "改动存盘后发 change，画完发 rendered；取消订阅后不再收到")
        #expect(result?["invalid"] as? Bool == true)
        #expect(result?["unknown"] as? Bool == true)
        #expect(result?["afterInvalid"] as? String == "第三版", "校验不过时什么都不改")
        #expect(result?["undone"] as? String == "第二版")
        #expect(result?["redone"] as? String == "第三版")
        #expect(result?["remaining"] as? Bool == true)
        #expect(result?["current"] as? Bool == true, "删掉当前稿子后打开下一篇")
        #expect(harness.pageErrors == [])
    }

    @Test("App API：导出单页、整组、长图都存进下载文件夹，文件名以标题开头")
    func exportsThroughTheSavePath() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create({ title: "接口导出", markdown });
            return {
              png: (await mc.output.exportPng(0)).filename,
              zip: (await mc.output.exportZip()).filename,
              long: (await mc.output.exportLongImage()).filename,
              mode: (await mc.drafts.current()).mode,
            };
        """, arguments: ["markdown": SendToIPhoneTests.markdown]) as? [String: String]
        let saved = try FileManager.default.contentsOfDirectory(atPath: harness.downloadsDirectory.path).sorted()
        await harness.tearDown()

        #expect(result == ["png": "接口导出-01.png", "zip": "接口导出.zip", "long": "接口导出.png", "mode": "article"])
        #expect(saved == ["接口导出-01.png", "接口导出.png", "接口导出.zip"])
        #expect(harness.pageErrors == [])
    }
}
