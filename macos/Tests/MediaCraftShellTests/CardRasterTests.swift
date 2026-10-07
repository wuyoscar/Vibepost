import Foundation
import Testing

/// HTML 卡片出图（ADR 0006）：页面把每页的 HTML 与卡片样式交给壳，壳在不上屏的 WKWebView 里截图成 PNG。
@MainActor
struct CardRasterTests {
    /// 出图结果另存一份给人看（设了 MC_REVIEW_DIR 才存）
    static func keep(_ base64: String, as name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MC_REVIEW_DIR"], let data = Data(base64Encoded: base64) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    static let referencePage = """
        <article class="mc-page" data-structure="notes" style="--pad-t:64px;--pad-r:60px;--pad-b:124px;--pad-l:60px;--mc-size-body:21px;--mc-leading:1.75;--h1:1.67;--h1-leading:1.32;--h1-weight:700;--h2:1.31;--h2-leading:1.4;--h2-weight:600;--h3:1.12;--h3-leading:1.5;--h3-weight:600;--h1-align:start;--mc-radius:16px">
          <div class="mc-body">
            <p class="mc-kicker">核心动作：拆</p>
            <h1>一段 prompt，拆成这样</h1>
            <div class="mc-mono">
              <p>Classify the support ticket into <mark class="mc-mark" data-tone="1">billing, shipping, or account</mark>. Set <mark class="mc-mark" data-tone="2">urgent=true if the customer cannot use the product or has a deadline today</mark>. If they <mark class="mc-mark" data-tone="2">ask for a refund</mark>, add refund=true. <mark class="mc-mark" data-tone="3"><del>Output JSON only.</del></mark></p>
            </div>
            <ul class="mc-rows">
              <li><span class="mc-badge" data-tone="1">choice</span><p><code>team</code> billing / shipping / account，再加一个 other 兜底，模型不会被逼着选错。</p></li>
              <li><span class="mc-badge" data-tone="2">noul</span><p><code>urgent</code> "用不了产品"和"今天截止"这两条定义，原样搬进 criteria。</p></li>
              <li><span class="mc-badge" data-tone="2">noul</span><p><code>refund_requested</code> 一个命题一个问题，高值就是"是"。</p></li>
              <li><span class="mc-badge" data-tone="3">drop</span><p><code>Output JSON only</code> 答案本来就是类型化的，格式指令没用了。</p></li>
              <li><span class="mc-badge" data-tone="4">code</span><p><strong>算术 日期 计数 精确匹配</strong> 永远留在代码里，Jev 不是计算器。</p></li>
            </ul>
            <p class="mc-footnote">所有问题放在同一个请求里并行发出。阈值集中在一个常量块里，按错误的代价来调。</p>
          </div>
          <footer class="mc-foot"><span class="mc-sign">prompt2jev</span><span class="mc-folio">5 / 10</span></footer>
        </article>
        """

    @Test("HTML 卡片出图：参考卡 1728 × 2304，同一页连出八次逐字节相同，记下耗时")
    func rasterizesReferenceCard() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate("""
            const css = (await Promise.all(["src/cards/card.css", "src/cards/structures.css"].map((path) => fetch(path).then((r) => r.text())))).join("\\n");
            const request = { pages: [page, page, page, page, page, page, page, page], style: css, media: {}, width: 864, height: 1152, scale: 2 };
            const { pages, totalMs, times } = await window.MediaCraftNative.rasterCards(request);
            const encode = async (blob) => {
              const bytes = new Uint8Array(await blob.arrayBuffer());
              let binary = "";
              for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
              return btoa(binary);
            };
            const images = await Promise.all(pages.map((page) => encode(page.png)));
            const bitmap = await createImageBitmap(pages[0].png);
            return { images, totalMs, times, width: bitmap.width, height: bitmap.height };
        """, arguments: ["page": Self.referencePage]) as? [String: Any]
        await harness.tearDown()

        let images = result?["images"] as? [String] ?? []
        if let first = images.first { Self.keep(first, as: "reference-card.png") }
        #expect(result?["width"] as? Int == 1728)
        #expect(result?["height"] as? Int == 2304)
        #expect(images.count == 8 && Set(images).count == 1, "同一页连出八次逐字节相同")
        if let dir = ProcessInfo.processInfo.environment["MC_REVIEW_DIR"] {
            let timing = "总 \(result?["totalMs"] ?? "?") ms，每页 \(result?["times"] ?? "?")"
            try? timing.write(toFile: dir + "/timing.txt", atomically: true, encoding: .utf8)
        }
        #expect(harness.pageErrors == [])
    }
}

extension CardRasterTests {
    /// 页面里跑一整条：Markdown → HTML 卡片 → 分页 → 壳里出图；得到每页的 PNG（base64）与分页结果
    static let pipeline = """
        const encode = async (blob) => {
          const bytes = new Uint8Array(await blob.arrayBuffer());
          let binary = "";
          for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
          return btoa(binary);
        };
        // rasterize 给的是正文 PNG + 真实页码的条：合成一张 PNG
        window.compositePng = async (page) => {
          const { WIDTH, HEIGHT, SCALE, paintPage } = window.MediaCraftCards;
          const canvas = Object.assign(document.createElement("canvas"), { width: WIDTH * SCALE, height: HEIGHT * SCALE });
          await paintPage(canvas.getContext("2d"), page);
          return new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
        };
        window.cardsOf = async (settings) => {
          const started = performance.now();
          const result = await window.MediaCraftCards.layout(settings);
          const layoutMs = performance.now() - started;
          const rendered = await window.MediaCraftCards.rasterize(result);
          const images = [];
          for (const page of rendered) images.push(await encode(await compositePng(page)));
          return { pages: result.pages.map((page) => ({ kind: page.kind, sources: page.sources })), images, layoutMs };
        };
    """
}

extension CardRasterTests {
    @Test("长稿子分页：内置说明书排成多页，每页都不溢出，记下排版耗时")
    func paginatesLongDraft() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.pipeline + """
            const guide = window.MediaCraftGuides.builtIns()[0].record;
            const out = await cardsOf({ markdown: guide.markdown, theme: "notes", images: guide.images, profile: { name: "wuyoscar", handle: "", avatar: "brand/avatar.png" } });
            // 每页放回量尺卡，看正文区有没有溢出
            const again = await window.MediaCraftCards.layout({ markdown: guide.markdown, theme: "notes", images: guide.images, profile: { name: "wuyoscar", handle: "", avatar: "" } });
            const overflow = again.pages.map((_, index) => {
              const host = window.MediaCraftCards.mount(again, index);
              Object.assign(host.style, { position: "fixed", left: "-30000px", top: "0" });
              document.body.append(host);
              const body = host.shadowRoot.querySelector(".mc-body");
              const over = body.scrollHeight - body.clientHeight;
              host.remove();
              return over;
            });
            return { ...out, overflow };
        """) as? [String: Any]
        await harness.tearDown()

        let images = result?["images"] as? [String] ?? []
        for (index, image) in images.enumerated() { Self.keep(image, as: "guide-\(String(format: "%02d", index + 1)).png") }
        if let dir = ProcessInfo.processInfo.environment["MC_REVIEW_DIR"] {
            try? "排版 \(result?["layoutMs"] ?? "?") ms，\(images.count) 页，溢出 \(result?["overflow"] ?? "?")".write(toFile: dir + "/guide-timing.txt", atomically: true, encoding: .utf8)
        }
        #expect(images.count >= 5)
        #expect((result?["overflow"] as? [Double] ?? [1]).allSatisfy { $0 <= 1 }, "每页正文区都不溢出")
        #expect(harness.pageErrors == [])
    }
}

extension CardRasterTests {
    @Test("每个主题：说明书前三页按各自的卡片结构、配色与字体排，页面框架齐全、正文不溢出")
    func rendersEveryTheme() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.pipeline + """
            const guide = window.MediaCraftGuides.builtIns()[0].record;
            const out = {};
            for (const theme of \(ThemeTests.idsJSON)) {
              const settings = { markdown: guide.markdown, theme, images: guide.images, profile: { name: "wuyoscar", handle: "@wuyoscar", avatar: "brand/avatar.png" } };
              const result = await window.MediaCraftCards.layout(settings);
              const pages = result.pages.slice(0, 3);
              const pngs = await window.MediaCraftCards.rasterize({ ...result, pages });
              const overflow = pages.map((_, index) => {
                const host = window.MediaCraftCards.mount(result, index);
                Object.assign(host.style, { position: "fixed", left: "-30000px", top: "0" });
                document.body.append(host);
                const body = host.shadowRoot.querySelector(".mc-body");
                const over = body.scrollHeight - body.clientHeight;
                const structure = host.shadowRoot.querySelector(".mc-page").dataset.structure;
                host.remove();
                return { over, structure };
              });
              out[theme] = { images: await Promise.all(pngs.map(async (page) => encode(await compositePng(page)))), count: result.pages.length, overflow };
            }
            return out;
        """) as? [String: [String: Any]]
        await harness.tearDown()

        #expect(Set(result?.keys.map { $0 } ?? []) == Set(ThemeTests.ids))
        for (theme, structure) in ThemeTests.structures {
            let entry = result?[theme]
            let images = entry?["images"] as? [String] ?? []
            for (index, image) in images.enumerated() { Self.keep(image, as: "theme-\(theme)-\(index + 1).png") }
            #expect(images.count == 3, "\(theme) 出了三页")
            let overflow = entry?["overflow"] as? [[String: Any]] ?? []
            #expect(overflow.allSatisfy { ($0["over"] as? Double ?? 1) <= 1 && $0["structure"] as? String == structure }, "\(theme)：\(overflow)")
        }
        #expect(harness.pageErrors == [])
    }
}

extension CardRasterTests {
    @Test("拼图：横图与方图并排，两格等宽、一样高")
    func pairsHaveEqualHeights() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.pipeline + """
            const guide = window.MediaCraftGuides.builtIns()[0].record;
            const [wideId] = Object.keys(guide.images);
            const images = { a: guide.images[wideId], b: { src: "brand/avatar.png" } };
            const settings = { markdown: "两张并排\\n\\n[[image:a|b]]", theme: "notes", images, profile: { name: "wuyoscar", handle: "", avatar: "" } };
            const out = await cardsOf(settings);
            const layout = await window.MediaCraftCards.layout(settings);
            const host = window.MediaCraftCards.mount(layout, 0);
            Object.assign(host.style, { position: "fixed", left: "-30000px", top: "0" });
            document.body.append(host);
            await Promise.all([...host.shadowRoot.querySelectorAll("img")].map((image) => image.decode().catch(() => undefined)));
            const cells = [...host.shadowRoot.querySelectorAll(".mc-pair > .mc-img")].map((cell) => cell.getBoundingClientRect());
            host.remove();
            return { images: out.images, cells: cells.map((rect) => [rect.width, rect.height]) };
        """) as? [String: Any]
        await harness.tearDown()

        if let image = (result?["images"] as? [String])?.first { Self.keep(image, as: "pair.png") }
        let cells = result?["cells"] as? [[Double]] ?? []
        #expect(cells.count == 2)
        if cells.count == 2 {
            #expect(abs(cells[0][0] - cells[1][0]) < 1 && abs(cells[0][1] - cells[1][1]) < 1, "两格等宽、一样高：\(cells)")
            #expect(cells[0][1] > 100)
        }
        #expect(harness.pageErrors == [])
    }
}

extension CardRasterTests {
    @Test("封面：每个主题有底图、没底图各出一张封面，都是 1728 × 2304；页面结果是 cover、标题在版心里")
    func rendersCovers() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.pipeline + """
            const guide = window.MediaCraftGuides.builtIns()[0].record;
            const [imageId] = Object.keys(guide.images);
            const out = {};
            for (const theme of \(ThemeTests.idsJSON)) {
              for (const image of [null, imageId]) {
                const settings = { markdown: guide.markdown, title: "把写好的内容排成一组小红书卡片", theme, images: guide.images,
                  cover: { enabled: true, subtitle: "从 Markdown 到发布，一键隔空投送", image }, profile: { name: "wuyoscar", handle: "@wuyoscar", avatar: "brand/avatar.png" } };
                const layout = await window.MediaCraftCards.layout(settings);
                const painted = await window.MediaCraftCards.paint(layout, { paint: 1 });
                await painted.draw();
                const [png] = await window.MediaCraftCards.rasterize(layout, [0]);
                const page = painted.pages[0];
                const titles = page.items.filter((item) => item.blockType === "title");
                out[`${theme}-${image ? "image" : "plain"}`] = {
                  image: await encode(await compositePng(png)), role: page.role, hits: page.imageHits.filter((hit) => hit.cover).length,
                  inside: titles.length > 0 && titles.every((item) => item.x >= page.bounds.left - 1 && item.x + item.width <= page.bounds.right + 1),
                };
              }
            }
            return out;
        """) as? [String: [String: Any]]
        await harness.tearDown()

        for (name, entry) in result ?? [:] {
            if let image = entry["image"] as? String { Self.keep(image, as: "cover-\(name).png") }
            #expect(entry["role"] as? String == "cover", "\(name)")
            #expect(entry["hits"] as? Int == (name.hasSuffix("image") ? 1 : 0), "\(name)：底图的点选框")
            #expect(entry["inside"] as? Bool == true, "\(name)：标题在版心里")
        }
        #expect(result?.count == ThemeTests.ids.count * 2)
        #expect(harness.pageErrors == [])
    }
}
