import Foundation
@testable import MediaCraftShell

/// 代替 AirDrop：记录每次发送的文件列表。
final class FakeIPhoneSender: IPhoneSender {
    private(set) var batches: [[URL]] = []
    func send(_ files: [URL]) throws { batches.append(files) }
}

/// 代替系统剪贴板，避免测试覆盖你正在用的剪贴板。
final class FakeClipboard: TextClipboard {
    private(set) var text: String?
    private(set) var html: String?
    func write(_ text: String) { self.text = text }
    func writeRich(html: String, text: String) {
        self.html = html
        self.text = text
    }
}

/// 代替触控板的触感反馈：按顺序记下页面要的每一下。
final class FakeHaptics: HapticPerformer {
    private(set) var patterns: [HapticPattern] = []
    func perform(_ pattern: HapticPattern) { patterns.append(pattern) }
}
