import Foundation
import Testing

/// 每种卡片结构的署名与页码：第一页有头像与名字，内页有页码与名字，页眉页脚不压正文。
@MainActor
struct CardStructureTests {
    static let script = CardDomProbe.script + """
        const mc = window.mediacraft;
        if (!window.structureDraftReady) {
          await mc.drafts.create({
            mode: "cards",
            markdown: "# 署名与页码\\n\\n" + Array.from({ length: 24 }, (_, index) =>
              `第 ${index + 1} 段：写得足够长，才能把内容推到后面的页面，检验页眉、页脚与分页的位置。`).join("\\n\\n"),
          });
          // 署名要有名字才看得出写没写（新装时名字是空的，见 IdentityTests）
          await mc.profile.update({ name: "wuyoscar" });
          window.structureDraftReady = true;
        }
        const { avatar, name } = await mc.profile.get();
        const rendered = await mc.render.offscreen({ structure });
        return rendered.pages.map((page, index) => {
          const own = cardDom(rendered.views[index]);
          const { top, bottom } = page.contentBounds;
          const labels = own.filter((call) => call.kind === "text" && (call.y < top || call.y > bottom)).map((call) => call.text);
          return {
            structure: page.structure,
            header: page.header,
            avatars: own.filter((call) => call.kind === "image" && call.src === avatar).length,
            labels,
            named: labels.some((label) => label.toLowerCase().includes(name.toLowerCase())),
            numbered: labels.some((label) => new RegExp(`(^|\\\\D)0?${index + 1}(\\\\D|$)`).test(label)),
            overflow: page.items.filter((item) => item.y < top || item.y + item.height > bottom).length,
          };
        });
    """

    /// 卡片结构的 id（不是主题：报刊与书卷共用一种）
    static let structures = ThemeTests.structureIds

    @Test("每种结构：第一页有头像（杂志只有刊头的名字）与名字；内页有页码与名字、不再画头像；内容不越出正文区")
    func everyStructureSignsItsCards() async throws {
        let harness = ShellHarness()
        try await harness.load()
        var results: [String: [[String: Any]]] = [:]
        for structure in Self.structures {
            results[structure] = try await harness.evaluate(Self.script, arguments: ["structure": structure]) as? [[String: Any]]
        }
        let unknown = try await harness.evaluate("""
            try {
              await window.mediacraft.render.offscreen({ structure: "classic" });
              return "";
            } catch (error) {
              return error.message;
            }
        """) as? String
        await harness.tearDown()

        for structure in Self.structures {
            let pages = results[structure] ?? []
            #expect(pages.count >= 3, "\(structure)：稿子要够三页")
            guard let first = pages.first else { continue }
            #expect(pages.allSatisfy { $0["structure"] as? String == structure })
            #expect(first["header"] as? Bool == true, "\(structure)")
            // 杂志的刊头只有名字（头像在结尾页的署名里）
            #expect(first["avatars"] as? Int == (structure == "editorial" ? 0 : 1), "\(structure)：第一页画一次头像")
            #expect(first["named"] as? Bool == true, "\(structure)：第一页有名字 \(first["labels"] ?? [])")
            for (index, page) in pages.enumerated() {
                let label = "\(structure) 第 \(index + 1) 页"
                #expect(page["overflow"] as? Int == 0, "\(label)：内容越出正文区")
                guard index > 0 else { continue }
                #expect(page["header"] as? Bool == false, "\(label)")
                #expect(page["numbered"] as? Bool == true, "\(label)：没有页码 \(page["labels"] ?? [])")
                #expect(page["avatars"] as? Int == 0, "\(label)：只在第一页画头像")
                #expect(page["named"] as? Bool == true, "\(label)：没有署名 \(page["labels"] ?? [])")
            }
        }
        #expect(unknown?.contains("没有这个卡片结构") == true, "没登记的结构 id 被拒绝：\(unknown ?? "")")
        #expect(harness.pageErrors == [])
    }
}
