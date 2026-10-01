import Testing

/// 纯文本（render.plainText、「复制卡片文字」与长文的「复制全文」、长文发送时的剪贴板）：每种写法变成什么。
@MainActor
struct PlainTextTests {
    @Test("每种写法的纯文本：去掉行内标记，列表留编号，表格留成竖线表，链接留网址，图片与分页符不进；空行按原文分段")
    func plainTextPerSyntax() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let cases: [(String, String)] = [
            ("# 一级\n## 二级\n#### 四级", "一级\n二级\n四级"),
            ("**粗** *斜* ***粗斜*** ~~删~~ `a**b**` {{color:#d9480f|红}}{{bg:#fff3bf|黄}}{{underline:dashed|虚}}", "粗 斜 粗斜 删 a**b** 红黄虚"),
            ("看[网站](https://example.com)吧，[**粗**普通](https://a.b)，[a](https://u)[b](https://u)，[不是链接](www.x)", "看[网站](https://example.com)吧，[粗普通](https://a.b)，[a](https://u)[b](https://u)，不是链接"),
            ("第一行\n第二行\n\n\n第二段", "第一行\n第二行\n\n第二段"),
            ("> 引用一\n>\n> **引用**二", "引用一\n\n引用二"),
            ("- 甲\n* 乙\n  + 缩进\n3. 丙\n7) 戊", "- 甲\n* 乙\n  + 缩进\n3. 丙\n7) 戊"),
            ("```js\nconst a = 1;\n  return a;\n```", "const a = 1;\n  return a;"),
            ("| 左 | 中 | 右 |\n| :--- | :---: | ---: |\n| 1 | **2** |", "| 左 | 中 | 右 |\n| :--- | :---: | ---: |\n| 1 | 2 |"),
            ("上\n\n***\n\n下", "上\n\n***\n\n下"),
            ("前\n[[image:a]]\n\n[[image:a|b|4x3]]\n![图](x.png)\n后", "前\n\n后"),
            ("第一页\n[[分页]]\n第二页", "第一页\n第二页"),
            ("文字[[image:a]]接着", "文字接着"),
            ("\n\n[[分页]]\n\n", ""),
        ]
        let actual = try await harness.evaluate("""
            await window.mediacraft.drafts.create();
            return Promise.all(cases.map((markdown) => window.mediacraft.render.plainText(markdown)));
        """, arguments: ["cases": cases.map(\.0)]) as? [String] ?? []
        await harness.tearDown()

        #expect(actual.count == cases.count)
        for (index, (markdown, expected)) in cases.enumerated() where index < actual.count {
            #expect(actual[index] == expected, "\(markdown)")
        }
        #expect(harness.pageErrors == [])
    }

    @Test("「复制卡片文字」把卡片上的纯文本放进剪贴板（不是正文栏）；卡片上没字时说一声，不动剪贴板；长文里叫「复制全文」")
    func copyPlainTextButton() async throws {
        let harness = ShellHarness()
        try await harness.load()
        _ = try await harness.evaluate("""
            await window.mediacraft.drafts.create({ markdown: "[[分页]]", caption: "正文栏的字不复制" });
            ui.click("复制卡片文字");
        """)
        let emptyStatus = try await harness.waitForPage("document.querySelector('#statusText').textContent.includes('没有可复制')", timeout: .seconds(3))
        let untouched = harness.clipboard.text == nil
        _ = try await harness.evaluate("""
            await window.mediacraft.drafts.update({ markdown: "# 标题\\n\\n正文 **粗** [[image:x]]" });
            ui.click("复制卡片文字");
        """)
        try await waitUntil(timeout: .seconds(5)) { harness.clipboard.text != nil }
        let copiedStatus = try await harness.waitForPage("document.querySelector('#statusText').textContent.startsWith('已复制卡片上的文字')", timeout: .seconds(3))
        let articleLabel = try await harness.evaluate("""
            await window.mediacraft.drafts.update({ mode: "article" });
            return [ui.find("复制全文") !== null, ui.find("复制卡片文字") === null];
        """) as? [Bool]
        await harness.tearDown()

        #expect(emptyStatus)
        #expect(untouched)
        #expect(harness.clipboard.text == "标题\n\n正文 粗")
        #expect(copiedStatus)
        #expect(articleLabel == [true, true], "长文里同一个按钮叫「复制全文」")
        #expect(harness.pageErrors == [])
    }
}
