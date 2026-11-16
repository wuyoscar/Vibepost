import Foundation
import Testing

/// 在 App 里填的接口（AI 设置 ›「接别家的模型」›「接口」）：一家服务商的密钥，或一个 OpenAI 兼容的接口地址加模型名。
/// 壳把它们存在本机（只有本人可读），起 OpenCode 时写成内联配置（OPENCODE_CONFIG_CONTENT）带给它、密钥各放一个环境变量；
/// 密钥只进不出，别的后端拿不到，出错信息里的密钥打码。OpenCode 换成假的可执行文件（Fixtures/ai/fake-acp），它记下收到的环境变量。
@MainActor
struct AIProvidersTests {
    static let helpers = AIACPTests.helpers("OpenCode") + """
        window.form = { within: "接口的设置" };
        window.type = (name, text) => {
          const input = ui.find(name, form);
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        };
        window.choose = (value) => {
          const select = ui.find("服务商", form);
          select.value = value;
          select.dispatchEvent(new Event("change", { bubbles: true }));
        };
        window.formError = () => {
          const node = document.querySelector("#aiProviderError");
          return node.hidden ? "" : node.textContent;
        };
        window.rows = () => [...document.querySelectorAll("#aiProviderList > li")].map((row) => row.innerText.replace(/\\s+/g, " ").trim());
        window.openProviders = async () => {
          ui.expand("AI 设置");
          ui.expand("接别家的模型");
          await until(() => ui.find("加一个接口"));
        };
    """

    private static func config(_ call: [String: Any]) -> [String: Any] {
        let text = (call["env"] as? [String: String])?["OPENCODE_CONFIG_CONTENT"] ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    @Test("在 AI 设置里填接口：预设的服务商只填密钥，自定义接口填地址和模型名；存完模型出现在 OpenCode 的选单里，起 OpenCode 时带上内联配置（并进用户原有的）与各家的密钥；密钥只进不出、存的文件只有本人可读、出错信息里打码；别的后端拿不到")
    func providersReachOpenCodeOnly() async throws {
        let agent = try FakeACP(script: [#"#stderr-env "VIBEPOST_API_KEY_1""#] + FakeACP.reply("好的"))
        let omp = try FakeACP(program: "omp")
        defer { agent.remove(); omp.remove() }
        let harness = ShellHarness(
            terminalPath: [agent.directory, omp.directory], onboarding: false,
            terminalVariables: ["OPENCODE_CONFIG_CONTENT": #"{"theme":"dark","provider":{"theirs":{"options":{"timeout":5}}}}"#]
        )
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "甲\\n" });
            await mc.ai.setBackend("opencode");
            await openAI();
            const exits = [];
            window.addEventListener("mediacraft:native-ai", (event) => {
              if (event.detail.type === "exit") exits.push(event.detail.stderr);
            });
            const before = (await mc.ai.models("opencode")).map((model) => model.id);
            await openProviders();

            // 预设的服务商：只有服务商和密钥两栏，不填密钥存不了
            ui.click("加一个接口");
            const presets = [...ui.find("服务商", form).options].map((option) => option.value);
            choose("deepseek");
            const presetFields = ["名字", "接口地址", "模型名", "密钥"].filter((name) => ui.find(name, form));
            ui.click("保存接口");
            await until(() => formError());
            const noKey = formError();
            type("密钥", "sk-deepseek-secret-1");
            ui.click("保存接口");
            await until(() => ui.find("修改", { within: "DeepSeek" }));

            // 自定义接口：名字、地址、模型名、密钥；填过的服务商不再出现在选单里
            ui.click("加一个接口");
            const remaining = [...ui.find("服务商", form).options].map((option) => option.value);
            choose("custom");
            type("名字", "公司的接口");
            type("接口地址", "api.example.com/v1");
            type("模型名", "model-a, org/model-b");
            type("密钥", "sk-custom-secret-2");
            ui.click("保存接口");
            await until(() => formError());
            const badAddress = formError();
            type("接口地址", "https://api.example.com/v1");
            ui.click("保存接口");
            await until(() => ui.find("修改", { within: "公司的接口" }));
            const shown = rows();
            const listed = await mc.ai.providers();
            const keyLeft = document.querySelector("#aiProviderKey").value;

            // 存完模型选单重新问：自定义接口的模型在里面
            await until(() => [...ui.find("模型").options].some((option) => option.value === "my-api/model-a"));
            const after = (await mc.ai.models("opencode")).map((model) => model.id);
            document.querySelector("#aiSettings").open = false;
            ask("你好");
            await until(() => finished(1));

            // 改：服务商不能换；换了接口地址不重新填密钥存不了
            await openProviders();
            ui.click("修改", { within: "公司的接口" });
            const editing = { preset: ui.find("服务商", form).disabled, placeholder: ui.find("密钥", form).placeholder, url: ui.find("接口地址", form).value };
            type("接口地址", "https://other.example.com/v1");
            ui.click("保存接口");
            await until(() => formError());
            const moved = formError();
            ui.click("取消");

            // 删：点两下
            ui.click("删除", { within: "DeepSeek" });
            const armed = ui.find("确定删除", { within: "DeepSeek" }) !== null;
            ui.click("确定删除", { within: "DeepSeek" });
            await until(() => rows().length === 1);
            const left = await mc.ai.providers();
            document.querySelector("#aiSettings").open = false;

            // 别的后端拿不到
            await mc.drafts.create({ markdown: "乙\\n" });
            await mc.ai.setBackend("omp");
            await until(() => ui.find("问 Oh My Pi") && !ui.find("问 Oh My Pi").disabled);
            const input = ui.find("问 Oh My Pi");
            input.value = "你好";
            input.dispatchEvent(new Event("input", { bubbles: true }));
            input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
            await until(async () => {
              const { running, messages } = await mc.ai.history();
              return !running && messages.some((message) => message.role === "end");
            });
            return { before, presets, presetFields, noKey, remaining, badAddress, shown, listed, keyLeft, after, exits, editing, moved, armed, left };
        """) as? [String: Any]

        let file = harness.aiRoot.appendingPathComponent("providers.json")
        let stored = try String(contentsOf: file, encoding: .utf8)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        await harness.tearDown()

        #expect(result?["before"] as? [String] == ["fake/large", "fake/mini"], "没填接口时只有它自己的模型：\(result?["before"] ?? "")")
        let presets = result?["presets"] as? [String] ?? []
        #expect(presets.first == "deepseek" && presets.last == "custom", "选单从国产的开始、最后是自定义接口：\(presets)")
        for provider in ["moonshotai-cn", "zhipuai", "zhipuai-coding-plan", "alibaba-cn", "minimax-cn", "volcengine", "kimi-code-plan-cn"] {
            #expect(presets.contains(provider), "预设里有 \(provider)")
        }
        #expect(result?["presetFields"] as? [String] == ["密钥"], "预设的服务商只要密钥：\(result?["presetFields"] ?? "")")
        #expect(result?["noKey"] as? String == "填上密钥")
        #expect((result?["remaining"] as? [String])?.contains("deepseek") == false, "填过的服务商不再列出来")
        #expect((result?["badAddress"] as? String)?.contains("接口地址") == true, "地址不带 https:// 存不了：\(result?["badAddress"] ?? "")")
        #expect(result?["shown"] as? [String] == [
            "DeepSeek 已填密钥 修改 删除",
            "公司的接口 https://api.example.com/v1 · model-a、org/model-b · 已填密钥 修改 删除",
        ], "列表：\(result?["shown"] ?? "")")
        let listed = result?["listed"] as? [[String: Any]] ?? []
        #expect(listed.map { $0["provider"] as? String } == ["deepseek", "my-api"], "中文名字的自定义接口叫 my-api：\(listed)")
        #expect(listed.allSatisfy { $0["hasKey"] as? Bool == true && $0["key"] == nil }, "页面拿到的只有「填了没有」：\(listed)")
        #expect(result?["keyLeft"] as? String == "", "存完密钥框是空的")
        #expect(result?["after"] as? [String] == ["fake/large", "fake/mini", "my-api/model-a", "my-api/org/model-b"], "存完模型在选单里：\(result?["after"] ?? "")")

        // 存的文件：有密钥，只有本人可读写
        #expect(stored.contains("sk-custom-secret-2") && !stored.contains("sk-deepseek-secret-1"), "删掉的那一家连密钥一起没了")
        #expect(mode?.intValue == 0o600, "providers.json 只有本人可读写：\(String(mode?.intValue ?? 0, radix: 8))")

        // 起 OpenCode 时：内联配置并进用户原有的，密钥在各自的环境变量里
        let calls = agent.calls()
        try #require(calls.count == 1)
        let environment = calls[0]["env"] as? [String: String] ?? [:]
        let config = Self.config(calls[0])
        let providers = config["provider"] as? [String: Any] ?? [:]
        #expect(config["theme"] as? String == "dark" && providers["theirs"] != nil, "用户原有的内联配置留着：\(config)")
        #expect((providers["deepseek"] as? [String: Any])?["options"] as? [String: String] == ["apiKey": "{env:VIBEPOST_API_KEY_1}"], "目录里的服务商只给密钥：\(providers)")
        let custom = providers["my-api"] as? [String: Any] ?? [:]
        #expect(custom["npm"] as? String == "@ai-sdk/openai-compatible" && custom["name"] as? String == "公司的接口")
        #expect(custom["options"] as? [String: String] == ["baseURL": "https://api.example.com/v1", "apiKey": "{env:VIBEPOST_API_KEY_2}"])
        #expect(Set((custom["models"] as? [String: Any] ?? [:]).keys) == ["model-a", "org/model-b"])
        #expect(environment["VIBEPOST_API_KEY_1"] == "sk-deepseek-secret-1" && environment["VIBEPOST_API_KEY_2"] == "sk-custom-secret-2")
        #expect(environment["OPENCODE_PERMISSION"]?.contains(#""bash":"ask""#) == true, "运行命令照样先问")
        #expect(!(environment["OPENCODE_CONFIG_CONTENT"] ?? "").contains("secret"), "配置里没有密钥本身")

        // 出错信息里带出了密钥：给页面之前打码
        let exits = result?["exits"] as? [String] ?? []
        #expect(exits.first?.contains("request failed: …") == true && exits.allSatisfy { !$0.contains("secret") }, "stderr 里的密钥打了码：\(exits)")

        let editing = result?["editing"] as? [String: Any]
        #expect(editing?["preset"] as? Bool == true && editing?["placeholder"] as? String == "留空：沿用已填的密钥" && editing?["url"] as? String == "https://api.example.com/v1")
        #expect(result?["moved"] as? String == "换了接口地址，密钥要重新填")
        #expect(result?["armed"] as? Bool == true, "删除第一下变成「确定删除」")
        #expect((result?["left"] as? [[String: Any]])?.map { $0["provider"] as? String } == ["my-api"])

        // Oh My Pi 用它自己的配置：拿不到这边填的接口；用户自己环境里的那份原样在
        let other = omp.calls()
        try #require(other.count == 1)
        let otherEnvironment = other[0]["env"] as? [String: String] ?? [:]
        #expect(otherEnvironment.keys.allSatisfy { !$0.hasPrefix("VIBEPOST_API_KEY_") }, "别的后端没有密钥：\(otherEnvironment.keys)")
        #expect(!(otherEnvironment["OPENCODE_CONFIG_CONTENT"] ?? "").contains("my-api"))
    }

    @Test("截图给人看：AI 设置里的「接口」，列表与自定义接口的表单（设了 MEDIACRAFT_SCREENSHOTS 才存）")
    func screenshots() async throws {
        let agent = try FakeACP()
        defer { agent.remove() }
        let harness = ShellHarness(terminalPath: [agent.directory], onboarding: false)
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "周末去湖边", markdown: "正文" });
            await mc.ai.setBackend("opencode");
            await mc.ai.saveProviders([
              { provider: "deepseek", name: "DeepSeek", key: "sk-one" },
              { provider: "zhipuai-coding-plan", name: "智谱 GLM Coding Plan", key: "sk-two" },
            ]);
            await openAI();
            await openProviders();
            await wait(300);
        """)
        try await harness.screenshot("ai-providers-list", of: ".ai-settings-popover")
        _ = try await harness.evaluate(Self.helpers + """
            ui.click("加一个接口");
            choose("custom");
            type("名字", "公司的接口");
            type("接口地址", "https://api.example.com/v1");
            type("模型名", "model-a, model-b");
            document.querySelector("#aiProviderForm").scrollIntoView({ block: "center" });
            await wait(300);
        """)
        try await harness.screenshot("ai-providers-form", of: ".ai-settings-popover")
        await harness.tearDown()
    }

    @Test("接口经 App API 存：没带密钥的沿用已存的，换了接口地址的那一项不沿用；不合规的（服务商、地址、模型名、密钥、重复）存不了，原来的不动")
    func savingRules() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(AISessionTests.helpers + """
            const flags = (list) => list.map((entry) => [entry.provider, entry.hasKey]);
            const fails = async (list) => {
              try {
                await mc.ai.saveProviders(list);
                return null;
              } catch (error) {
                return error.message;
              }
            };
            const custom = { provider: "my-api", name: "我的", baseURL: "https://api.example.com/v1", models: ["m"] };
            const first = await mc.ai.saveProviders([{ provider: "deepseek", name: "DeepSeek", key: "sk-one" }, { ...custom, key: "sk-two" }]);
            const kept = await mc.ai.saveProviders([{ provider: "deepseek", name: "DeepSeek" }, { ...custom, models: ["m", "n"] }]);
            const moved = await mc.ai.saveProviders([{ provider: "deepseek", name: "DeepSeek" }, { ...custom, baseURL: "https://other.example.com/v1" }]);
            const errors = [
              await fails([{ provider: "Bad Id", name: "x", key: "k" }]),
              await fails([{ provider: "my-x", name: "x", baseURL: "ftp://example.com", models: ["m"], key: "k" }]),
              await fails([{ provider: "my-x", name: "x", baseURL: "https://user:pass@example.com/v1", models: ["m"], key: "k" }]),
              await fails([{ provider: "my-x", name: "x", baseURL: "https://example.com/v1", models: [], key: "k" }]),
              await fails([{ provider: "my-x", name: "x", baseURL: "https://example.com/v1", models: ["has space"], key: "k" }]),
              await fails([{ provider: "my-x", name: "x", baseURL: "https://example.com/v1", models: ["m"], key: "two words" }]),
              await fails([{ provider: "deepseek", name: "一" , key: "k" }, { provider: "deepseek", name: "二", key: "k" }]),
              await fails("不是列表"),
            ];
            return { first: flags(first), kept: flags(kept), moved: flags(moved), errors, after: flags(await mc.ai.providers()) };
        """) as? [String: Any]
        await harness.tearDown()

        let pairs = { (value: Any?) in (value as? [[Any]] ?? []).map { "\($0[0]):\($0[1] as? Bool == true)" } }
        #expect(pairs(result?["first"]) == ["deepseek:true", "my-api:true"])
        #expect(pairs(result?["kept"]) == ["deepseek:true", "my-api:true"], "没带密钥、地址没变：沿用")
        #expect(pairs(result?["moved"]) == ["deepseek:true", "my-api:false"], "换了接口地址：旧密钥不跟过去")
        let errors = result?["errors"] as? [Any] ?? []
        #expect(errors.count == 8 && errors.allSatisfy { $0 is String }, "不合规的都存不了：\(errors)")
        #expect(pairs(result?["after"]) == ["deepseek:true", "my-api:false"], "存不了的那几次没动原来的")
    }
}
