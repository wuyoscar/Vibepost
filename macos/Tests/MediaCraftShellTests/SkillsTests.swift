import Foundation
import MediaCraftMCP
import Testing
@testable import MediaCraftShell

/// 内置技能：App 自带、只读、每轮都用的两份。「使用 Vibepost」就是操作手册（src/engine/manual.js，ManualTests），
/// 「写作」是 src/skills/写作.md（登记表 src/skills/index.js 由 scripts/build-skills.mjs 生成）。
/// App 里的 AI 每轮的说明书带两份的短版、AGENTS.md 是两份全文（WritingManualsTests、AgentManualTests）；外部 Agent 用 get_writing_skill 读，
/// 握手说明里带写作技能的短版。
@MainActor
struct SkillsTests {
    static let files = ShellHarness.repoRoot.appendingPathComponent("src/skills")

    @Test("登记表与 src/skills/*.md 一致（改了技能文件要重新运行 node scripts/build-skills.mjs）；MediaCraftSkills 列出两份：使用 Vibepost 是操作手册全文，写作是技能正文；AGENTS.md 两份全文、操作手册在前")
    func registryMatchesFiles() async throws {
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: Self.files.path).filter { $0.hasSuffix(".md") }.map { "src/skills/\($0)" }
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate("""
            const format = window.MediaCraftSkillFormat;
            const registry = window.MediaCraftSkillRegistry;
            const skills = window.MediaCraftSkills;
            const stale = [];
            for (const item of registry) {
              const text = await fetch(item.file).then((response) => response.text());
              if (JSON.stringify(format.entry(item.file, text)) !== JSON.stringify(item)) stale.push(item.file);
            }
            const writing = registry.find((item) => item.name === "写作");
            const agents = skills.agentsFile();
            return {
              files: registry.map((item) => item.file), stale,
              list: skills.list().map(({ name, builtIn }) => [name, String(builtIn)]),
              manualSame: skills.document("使用 Vibepost") === window.MediaCraftManual.document(),
              manualBrief: skills.brief("使用 Vibepost") === window.MediaCraftManual.brief(),
              writingSame: skills.document("写作") === writing.markdown,
              writingBrief: skills.brief("写作"),
              agentsOrder: agents.startsWith(window.MediaCraftManual.document()) && agents.endsWith(writing.markdown.trimEnd() + "\\n"),
              missing: (() => { try { skills.document("没有这份"); return null; } catch (error) { return error.message; } })(),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(Set(result?["files"] as? [String] ?? []) == Set(onDisk), "登记表里的文件就是目录里的：\(onDisk)")
        #expect(result?["stale"] as? [String] == [], "登记表过期了：运行 node scripts/build-skills.mjs")
        #expect(result?["list"] as? [[String]] == [["使用 Vibepost", "true"], ["写作", "true"]], "只有两份内置技能")
        #expect(result?["manualSame"] as? Bool == true && result?["manualBrief"] as? Bool == true, "使用 Vibepost 就是操作手册")
        #expect(result?["writingSame"] as? Bool == true)
        let brief = result?["writingBrief"] as? String ?? ""
        #expect(brief.hasPrefix("- 素材不够先问，不编") && brief.split(separator: "\n").count == 5, "短版是「## 最要紧的几条」那一节：\(brief)")
        #expect(result?["agentsOrder"] as? Bool == true, "AGENTS.md：操作手册全文在前，写作技能全文在后")
        #expect((result?["missing"] as? String)?.contains("没有这个内置技能") == true)
        #expect(harness.pageErrors == [])
    }

    @Test("写作技能本身：正文控制在三百行内，覆盖要素材不编、按顺序讲、不升华、AI 腔清单、标题 / 卡片 / 小红书正文、改别人稿子、转述、写完自查；每条规则配了例子")
    func writingSkillCoversTheRules() throws {
        let text = try String(contentsOf: Self.files.appendingPathComponent("写作.md"), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count <= 300, "正文控制在两三百行：\(lines.count)")
        #expect(text.hasPrefix("---\nname: 写作\ndescription: "))
        let sections = ["## 最要紧的几条", "## 动笔之前", "## 怎么讲", "## 收尾", "## 作者的声音", "## AI 腔清单", "## 各部分怎么写",
                        "### 标题（title.txt）", "### 卡片（draft.md）", "### 小红书正文（caption.txt）", "## 改别人的稿子", "## 转述别人的事", "## 写完自查"]
        for section in sections {
            #expect(text.contains("\n\(section)\n"), "少了「\(section)」")
        }
        for phrase in ["【待补：", "就是底稿", "具体时刻开头", "按发生的顺序讲", "写失败的版本", "先证据后判断", "宁可啰嗦", "比如", "不升华", "留白",
                       "敢把作者摆出来", "用作者自己的词", "数字当证据", "不是……而是……", "排比和金句", "首先 / 其次", "值得注意的是", "这提醒我们",
                       "冒号标签句成串", "假口语", "空泛的不确定", "只修错字", "不加第一人称"] {
            #expect(text.contains(phrase), "少了「\(phrase)」")
        }
        // 每个 ### 规则下面都有一段 > 例子（「各部分怎么写」的三个小节除外的规则也一样）
        let rules = text.components(separatedBy: "\n### ").dropFirst()
        let withoutExample = rules.filter { !$0.contains("\n> ") }.map { String($0.prefix(while: { $0 != "\n" })) }
        #expect(withoutExample.isEmpty, "这些规则没配例子：\(withoutExample)")
    }

    @Test("外部 Agent：get_writing_skill 读写作技能全文；握手说明带写作技能的短版并提到 get_writing_skill，后面仍是操作手册全文")
    func externalAgentReadsTheWritingSkill() async throws {
        let config = MCPConfiguration.temporary()
        let harness = ShellHarness(onboarding: false, mcp: config)
        try await harness.load()
        let client = MCPTestClient(socketPath: config.socketPath)
        let hello = try await client.initialize()
        let skill = try await client.call("get_writing_skill")
        let expected = try await harness.evaluate("""
            return { writing: window.MediaCraftSkills.document("写作"), brief: window.MediaCraftSkills.brief("写作"), manual: window.MediaCraftManual.document() };
        """) as? [String: String]
        client.close()
        await harness.tearDown()
        try? FileManager.default.removeItem(at: config.directory)

        let instructions = hello["instructions"] as? String ?? ""
        #expect(!skill.isError && skill.text == expected?["writing"], "\(skill.text.prefix(80))")
        #expect(instructions.contains("get_writing_skill") && instructions.contains(expected?["brief"] ?? "(没有)"), "握手说明带短版")
        #expect(instructions.hasSuffix(expected?["manual"] ?? "(没有)"), "最后仍是操作手册全文")
        #expect(harness.pageErrors == [])
    }
}
