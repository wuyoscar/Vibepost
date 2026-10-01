import AppKit
import WebKit

/// 网页工具栏占住标题栏（全尺寸内容 + 透明标题栏）时的窗口外框：
/// 工具栏空白处按下即拖动窗口、双击按系统设置缩放或最小化；按钮、输入框照常交给网页。
/// 可拖区域由页面报告（`window.webkit.messageHandlers.mediacraftWindow`），坐标是页面左上为原点的 CSS 像素（= 点）。
final class ChromeWebView: WKWebView {
    private(set) var dragRegions: [CGRect] = []
    private(set) var noDragRegions: [CGRect] = []

    func setDragRegions(_ drag: [CGRect], excluding noDrag: [CGRect]) {
        dragRegions = drag
        noDragRegions = noDrag
    }

    func isWindowDragPoint(_ point: CGPoint) -> Bool {
        dragRegions.contains { $0.contains(point) } && !noDragRegions.contains { $0.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        guard let window, isWindowDragPoint(point) else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            Self.performTitlebarDoubleClick(in: window)
        } else {
            window.performDrag(with: event)
        }
    }

    /// 系统设置「连按窗口标题栏以…」：缩放（默认）、最小化或不操作。
    private static func performTitlebarDoubleClick(in window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// 页面发来的外框消息：`{ drag: [[x, y, 宽, 高]…], noDrag: [[…]…] }` 更新可拖区域。
/// 窗口的深浅外观跟随系统（ADR 0007），页面的皮肤也跟着系统走，两边不互相设置。
@MainActor
final class WindowChromeMessages: NSObject, WKScriptMessageHandler {
    static let name = "mediacraftWindow"
    private weak var webView: ChromeWebView?

    init(webView: ChromeWebView) {
        self.webView = webView
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView, let body = message.body as? [String: Any] else { return }
        if let drag = body["drag"] as? [[Double]], let noDrag = body["noDrag"] as? [[Double]] {
            webView.setDragRegions(drag.compactMap(Self.rect), excluding: noDrag.compactMap(Self.rect))
        }
    }

    private static func rect(_ values: [Double]) -> CGRect? {
        values.count == 4 ? CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) : nil
    }
}
