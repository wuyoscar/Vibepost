import AppKit
import WebKit

/// 触控板的触感反馈。生产环境是 `NSHapticFeedbackManager`（Force Touch 触控板、手指还按在板上时才震），测试里换成假的记下每一次。
@MainActor
public protocol HapticPerformer {
    func perform(_ pattern: HapticPattern)
}

/// 页面能要的两种（`MediaCraftNative.haptic(pattern)`）：对齐、吸住（alignment），跨过一档（level-change）。
public enum HapticPattern: String, Sendable {
    case alignment
    case levelChange = "level-change"
}

public struct SystemHaptics: HapticPerformer {
    nonisolated public init() {}

    public func perform(_ pattern: HapticPattern) {
        let feedback: NSHapticFeedbackManager.FeedbackPattern = pattern == .alignment ? .alignment : .levelChange
        NSHapticFeedbackManager.defaultPerformer.perform(feedback, performanceTime: .now)
    }
}

/// 页面 → 壳：`window.webkit.messageHandlers.mediacraftHaptic.postMessage("alignment")`，不回复；认不出的忽略。
/// 走脚本消息而不是 `/__native/` 请求：拖动中要的是马上震，不等一次请求来回。
@MainActor
final class HapticMessages: NSObject, WKScriptMessageHandler {
    static let name = "mediacraftHaptic"
    private let performer: HapticPerformer

    init(performer: HapticPerformer) {
        self.performer = performer
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let name = message.body as? String, let pattern = HapticPattern(rawValue: name) else { return }
        performer.perform(pattern)
    }
}
