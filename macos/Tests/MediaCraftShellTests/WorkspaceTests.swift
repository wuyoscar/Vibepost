import Testing

@MainActor
struct WorkspaceTests {
    @Test("工作区不显示「Made by」署名")
    func workspaceHasNoCredit() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let text = try await harness.evaluate("return document.body.innerText") as? String ?? ""
        await harness.tearDown()
        #expect(!text.contains("Made by"))
    }
}
