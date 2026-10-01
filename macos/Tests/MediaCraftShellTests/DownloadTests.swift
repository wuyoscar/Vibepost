import Foundation
import Testing

@MainActor
struct DownloadTests {
    @Test("页面里的下载保存到下载文件夹，同名文件不覆盖")
    func pageDownloadsLandOnDisk() async throws {
        let harness = ShellHarness()
        try await harness.load()

        _ = try await harness.evaluate("""
            await window.MediaCraftNative.saveFile(new Blob(["第一份"], { type: "text/plain" }), "卡片.txt");
            await window.MediaCraftNative.saveFile(new Blob(["第二份"], { type: "text/plain" }), "卡片.txt");
        """)
        let first = harness.downloadsDirectory.appendingPathComponent("卡片.txt")
        let second = harness.downloadsDirectory.appendingPathComponent("卡片 2.txt")
        try await waitUntil { FileManager.default.fileExists(atPath: second.path) }
        let contents = [try String(contentsOf: first, encoding: .utf8), try String(contentsOf: second, encoding: .utf8)]
        await harness.tearDown()

        #expect(contents.sorted() == ["第一份", "第二份"])
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return }
        try await Task.sleep(for: .milliseconds(50))
    }
}
