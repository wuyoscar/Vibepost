import Foundation
import Testing

/// 推理强度：AI 助手里模型旁边的选单，档位来自这篇的后端与模型（Codex 问 model/list，Claude Code 固定 low…max），
/// 每篇各记各的、新稿子是「中」；换了模型不支持原来那档时退回 medium，没有 medium 时退回模型自己的默认档；
/// 真的作用到这一轮（Codex 的 turn/start 带 effort，Claude Code 带 --effort）。
@MainActor
struct EffortTests {
    static let helpers = """
        window.effortSelect = () => document.querySelector("#aiEffortSelect");
        window.effortOptions = () => [...effortSelect().options].map((option) => [option.value, option.textContent]);
        window.pickEffort = async (value) => {
          effortSelect().value = value;
          effortSelect().dispatchEvent(new Event("change", { bubbles: true }));
          await until(async () => (await mc.ai.effort()).effort === value);
        };
    """

    @Test("Codex：档位来自模型（model/list），新稿子是「中」；选「高」后这一轮的 turn/start 带 effort；换模型不支持时退回 medium、再退回模型默认档；每篇各记各的")
    func codexEffortFollowsModel() async throws {
        let codex = try FakeCodex(script: FakeCodex.reply("好的"))
        defer { codex.remove() }
        let harness = ShellHarness(terminalPath: [codex.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(AICodexTests.helpers + Self.helpers + """
            const first = await mc.drafts.create({ markdown: "甲\\n" });
            await openAI();
            await until(() => effortOptions().length === 6);
            const fresh = { options: effortOptions(), selected: effortSelect().value, info: await mc.ai.effort() };
            await pickEffort("high");
            ask("想深一点");
            await until(() => finished(1));
            await mc.ai.setModel("gpt-fake-mini");
            const onMini = await mc.ai.effort();
            await mc.ai.setModel("gpt-fake-large");
            await mc.ai.setEffort("max");
            await mc.ai.setModel("gpt-fake-mini");
            const fallback = await mc.ai.effort();
            const rejected = [];
            for (const value of ["ultra", "Max", "--model"]) await mc.ai.setEffort(value).catch((error) => rejected.push(error.message));
            // 新稿子沿用上次选的模型：换回大模型再新建，看它是不是从「中」开始
            await mc.ai.setModel("gpt-fake-large");
            await mc.drafts.create({ markdown: "另一篇\\n" });
            const other = await mc.ai.effort();
            await mc.drafts.open(first.id);
            await mc.ai.setModel("gpt-fake-mini");
            return { fresh, onMini, fallback, rejected, other, back: await mc.ai.effort() };
        """) as? [String: Any]
        let turnStart = codex.params(0, "turn/start")
        await harness.tearDown()

        let fresh = result?["fresh"] as? [String: Any]
        #expect((fresh?["options"] as? [[String]])?.map { $0[1] } == ["推理：低", "推理：中", "推理：高", "推理：很高", "推理：最高", "推理：极限"])
        #expect(fresh?["selected"] as? String == "medium", "新稿子是「中」")
        #expect(turnStart?["effort"] as? String == "high", "选的那档作用到这一轮：\(turnStart ?? [:])")
        #expect((result?["onMini"] as? [String: Any])?["effort"] as? String == "high", "换到小模型：它也支持「高」")
        #expect((result?["onMini"] as? [String: Any])?["efforts"] as? [String] == ["low", "high"])
        #expect((result?["fallback"] as? [String: Any])?["effort"] as? String == "high", "小模型不支持 max、也没有 medium：退回它自己的默认档")
        let rejected = result?["rejected"] as? [String] ?? []
        #expect(rejected.count == 3 && rejected[0].contains("low / high"), "\(rejected)")
        #expect((result?["other"] as? [String: Any])?["effort"] as? String == "medium", "每篇各记各的 \(result?["other"] ?? "")")
        #expect((result?["back"] as? [String: Any])?["effort"] as? String == "high")
        #expect(harness.pageErrors == [])
    }

    @Test("Claude Code：固定 low / medium / high / xhigh / max，新稿子带 --effort medium；选「很高」后下一轮带 --effort xhigh")
    func claudeEffortIsPassed() async throws {
        let fake = try FakeClaude(script: StreamJSON.reply(["好的。"]))
        defer { fake.remove() }
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(AISessionTests.helpers + Self.helpers + """
            await mc.drafts.create({ markdown: "甲\\n" });
            await openAI();
            await until(() => effortOptions().length === 5);
            const options = effortOptions().map(([value]) => value);
            ask("第一轮");
            await until(() => finished(1));
            await pickEffort("xhigh");
            ask("第二轮");
            await until(() => finished(2));
            return { options };
        """) as? [String: Any]
        let calls = fake.calls()
        await harness.tearDown()

        #expect(result?["options"] as? [String] == ["low", "medium", "high", "xhigh", "max"])
        #expect(calls.count == 2)
        #expect(FakeClaude.option("--effort", in: calls.first ?? [:]) == "medium")
        #expect(FakeClaude.option("--effort", in: calls.last ?? [:]) == "xhigh", "\((calls.last?["argv"] as? [String]) ?? [])")
        #expect(harness.pageErrors == [])
    }
}
