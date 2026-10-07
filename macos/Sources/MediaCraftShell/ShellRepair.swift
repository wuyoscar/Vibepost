import AppKit
import WebKit

/// 换显示器、合盖开盖、唤醒之后网页不再重画的自愈。
///
/// 2026-10-07 那次「第二天卡住，只显示中间」：接上外接显示器、内建屏关掉的那一刻，系统报 `invalid display identifier`，
/// 显示器编号 3 随即变成 7；之后页面进程一直空闲（0% CPU），画面却不再更新——WebKit 还认着已经没有了的那块屏。
/// 这里在显示器配置变了、系统或屏幕唤醒之后，把网页从窗口里摘下再挂回去（WebKit 借此重新认窗口所在的屏幕、
/// 重建画面），再确认页面能画出新的一帧；还是画不出来就先存稿、再重新载入这个窗口（地址上记着它开着的那篇）。
/// 窗口自己换到别的屏幕、缩放比例变了时先查，画不出来才这样修。窗口看不见时不查，等它回到前面。
extension ShellWebView {
    /// 自愈的结果
    public enum Repair: String, Sendable {
        /// 窗口看不见：等它回到前面再修
        case deferred
        /// 本来就能画
        case healthy
        /// 重新挂上之后能画了
        case reattached
        /// 重新挂上还画不出来：存稿后重新载入了
        case reloaded
        /// 页面的 JS 正忙着（出图、分页），不是画不出来：过几秒再查，不重载（重载会杀掉这个窗口 AI 的这一轮、丢掉页内对话框）
        case busy
    }

    /// 为什么要修
    public enum RepairReason: String, Sendable {
        case displays = "显示器配置变了"
        case wake = "系统唤醒了"
        case screensWake = "屏幕唤醒了"
        case screen = "窗口换了屏幕"
        case backing = "窗口的缩放比例变了"

        /// 显示器、唤醒：WebKit 可能还认着旧屏幕，先重新挂上再查；窗口自己换屏：先查，画不出来再挂
        var reattachFirst: Bool { self == .displays || self == .wake || self == .screensWake }
    }

    func observeDisplays() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRepair(.displays) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, reason) in [
            (NSWorkspace.didWakeNotification, RepairReason.wake),
            (NSWorkspace.screensDidWakeNotification, RepairReason.screensWake),
        ] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRepair(reason) }
            })
        }
        for (name, reason) in [
            (NSWindow.didChangeScreenNotification, RepairReason.screen),
            (NSWindow.didChangeBackingPropertiesNotification, RepairReason.backing),
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.object as? NSWindow === self.webView.window else { return }
                    self.scheduleRepair(reason)
                }
            })
        }
        // 看不见时来过一次：回到前面就修
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.object as? NSWindow === self.webView.window,
                      let reason = self.repairDeferred, self.isShown() else { return }
                self.scheduleRepair(reason)
            }
        })
    }

    /// 过一秒再修（显示器编号会接连变两次）；这期间又来的合成一次，显示器、唤醒的优先
    func scheduleRepair(_ reason: RepairReason, after delay: Duration = .seconds(1)) {
        if repairPending?.reattachFirst != true || reason.reattachFirst { repairPending = reason }
        repairTask?.cancel()
        repairTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let reason = self.repairPending else { return }
            self.repairPending = nil
            await self.repair(reason)
        }
    }

    /// 修一次（见上面的说明），返回做了什么
    @discardableResult
    public func repair(_ reason: RepairReason) async -> Repair {
        guard webView.window != nil, isShown() else {
            if repairDeferred?.reattachFirst != true || reason.reattachFirst { repairDeferred = reason }
            return finishRepair(.deferred, reason)
        }
        repairDeferred = nil
        if !reason.reattachFirst, await paints() { return finishRepair(.healthy, reason) }
        reattach()
        if await paints() { return finishRepair(.reattached, reason) }
        // 一帧没回来有两种可能：JS 线程正忙（连 1+1 都答不上）——那是忙不是坏，过几秒再查；JS 答得上、帧却不来——才是真画不出来
        if !(await responds()) {
            scheduleRepair(reason, after: .seconds(5))
            return finishRepair(.busy, reason)
        }
        shellLog.error("窗口 \(self.windowId, privacy: .public) 重新挂上网页之后还是画不出新的一帧：存稿后重新载入")
        try? await reload()
        return finishRepair(.reloaded, reason)
    }

    private func finishRepair(_ repair: Repair, _ reason: RepairReason) -> Repair {
        lastRepair = repair
        shellLog.notice("窗口 \(self.windowId, privacy: .public) \(reason.rawValue, privacy: .public)：\(repair.rawValue, privacy: .public)")
        return repair
    }

    /// 页面的 JS 还答不答得上话（和画不画得出分开）：timeout 内算出 1+1 就算答得上
    func responds(timeout: Duration = .milliseconds(1500)) async -> Bool {
        let webView = webView
        return await firstOf(timeout: timeout) {
            ((try? await webView.evaluateJavaScript("1+1")) as? Int) == 2
        } ?? false
    }

    /// 页面能不能画出新的一帧：请求一帧动画，timeout 内回来就算能（页面卡住、没回也算不能）
    func paints(timeout: Duration = .milliseconds(1500)) async -> Bool {
        let script = "return await new Promise((resolve) => requestAnimationFrame(() => resolve(true)));"
        let webView = webView
        return await firstOf(timeout: timeout) {
            (try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)) as? Bool ?? false
        } ?? false
    }

    /// 把网页从窗口里摘下再挂回去：大小、位置不变，键盘焦点在它上面的还给它
    func reattach() {
        guard let window = webView.window else { return }
        let focused = (window.firstResponder as? NSView).map { $0 === webView || $0.isDescendant(of: webView) } ?? false
        let frame = webView.frame
        if window.contentView === webView {
            window.contentView = NSView(frame: frame)
            window.contentView = webView
        } else if let container = webView.superview {
            let above = container.subviews.firstIndex(of: webView).flatMap { $0 + 1 < container.subviews.count ? container.subviews[$0 + 1] : nil }
            webView.removeFromSuperview()
            webView.frame = frame
            if let above { container.addSubview(webView, positioned: .below, relativeTo: above) } else { container.addSubview(webView) }
        }
        if focused { window.makeFirstResponder(webView) }
    }
}
