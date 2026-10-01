import Foundation
import Testing

/// 新解析器与现在卡片的一致性（黑盒）：同一篇稿子，把 mediacraft.engine.parse 的块投影成卡片上应画的内容项，
/// 与 mediacraft.render.pages() 实际画出的逐项比对种类、blockType、编号、源码范围、文字与行内格式。
///
/// 投影规则（这些是排版的事，不是解析的事）：
/// - 标题 → text/h1–h3（四到六级按 h3 画）；段落每行、引用每行、列表每项各是一行 text；
///   文字项的源码范围从第一个看得见的字到最后一个，列表项从编号算起；
/// - 一段引用先有一个 quote 框；分割线在一张卡片最顶上时不画；[[分页]] 不画；
/// - 图片、拼图、表格各一项，源码范围取整块。
/// 卡片把长行折成几行、长引用跨页时框分成几段、长表格跨页时每页重复表头，比对前按源码并回。
///
/// 语料只放两边一致的写法。有意不同的几处（落单的 ** 照原样显示、斜体里嵌加粗、单独一行 > 是引用里的空行、
/// ``` 代码块、标题与引用里的图片不再丢失、紧跟表格的拼图不再被吞进表格）见 MarkdownParserTests.intentionalDifferences 与 docs/markdown-syntax.md。
@MainActor
struct MarkdownParserConformanceTests {
    static let corpus: [String] = [
        """
        # 标题

        正文第一段，**加粗**与*斜体*。
        第二行 {{color:#d9480f|橙色}} 与 {{bg:#fff3bf|高亮}}、{{underline:dashed|虚线}}。

        ## 小节

        - 要点一
        - 要点 **二**
        1. 第一步
        2. 第二步

        > 引用一行
        > 引用二行 ~~删掉~~

        ---

        结尾 `code` 与 [链接](https://example.com)。
        """,
        "[[image:{A}]]\n\n前文 [[image:{A}]] 后文\n\n[[image:{A}|{B}|4x3]]\n\n![图](left.png)\n\n- 列表 [[image:{B}]] 尾\n  [[image:{B}]]  ",
        "| 项目 | 说明 |\n| --- | :---: |\n| 字号 | **34** |\n| 行距 | `1.85` |\n正文紧跟表格\n\n| a | b |\n| --- | --- |\n\n表后\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n[[image:{A}|{B}]]",
        "第一页\n\n[[分页]]\n\n---\n第二页 ***粗斜*** 与 **粗*斜*粗**\n[[分页]]\n\n# 第三页\n> 引用\n\n\n- 甲\n\n\n2024. 回顾",
        "#无空格\n####### 七级\n#### 四级\n##### 五级\n-无空格\n* *\n- - -\n3、三\n>无空格\n  > 缩进引用\n\t\t制表缩进\n好开心~~ 明天见~~\n~~删~~和~~删~~\n5 * 3 = 15\n{{color:red|不是颜色}}\n[空]()\n[[ 分页 ]]\n| 单列 |\n![图](left.png) 文字",
        "甲\n\n\n乙\n   \n丙\n  - 缩进列表\n\t1) 制表有序\n001. 前导零\n- [ ] 待办",
        "`**不粗**` **`粗码`** ``b`c``\n{{color:#abc|外{{color:#def|内}}外}} **{{bg:#fff3bf|粗底}}**\n[**粗链**](https://x.com) [站](www.x.com) [邮](mailto:a@b.c)\n中**文**字 a*b*c **a*b**c*\n~~a ~~ b~~ **~~删粗~~**",
        "😀 **粗** emoji 与 𠮷 {{color:#abc|𠮷}}\n> **引用里的粗** `码`\n## 标题里 [链](https://x.com)",
    ]

    static let script = #"""
        const mc = window.mediacraft;
        const MARKS = ["bold", "italic", "strike", "code", "color", "bg", "underline", "link"];
        // 按格式把片段并起来再比（卡片按字切片段，解析器按原文切），空白不计（折行处的空格可能被吃掉）
        const runsKey = (runs) => {
          const merged = [];
          for (const run of runs) {
            const key = MARKS.filter((mark) => run[mark] !== undefined).map((mark) => `${mark}=${run[mark]}`).join(",");
            if (merged.length && merged[merged.length - 1].key === key) merged[merged.length - 1].text += run.text;
            else merged.push({ text: run.text, key });
          }
          return merged.map((run) => (run.key ? `(${run.text}:${run.key})` : run.text)).join("").replace(/\s+/g, "");
        };
        const visible = (runs) => (runs.length ? [runs[0].source[0], runs[runs.length - 1].source[1]] : null);
        const text = (runs) => runs.map((run) => run.text).join("").replace(/\s+/g, "");

        // 解析树 → 卡片上应画的内容项
        const project = (tree) => {
          const items = [];
          let pageTop = true;
          const line = (blockType, runs, extra = {}) => ({ kind: "text", blockType, source: visible(runs), text: text(runs), runs: runsKey(runs), ...extra });
          for (const block of tree.blocks) {
            if (block.type === "pageBreak") {
              pageTop = true;
              continue;
            }
            if (block.type === "rule" && pageTop) continue;
            if (block.type === "heading") items.push(line(`h${Math.min(block.level, 3)}`, block.runs));
            if (block.type === "paragraph") block.lines.forEach((entry) => items.push(line("p", entry.runs)));
            if (block.type === "list") {
              block.items.forEach((item) => items.push({
                ...line("li", item.runs, { marker: item.marker }),
                source: [item.markerSource[0], visible(item.runs)?.[1] ?? item.markerSource[1]],
              }));
            }
            if (block.type === "quote") {
              items.push({ kind: "quote" });
              block.lines.forEach((entry) => items.push(line("quote", entry.runs)));
            }
            if (block.type === "rule") items.push({ kind: "rule", source: block.source });
            if (block.type === "image") items.push({ kind: "image", source: block.source, ...(block.imageId ? { imageId: block.imageId } : {}) });
            if (block.type === "imagePair") items.push({ kind: "imagePair", source: block.source, imageIds: block.imageIds });
            if (block.type === "table") {
              const rows = [block.header, ...block.rows].map((row) => Array.from({ length: block.columns }, (_, column) => text(row.cells[column]?.runs ?? [])));
              items.push({ kind: "table", source: block.source, rows });
            }
            if (block.type === "code") items.push({ kind: "code" });
            pageTop = false;
          }
          return items;
        };

        // 卡片画出的内容项：折行并回一行，跨页引用的续框去掉
        const drawn = (pages, md) => {
          const items = [];
          for (const page of pages) {
            page.items.forEach((item, index) => {
              const previous = items[items.length - 1];
              const pageStart = index === 0;
              if (item.kind === "quote" && pageStart && previous?.blockType === "quote") return;
              if (item.kind === "text") {
                // 跨页拆在一个行内标记（高亮、字色……）中间时，前半截的源码范围到标记末尾，后半截从标记里接着：起点落在前半截里
                const splitInside = pageStart && item.source[0] > previous?.source[0] && item.source[0] < previous?.source[1];
                const continues = previous?.kind === "text" && previous.blockType === item.blockType && !item.marker
                  && (splitInside || (item.source[0] >= previous.source[1] && !md.slice(previous.source[1], item.source[0]).includes("\n")));
                if (continues) {
                  previous.source = [previous.source[0], item.source[1]];
                  previous.runs = [...previous.runs, ...item.runs];
                } else {
                  items.push({ kind: "text", blockType: item.blockType, source: item.source, runs: item.runs, ...(item.marker ? { marker: item.marker } : {}), pageStart });
                }
                return;
              }
              if (item.kind === "quote") items.push({ kind: "quote", pageStart });
              if (item.kind === "rule") items.push({ kind: "rule", source: item.source, pageStart });
              if (item.kind === "image") items.push({ kind: "image", source: item.source, imageId: item.imageId, pageStart });
              if (item.kind === "imagePair") items.push({ kind: "imagePair", source: item.source, imageIds: item.imageIds, pageStart });
              if (item.kind === "table") {
                const rows = item.rows.map((row) => row.cells.map((cell) => cell.replace(/\s+/g, "")));
                // 跨页的表格：接着上一页的同一张表，去掉重复的表头
                if (pageStart && previous?.kind === "table" && previous.source[0] === item.source[0]) previous.rows.push(...rows.slice(1));
                else items.push({ kind: "table", source: item.source, rows, pageStart });
              }
            });
          }
          return items.map((item) => (item.kind === "text" ? { ...item, text: text(item.runs), runs: runsKey(item.runs) } : item));
        };
        // 键按字母序输出，比较时不受字段顺序影响
        const canonical = (value) => JSON.stringify(value, value ? Object.keys(value).sort() : undefined);

        const compare = (expected, actual) => {
          const differences = [];
          let j = 0;
          for (let i = 0; i < expected.length; i += 1) {
            const want = expected[i];
            const got = actual[j];
            // 分割线落在自然换页后的卡片顶上时不画
            if (want.kind === "rule" && got && got.kind !== "rule" && got.pageStart) continue;
            const { pageStart, ...shown } = got ?? {};
            if (want.kind === "image" && !want.imageId) delete shown.imageId; // 标准 Markdown 图片由排版按文件名找回
            const a = canonical(want);
            const b = canonical(got ? shown : null);
            if (a !== b) differences.push(`第 ${i + 1} 项：解析 ${a} ≠ 卡片 ${b}`);
            j += 1;
          }
          for (; j < actual.length; j += 1) differences.push(`卡片多出 ${JSON.stringify(actual[j])}`);
          return differences;
        };

        await mc.drafts.create({ mode: "cards", fontSize: 34, lineHeight: 1.85 });
        const png = (name, width, height) => new Promise((resolve) => {
          const canvas = document.createElement("canvas");
          canvas.width = width;
          canvas.height = height;
          canvas.getContext("2d").fillRect(0, 0, width / 2, height);
          canvas.toBlob((blob) => resolve(new File([blob], name, { type: "image/png" })), "image/png");
        });
        const idOf = {};
        for (const id of await mc.media.import([await png("left.png", 120, 90), await png("right.png", 90, 120), await png("single.png", 160, 120)])) {
          idOf[(await mc.media.get(id)).name] = id;
          await mc.media.update(id, { layout: { widthPercent: 30, align: "center" } });
        }
        const drafts = corpus.map((md) => md.replaceAll("{A}", idOf["left.png"]).replaceAll("{B}", idOf["right.png"]));
        drafts.push(golden
          .replace("[[image:single]]", `[[image:${idOf["single.png"]}]]`)
          .replace("[[image:left|right|4x3]]", `[[image:${idOf["left.png"]}|${idOf["right.png"]}|4x3]]`));

        const results = [];
        const check = async (label, md) => {
          const pages = await mc.render.pages();
          const expected = project(await mc.engine.parse(md));
          const actual = drawn(pages, md);
          results.push({ label, items: actual.length, kinds: [...new Set(actual.map((item) => item.blockType ?? item.kind))], differences: compare(expected, actual) });
        };
        for (const [index, md] of drafts.entries()) {
          await mc.drafts.update({ markdown: md });
          await check(`第 ${index + 1} 篇`, md);
        }
        // 内置的图文卡片说明书（含普通图片与实况）
        const guide = (await mc.drafts.list()).find((draft) => draft.builtIn && draft.mode === "cards");
        await mc.drafts.open(guide.id);
        await check("说明书", (await mc.drafts.current()).markdown);
        return results;
    """#

    @Test("与现在的卡片一致：一组稿子（含说明书与出图基准稿）的块种类、编号、源码范围、文字与行内格式都和 render.pages() 相同")
    func parserAgreesWithCurrentCards() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let results = try await harness.evaluate(
            "const corpus = JSON.parse(corpusJSON);" + Self.script,
            arguments: ["corpusJSON": String(decoding: try JSONEncoder().encode(Self.corpus), as: UTF8.self), "golden": CardGoldenTests.draft]
        ) as? [[String: Any]] ?? []
        await harness.tearDown()

        #expect(results.count == Self.corpus.count + 2)
        for result in results {
            let label = result["label"] as? String ?? "?"
            #expect((result["items"] as? Int ?? 0) > 0, "\(label)：卡片上什么都没有")
            #expect(result["differences"] as? [String] == [], "\(label)")
        }
        let kinds = Set(results.flatMap { $0["kinds"] as? [String] ?? [] })
        #expect(kinds.isSuperset(of: ["h1", "h2", "h3", "p", "li", "quote", "rule", "table", "image", "imagePair"]), "语料覆盖了各种内容项：\(kinds.sorted())")
        #expect(harness.pageErrors == [])
    }
}
