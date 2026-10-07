import Foundation
import Testing
@testable import MediaCraftShell

/// 模板库（src/templates/）：仓库自带的模板（src/templates/*.md → 登记表 index.js）与用户自己存的（支持目录「模板/<名字>/」，壳 TemplateLibrary.swift）。
/// 模板不是稿子：不在稿件列表里、不能打开；`create({ template })` 复制一份成自己的稿子，主题 / 配色 / 字体 / 封面 / 图片都照模板；
/// `firstPage` 认得模板的 id（画廊缩略图）；「存为模板」写进文件夹（md + 图片），再列出能看到、能删，自带的不能删。
@MainActor
struct TemplatesTests {
    static let files = ShellHarness.repoRoot.appendingPathComponent("src/templates")

    static let helpers = """
        const mc = window.mediacraft;
        window.until = async (condition, timeout = 10000) => {
          const deadline = Date.now() + timeout;
          while (Date.now() < deadline) {
            const value = await condition();
            if (value) return value;
            await new Promise((resolve) => setTimeout(resolve, 20));
          }
          throw new Error(`等不到：${condition}`);
        };
        window.rejects = async (action) => {
          try {
            await action();
            return "";
          } catch (error) {
            return error.message;
          }
        };
        // 出图后每页的排版问题（太空的不算：模板的结尾页本来就留白）
        window.layoutIssues = async () => (await mc.render.pages()).flatMap((page) => page.issues.filter((issue) => issue.id !== "sparse").map((issue) => `第 ${page.index + 1} 页 ${issue.id}`));
        // 这篇的图片都载得出来
        window.imagesDecode = async () => Promise.all((await mc.media.list()).map(async (info) => {
          const image = new Image();
          image.src = await mc.media.src(info.id);
          await image.decode();
          return image.naturalWidth > 0;
        }));
        // 行内代码以外没有英文记号
        window.englishMarkers = (text) => /\\{\\{(?:color|bg|underline|mark)[:：]|\\[\\[(?:image|page|end)\\b|^:::(?:kicker|note|footnote|mono|rows|steps)\\b|align=/m.test(text.replace(/`[^`\\n]*`/g, ""));
    """

    /// 等 harness 记下来的东西到齐（页面经原生桥要的，主线程上记）
    static func waitFor(_ condition: () -> Bool, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("登记表与 src/templates/*.md 一致（改了模板文件要重新运行 node scripts/build-templates.mjs）；drafts.templates() 列出自带的（名字、标签、主题、builtIn）；模板不在稿件列表与抽屉里；记号全是中文、图片都登记了")
    func registryMatchesFiles() async throws {
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: Self.files.path).filter { $0.hasSuffix(".md") && $0 != "README.md" }.map { "src/templates/\($0)" }
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const format = window.MediaCraftTemplateFormat;
            const registry = window.MediaCraftTemplateRegistry;
            const stale = [];
            const problems = [];
            for (const item of registry) {
              const text = await fetch(item.file).then((response) => response.text());
              const parsed = format.entry(item.file, text);
              if (JSON.stringify(parsed) !== JSON.stringify(item)) stale.push(item.file);
              // 写回再读一样（存为模板用的是同一个 compose）
              if (JSON.stringify(format.entry(item.file, format.compose(item))) !== JSON.stringify(item)) problems.push(`${item.file}：写回再读不一样`);
              const markdown = item.markdown.join("\\n");
              if (englishMarkers(markdown)) problems.push(`${item.file}：有英文记号`);
              if (!item.tags.length || item.tags.length > 2) problems.push(`${item.file}：标签要题材一个、风格一个`);
              if (!item.name || !item.description || !item.theme) problems.push(`${item.file}：缺 name / description / theme`);
              for (const match of markdown.matchAll(/\\[\\[图片:([\\w|-]+)\\]\\]/g)) {
                for (const id of match[1].split("|")) if (!item.images[id] && !/^\\d+x\\d+$/.test(id)) problems.push(`${item.file}：正文里的图片 ${id} 没登记`);
              }
              if (item.cover.image && !item.images[item.cover.image]) problems.push(`${item.file}：封面底图 ${item.cover.image} 没登记`);
              for (const path of Object.values(item.images)) {
                const response = await fetch(path).then((response) => response.ok, () => false);
                if (!response) problems.push(`${item.file}：图片 ${path} 读不到`);
              }
            }
            const templates = await mc.drafts.templates();
            const list = await mc.drafts.list();
            ui.expand("稿件列表");
            const drawer = [...document.querySelector('[aria-label="稿件"]').querySelectorAll('[role="listitem"]')].map((item) => item.textContent);
            return {
              files: registry.map((item) => item.file), stale, problems,
              templates: templates.map(({ id, name, tags, theme, builtIn }) => [id, name, tags.join(","), theme, String(builtIn)]),
              descriptions: templates.every((item) => item.description.length > 0),
              inList: list.filter((item) => item.id.startsWith("template_")).length,
              inDrawer: drawer.filter((text) => templates.some((item) => text.includes(item.name))).length,
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(Set(result?["files"] as? [String] ?? []) == Set(onDisk), "登记表里的文件就是目录里的：\(onDisk)")
        #expect(result?["stale"] as? [String] == [], "登记表过期了：运行 node scripts/build-templates.mjs")
        #expect(result?["problems"] as? [String] == [], "\(result?["problems"] ?? [])")
        let templates = result?["templates"] as? [[String]] ?? []
        #expect(templates.map { $0[1] } == ["干货清单", "踩坑经验", "一周要闻", "论文解读", "工具实测", "读书笔记", "旅行日记", "活动通知"], "\(templates)")
        #expect(templates.allSatisfy { $0[0] == "template_\($0[1])" && $0[4] == "true" && $0[2].split(separator: ",").count == 2 }, "id 是 template_名字，两个标签：\(templates)")
        #expect(result?["descriptions"] as? Bool == true)
        #expect(result?["inList"] as? Int == 0, "模板不是稿子，不在 drafts.list() 里")
        #expect(result?["inDrawer"] as? Int == 0, "抽屉里也没有")
        #expect(harness.pageErrors == [])
    }

    @Test("create({ template })：按 id 或名字复制成一篇可改的稿子，主题 / 封面 / 图片 / 小红书正文都照模板、出图没有排版问题；其余 init 字段在模板之后套用；模板本身读得到（只读）但打不开；firstPage 认得模板的 id")
    func createFromTemplate() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const registry = window.MediaCraftTemplateRegistry;
            const checklist = registry.find((item) => item.id === "干货清单");
            const travel = registry.find((item) => item.id === "旅行日记");
            const firstImage = Object.keys(checklist.images)[0];
            const own = () => mc.drafts.list().then((list) => list.filter((item) => !item.builtIn).length);
            const before = await own();

            const byName = await mc.drafts.create({ template: "干货清单" });
            const images = await mc.media.list();
            const src = await mc.media.src(firstImage);
            const issues = await layoutIssues();
            const pages = (await mc.render.pages()).length;
            const decoded = await imagesDecode();
            const edited = await mc.drafts.update({ markdown: byName.markdown + "\\n\\n加一段" });
            const listed = (await mc.drafts.list()).find((item) => item.id === byName.id);

            const withInit = await mc.drafts.create({ template: "template_旅行日记", title: "我的标题", colors: { bg: "#fffaf3", text: "#3a3330", accent: "#f08a8a" } });
            const travelImages = (await mc.media.list()).map((info) => info.id).sort();
            const travelIssues = await layoutIssues();

            const asDraft = await mc.drafts.get("template_干货清单");
            const opened = await rejects(() => mc.drafts.open("template_干货清单"));
            const unknown = await rejects(() => mc.drafts.create({ template: "没有这个" }));
            const badKey = await rejects(() => mc.drafts.create({ template: 3 }));
            const first = await mc.drafts.firstPage("template_干货清单");
            const firstTravel = await mc.drafts.firstPage("template_旅行日记");
            const stillCurrent = (await mc.drafts.current()).id === withInit.id;
            return {
              created: await own() - before,
              byName: { readOnly: byName.readOnly, title: byName.title, theme: byName.theme, cover: byName.cover, caption: byName.caption, markdown: byName.markdown === checklist.markdown.join("\\n"), colors: byName.colors },
              images: images.map((info) => info.id).sort(), kinds: [...new Set(images.map((info) => info.kind))], src, issues, pages, decoded,
              expected: {
                title: checklist.title, theme: checklist.theme, captionStart: checklist.caption.split("\\n")[0], cover: checklist.cover,
                images: Object.keys(checklist.images).sort(), src: checklist.images[firstImage], bg: checklist.colors.bg ?? null,
                travelTheme: travel.theme, travelSubtitle: travel.cover.subtitle, travelImages: Object.keys(travel.images).sort(),
              },
              edited: edited.markdown.endsWith("加一段"), listed: listed ? [listed.title, listed.builtIn] : null,
              withInit: { title: withInit.title, theme: withInit.theme, colors: withInit.colors, cover: withInit.cover.enabled, subtitle: withInit.cover.subtitle },
              travelImages, travelIssues,
              asDraft: asDraft ? [asDraft.readOnly, asDraft.theme, asDraft.title] : null,
              opened, unknown, badKey,
              first: [first.pageCount, first.canvas ? first.canvas.width : 0], firstTravel: [firstTravel.pageCount, firstTravel.canvas ? firstTravel.canvas.height : 0],
              stillCurrent,
            };
        """) as? [String: Any]
        await harness.tearDown()

        let theme = result?["byName"] as? [String: Any]
        let expected = result?["expected"] as? [String: Any] ?? [:]
        #expect(result?["created"] as? Int == 2, "两次都新建了一篇自己的稿子")
        #expect(theme?["readOnly"] as? Bool == false, "复制出来的是自己的稿子，可以改")
        #expect(theme?["title"] as? String == expected["title"] as? String, "标题照模板")
        #expect(theme?["theme"] as? String == expected["theme"] as? String)
        #expect(theme?["markdown"] as? Bool == true, "卡片内容照模板")
        #expect((theme?["caption"] as? String ?? "").hasPrefix(expected["captionStart"] as? String ?? "?") && (theme?["caption"] as? String ?? "").contains("#"), "小红书正文照模板：\(theme?["caption"] ?? "")")
        let cover = theme?["cover"] as? [String: Any]
        let expectedCover = expected["cover"] as? [String: Any]
        #expect(cover?["enabled"] as? Bool == expectedCover?["enabled"] as? Bool && cover?["subtitle"] as? String == expectedCover?["subtitle"] as? String && cover?["image"] as? String == expectedCover?["image"] as? String, "封面照模板：\(cover ?? [:]) vs \(expectedCover ?? [:])")
        #expect(cover?["enabled"] as? Bool == true, "自带模板都开着封面")
        if let bg = expected["bg"] as? String { #expect((theme?["colors"] as? [String: String])?["bg"] == bg, "配色照模板") }
        #expect(result?["images"] as? [String] == expected["images"] as? [String], "图片跟着进来")
        #expect(result?["kinds"] as? [String] == ["image"])
        #expect(result?["src"] as? String == expected["src"] as? String, "自带模板的图片留相对路径")
        #expect(result?["issues"] as? [String] == [], "出图没有溢出、只有标题、偏挤的页")
        #expect((result?["pages"] as? Int ?? 0) >= 6, "封面 + 几条 + 结尾页：\(result?["pages"] ?? 0)")
        #expect(result?["decoded"] as? [Bool] == Array(repeating: true, count: (expected["images"] as? [String])?.count ?? 0))
        #expect(result?["edited"] as? Bool == true, "改得动")
        let listed = result?["listed"] as? [AnyHashable] ?? []
        #expect(listed.count == 2 && (listed[1] as? Bool) == false && !(listed[0] as? String ?? "").isEmpty, "在稿件列表里是自己的稿子：\(listed)")
        let withInit = result?["withInit"] as? [String: Any]
        #expect(withInit?["title"] as? String == "我的标题", "init 里的字段在模板之后套用")
        #expect(withInit?["theme"] as? String == expected["travelTheme"] as? String)
        #expect((withInit?["colors"] as? [String: String])?["accent"] == "#f08a8a")
        #expect(withInit?["cover"] as? Bool == true && withInit?["subtitle"] as? String == expected["travelSubtitle"] as? String)
        #expect(result?["travelImages"] as? [String] == expected["travelImages"] as? [String])
        #expect(result?["travelIssues"] as? [String] == [])
        #expect(result?["asDraft"] as? [AnyHashable] == [true, expected["theme"] as? String ?? "", expected["title"] as? String ?? ""] as [AnyHashable], "模板本身读得到，只读")
        #expect((result?["opened"] as? String ?? "").contains("模板"), "模板打不开：\(result?["opened"] ?? "")")
        #expect((result?["unknown"] as? String ?? "").contains("没有这个模板"))
        #expect((result?["badKey"] as? String ?? "").contains("template"))
        let first = result?["first"] as? [Int] ?? []
        #expect(first.count == 2 && first[0] >= 6 && first[1] > 0, "firstPage 认得模板：\(first)")
        let firstTravel = result?["firstTravel"] as? [Int] ?? []
        #expect(firstTravel.count == 2 && firstTravel[0] >= 5 && firstTravel[1] > 0)
        #expect(result?["stillCurrent"] as? Bool == true, "firstPage 不切换稿子")
        #expect(harness.pageErrors == [])
    }

    @Test("每套自带模板都能建成稿子：主题是登记表里的、图片都找得到并能出图、排版自检没有问题、记号全是中文")
    func everyBuiltInTemplateRenders() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const report = [];
            for (const entry of window.MediaCraftTemplateRegistry) {
              const draft = await mc.drafts.create({ template: `template_${entry.id}` });
              const pages = await mc.render.pages();
              const images = await mc.media.list();
              report.push({
                name: entry.name, theme: draft.theme === entry.theme, pages: pages.length,
                // 字多了会被悄悄拆到下一页：正文页（封面页、结尾页之外）要正好是分页记号数 + 1
                splits: pages.filter((page) => page.role === "body").length - draft.markdown.split("[[分页]]").length,
                sparse: pages.filter((page) => page.issues.some((issue) => issue.id === "sparse")).map((page) => page.index + 1),
                type: [draft.fontSize, draft.lineHeight],
                issues: pages.flatMap((page) => page.issues.filter((issue) => issue.id !== "sparse").map((issue) => `${page.index + 1}:${issue.id}`)),
                images: images.length === Object.keys(entry.images).length, decoded: (await imagesDecode()).every(Boolean),
                english: /\\[\\[image:|\\{\\{(?:color|bg|underline|mark):|:::(?:kicker|note|footnote|mono|rows|steps)\\b|align=/.test(draft.markdown),
                cover: draft.cover.enabled, caption: draft.caption.includes("#"),
              });
            }
            return report;
        """) as? [[String: Any]] ?? []
        await harness.tearDown()

        #expect(result.count == 8)
        for item in result {
            let name = item["name"] as? String ?? "?"
            #expect(item["theme"] as? Bool == true, "\(name) 的主题")
            #expect((item["pages"] as? Int ?? 0) >= 6, "\(name) 页数 \(item["pages"] ?? 0)")
            #expect(item["splits"] as? Int == 0, "\(name) 有卡片字多到被拆页：多出 \(item["splits"] ?? 0) 页")
            #expect(item["sparse"] as? [Int] == [], "\(name) 太空的页：\(item["sparse"] ?? [])")
            #expect(item["type"] as? [Double] == [30, 1.6], "\(name) 的字号与行距照模板")
            #expect(item["issues"] as? [String] == [], "\(name) 的排版自检：\(item["issues"] ?? [])")
            #expect(item["images"] as? Bool == true && item["decoded"] as? Bool == true, "\(name) 的图片")
            #expect(item["english"] as? Bool == false, "\(name) 只用中文记号")
            #expect(item["cover"] as? Bool == true && item["caption"] as? Bool == true, "\(name) 有封面与正文")
        }
        #expect(harness.pageErrors == [])
    }

    @Test("存为模板：写进支持目录「模板/<名字>/」（模板.md + 图片），再列出能看到、重新打开 App 也在；从它新建时图片读回来能出图、主题 / 配色 / 字体 / 封面照旧；同名整套换掉；在 Finder 中显示；只能删自己的")
    func userTemplatesRoundTrip() async throws {
        let harness = ShellHarness(onboarding: false)
        let folder = harness.aiRoot.appendingPathComponent("模板")
        try await harness.load()
        let saved = try await harness.evaluate(Self.helpers + """
            const blob = await fetch("docs/guide-assets/night-lake.jpg").then((response) => response.blob());
            const draft = await mc.drafts.create({ title: "湖边一晚", markdown: "## 夜湖\\n\\n一句话。\\n\\n" });
            await mc.editor.select(draft.markdown.length);
            const [imageId] = await mc.media.import([new File([blob], "night-lake.jpg", { type: "image/jpeg" })]);
            await mc.drafts.update({
              theme: "glow", colors: { bg: "#fff8f0", text: "#222222", accent: "#d9480f" }, fonts: { zh: "lxgw-wenkai" },
              fontSize: 30, lineHeight: 1.6,
              cover: { enabled: true, subtitle: "副标题", image: imageId }, caption: "第一段\\n\\n#话题",
            });
            const folderBefore = (await mc.drafts.templates()).length;
            const badName = await rejects(() => mc.drafts.saveAsTemplate({ name: "a/b" }));
            const template = await mc.drafts.saveAsTemplate({ name: "我的清单", description: "自己存的", tags: ["清单", "柔和"] });
            const replaced = await mc.drafts.saveAsTemplate({ name: "我的清单", description: "改了说明", tags: ["清单", "柔和"] });
            const listed = (await mc.drafts.templates()).map(({ id, name, description, builtIn }) => [id, name, description, String(builtIn)]);
            const markdown = (await mc.drafts.current()).markdown;
            await mc.drafts.revealTemplate(template.id);
            await mc.drafts.revealTemplate();
            const revealBuiltIn = await rejects(() => mc.drafts.revealTemplate("template_干货清单"));
            const builtIns = window.MediaCraftTemplateRegistry.map((item) => `template_${item.id}`);
            return { imageId, badName, template, replaced: replaced.description, listed, folderBefore, markdown, revealBuiltIn, builtIns };
        """) as? [String: Any]
        let imageId = saved?["imageId"] as? String ?? ""
        let templateFolder = folder.appendingPathComponent("我的清单")
        try await Self.waitFor { harness.revealedFiles.count == 2 }
        let revealed = harness.revealedFiles.map { $0.resolvingSymlinksInPath().path }
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: templateFolder.path))?.sorted() ?? []
        let content = (try? String(contentsOf: templateFolder.appendingPathComponent("模板.md"), encoding: .utf8)) ?? ""
        let imageBytes = (try? Data(contentsOf: templateFolder.appendingPathComponent("\(imageId).jpg")))?.count ?? 0
        let stray = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []

        // 重新打开 App：模板从文件夹里读回来，从它新建的一篇图片是读回来的 data URL、能出图
        try await harness.load()
        let reopened = try await harness.evaluate(Self.helpers + """
            const listed = (await mc.drafts.templates()).map((item) => item.id);
            const asDraft = await mc.drafts.get("user_template_我的清单");
            const first = await mc.drafts.firstPage("user_template_我的清单");
            const draft = await mc.drafts.create({ template: "我的清单" });
            const src = await mc.media.src("\(imageId)");
            const issues = await layoutIssues();
            const decoded = await imagesDecode();
            const removeBuiltIn = await rejects(() => mc.drafts.removeTemplate("template_干货清单"));
            await mc.drafts.removeTemplate("user_template_我的清单");
            const afterRemove = (await mc.drafts.templates()).map((item) => item.id);
            const removeAgain = await rejects(() => mc.drafts.removeTemplate("user_template_我的清单"));
            return {
              listed, asDraft: asDraft ? [asDraft.readOnly, asDraft.theme, asDraft.title] : null, first: [first.pageCount, first.canvas ? first.canvas.width : 0],
              draft: { title: draft.title, theme: draft.theme, colors: draft.colors, tuned: draft.tunedColors, fonts: draft.fonts, cover: draft.cover, caption: draft.caption, markdown: draft.markdown, readOnly: draft.readOnly, type: [draft.fontSize, draft.lineHeight, draft.imageMaxHeight] },
              src: src.slice(0, 22), issues, decoded, removeBuiltIn, afterRemove, removeAgain,
            };
        """) as? [String: Any]
        let removedOnDisk = !FileManager.default.fileExists(atPath: templateFolder.path)
        let folderStays = FileManager.default.fileExists(atPath: folder.path)
        await harness.tearDown()

        #expect((saved?["badName"] as? String ?? "").contains("/ \\ :"), "名字不合规矩直接 reject：\(saved?["badName"] ?? "")")
        let template = saved?["template"] as? [String: Any]
        #expect(template?["id"] as? String == "user_template_我的清单" && template?["builtIn"] as? Bool == false && template?["theme"] as? String == "glow", "\(template ?? [:])")
        #expect(template?["tags"] as? [String] == ["清单", "柔和"])
        #expect(saved?["replaced"] as? String == "改了说明", "同名的整套换掉")
        let builtIns = saved?["builtIns"] as? [String] ?? []
        let listedRows = saved?["listed"] as? [[String]] ?? []
        #expect(listedRows.map { $0[0] } == builtIns + ["user_template_我的清单"], "自带的在前，自己的在后：\(listedRows)")
        #expect(listedRows.last == ["user_template_我的清单", "我的清单", "改了说明", "false"])
        #expect(listedRows.dropLast().allSatisfy { $0[3] == "true" && !$0[2].isEmpty })
        #expect(saved?["folderBefore"] as? Int == builtIns.count && builtIns.count == 8, "存之前只有自带的")
        #expect((saved?["revealBuiltIn"] as? String ?? "").contains("自带"))
        #expect(revealed == [templateFolder.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path], "在 Finder 中显示那一套的文件夹、模板文件夹：\(revealed)")
        #expect(onDisk == ["\(imageId).jpg", "模板.md"], "文件夹里是 模板.md 与图片：\(onDisk)")
        #expect(stray == ["我的清单"], "临时文件夹不留：\(stray)")
        #expect(imageBytes > 1000)
        let parsed = WritingManuals.parse(content, fallbackName: "x")
        #expect(parsed.name == "我的清单" && parsed.description == "改了说明", "开头和写作手册同一套写法：\(content.prefix(200))")
        for line in ["tags: 清单, 柔和", "title: 湖边一晚", "theme: glow", "colors:", "  bg: #fff8f0", "  accent: #d9480f", "fonts:", "  zh: lxgw-wenkai", "fontSize: 30", "lineHeight: 1.6", "cover:", "  enabled: true", "  subtitle: 副标题", "  image: \(imageId)", "caption: |", "  第一段", "  #话题", "images:", "  \(imageId): \(imageId).jpg"] {
            #expect(content.contains("\n\(line)\n"), "模板.md 里有「\(line)」：\n\(content)")
        }
        #expect(!content.contains("secondary") && !content.contains("surface"), "没单独调过的辅助、衬底不写")
        #expect(!content.contains("imageMaxHeight"), "和默认值一样的图片最大高不写")
        #expect(content.hasSuffix("\n\n" + (saved?["markdown"] as? String ?? "?").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"), "正文在后面：\(content.suffix(120))")

        #expect(reopened?["listed"] as? [String] == builtIns + ["user_template_我的清单"], "重新打开 App 还在")
        #expect(reopened?["asDraft"] as? [AnyHashable] == [true, "glow", "湖边一晚"] as [AnyHashable])
        let first = reopened?["first"] as? [Int] ?? []
        #expect(first.count == 2 && first[0] >= 2 && first[1] > 0, "firstPage 认得用户模板：\(first)")
        let draft = reopened?["draft"] as? [String: Any]
        #expect(draft?["readOnly"] as? Bool == false && draft?["title"] as? String == "湖边一晚" && draft?["theme"] as? String == "glow")
        let colors = draft?["colors"] as? [String: String]
        #expect(colors?["bg"] == "#fff8f0" && colors?["text"] == "#222222" && colors?["accent"] == "#d9480f", "\(colors ?? [:])")
        #expect(draft?["tuned"] as? [String] == [], "辅助、衬底按三色规则推，没单独调过")
        #expect((draft?["fonts"] as? [String: String])?["zh"] == "lxgw-wenkai" && (draft?["fonts"] as? [String: String])?["en"] == "theme")
        let cover = draft?["cover"] as? [String: Any]
        #expect(cover?["enabled"] as? Bool == true && cover?["subtitle"] as? String == "副标题" && cover?["image"] as? String == imageId, "\(cover ?? [:])")
        #expect(draft?["caption"] as? String == "第一段\n\n#话题")
        #expect(draft?["type"] as? [Double] == [30, 1.6, 1048], "字号、行距照模板，没写的图片最大高用默认值")
        #expect(draft?["markdown"] as? String == (saved?["markdown"] as? String ?? "?").trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(reopened?["src"] as? String == "data:image/jpeg;base64", "用户模板的图片由壳读成 data URL")
        #expect(reopened?["issues"] as? [String] == [])
        #expect(reopened?["decoded"] as? [Bool] == [true], "读回来的图片能出图")
        #expect((reopened?["removeBuiltIn"] as? String ?? "").contains("自带"), "自带的不能删")
        #expect(reopened?["afterRemove"] as? [String] == builtIns)
        #expect((reopened?["removeAgain"] as? String ?? "").contains("没有这个模板"))
        #expect(removedOnDisk && folderStays, "删的是那一套的文件夹，模板文件夹本身留着")
        #expect(harness.pageErrors == [])
    }
}
