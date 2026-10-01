import Testing

/// 新 Markdown 解析器（mediacraft.engine.parse）：每种语法认得对、源码范围对得上、够快，
/// 并且对一组稿子给出的块与现在卡片上画出的内容一致。语法说明见 docs/markdown-syntax.md。
@MainActor
struct MarkdownParserTests {
    /// outline(tree)：每块一行摘要，便于逐条比对；片段写成「(文字:格式)」，无格式的直接写文字。
    /// violations(tree, md)：源码范围的不变量，返回违反的条目（应为空）。
    static let helpers = #"""
        const mc = window.mediacraft;
        const FLAGS = [["bold", "b"], ["italic", "i"], ["strike", "s"], ["code", "c"]];
        const VALUES = [["color", "color"], ["bg", "bg"], ["underline", "u"], ["link", "link"]];
        window.runsText = (runs) => runs.map((run) => {
          const marks = [
            ...FLAGS.filter(([key]) => run[key]).map(([, name]) => name),
            ...VALUES.filter(([key]) => run[key]).map(([key, name]) => `${name}=${run[key]}`),
          ];
          return marks.length ? `(${run.text}:${marks.join("+")})` : run.text;
        }).join("");
        const lineTexts = (lines) => lines.map((line) => runsText(line.runs)).join("/");
        window.outline = (tree) => tree.blocks.map((block) => {
          switch (block.type) {
            case "heading": return `h${block.level}:${runsText(block.runs)}`;
            case "paragraph": return `p:${lineTexts(block.lines)}`;
            case "quote": return `quote:${lineTexts(block.lines)}`;
            case "list": return `list:${block.items.map((item) => `${item.marker} ${runsText(item.runs)}`).join(";")}`;
            case "rule": return "rule";
            case "pageBreak": return "break";
            case "image": return block.imageId !== undefined ? `image:${block.imageId}` : `image:${block.path}(${block.alt})`;
            case "imagePair": return `pair:${block.imageIds.join(",")},${block.ratio ?? "-"}`;
            case "code": return `code:${block.lang}:${block.text.replace(/\n/g, "⏎")}`;
            case "table": {
              const rows = [block.header, ...block.rows].map((row) => row.cells.map((cell) => runsText(cell.runs)).join("|"));
              return `table:${block.columns}:${block.align.map((align) => align ?? "-").join(",")}:${rows.join("/")}`;
            }
            default: return `?${block.type}`;
          }
        });
        window.violations = (tree, md) => {
          const problems = [];
          const inside = (inner, outer, label) => {
            if (inner && !(outer[0] <= inner[0] && inner[0] <= inner[1] && inner[1] <= outer[1])) {
              problems.push(`${label} ${JSON.stringify(inner)} 不在 ${JSON.stringify(outer)} 里`);
            }
          };
          const checkRuns = (runs, content, label) => {
            let last = content[0];
            for (const run of runs) {
              if (md.slice(run.source[0], run.source[1]) !== run.text) problems.push(`${label}：片段「${run.text}」与原文不符`);
              if (run.source[0] < last || run.text === "") problems.push(`${label}：片段乱序或为空`);
              last = run.source[1];
              inside(run.source, content, `${label} 片段`);
            }
          };
          const checkLine = (line, outer, label) => {
            inside(line.source, outer, label);
            inside(line.contentSource, line.source, `${label} 内容`);
            const content = md.slice(line.contentSource[0], line.contentSource[1]);
            if (content !== content.trim()) problems.push(`${label}：内容两端有空白`);
            if (line.markerSource) {
              inside(line.markerSource, line.source, `${label} 标记`);
              if (md.slice(line.markerSource[0], line.markerSource[1]) !== line.marker) problems.push(`${label}：标记与原文不符`);
            }
            checkRuns(line.runs, line.contentSource, label);
          };
          inside(tree.source, [0, md.length], "文档");
          let previousEnd = 0;
          tree.blocks.forEach((block, index) => {
            const label = `第 ${index + 1} 块 ${block.type}`;
            inside(block.source, [0, md.length], label);
            if (block.source[0] < previousEnd) problems.push(`${label} 与前一块重叠`);
            previousEnd = block.source[1];
            if (block.type === "heading") checkLine(block, block.source, label);
            for (const line of block.lines ?? []) checkLine(line, block.source, label);
            for (const item of block.items ?? []) checkLine(item, block.source, label);
            if (block.type === "table") {
              for (const row of [block.header, ...block.rows]) {
                inside(row.source, block.source, `${label} 行`);
                for (const cell of row.cells) {
                  inside(cell.source, row.source, `${label} 格`);
                  checkRuns(cell.runs, cell.source, `${label} 格`);
                }
              }
            }
            if (block.type === "code" && block.contentSource) {
              inside(block.contentSource, block.source, label);
              if (md.slice(block.contentSource[0], block.contentSource[1]) !== block.text) problems.push(`${label}：代码与原文不符`);
            }
          });
          return problems;
        };
        // 解析一组稿子，返回每篇的摘要与不变量检查结果
        window.outlineAll = async (markdowns) => {
          const results = [];
          for (const md of markdowns) {
            const tree = await mc.engine.parse(md);
            results.push({ outline: outline(tree), problems: violations(tree, md) });
          }
          return results;
        };
    """#

    /// 在页面里解析每篇稿子，逐篇比对摘要，并检查源码范围不变量。
    func expectOutlines(_ cases: [(String, [String])], sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let harness = ShellHarness()
        try await harness.load()
        let results = try await harness.evaluate(
            Self.helpers + "return await outlineAll(markdowns);",
            arguments: ["markdowns": cases.map(\.0)]
        ) as? [[String: Any]] ?? []
        await harness.tearDown()

        #expect(results.count == cases.count, sourceLocation: sourceLocation)
        for ((markdown, expected), result) in zip(cases, results) {
            #expect(result["outline"] as? [String] == expected, "\(markdown.debugDescription)", sourceLocation: sourceLocation)
            #expect(result["problems"] as? [String] == [], "\(markdown.debugDescription)", sourceLocation: sourceLocation)
        }
        #expect(harness.pageErrors == [], sourceLocation: sourceLocation)
    }

    @Test("块：标题、段落、列表、引用、分割线、分页各按规则认出，不合规则的原样当文字")
    func blocks() async throws {
        try await expectOutlines([
            ("", []),
            ("\n\n  \n\t\u{3000}", []),
            ("# 一级\n## 二级\n### 三级\n#### 四级\n###### 六级", ["h1:一级", "h2:二级", "h3:三级", "h4:四级", "h6:六级"]),
            ("####### 七级\n#无空格\n# \n#\t制表 # 尾\n   # 缩进也算", ["p:####### 七级/#无空格/#", "h1:制表 # 尾", "h1:缩进也算"]),
            ("标题\n===\n正文", ["p:标题/===/正文"]),
            ("第一行\n第二行\n\n第三段\n\n\n第四段", ["p:第一行/第二行", "p:第三段", "p:第四段"]),
            ("  前导空格\n行尾空格   \n\t\t制表", ["p:前导空格/行尾空格/制表"]),
            ("- 甲\n* 乙\n+ 丙\n1. 一\n2) 二\n2024. 年\n001. 零", ["list:- 甲;* 乙;+ 丙;1. 一;2) 二;2024. 年;001. 零"]),
            ("- 列表\n续行不算列表\n  - 缩进不嵌套\n\t- 制表\n\n- 空行后另起", ["list:- 列表", "p:续行不算列表", "list:- 缩进不嵌套;- 制表", "list:- 空行后另起"]),
            ("-\n- \n1.\n1.无空格\n-无空格\n3、三", ["p:-/-/1./1.无空格/-无空格/3、三"]),
            ("- [ ] 待办\n-\t制表\n- - 双层\n* *斜*", ["list:- [ ] 待办;- 制表;- - 双层;* (斜:i)"]),
            ("> 一\n> 二\n>\n> 三\n\n> 另一段\n>没空格\n＞ 全角", ["quote:一/二//三", "quote:另一段", "p:>没空格/＞ 全角"]),
            ("> # 不是标题\n> - 不是列表\n> > 不嵌套\n  > 缩进\n\u{3000}> 全角空格缩进", ["quote:# 不是标题/- 不是列表/> 不嵌套/缩进/全角空格缩进"]),
            ("正文\n---\n***\n___\n- - -\n* * *\n-- -\n----------\n   ---   ", ["p:正文", "rule", "rule", "rule", "rule", "rule", "rule", "rule", "rule"]),
            ("--\n* *\n-*-\n——", ["p:--", "list:* *", "p:-*-/——"]),
            ("第一段\n[[分页]]\n  [[分页]]  \n前文 [[分页]] 后文\n- [[分页]]\n[[ 分页 ]]\n［［分页］］",
             ["p:第一段", "break", "break", "p:前文 [[分页]] 后文", "list:- [[分页]]", "p:[[ 分页 ]]/［［分页］］"]),
            ("[微笑][捂脸] 😀 <b>不是 HTML</b> &amp;", ["p:[微笑][捂脸] 😀 <b>不是 HTML</b> &amp;"]),
            ("\\# 不转义 \\*斜\\*", ["p:\\# 不转义 \\(斜\\:i)"]),
            ("# 标题\r\n正文\r\n\r\n- 甲\r\n", ["h1:标题", "p:正文", "list:- 甲"]),
        ])
    }

    @Test("图片、拼图、标准图片与表格、代码块：整行标记成块，行内图片把一行拆开")
    func imagesTablesAndCode() async throws {
        try await expectOutlines([
            ("[[image:img_1]]\n  [[image:a-b_C9]]  \n[[image:A|B]]\n[[image:A|B|4x3]]\n[[image:A|B|16x9]]",
             ["image:img_1", "image:a-b_C9", "pair:A,B,-", "pair:A,B,4x3", "pair:A,B,16x9"]),
            ("![图](dir/left.png)\n![](right.png \"标题\")\n  ![说明](a.png)  ", ["image:dir/left.png(图)", "image:right.png()", "image:a.png(说明)"]),
            ("前文 [[image:A]] 后文\n下一行", ["p:前文", "image:A", "p:后文/下一行"]),
            ("上一行\n[[image:A]][[image:B]] 说明", ["p:上一行", "image:A", "image:B", "p:说明"]),
            ("- 列表 [[image:A]] 尾\n- [[image:B]]", ["list:- 列表", "image:A", "p:尾", "list:- ", "image:B"]),
            ("# 标题 [[image:A]] 尾\n> 引用 [[image:B]] 尾\n> 续", ["h1:标题", "image:A", "p:尾", "quote:引用", "image:B", "quote:尾/续"]),
            ("`[[image:A]]` 在代码里", ["p:([[image:A]]:c) 在代码里"]),
            ("[[image:中文]]\n[[image: A ]]\n[[image:A|B|4:3]]\n[[image:A|B|C|D]]\n文 [[image:A|B]] 文\n![图](a.png) 文字",
             ["p:[[image:中文]]/[[image: A ]]/[[image:A|B|4:3]]/[[image:A|B|C|D]]/文 [[image:A|B]] 文/!图 文字"]),
            ("| 甲 | 乙 |\n| :--- | ---: |\n| 1 | **2** |\n正文 | 竖线\n结尾", ["table:2:left,right:甲|乙/1|(2:b)/正文|竖线", "p:结尾"]),
            ("甲 | 乙 | 丙\n--- | --- | :---:\n1 | 2\n| a | | c |", ["table:3:-,-,center:甲|乙|丙/1|2/a||c"]),
            ("| a | b |\n| --- | --- |\n| 1 | 2 | 3 |", ["table:3:-,-,-:a|b/1|2|3"]),
            ("| 单列 |\n| --- |\n| 1 |", ["p:| 单列 |/| --- |/| 1 |"]),
            ("| a | b |\n| -- | -- |", ["p:| a | b |/| -- | -- |"]),
            ("| a | b |\n---\n| 1 | 2 |", ["p:| a | b |", "rule", "p:| 1 | 2 |"]),
            ("| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 |\n[[image:A|B]]", ["table:2:-,-:a|b/1|2", "p:| 3 |", "pair:A,B,-"]),
            ("正文\n| a | b |\n| --- | --- |\n\n正文", ["p:正文", "table:2:-,-:a|b", "p:正文"]),
            ("| {{color:#abc|色}} | `c|d` |\n| --- | --- |", ["table:4:-,-,-,-:{{color:#abc|色}}|`c|d`"]),
            ("| [[image:A]] 图 | b |\n| --- | --- |", ["table:2:-,-: 图|b"]),
            ("```js\nconst a = 1;\n  缩进 **不解析**\n```\n正文", ["code:js:const a = 1;⏎  缩进 **不解析**", "p:正文"]),
            ("````\n```\n````", ["code::```"]),
            ("```\n```", ["code::"]),
            ("```\n没有收尾\n正文", ["p:```/没有收尾/正文"]),
            ("~~~\n不是代码\n~~~\n    缩进四格也不是", ["p:~~~/不是代码/~~~/缩进四格也不是"]),
        ])
    }

    @Test("行内：加粗斜体可嵌套、删除线贴着文字、行内代码优先、颜色高亮下划线、链接；落单的标记原样显示，格式不跨行")
    func inlineFormatting() async throws {
        try await expectOutlines([
            ("**粗** *斜* ***粗斜*** ~~删~~ `码`", ["p:(粗:b) (斜:i) (粗斜:b+i) (删:s) (码:c)"]),
            ("**粗*斜*粗** *斜**粗**斜*", ["p:(粗:b)(斜:b+i)(粗:b) (斜:i)(粗:b+i)(斜:i)"]),
            ("***a** b* ***a* b** *a **b** c*", ["p:(a:b+i)( b:i) (a:b+i)( b:b) (a :i)(b:b+i)( c:i)"]),
            ("中**文**字 a*b*c ** 两侧空格 ** **a**b**c**", ["p:中(文:b)字 a(b:i)c ( 两侧空格 :b) (a:b)b(c:b)"]),
            ("**未闭合 粗", ["p:**未闭合 粗"]),
            ("5 * 3 = 15", ["p:5 * 3 = 15"]),
            ("****四星**** _不是斜体_ __不是加粗__", ["p:****四星**** _不是斜体_ __不是加粗__"]),
            ("**a*b**c*", ["p:(a*b:b)c*"]),
            ("**跨\n行** *也\n不* ~~跨\n行~~", ["p:**跨/行** *也/不* ~~跨/行~~"]),
            ("~~删 除~~ 好开心~~ 明天见~~ ~~ 空格~~ ~单~ ~~~三~~~ a~~b~~c", ["p:(删 除:s) 好开心~~ 明天见~~ ~~ 空格~~ ~单~ ~~~三~~~ a(b:s)c"]),
            ("~~a ~~ b~~ ~~**粗删**~~ **~~删粗~~**", ["p:(a ~~ b:s) (粗删:b+s) (删粗:b+s)"]),
            ("**a ~~b** c~~", ["p:(a ~~b:b) c~~"]),
            ("`a` ``b`c`` `未闭合 `x**y**`", ["p:(a:c) (b`c:c) (未闭合 :c)x(y:b)`"]),
            ("`` ` `` 两侧空格保留", ["p:( ` :c) 两侧空格保留"]),
            ("`**不粗**` **`粗码`** `{{color:#abc|x}}`", ["p:(**不粗**:c) (粗码:b+c) ({{color:#abc|x}}:c)"]),
            ("{{color:#d9480f|橙}}{{bg:#FFF3BF|黄}}{{underline:solid|实}}{{underline:dashed|虚}}{{color:#abc|短}}{{color:#d9480f80|八位}}",
             ["p:(橙:color=#d9480f)(黄:bg=#FFF3BF)(实:u=solid)(虚:u=dashed)(短:color=#abc)(八位:color=#d9480f80)"]),
            ("{{color:#abc|外{{color:#def|内}}外}} {{color:#abc|**粗**}} **{{bg:#abc|底}}** {{underline:dashed|{{color:#abc|色}}}}",
             ["p:(外:color=#abc)(内:color=#def)(外:color=#abc) (粗:b+color=#abc) (底:b+bg=#abc) (色:color=#abc+u=dashed)"]),
            ("{{color:#abc|}}空{{color:#abc|a|b}}{{color:#abc|a}}}", ["p:空(a|b:color=#abc)(a:color=#abc)}"]),
            ("{{color:red|名}} {{color: #abc|空}} {{COLOR:#abc|大}} {{underline:wavy|波}} {{color:#12|短}} {{color:#abc |空}} {{color:#abc|未收尾",
             ["p:{{color:red|名}} {{color: #abc|空}} {{COLOR:#abc|大}} {{underline:wavy|波}} {{color:#12|短}} {{color:#abc |空}} {{color:#abc|未收尾"]),
            ("{{color:#abc|a **b}} c**", ["p:(a **b:color=#abc) c**"]),
            ("[链](https://x.com) [邮](mailto:a@b.c) [大写](HTTPS://X.COM) [站](www.x.com) [空]() [题](https://x.com \"标题\") [括](https://x.com/(p))",
             ["p:(链:link=https://x.com) (邮:link=mailto:a@b.c) (大写:link=HTTPS://X.COM) 站 空 (题:link=https://x.com) (括:link=https://x.com/(p))"]),
            ("[文字] [a](https://x.com/a b) [c [d] e](https://x.com) []() https://bare.x <https://x.com>",
             ["p:[文字] [a](https://x.com/a b) [c [d] e](https://x.com) []() https://bare.x <https://x.com>"]),
            ("[**粗**链](https://x.com) {{color:#abc|[链](https://x.com)}} [a *斜* `码`](https://x.com)",
             ["p:(粗:b+link=https://x.com)(链:link=https://x.com) (链:color=#abc+link=https://x.com) (a :link=https://x.com)(斜:i+link=https://x.com)( :link=https://x.com)(码:c+link=https://x.com)"]),
            ("# 标题 **粗** {{color:#abc|色}}\n- 列表 `码` ~~删~~\n> 引用 [链](https://x.com)\n| **格** | *斜* |\n| --- | --- |",
             ["h1:标题 (粗:b) (色:color=#abc)", "list:- 列表 (码:c) (删:s)", "quote:引用 (链:link=https://x.com)", "table:2:-,-:(格:b)|(斜:i)"]),
        ])
    }

    @Test("有意与旧卡片不同的几处：落单的 ** 照原样显示、斜体里嵌加粗、单独的 > 是引用里的空行、``` 代码块、标题与引用里的图片不再丢失、紧跟表格的拼图不进表格")
    func intentionalDifferences() async throws {
        // 旧卡片：落单的 ** 被删掉（* ~~ ` 却照原样）；*斜**粗**斜* 丢了加粗；单独一行 > 画成文字「>」；
        // ``` 各行当普通文字；标题、引用里的 [[image:…]] 连图带标记一起消失；
        // 紧跟在表格下一行的拼图被当成一行表格（格子里是半截标记）。新解析器按下面的结果给出。
        try await expectOutlines([
            ("a ** b\n正文 **粗\n继续** 正文", ["p:a ** b/正文 **粗/继续** 正文"]),
            ("*斜**粗**斜*", ["p:(斜:i)(粗:b+i)(斜:i)"]),
            ("> 第一段\n>\n> 第二段", ["quote:第一段//第二段"]),
            ("```\n代码\n```", ["code::代码"]),
            ("# [[image:A]]\n> [[image:B]]", ["image:A", "image:B"]),
            ("| a | b |\n| --- | --- |\n| 1 | 2 |\n[[image:A|B|4x3]]", ["table:2:-,-:a|b/1|2", "pair:A,B,4x3"]),
        ])
    }

    @Test("源码范围精确到字（UTF-16）：块、标记、内容、片段都能映射回原文，空行数记在块上")
    func sourceRanges() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + #"""
            const slice = (md, range) => (range ? md.slice(range[0], range[1]) : null);
            const md = "😀 **粗** {{color:#abc|色}}\n\n\n## 标题 `码`\n  - 甲 [链](https://x.com)\n> 引\n>\n| a | b |\n| --- | --- |\n| 1 | 2 |\n前 [[image:x]] 后\r\n```js\nlet a;\n```";
            const tree = await mc.engine.parse(md);
            const [paragraph, heading, list, quote, table, before, image, after, code] = tree.blocks;
            const line = paragraph.lines[0];
            const item = list.items[0];
            return {
              types: tree.blocks.map((block) => block.type),
              blankLines: tree.blocks.map((block) => block.blankLinesBefore),
              document: tree.source,
              runSources: line.runs.map((run) => run.source),
              runs: line.runs.map((run) => run.text),
              heading: [slice(md, heading.source), slice(md, heading.markerSource), slice(md, heading.contentSource), heading.runs.map((run) => slice(md, run.source)).join("|")],
              item: [slice(md, item.source), slice(md, item.markerSource), slice(md, item.contentSource), String(item.indent), String(item.ordered)],
              quote: quote.lines.map((entry) => [slice(md, entry.source), slice(md, entry.markerSource), slice(md, entry.contentSource)].join("|")),
              table: [slice(md, table.source), slice(md, table.header.source), table.rows.map((row) => row.cells.map((cell) => slice(md, cell.source)).join(",")).join(";")],
              split: [slice(md, before.source), slice(md, before.lines[0].contentSource), slice(md, image.source), slice(md, after.source), slice(md, after.lines[0].contentSource)],
              code: [slice(md, code.source), slice(md, code.contentSource), code.text, code.lang],
              problems: violations(tree, md),
            };
        """#) as? [String: Any]
        await harness.tearDown()

        #expect(result?["types"] as? [String] == ["paragraph", "heading", "list", "quote", "table", "paragraph", "image", "paragraph", "code"])
        #expect(result?["blankLines"] as? [Int] == [0, 2, 0, 0, 0, 0, 0, 0, 0])
        #expect(result?["document"] as? [Int] == [0, 136])
        #expect(result?["runSources"] as? [[Int]] == [[0, 3], [5, 6], [8, 9], [22, 23]], "emoji 占两个 UTF-16 位")
        #expect(result?["runs"] as? [String] == ["😀 ", "粗", " ", "色"])
        #expect(result?["heading"] as? [String] == ["## 标题 `码`", "##", "标题 `码`", "标题 |码"])
        #expect(result?["item"] as? [String] == ["  - 甲 [链](https://x.com)", "-", "甲 [链](https://x.com)", "2", "false"])
        #expect(result?["quote"] as? [String] == ["> 引|>|引", ">|>|"])
        #expect(result?["table"] as? [String] == ["| a | b |\n| --- | --- |\n| 1 | 2 |", "| a | b |", "1,2"])
        #expect(result?["split"] as? [String] == ["前 ", "前", "[[image:x]]", " 后", "后"], "行尾的 \\r 不算内容")
        #expect(result?["code"] as? [String] == ["```js\nlet a;\n```", "let a;", "let a;", "js"])
        #expect(result?["problems"] as? [String] == [])
        #expect(harness.pageErrors == [])
    }

    @Test("两万字的稿子每次解析不到一帧；各种病态写法也不卡")
    func parsesLargeDraftsQuickly() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + #"""
            const parse = window.MediaCraftEngine.parseMarkdown;
            const section = (i) => `## 第${i}节 **重点**\n\n这是一段正文，混着 **加粗**、*斜体*、~~删除~~、\`代码\`、{{color:#d9480f|橙色}}、{{bg:#fff3bf|高亮}} 和 [链接](https://example.com)。\n第二行接着写 English words 2026。\n\n- 列表一\n- 列表二 **粗**\n1. 有序\n\n> 引用一行\n> 引用二行\n\n| 项目 | 说明 |\n| --- | --- |\n| 甲 | **乙** |\n\n[[image:img_${i}]]\n\n---\n\n`;
            let draft = "";
            for (let i = 0; draft.length < 20000; i += 1) draft += section(i);
            const average = (text, rounds) => {
              parse(text);
              const started = performance.now();
              for (let round = 0; round < rounds; round += 1) parse(text);
              return (performance.now() - started) / rounds;
            };
            const pathological = {
              backticks: "a`b``c".repeat(4000),
              stars: "*a **b ".repeat(4000),
              brackets: "[[[[a]".repeat(4000),
              braces: "{{color:#abc|".repeat(2000) + "}}".repeat(10),
              tildes: "~~a ".repeat(5000),
              links: "[a](https://x.com/(((((((((".repeat(1000),
              lines: "一行\n".repeat(10000),
              table: "| a | b |\n| --- | --- |\n" + "| 1 | 2 |\n".repeat(2000),
            };
            const worst = Object.entries(pathological).map(([name, text]) => [name, average(text, 3)]).sort((a, b) => b[1] - a[1])[0];
            const tree = await mc.engine.parse(draft);
            return {
              length: draft.length,
              blocks: tree.blocks.length,
              problems: violations(tree, draft).length,
              average: average(draft, 30),
              worstName: worst[0],
              worst: worst[1],
            };
        """#) as? [String: Any]
        await harness.tearDown()

        #expect((result?["length"] as? Int ?? 0) >= 20000)
        #expect((result?["blocks"] as? Int ?? 0) > 500)
        #expect(result?["problems"] as? Int == 0)
        let average = result?["average"] as? Double ?? .infinity
        #expect(average < 16, "两万字每次解析 \(average) 毫秒")
        let worst = result?["worst"] as? Double ?? .infinity
        #expect(worst < 100, "最慢的病态写法 \(result?["worstName"] ?? "") 每次 \(worst) 毫秒")
        #expect(harness.pageErrors == [])
    }

    @Test("App API：engine.parse 不给参数时解析当前正文，不改稿子也不出图；参数不对 reject TypeError；结果可 JSON 往返")
    func appApi() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + #"""
            await mc.drafts.create({ markdown: "# 当前稿子\n\n正文" });
            const before = await mc.drafts.current();
            const events = [];
            const offChange = mc.on("change", () => events.push("change"));
            const offRendered = mc.on("rendered", () => events.push("rendered"));
            const current = await mc.engine.parse();
            const given = await mc.engine.parse("- 给定的");
            await new Promise((resolve) => setTimeout(resolve, 300));
            offChange();
            offRendered();
            let error = "";
            try {
              await mc.engine.parse(42);
            } catch (caught) {
              error = caught.constructor.name;
            }
            return {
              current: outline(current),
              given: outline(given),
              roundTrip: JSON.stringify(JSON.parse(JSON.stringify(current))) === JSON.stringify(current),
              unchanged: JSON.stringify(await mc.drafts.current()) === JSON.stringify(before),
              events,
              error,
              frozen: Object.isFrozen(mc.engine),
            };
        """#) as? [String: Any]
        await harness.tearDown()

        #expect(result?["current"] as? [String] == ["h1:当前稿子", "p:正文"])
        #expect(result?["given"] as? [String] == ["list:- 给定的"])
        #expect(result?["roundTrip"] as? Bool == true)
        #expect(result?["unchanged"] as? Bool == true)
        #expect(result?["events"] as? [String] == [], "解析不存盘、不出图")
        #expect(result?["error"] as? String == "TypeError")
        #expect(result?["frozen"] as? Bool == true)
        #expect(harness.pageErrors == [])
    }
}
