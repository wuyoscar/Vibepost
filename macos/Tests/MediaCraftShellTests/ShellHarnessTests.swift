import Testing

/// 测试 harness 自身：全量一次要开上百个 harness，每个都得从空的本机存储开始、都打得开 IndexedDB。
@MainActor
struct ShellHarnessTests {
    /// WebKit 在同一个进程里最多接约 185 个持久化数据存储（之后 IndexedDB 打不开），开得比它多才测得出来。
    static let moreThanWebKitAllows = 200

    static let openIndexedDB = """
        return await new Promise((resolve) => {
          const request = indexedDB.open("harness-check");
          request.onsuccess = () => { request.result.close(); resolve("ok"); };
          request.onerror = () => resolve(String(request.error));
        });
    """

    @Test("同一个测试进程里一个接一个开的 harness 比 WebKit 允许的持久化数据存储还多，每个都打得开 IndexedDB")
    func manyHarnessesInOneProcess() async throws {
        var failures: [String] = []
        for index in 1...Self.moreThanWebKitAllows {
            let harness = ShellHarness()
            try await harness.prepareStorage("")
            let result = try await harness.evaluate(Self.openIndexedDB) as? String
            await harness.tearDown()
            if result != "ok" { failures.append("第 \(index) 个：\(result ?? "nil")") }
            if failures.count >= 3 { break }
        }
        #expect(failures == [])
    }

    @Test("下一个 harness 接着用上一个的存储，但它是空的：稿子、localStorage、看过新手引导的记录都不留下")
    func reusedStorageStartsEmpty() async throws {
        let first = ShellHarness()
        try await first.load()
        let written = try await first.evaluate("""
            const mc = window.mediacraft;
            await mc.drafts.list(); // 稿件存储就绪；新环境的新手引导这时已经弹出
            ui.click("跳过");
            await mc.drafts.create({ markdown: "上一个 harness 写的稿子" });
            localStorage.setItem("harness-check", "上一个 harness 写的");
            return (await mc.drafts.list()).filter((draft) => !draft.builtIn).length;
        """) as? Int
        await first.tearDown()

        let second = ShellHarness()
        try await second.load()
        let found = try await second.evaluate("""
            const mc = window.mediacraft;
            const own = (await mc.drafts.list()).filter((draft) => !draft.builtIn).length;
            return { own, local: localStorage.getItem("harness-check") ?? "", tour: ui.find("跳过") !== null };
        """) as? [String: Any]
        await second.tearDown()

        #expect(written == 1)
        #expect(
            second.webView.configuration.websiteDataStore.identifier == first.webView.configuration.websiteDataStore.identifier,
            "串行跑时循环用同一个存储"
        )
        #expect(found?["own"] as? Int == 0, "上一个 harness 的稿子不留下")
        #expect(found?["local"] as? String == "", "上一个 harness 的 localStorage 不留下")
        #expect(found?["tour"] as? Bool == true, "看过新手引导的记录不留下，新环境照常弹")
        #expect(first.pageErrors == [])
        #expect(second.pageErrors == [])
    }
}
