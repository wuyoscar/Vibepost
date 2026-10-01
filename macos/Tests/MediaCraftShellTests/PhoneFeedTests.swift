import Foundation
import Testing

/// 手机预览的「发现页」「主页」：看这一篇混在最近几篇稿子里的样子。发现页双列瀑布流（首图、标题、头像昵称、点赞位），
/// 这一篇在右列最上面；主页是资料头加三列网格，这一篇在第一格。别的稿子的首图停手后逐篇生成、缓存，
/// 不跟打字抢主线程；这一篇的首图随出图实时更新。⌘1–3 只在焦点在手机预览里时切换视图。
@MainActor
struct PhoneFeedTests {
    static let helpers = PhonePreviewTests.helpers + """
        window.waitFor = async (condition, timeout = 60000) => {
          const start = performance.now();
          while (!(await condition())) {
            if (performance.now() - start > timeout) throw new Error("等不到：" + condition);
            await pause(50);
          }
        };
        window.feedList = () => phone().querySelector('[role="list"][aria-label="发现页"]');
        window.gridList = () => phone().querySelector('[role="list"][aria-label="主页网格"]');
        // 发现页的两列，各自从上到下每格的名字
        window.columns = () => [...feedList().children].map((column) => [...column.children].map((tile) => tile.getAttribute("aria-label")));
        window.feedTiles = () => [...feedList().querySelectorAll('[role="listitem"]')];
        window.gridTiles = () => [...gridList().querySelectorAll('[role="listitem"]')];
        window.tileNamed = (tiles, name) => tiles.find((tile) => tile.getAttribute("aria-label") === name);
        window.mine = (tiles) => tiles.filter((tile) => tile.getAttribute("aria-current") === "true");
        window.cover = (tile) => tile.querySelector("canvas");
        window.coverPixels = (tile) => [...cover(tile).getContext("2d").getImageData(0, 0, cover(tile).width, cover(tile).height).data];
        // 首图画上了的格子数（没画的格子是透明的）
        window.filled = (tiles) => tiles.filter((tile) => cover(tile).getContext("2d").getImageData(2, 2, 1, 1).data[3] === 255).length;
        window.shrinkLike = (tile, source) => {
          const canvas = document.createElement("canvas");
          canvas.width = cover(tile).width;
          canvas.height = cover(tile).height;
          const context = canvas.getContext("2d");
          context.imageSmoothingQuality = "high";
          context.drawImage(source, 0, 0, canvas.width, canvas.height);
          return [...context.getImageData(0, 0, canvas.width, canvas.height).data];
        };
        window.meanDiff = (a, b) => a.reduce((sum, value, index) => sum + Math.abs(value - b[index]), 0) / a.length;
        window.busy = (list) => list.getAttribute("aria-busy") === "true";
        window.viewPressed = () => [...phone().querySelectorAll('[aria-label="手机预览的视图"] [aria-pressed="true"]')].map((button) => button.textContent);
        window.screenShown = () => ["卡片", "发现页", "主页网格"].filter((label) => shown(phone().querySelector(`[aria-label="${label}"]`)));
    """

    @Test("发现页：双列瀑布流里有这一篇（右列最上）与最近 9 篇别的稿子（不含说明书与长文），首图就是各篇的第一张卡片；主页：资料头与三列网格，这一篇在第一格")
    func showsRecentDraftsAroundThisOne() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            // 11 篇别的稿子（先建的更旧），一篇长文，一篇纯黑主题
            for (let index = 1; index <= 11; index += 1) {
              await mc.drafts.create({ title: `旧稿 ${index}`, markdown: `# 旧稿 ${index}\\n\\n` + longText(index % 3 + 1) });
            }
            await mc.drafts.create({ title: "长文一篇", markdown: "长文不进网格", mode: "article" });
            await mc.drafts.create({ title: "夜里的稿子", markdown: "# 夜里\\n\\n" + longText(2), theme: "ink" });
            await mc.drafts.create({ title: "这一篇", markdown: "# 这一篇\\n\\n" + longText(6) });
            await mc.profile.update({ name: "小周", handle: "zhou_2026" });
            ui.click("手机预览");
            await phoneSynced();
            ui.click("发现页");
            await waitFor(() => feedTiles().length && !busy(feedList()));
            const list = await mc.drafts.list();
            const recent = list.filter((item) => !item.builtIn && !item.current && item.mode === "cards").slice(0, 9);
            const firstPages = {};
            for (const item of recent) firstPages[item.title] = (await mc.drafts.firstPage(item.id)).canvas;
            const [current] = await mc.render.canvases();
            const text = phone().textContent.replace(/\\s+/g, " ");
            const feed = {
              pressed: viewPressed(),
              screens: screenShown(),
              columns: columns(),
              recent: recent.map((item) => item.title),
              mine: mine(feedTiles()).map((tile) => tile.getAttribute("aria-label")),
              coverDiffs: recent.map((item) => meanDiff(coverPixels(tileNamed(feedTiles(), item.title)), shrinkLike(tileNamed(feedTiles(), item.title), firstPages[item.title]))),
              mineDiff: meanDiff(coverPixels(mine(feedTiles())[0]), shrinkLike(mine(feedTiles())[0], current)),
              nightCorner: pixel(cover(tileNamed(feedTiles(), "夜里的稿子")), 0.01, 0.01),
              tile: [...tileNamed(feedTiles(), "这一篇").querySelectorAll("p, span")].map((node) => node.textContent.trim()).filter(Boolean),
              guides: list.filter((item) => item.builtIn).some((item) => text.includes(item.title)),
              brand: /小红书|RED|Instagram|抖音|微博/i.test(text),
              clock: /\\d{1,2}:\\d{2}/.test(text),
            };
            ui.click("主页");
            await waitFor(() => gridTiles().length && !busy(gridList()));
            const profile = {
              pressed: viewPressed(),
              screens: screenShown(),
              head: [...phone().querySelectorAll(".phone-profile-head p")].filter(shown).map((node) => node.textContent.replace(/\\s+/g, " ").trim()),
              grid: gridTiles().map((tile) => tile.getAttribute("aria-label")),
              mine: mine(gridTiles()).map((tile) => tile.getAttribute("aria-label")),
              columns: getComputedStyle(gridList()).gridTemplateColumns.split(" ").length,
              coverDiffs: recent.map((item) => meanDiff(coverPixels(tileNamed(gridTiles(), item.title)), shrinkLike(tileNamed(gridTiles(), item.title), firstPages[item.title]))),
            };
            ui.click("笔记");
            const note = { pressed: viewPressed(), screens: screenShown(), counter: counter() };
            return { feed, profile, note };
        """) as? [String: Any]
        await harness.tearDown()

        let feed = result?["feed"] as? [String: Any] ?? [:]
        let recent = feed["recent"] as? [String] ?? []
        #expect(recent == ["夜里的稿子"] + (4...11).reversed().map { "旧稿 \($0)" }, "最近 9 篇，新的在前，不含说明书与长文：\(recent)")
        #expect(feed["pressed"] as? [String] == ["发现页"])
        #expect(feed["screens"] as? [String] == ["发现页"], "笔记收起，只显示发现页")
        let columns = feed["columns"] as? [[String]] ?? []
        #expect(columns.count == 2)
        #expect(columns.first == [recent[0], recent[1], recent[3], recent[5], recent[7]], "左列：\(columns)")
        #expect(columns.last == ["这一篇", recent[2], recent[4], recent[6], recent[8]], "这一篇在右列最上面：\(columns)")
        #expect(feed["mine"] as? [String] == ["这一篇"], "这一篇标为当前")
        let diffs = feed["coverDiffs"] as? [Double] ?? []
        #expect(diffs.count == 9 && diffs.allSatisfy { $0 < 1 }, "首图是各篇的第一张卡片：\(diffs)")
        #expect((feed["mineDiff"] as? Double ?? 99) < 1, "这一篇的首图是预览的第一页")
        #expect(feed["nightCorner"] as? [Int] == [12, 12, 12], "按各篇自己的主题出图")
        #expect(feed["tile"] as? [String] == ["这一篇", "小周", "赞"], "一格：标题、昵称、点赞位：\(feed["tile"] ?? "")")
        #expect(feed["guides"] as? Bool == false, "没有内置说明书")
        #expect(feed["brand"] as? Bool == false, "不用任何平台的标识")
        #expect(feed["clock"] as? Bool == false)

        let profile = result?["profile"] as? [String: Any] ?? [:]
        #expect(profile["pressed"] as? [String] == ["主页"])
        #expect(profile["screens"] as? [String] == ["主页网格"])
        #expect(profile["head"] as? [String] == ["小周", "账号：zhou_2026", "— 关注— 粉丝— 获赞"], "\(profile["head"] ?? "")")
        #expect(profile["grid"] as? [String] == ["这一篇"] + recent, "这一篇在第一格，其余按最近修改")
        #expect(profile["mine"] as? [String] == ["这一篇"])
        #expect(profile["columns"] as? Int == 3, "三列网格")
        let gridDiffs = profile["coverDiffs"] as? [Double] ?? []
        #expect(gridDiffs.count == 9 && gridDiffs.allSatisfy { $0 < 1 }, "\(gridDiffs)")
        let note = result?["note"] as? [String: Any] ?? [:]
        #expect(note["pressed"] as? [String] == ["笔记"])
        #expect(note["screens"] as? [String] == ["卡片"], "切回笔记")
        #expect((note["counter"] as? String)?.hasPrefix("1/") == true)
        #expect(harness.pageErrors == [])
    }

    @Test("这一篇的格子随编辑实时更新：改标题、正文、主题后发现页与主页里跟着变；别的稿子的首图用缓存，不重画")
    func currentTileFollowsEdits() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ title: "别的稿子", markdown: "# 别的\\n\\n" + longText(3) });
            await mc.drafts.create({ title: "第一版", markdown: "# 第一版\\n\\n" + longText(3) });
            ui.click("手机预览");
            ui.click("发现页");
            await waitFor(() => feedTiles().length === 2 && !busy(feedList()));
            const other = cover(tileNamed(feedTiles(), "别的稿子"));
            const otherBefore = coverPixels(tileNamed(feedTiles(), "别的稿子"));
            const matchesPreview = async (tile) => meanDiff(coverPixels(tile), shrinkLike(tile, (await mc.render.canvases())[0])) < 1;

            await mc.drafts.update({ title: "第二版", markdown: "# 第二版\\n\\n只有一段。" });
            await waitFor(async () => mine(feedTiles())[0]?.getAttribute("aria-label") === "第二版" && await matchesPreview(mine(feedTiles())[0]));
            const edited = {
              title: mine(feedTiles())[0].querySelector("p").textContent,
              corner: pixel(cover(mine(feedTiles())[0]), 0.01, 0.01),
            };
            await mc.themes.apply("ink");
            await waitFor(async () => await matchesPreview(mine(feedTiles())[0]));
            const night = pixel(cover(mine(feedTiles())[0]), 0.01, 0.01);

            ui.click("主页");
            await waitFor(() => gridTiles().length === 2 && !busy(gridList()));
            await mc.drafts.update({ title: "第三版", markdown: "# 第三版\\n\\n又改了。" });
            await waitFor(async () => gridTiles()[0].getAttribute("aria-label") === "第三版" && await matchesPreview(gridTiles()[0]));
            const grid = { first: gridTiles()[0].getAttribute("aria-label"), mine: mine(gridTiles()).length };
            ui.click("发现页");
            await waitFor(async () => mine(feedTiles())[0]?.getAttribute("aria-label") === "第三版" && await matchesPreview(mine(feedTiles())[0]));
            return {
              edited, night, grid,
              otherSame: cover(tileNamed(feedTiles(), "别的稿子")) === other,
              otherDiff: meanDiff(otherBefore, coverPixels(tileNamed(feedTiles(), "别的稿子"))),
            };
        """) as? [String: Any]
        await harness.tearDown()

        let edited = result?["edited"] as? [String: Any] ?? [:]
        #expect(edited["title"] as? String == "第二版", "标题跟着改")
        #expect(edited["corner"] as? [Int] == [255, 255, 255])
        #expect(result?["night"] as? [Int] == [12, 12, 12], "换主题后首图跟着变")
        let grid = result?["grid"] as? [String: Any] ?? [:]
        #expect(grid["first"] as? String == "第三版", "主页第一格跟着改")
        #expect(grid["mine"] as? Int == 1)
        #expect(result?["otherSame"] as? Bool == true, "别的稿子的格子不重建")
        #expect((result?["otherDiff"] as? Double ?? 99) == 0, "别的稿子的首图不变")
        #expect(harness.pageErrors == [])
    }

    @Test("别的稿子的首图停手后才逐篇生成：按键时停下；生成时每次只占主线程一小会；生成到一半改稿，出图照常不用等")
    func thumbnailsNeverBlockTyping() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            const png = (width, height, hue) => new Promise((resolve) => {
              const canvas = document.createElement("canvas");
              canvas.width = width;
              canvas.height = height;
              const context = canvas.getContext("2d");
              for (let y = 0; y < height; y += 40) {
                context.fillStyle = `hsl(${hue + y / 10}, 60%, 60%)`;
                context.fillRect(0, y, width, 40);
              }
              canvas.toBlob((blob) => resolve(new File([blob], `图${hue}.png`, { type: "image/png" })), "image/png");
            });
            // 6 篇重稿子：大图、表格、代码与长文
            const heavy = async (index) => {
              await mc.drafts.create({ title: `重稿 ${index}`, markdown: "占位" });
              const [id] = await mc.media.import([await png(2400, 1800, index * 40)], { at: 0 });
              await mc.drafts.update({ markdown: [`# 重稿 ${index}`, `[[image:${id}]]`, longText(12),
                "| 列一 | 列二 |\\n| --- | --- |\\n| 甲 | 乙 |", "```\\nconst answer = 42;\\n```", longText(12)].join("\\n\\n") });
            };
            for (let index = 1; index <= 6; index += 1) await heavy(index);
            await mc.drafts.create({ title: "这一篇", markdown: "# 这一篇\\n\\n" + longText(20) });
            const edit = async (markdown) => {
              const start = performance.now();
              await mc.drafts.update({ markdown });
              return performance.now() - start;
            };
            const idleEdit = await edit("# 这一篇\\n\\n" + longText(21));
            ui.click("手机预览");
            ui.click("发现页");
            await waitFor(() => feedTiles().length === 7);

            // 一直在按键：一张都不生成
            const editor = document.querySelector('[aria-label="正文"]'); // 编辑器的正文区（contenteditable）
            for (let index = 0; index < 12; index += 1) {
              editor.dispatchEvent(new KeyboardEvent("keydown", { key: "Shift", bubbles: true }));
              await pause(120);
            }
            const whileTyping = filled(feedTiles());

            // 停手后逐篇生成：主线程最长被占多久（MessageChannel 一直来回发消息，量相邻两次之间的空档）
            const channel = new MessageChannel();
            let last = performance.now();
            let longest = 0;
            let pinging = true;
            channel.port1.onmessage = () => {
              const now = performance.now();
              longest = Math.max(longest, now - last);
              last = now;
              if (pinging) channel.port2.postMessage(0);
            };
            channel.port2.postMessage(0);
            // 生成到第三张时改稿：出图用时和平时差不多
            await waitFor(() => filled(feedTiles()) >= 3);
            const midEdit = await edit("# 这一篇\\n\\n" + longText(22));
            await waitFor(() => !busy(feedList()));
            pinging = false;
            return { idleEdit, whileTyping, longest, midEdit, afterTyping: filled(feedTiles()) };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["whileTyping"] as? Int == 1, "一直在按键时只有这一篇（直接用预览的第一页），别的不生成")
        #expect(result?["afterTyping"] as? Int == 7, "停手后 6 篇都补上")
        let longest = result?["longest"] as? Double ?? 999
        #expect(longest < 120, "生成首图时主线程最长只被占 \(Int(longest)) ms")
        let idleEdit = result?["idleEdit"] as? Double ?? 0
        let midEdit = result?["midEdit"] as? Double ?? 999
        #expect(midEdit < idleEdit * 2 + 150, "生成到一半改稿：出图 \(Int(midEdit)) ms，平时 \(Int(idleEdit)) ms")
        #expect(harness.pageErrors == [])
    }

    @Test("⌘1 / ⌘2 / ⌘3 在焦点落在手机预览里时切换视图；焦点在编辑器里时 ⌘2 还是小标题，手机预览不动")
    func commandDigitsSwitchViews() async throws {
        let harness = ShellHarness(onboarding: false)
        try await harness.load()
        let result = try await harness.evaluate(Self.helpers + """
            await mc.drafts.create({ markdown: "第一行\\n\\n" + longText(3) });
            ui.click("手机预览");
            await phoneSynced();
            const key = (target, digit) => target.dispatchEvent(new KeyboardEvent("keydown", { key: String(digit), metaKey: true, bubbles: true, cancelable: true }));
            // 点进手机预览（落在没有焦点的地方），焦点交给整层
            phone().querySelector(".phone-post").dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, button: 0 }));
            const focusedPhone = phone().contains(document.activeElement);
            const steps = [];
            for (const digit of [2, 3, 1]) {
              key(document.activeElement, digit);
              steps.push(viewPressed()[0]);
            }
            key(carousel(), 3);
            steps.push(viewPressed()[0]);
            ui.click("笔记");

            await mc.editor.select(0);
            const inEditor = document.activeElement.closest("#markdownEditor") !== null;
            key(document.activeElement, 2);
            await pause(100);
            return { focusedPhone, steps, inEditor, afterEditor: viewPressed(), markdown: (await mc.drafts.current()).markdown.split("\\n")[0] };
        """) as? [String: Any]
        await harness.tearDown()

        #expect(result?["focusedPhone"] as? Bool == true, "点进手机预览后焦点在里面")
        #expect(result?["steps"] as? [String] == ["发现页", "主页", "笔记", "主页"], "⌘2 ⌘3 ⌘1，轮播里按 ⌘3 也行")
        #expect(result?["inEditor"] as? Bool == true)
        #expect(result?["afterEditor"] as? [String] == ["笔记"], "焦点在编辑器里时不切换")
        #expect(result?["markdown"] as? String == "## 第一行", "编辑器里的 ⌘2 照常是小标题")
        #expect(harness.pageErrors == [])
    }
}
