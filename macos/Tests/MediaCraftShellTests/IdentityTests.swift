import Testing

/// 署名：新装时名字空着、头像是 App 图标（卡片上不留空的小签，发布检查提醒一句）；说明书署 Vibepost；
/// 填了名字后每页的小签写名字，第一页的带头像。
@MainActor
struct IdentityTests {
    static let avatarPath = "brand/icon-256.png"

    @Test("没填过署名时：名字与账号空着，头像是 App 图标")
    func defaultIdentityIsUnnamed() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            await window.mediacraft.drafts.create();
            const profile = await window.mediacraft.profile.get();
            const avatar = await new Promise((resolve, reject) => {
              const image = new Image();
              image.onload = () => resolve(image);
              image.onerror = reject;
              image.src = profile.avatar;
            });
            return {
              name: profile.name,
              handle: profile.handle,
              avatar: profile.avatar,
              size: [avatar.naturalWidth, avatar.naturalHeight],
              preview: document.querySelector('img[alt="头像"]').getAttribute("src"),
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["name"] as? String == "")
        #expect(result?["handle"] as? String == "")
        #expect(result?["avatar"] as? String == Self.avatarPath)
        #expect(result?["size"] as? [Int] == [256, 256])
        #expect(result?["preview"] as? String == Self.avatarPath)
        #expect(harness.pageErrors == [])
    }

    @Test("还没填署名：备忘的第一页小签只有头像、之后的页不画小签；手帐的胶带只写页码；结尾页不留名字；手机预览与发布检查都说一句；填上就好；说明书署 Vibepost")
    func unnamedBylineStaysTidy() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(CardDomProbe.script + """
            const mc = window.mediacraft;
            const until = async (condition) => {
              for (let waited = 0; waited < 15000; waited += 50) {
                const value = await condition();
                if (value) return value;
                await new Promise((resolve) => setTimeout(resolve, 50));
              }
              throw new Error(`等不到：${condition}`);
            };
            const markdown = Array.from({ length: 14 }, (_, index) =>
              `第 ${index + 1} 段：写得足够长，才能把内容推到后面的页面。`).join("\\n\\n") + "\\n\\n[[结尾]]\\n\\n下期见。";
            const own = await mc.drafts.create({ mode: "cards", theme: "notes", markdown });
            await mc.render.pages();
            const shadow = (index) => stageCards()[index].shadowRoot;
            const count = stageCards().length;
            const notes = {
              first: [shadow(0).querySelector(".mc-notes-tag")?.className ?? "", shadow(0).querySelector(".mc-notes-tag")?.textContent.trim() ?? null,
                Boolean(shadow(0).querySelector(".mc-notes-tag .mc-avatar"))],
              later: Array.from({ length: count - 1 }, (_, index) => shadow(index + 1).querySelector(".mc-notes-tag") !== null),
              end: [Boolean(shadow(count - 1).querySelector(".mc-signature .mc-avatar")), shadow(count - 1).querySelector(".mc-sig-name") !== null],
            };
            await mc.drafts.update({ theme: "journal" });
            await mc.render.pages();
            const tapes = [shadow(0), shadow(1)].map((root) => root.querySelector(".mc-tape")?.textContent.trim() ?? null);

            ui.click("手机预览");
            const phone = await until(() => document.querySelector(".phone-name")?.textContent);
            ui.click("手机预览");
            const checkLabels = () => [...document.querySelectorAll('[role="dialog"][aria-labelledby="publishCheckTitle"] .check-label')]
              .map((node) => node.textContent);
            ui.click("检查");
            const reminded = await until(() => checkLabels().includes("署名还没填"));
            await mc.profile.update({ name: "小明" });
            await until(() => !checkLabels().includes("署名还没填"));
            await mc.render.pages();
            const named = shadow(1).querySelector(".mc-tape")?.textContent.trim();

            const guide = (await mc.drafts.list()).find((draft) => draft.builtIn);
            await mc.drafts.open(guide.id);
            await mc.render.pages();
            const guideTag = shadow(0).querySelector(".mc-notes-tag")?.textContent.trim();
            // 回到自己的稿子：署名还是自己的
            await mc.drafts.open(own.id);
            return { count, notes, tapes, phone, reminded, named, guideTag, profile: (await mc.profile.get()).name };
        """) as? [String: Any]
        await harness.tearDown()

        let notes = result?["notes"] as? [String: Any] ?? [:]
        let first = notes["first"] as? [Any] ?? []
        #expect((result?["count"] as? Int ?? 0) >= 3, "要有好几页，还有结尾页")
        let firstClass = first.first as? String ?? ""
        let firstText = first.count > 1 ? first[1] as? String : nil
        let firstAvatar = first.count > 2 ? first[2] as? Bool : nil
        #expect(firstClass.contains("is-avatar-only") && firstText == "" && firstAvatar == true, "第一页的小签只有头像：\(first)")
        #expect((notes["later"] as? [Bool] ?? [true]).allSatisfy { !$0 }, "之后的页不画空的小签")
        #expect(notes["end"] as? [Bool] == [true, false], "结尾页有头像、没有空着的名字")
        #expect(result?["tapes"] as? [String] == ["", "02"], "手帐：第一页的胶带只有头像，之后只写页码，没有多余的「·」")
        #expect(result?["phone"] as? String == "还没填署名")
        #expect(result?["reminded"] as? Bool == true, "发布检查提醒「署名还没填」")
        #expect(result?["named"] as? String == "小明 · 02", "填上名字后照常写名字与页码")
        #expect(result?["guideTag"] as? String == "Vibepost", "说明书署 Vibepost")
        #expect(result?["profile"] as? String == "小明", "看说明书不改你的署名")
        #expect(harness.pageErrors == [])
    }

    @Test("署名（默认主题备忘）：每页左上一个写着名字的小签，只有第一页的带头像；右上是页码；没有 @账号，不画页脚，页眉不压正文")
    func signatureOnEveryPageTag() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(CardDomProbe.script + """
            const mc = window.mediacraft;
            await mc.drafts.create({
              mode: "cards",
              markdown: Array.from({ length: 16 }, (_, index) =>
                `第 ${index + 1} 段：写得足够长，才能把内容推到后面的页面，检验页眉、页脚与分页的位置。`).join("\\n\\n"),
            });
            await mc.profile.update({ name: "wuyoscar" });

            // 出图后读出每页卡片上的字与图（逻辑坐标），按页码（从 1 起）归好
            const summaries = await mc.render.refresh();
            const canvases = await mc.render.canvases();
            const calls = stageCards().flatMap((host, index) => cardDom(host).map((call) => ({ ...call, page: index + 1 })));
            const { colors } = await mc.drafts.current();
            const profile = await mc.profile.get();

            const bg = colors.bg;
            const [bgR, bgG, bgB] = [1, 3, 5].map((index) => Number.parseInt(bg.slice(index, index + 2), 16));
            // 一块区域里不是底色的像素个数（逻辑坐标）。
            const inkCount = (canvas, left, top, right, bottom) => {
              const { data } = canvas.getContext("2d").getImageData(left * 2, top * 2, (right - left) * 2, (bottom - top) * 2);
              let count = 0;
              for (let i = 0; i < data.length; i += 4) {
                if (data[i] !== bgR || data[i + 1] !== bgG || data[i + 2] !== bgB) count += 1;
              }
              return count;
            };
            const total = summaries.length;
            const pages = summaries.map((page, index) => {
              const canvas = canvases[index];
              const bounds = page.contentBounds;
              const number = index + 1;
              const texts = calls.filter((call) => call.kind === "text" && call.page === number);
              const footer = texts.filter((call) => call.y > bounds.bottom);
              const contentBottom = Math.max(...page.items.map((item) => item.y + item.height));
              return {
                showHeader: page.header,
                top: bounds.top,
                headerTexts: texts.filter((call) => call.y < bounds.top).map((call) => call.text),
                avatarSizes: calls
                  .filter((call) => call.kind === "image" && call.page === number && call.src === profile.avatar)
                  .map((call) => [call.args.at(-2), call.args.at(-1)]),
                footerTexts: footer.map((call) => call.text),
                footerClear: footer.every((call) => call.top >= bounds.bottom) && contentBottom <= bounds.bottom,
                bottomInk: inkCount(canvas, 0, bounds.bottom, 864, 1152),
              };
            });
            return { total, name: profile.name, pages };
        """) as? [String: Any]
        await harness.tearDown()

        let total = result?["total"] as? Int ?? 0
        let pages = result?["pages"] as? [[String: Any]] ?? []
        #expect(total >= 3, "稿子要够三页")
        guard let first = pages.first, pages.count == total else { return }

        #expect(first["showHeader"] as? Bool == true)
        let avatarSizes = first["avatarSizes"] as? [[Double]] ?? []
        #expect(avatarSizes.count == 1, "第一页的小签带头像")
        #expect(avatarSizes.allSatisfy { $0.allSatisfy { (26...30).contains($0) } }, "小签里的头像约 28 逻辑像素：\(avatarSizes)")
        for (index, page) in pages.enumerated() {
            let label = "第 \(index + 1) 页"
            #expect(page["headerTexts"] as? [String] == ["wuyoscar", "\(index + 1)/\(total)"], "\(label)：小签写名字（没有 @账号），右上是页码")
            if index > 0 {
                #expect(page["avatarSizes"] as? [[Double]] == [], "\(label)：只有第一页的小签带头像")
                #expect((page["top"] as? Double) == (first["top"] as? Double), "\(label)：正文和第一页一样高")
            }
            #expect(page["footerTexts"] as? [String] == [], "\(label)：不画页脚")
            #expect(page["footerClear"] as? Bool == true, "\(label)：正文没出正文区")
            #expect(page["bottomInk"] as? Int == 0, "\(label)：正文区下面是空白")
        }
        #expect(harness.pageErrors == [])
    }

    @Test("界面与页面标题叫 Vibepost")
    func appIsNamedVibepost() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate("""
            return {
              title: document.title,
              brand: document.querySelector("h1")?.textContent ?? "",
            };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["title"] as? String == "Vibepost")
        #expect(result?["brand"] as? String == "Vibepost")
        #expect(harness.pageErrors == [])
    }

    @Test("裁剪过的头像：卡片上的头像是裁剪框里的那一块")
    func croppedAvatarOnCards() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let result = try await harness.evaluate(CardDomProbe.script + """
            const mc = window.mediacraft;
            // 左红右蓝的头像，裁右半边
            const source = Object.assign(document.createElement("canvas"), { width: 100, height: 50 });
            const context = source.getContext("2d");
            context.fillStyle = "#ff0000";
            context.fillRect(0, 0, 50, 50);
            context.fillStyle = "#0000ff";
            context.fillRect(50, 0, 50, 50);
            await mc.drafts.create({ mode: "cards", markdown: "一段正文" });
            await mc.profile.update({ avatar: source.toDataURL("image/png") });
            await mc.profile.update({ avatarCrop: { x: 50, y: 0, width: 50, height: 50 } });
            await mc.render.refresh();
            const [avatar] = cardDom(stageCards()[0]).filter((call) => call.kind === "image");
            const image = new Image();
            image.src = avatar.src;
            await image.decode();
            const probe = Object.assign(document.createElement("canvas"), { width: image.naturalWidth, height: image.naturalHeight });
            probe.getContext("2d").drawImage(image, 0, 0);
            const pixel = (x) => [...probe.getContext("2d").getImageData(Math.round(x * probe.width), probe.height / 2, 1, 1).data.slice(0, 3)];
            return { square: probe.width === probe.height, left: pixel(0.1), right: pixel(0.9) };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["square"] as? Bool == true)
        #expect(result?["left"] as? [Int] == [0, 0, 255], "裁剪框里只有蓝色那一半")
        #expect(result?["right"] as? [Int] == [0, 0, 255])
        #expect(harness.pageErrors == [])
    }
}
