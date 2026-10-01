import Testing

@MainActor
struct OfflineTests {
    @Test("页面不向外网请求任何资源，断网也能用")
    func pageLoadsNothingFromNetwork() async throws {
        let harness = ShellHarness()
        try await harness.load()

        let external = try await harness.evaluate("""
            return performance.getEntriesByType("resource")
              .map((entry) => entry.name)
              .filter((url) => !url.startsWith("mediacraft:") && !url.startsWith("blob:") && !url.startsWith("data:"));
        """) as? [String]
        let librariesReady = try await harness.evaluate(
            "return typeof html2canvas === 'function' && typeof JSZip === 'function' && typeof CodeMirror?.EditorView === 'function'"
        ) as? Bool
        await harness.tearDown()

        #expect(external == [])
        #expect(librariesReady == true)
        #expect(harness.pageErrors == [])
    }
}
