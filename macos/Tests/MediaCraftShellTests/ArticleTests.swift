import Foundation
import Testing

/// 长文（公众号）模式：语义 HTML、跟随主题的预览、公众号富文本、图文卡片 / 长文切换。
@MainActor
struct ArticleTests {
    static let everySyntax = [
        "# 一级", "## 二级", "#### 四级", "",
        "第一行 **粗** *斜* ***粗斜*** ~~删~~ `码` {{color:#d9480f|红}} {{bg:#fff3bf|黄}} {{underline:solid|实}} {{underline:dashed|虚}} [链](https://example.com)",
        "第二行 <b>不是标签</b> & 符号", "",
        "> 引用一", "> 引用二", ">", "> 新段", "",
        "- 甲", "* 乙", "3. 丙", "4. 丁", "7) 戊", "",
        "```js", "const a = \"<a>\";", "  return a;", "```", "",
        "| 左 | 中 | 右 |", "| :--- | :---: | ---: |", "| 1 | **2** |", "",
        "---", "",
        "[[image:missing]]", "",
        "[[分页]]", "",
        "尾段",
    ].joined(separator: "\n")

    @Test("render.articleHtml：每种写法对应的语义 HTML（找不到的图、分页符不出现），图片带画面与名字")
    func articleHtmlPerSyntax() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create();
            const canvas = document.createElement("canvas");
            canvas.width = 40;
            canvas.height = 30;
            const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
            const [id] = await mc.media.import([new File([blob], "图甲.png", { type: "image/png" })], { at: 0 });
            const withImage = await mc.render.articleHtml(`[[image:${id}]]\\n![说明](dir/图甲.png)\\n[[image:${id}|${id}|4x3]]`);
            return {
              syntax: await mc.render.articleHtml(markdown),
              image: withImage.replace(/src="data:image\\/png;base64,[^"]+"/g, 'src="…"'),
            };
        """, arguments: ["markdown": Self.everySyntax]) as? [String: String]
        await harness.tearDown()

        #expect(result?["syntax"] == """
            <h1>一级</h1><h2>二级</h2><h4>四级</h4>\
            <p>第一行 <strong>粗</strong> <em>斜</em> <strong><em>粗斜</em></strong> <s>删</s> <code>码</code> \
            <span style="color:#d9480f;">红</span> <span style="background-color:#fff3bf;">黄</span> <u>实</u> \
            <u style="text-decoration-style:dashed;">虚</u> <a href="https://example.com">链</a>\
            <br>第二行 &lt;b&gt;不是标签&lt;/b&gt; &amp; 符号</p>\
            <blockquote><p>引用一<br>引用二</p><p>新段</p></blockquote>\
            <ul><li>甲</li><li>乙</li></ul><ol start="3"><li>丙</li><li>丁</li><li value="7">戊</li></ol>\
            <pre><code class="language-js">const a = &quot;&lt;a&gt;&quot;;\n  return a;</code></pre>\
            <table><thead><tr><th style="text-align:left;">左</th><th style="text-align:center;">中</th><th style="text-align:right;">右</th></tr></thead>\
            <tbody><tr><td style="text-align:left;">1</td><td style="text-align:center;"><strong>2</strong></td><td style="text-align:right;"></td></tr></tbody></table>\
            <hr><p>尾段</p>
            """)
        #expect(result?["image"] == #"<figure><img src="…" alt="图甲.png"></figure><figure><img src="…" alt="图甲.png"></figure>"#
            + #"<figure><img src="…" alt="图甲.png"><img src="…" alt="图甲.png"></figure>"#, "应用图片、按文件名找回的图、拼图")
        #expect(harness.pageErrors == [])
    }

    /// 长文预览的版心：底色、正文色、字体、字号，二级标题左边竖线的颜色（强调色）。
    static let readPage = """
        window.readPage = async () => {
          await window.mediacraft.render.pages();
          const page = document.querySelector(".article-page");
          const style = getComputedStyle(page);
          return {
            // 字号读行内样式：舞台窄时整页 zoom 缩小，算出来的值会带小数
            bg: style.backgroundColor, text: style.color, font: style.fontFamily, size: page.style.fontSize,
            accent: getComputedStyle(page.querySelector("h2")).borderLeftColor,
          };
        };
    """

    @Test("长文跟随主题：换主题换底色、正文色与字体；颜色微调、字体、字号也跟着变")
    func articleFollowsTheTheme() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(Self.readPage + """
            const mc = window.mediacraft;
            await mc.drafts.create({ markdown: "# 标题\\n\\n## 小标题\\n\\n正文", mode: "article" });
            await mc.themes.apply("editorial");
            const light = await readPage();
            await mc.themes.apply("ink");
            const dark = await readPage();
            await mc.drafts.update({ colors: { accent: "#d9480f" }, fonts: { zh: "lxgw-wenkai" }, fontSize: 40 });
            const tweaked = await readPage();
            return { light, dark, tweaked };
        """) as? [String: [String: String]]
        await harness.tearDown()

        let light = result?["light"] ?? [:]
        let dark = result?["dark"] ?? [:]
        let tweaked = result?["tweaked"] ?? [:]
        #expect(light["bg"] == "rgb(242, 246, 250)" && light["text"] == "rgb(27, 36, 48)")
        #expect(light["accent"] == "rgb(47, 103, 177)")
        #expect(light["font"]?.hasPrefix("\"MC Source Serif 4\", \"MC Noto Serif SC\"") == true, "杂志：\(light["font"] ?? "")")
        #expect(light["size"] == "21.25px", "字号 34 按 540 宽的版心折算")
        #expect(dark["bg"] == "rgb(12, 12, 12)" && dark["text"] == "rgb(232, 232, 229)")
        #expect(dark["accent"] == "rgb(232, 232, 229)")
        #expect(dark["font"]?.hasPrefix("\"MC Inter\", \"MC Noto Sans SC\"") == true, "纯黑：\(dark["font"] ?? "")")
        #expect(tweaked["accent"] == "rgb(217, 72, 15)")
        #expect(tweaked["font"]?.contains("\"MC LXGW WenKai\"") == true)
        #expect(tweaked["size"] == "25px")
        #expect(tweaked["bg"] == "rgb(12, 12, 12)", "只改强调色，底色不动")
        #expect(harness.pageErrors == [])
    }

    @Test("复制公众号格式：剪贴板是只带行内样式的 HTML 与全文纯文本；深色主题换成白底深字，字体换成系统字体")
    func wechatRichTextPayload() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let plain = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create({ markdown, mode: "article" });
            await mc.themes.apply("ink");
            ui.click("复制公众号格式");
            return mc.render.plainText();
        """, arguments: ["markdown": Self.everySyntax]) as? String
        try await waitUntil(timeout: .seconds(10)) { harness.clipboard.html != nil }
        let html = harness.clipboard.html ?? ""
        let structure = try await harness.evaluate("""
            const root = new DOMParser().parseFromString(html, "text/html").body;
            const styled = [...root.querySelectorAll("*")];
            return {
              root: root.firstElementChild.tagName + " " + root.firstElementChild.style.color + " " + root.firstElementChild.style.fontFamily,
              tags: [...new Set(styled.map((element) => element.tagName.toLowerCase()))].sort().join(" "),
              unstyled: styled.filter((element) => !element.getAttribute("style")).map((element) => element.tagName.toLowerCase()).sort().join(" "),
              codeBreaks: root.querySelector("pre code").innerHTML,
              listMarkers: [...root.querySelectorAll("p > span:first-child")].map((span) => span.textContent).join(" "),
            };
        """, arguments: ["html": html]) as? [String: String]
        await harness.tearDown()

        #expect(!html.contains("class="), "公众号编辑器不认 class")
        #expect(!html.contains("<style"), "只用行内样式")
        #expect(!html.contains("MC "), "公众号用不了自带字体")
        #expect(structure?["root"] == "SECTION rgb(31, 31, 31) -apple-system, BlinkMacSystemFont, \"Helvetica Neue\", \"PingFang SC\", \"Hiragino Sans GB\", \"Microsoft YaHei\", sans-serif", "纯黑：深色换成白底深字，打包的黑体换成系统黑体")
        #expect(structure?["tags"] == "a blockquote br code em h1 h2 h4 hr p pre s section span strong table tbody td th thead tr u")
        #expect(structure?["unstyled"] == "br br br em em s tbody thead tr tr u", "排版用的元素都带行内样式")
        #expect(structure?["codeBreaks"] == "const a = \"&lt;a&gt;\";<br>&nbsp;&nbsp;return a;", "公众号会吞掉换行与行首空格")
        #expect(structure?["listMarkers"] == "• • 3. 4. 7)", "编号照原文")
        #expect(harness.clipboard.text == plain)
        #expect(harness.pageErrors == [])
    }

    @Test("新界面里切换图文卡片 / 长文：长文里是一篇长文、换成长图与公众号按钮；切回来恢复卡片")
    func switchModesInToolbar() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.create({ markdown });
            const visible = () => ["批量下载", "下载长图", "复制公众号格式", "发送到 iPhone"].filter((name) => ui.find(name)).join(" ");
            const cards = { buttons: visible(), pages: (await mc.render.pages()).length };
            ui.click("长文", { within: "排版模式" });
            await mc.render.pages();
            const article = {
              mode: (await mc.drafts.current()).mode,
              pressed: ui.find("长文", { within: "排版模式" }).getAttribute("aria-pressed"),
              buttons: visible(),
              pages: (await mc.render.pages()).length,
              articles: document.querySelectorAll("#stageCards .article-page").length,
              canvases: document.querySelectorAll("#stageCards canvas").length,
              filmstrip: getComputedStyle(document.querySelector("#filmstrip")).display,
            };
            ui.click("图文卡片", { within: "排版模式" });
            await mc.render.pages();
            const back = {
              mode: (await mc.drafts.current()).mode,
              buttons: visible(),
              canvases: document.querySelectorAll("#stageCards canvas").length,
              articles: document.querySelectorAll("#stageCards .article-page").length,
            };
            return { cards, article, back };
        """, arguments: ["markdown": SendToIPhoneTests.markdown]) as? [String: [String: Any]]
        await harness.tearDown()

        let pages = result?["cards"]?["pages"] as? Int ?? 0
        #expect(pages >= 2)
        #expect(result?["cards"]?["buttons"] as? String == "批量下载 发送到 iPhone")
        #expect(result?["article"]?["mode"] as? String == "article")
        #expect(result?["article"]?["pressed"] as? String == "true")
        #expect(result?["article"]?["buttons"] as? String == "下载长图 复制公众号格式 发送到 iPhone")
        #expect(result?["article"]?["pages"] as? Int == 0)
        #expect(result?["article"]?["articles"] as? Int == 1)
        #expect(result?["article"]?["canvases"] as? Int == 0)
        #expect(result?["article"]?["filmstrip"] as? String == "none")
        #expect(result?["back"]?["mode"] as? String == "cards")
        #expect(result?["back"]?["buttons"] as? String == "批量下载 发送到 iPhone")
        #expect(result?["back"]?["canvases"] as? Int == pages)
        #expect(result?["back"]?["articles"] as? Int == 0)
        #expect(harness.pageErrors == [])
    }
}
