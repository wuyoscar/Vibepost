import Foundation
import Testing

/// 假的生图接口（`Fixtures/ai/fake-image-api`）：在本机随机端口上代替 OpenAI，记下每个请求，按 mode.json 回答。
final class FakeImageAPI {
    /// 假接口认的密钥（放进假的「终端」环境）
    static let key = "sk-test-mediacraft"

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mediacraft-fake-image-\(UUID().uuidString)")
    private let process = Process()
    private(set) var url = URL(string: "http://127.0.0.1:9")!

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [FakeClaude.fixtures.appendingPathComponent("fake-image-api").path, directory.path]
        process.standardOutput = output
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) { line.append(byte) }
        let port = try #require(Int(String(decoding: line, as: UTF8.self)))
        url = URL(string: "http://127.0.0.1:\(port)")!
    }

    /// 之后的请求怎么回答：`["status": 401, "message": …]` 或 `["hang": true]`（没设时照常出图）
    func mode(_ mode: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: mode).write(to: directory.appendingPathComponent("mode.json"))
    }

    /// 按先后的每个请求：`{ path, bearerKey, body }`
    func requests() -> [[String: Any]] {
        let folder = directory.appendingPathComponent("requests")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> (Int, [String: Any])? in
            guard let index = Int(name.dropLast(5)), let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return (index, record)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func remove() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// AI 会话（五）：App 自己的生图工具 generate_image。原生壳直接调生图接口（不经 Bash、不用确认），密钥取「终端」环境，
/// 生成的图进配图候选（点了才插入）；设置里选服务与模型；没有密钥、接口出错时说清楚；生成中面板显示进度、可以停止。
/// claude 与生图接口都是假的，测试不会调到真的接口（harness 的环境里去掉了真的密钥）。
@MainActor
struct AIImageTests {
    static let helpers = AIToolsTests.helpers + """
        window.generatingRow = () => document.querySelector(".ai-generating");
    """

    private static func tail(_ text: String) -> [String] {
        [StreamJSON.textStart(), StreamJSON.textDelta(text), StreamJSON.assistantText(text), StreamJSON.result(text)]
    }

    /// 页面对工具调用的回答：{ text, isError }
    private static func toolAnswer(_ fake: FakeClaude, call: Int = 0, _ requestId: String) -> (text: String, isError: Bool) {
        let response = (fake.response(call, requestId)?["response"] as? [String: Any])?["mcp_response"] as? [String: Any]
        let result = response?["result"] as? [String: Any]
        let text = (result?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, result?["isError"] as? Bool ?? false)
    }

    @Test("生图成功：OpenAI 默认 gpt-image-2（与 gpt-image 技能一致），设置里可以换模型；密钥取终端环境或 ~/.env，只进请求头；生成的图进配图候选，点了才插入；不弹确认框；没有 Gemini 了，旧偏好里选过 Gemini 的读成 OpenAI")
    func generatesCandidates() async throws {
        let api = try FakeImageAPI()
        let fake = try FakeClaude()
        defer { fake.remove(); api.remove() }
        try fake.script([
            StreamJSON.initEvent(),
            StreamJSON.toolCall("g1", "generate_image", ["prompt": "窗边的橘猫", "count": 2, "style": "水彩"]),
        ] + Self.tail("生成好了"), call: 1)
        try fake.script([
            StreamJSON.initEvent(),
            StreamJSON.toolCall("g2", "generate_image", ["prompt": "海边日落", "count": 2, "size": "1536x1024"]),
        ] + Self.tail("又生成了两张"), call: 2)
        // 密钥不在终端环境里，写在 ~/.env（harness 换成 aiRoot 里的 test.env）
        let harness = ShellHarness(terminalPath: [fake.directory], onboarding: false, imageAPI: api.url)
        try "# 密钥\nexport OPENAI_API_KEY=\"\(FakeImageAPI.key)\"\n".write(
            to: harness.aiRoot.appendingPathComponent("test.env"), atomically: true, encoding: .utf8
        )
        try await harness.load()
        let first = try await harness.evaluate(Self.helpers + """
            localStorage.setItem("mediacraft.ai.v1", JSON.stringify({ image: { provider: "gemini", model: "gemini-3.1-flash-image" } }));
            const legacy = await mc.ai.imageSettings();
            const refused = await mc.ai.setImageSettings({ provider: "gemini" }).then(() => "改了", (error) => error.message);
            await mc.drafts.create({ markdown: "# 猫\\n\\n正文" });
            await openAI();
            let sheetSeen = false;
            const watch = setInterval(() => { sheetSeen ||= sheetView().shown; }, 20);
            ask("配两张猫的图");
            await until(() => finished(1));
            clearInterval(watch);
            await until(() => document.querySelectorAll(".ai-candidate").length === 2);
            return { legacy, refused, sheetSeen, lines: lines() };
        """) as? [String: Any]
        try await harness.screenshot("generate-image-candidates", of: "#aiPanel")
        let second = try await harness.evaluate("""
            ui.click("AI 设置");
            const gemini = Boolean(ui.find("Gemini"));
            const input = ui.find("生图模型");
            const placeholder = input.placeholder;
            input.value = "gpt-image-1.5";
            input.dispatchEvent(new Event("change", { bubbles: true }));
            await until(async () => (await mc.ai.imageSettings()).model === "gpt-image-1.5");
            ui.click("AI 设置");
            ask("再来两张海边的");
            await until(() => finished(2));
            const buttons = [...document.querySelectorAll(".ai-candidate")];
            buttons[0].click();
            await until(async () => (await mc.ai.history()).messages.some((message) => message.images?.some((image) => image.inserted)));
            const history = await mc.ai.history();
            return {
              gemini, placeholder,
              candidates: history.messages.filter((message) => message.role === "candidates").map((message) => message.images.length),
              markdown: (await mc.drafts.current()).markdown,
              media: (await mc.media.list()).length,
              leaked: JSON.stringify(history).includes(key),
            };
        """, arguments: ["key": FakeImageAPI.key]) as? [String: Any]
        let requests = api.requests()
        let stdin = (fake.calls().flatMap { $0["stdin"] as? [String] ?? [] }).joined()
        let argv = (fake.calls().flatMap { $0["argv"] as? [String] ?? [] }).joined(separator: " ")
        await harness.tearDown()

        let legacy = first?["legacy"] as? [String: Any]
        #expect(legacy?["provider"] as? String == "openai" && legacy?["model"] as? String == "gpt-image-2", "旧偏好里的 Gemini 读成 OpenAI 的默认：\(legacy ?? [:])")
        #expect((first?["refused"] as? String ?? "").contains("只有 OpenAI"), "\(first?["refused"] ?? "")")
        #expect(first?["sheetSeen"] as? Bool == false, "App 自己的工具不弹确认框")
        let lines = first?["lines"] as? [[String]] ?? []
        #expect(lines.contains { $0.first == "candidates" && $0.last?.hasPrefix("配图候选 · 点一张插进稿子") == true }, "\(lines)")
        #expect(Self.toolAnswer(fake, "g1").text.hasPrefix("已生成 2 张图"), "\(Self.toolAnswer(fake, "g1"))")
        #expect(Self.toolAnswer(fake, call: 1, "g2").text.hasPrefix("已生成 2 张图"))
        try #require(requests.count == 2, "OpenAI 一次出两张：\(requests.count)")
        #expect(requests.allSatisfy { $0["path"] as? String == "/v1/images/generations" && $0["bearerKey"] as? Bool == true })
        let openAI = requests[0]["body"] as? [String: Any] ?? [:]
        #expect(openAI["model"] as? String == "gpt-image-2" && openAI["n"] as? Int == 2 && openAI["quality"] as? String == "high")
        #expect(openAI["size"] as? String == "1024x1536", "默认竖图，配 3:4 卡片")
        #expect(openAI["prompt"] as? String == "窗边的橘猫\n\n风格：水彩")
        let changed = requests[1]["body"] as? [String: Any] ?? [:]
        #expect(changed["model"] as? String == "gpt-image-1.5" && changed["size"] as? String == "1536x1024", "设置里换的模型：\(changed)")
        #expect(second?["gemini"] as? Bool == false, "设置里没有 Gemini 了")
        #expect(second?["placeholder"] as? String == "gpt-image-2")
        #expect(second?["candidates"] as? [Int] == [2, 2])
        #expect(second?["media"] as? Int == 1, "点了一张才插进稿子")
        #expect((second?["markdown"] as? String ?? "").contains("[[图片:"), "插进稿子的是中文写法")
        #expect(second?["leaked"] as? Bool == false && !stdin.contains(FakeImageAPI.key) && !argv.contains(FakeImageAPI.key), "密钥只进请求头")
        #expect(harness.pageErrors == [])
    }

    @Test("生图失败说清楚：参数不对不发请求；没有密钥时说明去哪设；接口出错带上原因且不带密钥；会话里记一行")
    func explainsFailures() async throws {
        let api = try FakeImageAPI()
        let fake = try FakeClaude()
        defer { fake.remove(); api.remove() }
        try api.mode(["status": 401, "message": "Incorrect API key provided: \(FakeImageAPI.key)"])
        let script = [
            StreamJSON.initEvent(),
            StreamJSON.toolCall("g1", "generate_image", ["prompt": "猫", "count": 9]),
            StreamJSON.toolCall("g2", "generate_image", ["prompt": "猫"]),
        ] + Self.tail("没成功")
        try fake.script(script)
        let noKey = ShellHarness(terminalPath: [fake.directory], onboarding: false, imageAPI: api.url)
        try await noKey.load()
        let missing = try await noKey.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            ask("配图");
            await until(() => finished(1));
            return lines().filter(([kind]) => kind === "tool").map(([, text]) => text);
        """) as? [String] ?? []
        await noKey.tearDown()
        let requestsWithoutKey = api.requests().count
        let range = Self.toolAnswer(fake, "g1")
        let noKeyAnswer = Self.toolAnswer(fake, "g2")

        let withKey = ShellHarness(
            terminalPath: [fake.directory], onboarding: false, terminalVariables: ["OPENAI_API_KEY": FakeImageAPI.key], imageAPI: api.url
        )
        try await withKey.load()
        _ = try await withKey.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await mc.ai.send("配图");
        """)
        await withKey.tearDown()
        let rejected = Self.toolAnswer(fake, call: 1, "g2")

        #expect(range.isError && range.text == "count 要在 1–4 之间", "\(range)")
        #expect(noKeyAnswer.isError && noKeyAnswer.text.contains("没有找到 OPENAI_API_KEY") && noKeyAnswer.text.contains("~/.zshrc"), "\(noKeyAnswer)")
        #expect(requestsWithoutKey == 0, "参数不对、没有密钥时不发请求")
        #expect(missing.contains { $0.hasPrefix("生成图片没成功：没有找到 OPENAI_API_KEY") }, "\(missing)")
        #expect(rejected.isError && rejected.text.hasPrefix("OpenAI 生图失败（401）：Incorrect API key provided"), "\(rejected)")
        #expect(!rejected.text.contains(FakeImageAPI.key), "错误里去掉密钥：\(rejected.text)")
        #expect(noKey.pageErrors == [] && withKey.pageErrors == [])
    }

    @Test("生图不用确认，所以一轮最多 8 张：超出的那次不发请求，告诉 Claude 原因")
    func capsImagesPerTurn() async throws {
        let api = try FakeImageAPI()
        let fake = try FakeClaude()
        defer { fake.remove(); api.remove() }
        try fake.script([
            StreamJSON.initEvent(),
            StreamJSON.toolCall("g1", "generate_image", ["prompt": "猫", "count": 4]),
            StreamJSON.toolCall("g2", "generate_image", ["prompt": "狗", "count": 4]),
            StreamJSON.toolCall("g3", "generate_image", ["prompt": "鸟", "count": 1]),
        ] + Self.tail("够了"))
        let harness = ShellHarness(
            terminalPath: [fake.directory], onboarding: false, terminalVariables: ["OPENAI_API_KEY": FakeImageAPI.key], imageAPI: api.url
        )
        try await harness.load()
        _ = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await mc.ai.send("配图");
        """)
        await harness.tearDown()
        let third = Self.toolAnswer(fake, "g3")

        #expect(!Self.toolAnswer(fake, "g1").isError && !Self.toolAnswer(fake, "g2").isError)
        #expect(third.isError && third.text.contains("一轮最多 8 张"), "\(third)")
        #expect(api.requests().count == 2, "超出的那次不发请求")
        #expect(harness.pageErrors == [])
    }

    @Test("生成中面板显示进度（服务、模型、张数、用时），「停止生成」取消请求，Claude 收到「已停止生图」，这一轮接着说完")
    func stopsGeneration() async throws {
        let api = try FakeImageAPI()
        let fake = try FakeClaude(script: [
            StreamJSON.initEvent(), StreamJSON.toolCall("g1", "generate_image", ["prompt": "慢慢画", "count": 3]),
        ] + Self.tail("好的，不画了"))
        defer { fake.remove(); api.remove() }
        try api.mode(["hang": true])
        let harness = ShellHarness(
            terminalPath: [fake.directory], onboarding: false, terminalVariables: ["OPENAI_API_KEY": FakeImageAPI.key], imageAPI: api.url
        )
        try await harness.load()
        let progress = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "正文" });
            await openAI();
            ask("画三张");
            await until(() => generatingRow());
            await wait(1200);
            return { text: generatingRow().innerText.replace(/\\s+/g, " "), generating: (await mc.ai.history()).generating };
        """) as? [String: Any]
        try await harness.screenshot("generate-image-progress", of: "#aiPanel")
        let stopped = try await harness.evaluate("""
            const started = Date.now();
            ui.click("停止生成");
            await until(() => finished(1));
            return { seconds: (Date.now() - started) / 1000, row: Boolean(generatingRow()), end: shown().at(-1), generating: (await mc.ai.history()).generating };
        """) as? [String: Any]
        await harness.tearDown()

        let text = progress?["text"] as? String ?? ""
        #expect(text.contains("正在用 OpenAI gpt-image-2 生成 3 张图（1024x1536）") && text.contains("秒") && text.contains("停止生成"), "\(text)")
        #expect((progress?["generating"] as? [String: Any])?["count"] as? Int == 3)
        #expect((stopped?["seconds"] as? Double ?? 99) < 5, "停止不用等接口")
        #expect(stopped?["row"] as? Bool == false && stopped?["generating"] is NSNull, "进度收起")
        let answer = Self.toolAnswer(fake, "g1")
        #expect(answer.isError && answer.text == "已停止生图", "\(answer)")
        #expect((stopped?["end"] as? [String])?.last?.hasPrefix("claude-opus-4-6") == true, "这一轮照常说完：\(String(describing: stopped?["end"]))")
        #expect(api.requests().count == 1)
        #expect(harness.pageErrors == [])
    }
}
