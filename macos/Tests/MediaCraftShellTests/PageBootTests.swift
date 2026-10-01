import Testing

@MainActor
struct PageBootTests {
    @Test("页面在壳里以无账号本地模式启动，没有任何报错")
    func pageBootsInShellWithoutErrors() async throws {
        let harness = ShellHarness()
        try await harness.load()

        let origin = try await harness.evaluate("return location.origin") as? String
        let isSafari = try await harness.evaluate("return /Safari\\//.test(navigator.userAgent)") as? Bool
        await harness.tearDown()

        #expect(origin == "mediacraft://app")
        #expect(isSafari == true, "UA 需含 Safari，页面才会走 Safari 分支")
        #expect(harness.pageErrors == [])
    }
}
