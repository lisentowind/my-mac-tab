import AppKit
@preconcurrency import ApplicationServices
import Combine
import QuartzCore
import SwiftUI

struct ManagedWindow: Identifiable {
    let id: String
    let applicationName: String
    let title: String
    let applicationIcon: NSImage
    let element: AXUIElement
    let application: NSRunningApplication
    let unnamedWindowNumber: Int?
    let isMinimized: Bool
    let isFocused: Bool
}

struct WindowApplication: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let application: NSRunningApplication
    let windows: [ManagedWindow]
}

@MainActor
final class WindowManager: NSObject, ObservableObject {
    static let shared = WindowManager()

    @Published private(set) var applications: [WindowApplication] = []
    @Published private(set) var hasAccessibilityPermission = AXIsProcessTrusted()
    @Published var selectedIndex = 0
    @Published var selectedApplicationID: String?
    @Published private(set) var dockPreviewApplicationID: String?
    @Published private(set) var dockPreviewFocusedWindowID: String?
    @Published private(set) var isRingPresented = false
    @Published private(set) var dockSearchText = ""
    @Published private(set) var isDockSearchEditing = false
    @Published private(set) var isDockKeyboardAvailable = false
    @Published private(set) var dockPreviewWindows: [ManagedWindow] = []
    let preferences = PreviewPreferences.shared
    let thumbnail = WindowThumbnailPresenter()
    private let previewKeyboard = PreviewKeyboardMonitor()
    private var preferencesObservation: AnyCancellable?
    private var recentWindowOrder: [String: UInt64] = [:]
    private var useSequence: UInt64 = 0
    private var lastFocusedWindowByPID: [pid_t: String] = [:]
    private var focusedWindowObserver: AXObserver?
    private var focusObservationTask: Task<Void, Never>?
    private var focusRefreshTask: Task<Void, Never>?
    private var focusObservationGeneration: UInt = 0
    private var observedFocusPID: pid_t?
    private var isDockSearchComposing = false
    private var dockKeyboardPointer: CGPoint?

    var dockSelectedWindowID: String? {
        selectedApplicationID == dockPreviewApplicationID ? selectedWindow?.id : nil
    }

    func selectDockWindow(_ id: String) {
        guard let app = dockPreviewApplication, let index = app.windows.firstIndex(where: { $0.id == id }) else { return }
        selectApplication(app.id)
        selectWindow(index)
    }

    func hoverDockWindow(_ id: String) {
        // 键盘滚动/筛选引发的布局变化，不应被静止指针重新选中。
        if dockKeyboardPointer == NSEvent.mouseLocation { return }
        dockKeyboardPointer = nil
        guard let window = windowsByID[id] else { return }
        selectDockWindow(id)
        thumbnail.hover(window, preferences: preferences)
    }

    func leaveDockWindow(_ id: String) {
        guard dockKeyboardPointer != NSEvent.mouseLocation else { return }
        thumbnail.leaveRow(id)
    }

    private func updateDockPreviewWindows() {
        let windows = dockPreviewApplication?.windows ?? []
        let query = dockSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = query.isEmpty ? windows : windows.filter { $0.title.localizedStandardContains(query) }
        guard dockPreviewWindows.count != updated.count || !zip(dockPreviewWindows, updated).allSatisfy({
            $0.id == $1.id && $0.title == $1.title && $0.isMinimized == $1.isMinimized && $0.isFocused == $1.isFocused
        }) else { return }
        dockPreviewWindows = updated
    }

    func clearDockSearch() { setDockSearch("") }

    func setDockSearch(_ query: String) {
        guard dockSearchText != query else { return }
        dockSearchText = query
        dockKeyboardPointer = NSEvent.mouseLocation
        thumbnail.hide()
        updateDockPreviewWindows()
        if !dockPreviewWindows.contains(where: { $0.id == dockSelectedWindowID }), let first = dockPreviewWindows.first {
            selectDockWindow(first.id)
        }
    }

    func beginDockSearch() {
        guard let panel = dockPreviewPanel as? DockPreviewPanel else { return }
        isDockSearchEditing = true
        panel.allowsKeyboardFocus = true
        panel.makeKey()
    }

    func endDockSearch() {
        isDockSearchComposing = false
        if isDockSearchEditing { isDockSearchEditing = false }
        if let panel = dockPreviewPanel as? DockPreviewPanel {
            if panel.isKeyWindow { panel.resignKey() }
            panel.allowsKeyboardFocus = false
        }
    }

    func updateDockSearchComposition(_ composing: Bool) { isDockSearchComposing = composing }

    func dismissDockSearchOnOutsideClick(_ point: CGPoint) {
        guard isDockSearchEditing, !isDockSearchComposing, let panel = dockPreviewPanel,
              !panel.frame.contains(point), !thumbnail.contains(point) else { return }
        dismissDockPreview()
    }

    func handleDockSearchCommand(_ selector: Selector) -> Bool {
        let code: Int64
        switch NSStringFromSelector(selector) {
        case "moveUp:": code = 126
        case "moveDown:": code = 125
        case "insertNewline:": code = 36
        case "cancelOperation:":
            if dockSearchText.isEmpty { dismissDockPreview() } else { clearDockSearch() }
            return true
        default: return false
        }
        return handlePreviewKey(code, text: "", flags: [], fromSearch: true)
    }

    private func handlePreviewKey(_ code: Int64, text: String, flags: CGEventFlags, fromSearch: Bool = false) -> Bool {
        guard let panel = dockPreviewPanel, panel.isVisible, dockPreviewMenuFrames.isEmpty,
              fromSearch || (!panel.isKeyWindow && (panel.frame.contains(NSEvent.mouseLocation) || thumbnail.contains(NSEvent.mouseLocation))),
              flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty else { return false }
        switch code {
        case 125, 126, 48:
            dockKeyboardPointer = NSEvent.mouseLocation
            guard !dockPreviewWindows.isEmpty else { return true }
            let offset = code == 126 || (code == 48 && flags.contains(.maskShift)) ? -1 : 1
            let current = dockPreviewWindows.firstIndex(where: { $0.id == dockSelectedWindowID }) ?? (offset > 0 ? -1 : 0)
            let window = dockPreviewWindows[(current + offset + dockPreviewWindows.count) % dockPreviewWindows.count]
            selectDockWindow(window.id)
            thumbnail.hover(window, preferences: preferences)
            return true
        case 36, 76:
            if let id = dockSelectedWindowID, dockPreviewWindows.contains(where: { $0.id == id }) { openDockWindow(id) }
            return true
        case 53:
            if dockSearchText.isEmpty { dismissDockPreview() } else { clearDockSearch() }
            return true
        case 51, 117:
            if !dockSearchText.isEmpty { setDockSearch(String(dockSearchText.dropLast())) }
            return true
        default:
            guard !text.isEmpty, text.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .privateUse
            }),
                  dockSearchText.count < 120 else { return false }
            setDockSearch(dockSearchText + text)
            return true
        }
    }

    private var ringPanel: NSPanel?
    private var ringDisplayScale: CGFloat = 1
    private var dockPreviewPanel: NSPanel?
    private var dockPreviewAnchor: CGRect?
    private var dockPreviewPreferredFrame: CGRect?
    private var dockPreviewVisibleFrame: CGRect?
    private var dockPreviewTargetFrame: CGRect?
    private var dockPreviewDisplayLink: CADisplayLink?
    private var dockPreviewMotion: DockPreviewMotion?
    private var dockPreviewLastFrameTime: CFTimeInterval = 0
    private var dockPreviewLoadTask: Task<Void, Never>?
    private var dockPreviewRequestedApplicationID: String?
    private var dockPreviewMenuFrames: [CGRect] = []
    private var dockPreviewLabelFrames: [CGRect] = []
    private var ringFrontmostPID: pid_t?
    private var ringRequested = false
    private var windowCache: [pid_t: [ManagedWindow]] = [:]
    private var windowCacheTimes: [pid_t: TimeInterval] = [:]
    private var iconCache: [pid_t: NSImage] = [:]
    private var applicationsByID: [String: WindowApplication] = [:]
    private var windowsByID: [String: ManagedWindow] = [:]
    private var refreshTask: Task<Void, Never>?
    private var windowActionTask: Task<Void, Never>?
    private var windowActionGeneration: UInt = 0
    private var dockPreviewContentWidth: CGFloat?
    private var refreshGeneration: UInt = 0
    private var isObservingApplications = false
    private let windowCacheLifetime: TimeInterval = 1
    private var outsideClickMonitor: Any?
    private var ringClickMonitor: Any?

    var selectedApplication: WindowApplication? {
        selectedApplicationID.flatMap { applicationsByID[$0] } ?? applications.first
    }

    var dockPreviewApplication: WindowApplication? {
        dockPreviewApplicationID.flatMap { applicationsByID[$0] }
    }

    var isRingActive: Bool { ringRequested }

    func isDockPreviewRequested(for applicationID: String) -> Bool {
        dockPreviewRequestedApplicationID == applicationID
    }

    var selectedWindow: ManagedWindow? {
        guard let app = selectedApplication, app.windows.indices.contains(selectedIndex) else { return nil }
        return app.windows[selectedIndex]
    }

    func refreshPermission() {
        updateAccessibilityPermission(AXIsProcessTrusted())
        if !hasAccessibilityPermission {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    func updateAccessibilityPermission(_ trusted: Bool) {
        guard hasAccessibilityPermission != trusted else { return }
        hasAccessibilityPermission = trusted
        if trusted, isObservingApplications { frontmostApplicationChanged() }
        if !trusted {
            suspendPanels()
            windowCache = [:]
            windowCacheTimes = [:]
            iconCache = [:]
            rebuildApplications()
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func showRing() {
        refreshPermission()
        guard hasAccessibilityPermission else {
            openAccessibilitySettings()
            return
        }
        if !ringRequested {
            ringFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        ringRequested = true
        dismissDockPreview()
        rebuildApplications()
        if !applications.isEmpty { presentRing() }
        refreshWindows()
    }

    private func presentRing() {
        guard ringRequested, ringPanel?.isVisible != true else { return }
        let screen = screenUnderPointer()
        let panel = ringPanel ?? makeRingPanel()
        ringPanel = panel
        let available = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        ringDisplayScale = min(1, min(available.width / WindowRingGeometry.panelSize.width,
                                     available.height / WindowRingGeometry.panelSize.height))
        let size = CGSize(width: WindowRingGeometry.panelSize.width * ringDisplayScale,
                          height: WindowRingGeometry.panelSize.height * ringDisplayScale)
        let hostingView = NSHostingView(rootView: WindowRingView(manager: self, displayScale: ringDisplayScale))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.setFrame(CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        // 初始布局完成后直接显示；快捷键呼出不添加缩放或位移动画。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ringRequested, self.ringPanel?.isVisible == true else { return }
            self.isRingPresented = true
        }
        installRingClickMonitors()
    }

    func dismissRing() {
        ringRequested = false
        cancelWindowRefresh()
        if isRingPresented { isRingPresented = false }
        ringPanel?.orderOut(nil)
        ringPanel?.contentView = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let ringClickMonitor { NSEvent.removeMonitor(ringClickMonitor) }
        outsideClickMonitor = nil
        ringClickMonitor = nil
    }

    private func installRingClickMonitors() {
        guard outsideClickMonitor == nil, ringClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.ringPanel?.isVisible == true else { return }
                self.dismissRing()
            }
        }
        ringClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.ringPanel, panel.isVisible,
                  event.window === panel, !self.isRingContentPoint(NSEvent.mouseLocation) else { return event }
            self.dismissRing()
            return nil
        }
    }

    private func isRingContentPoint(_ point: CGPoint) -> Bool {
        guard let panel = ringPanel else { return false }
        // 屏幕坐标的 y 轴向上，SwiftUI 的 y 轴向下，统一到视图坐标后直接复用绘制路径。
        let localPoint = CGPoint(x: (point.x - panel.frame.minX) / ringDisplayScale,
                                 y: (panel.frame.maxY - point.y) / ringDisplayScale)
        let center = WindowRingGeometry.center
        if hypot(localPoint.x - center.x, localPoint.y - center.y) <= WindowRingGeometry.circleRadius { return true }

        let closeButton = CGRect(x: WindowRingGeometry.panelSize.width - 52, y: 0, width: 52, height: 52)
        if closeButton.contains(localPoint) { return true }

        guard let app = selectedApplication,
              let appIndex = applications.firstIndex(where: { $0.id == app.id }) else { return false }
        let baseAngle = 2 * CGFloat.pi * CGFloat(appIndex) / CGFloat(max(applications.count, 1)) - (.pi / 2)
        let visibleRange = WindowRingGeometry.visibleWindowRange(count: app.windows.count, selectedIndex: selectedIndex)
        return visibleRange.contains { index in
            WindowRingGeometry.sector(baseAngle: baseAngle, index: index - visibleRange.lowerBound, count: visibleRange.count)
                .path(in: CGRect(origin: .zero, size: WindowRingGeometry.panelSize)).contains(localPoint)
        }
    }

    func moveApplication(_ offset: Int) {
        let apps = applications
        guard !apps.isEmpty else { return }
        let current = apps.firstIndex(where: { $0.id == selectedApplicationID }) ?? 0
        let id = apps[(current + offset + apps.count) % apps.count].id
        if selectedApplicationID != id { selectedApplicationID = id }
        let index = min(selectedIndex, max((selectedApplication?.windows.count ?? 1) - 1, 0))
        if selectedIndex != index { selectedIndex = index }
    }

    func moveWindow(_ offset: Int) {
        guard let app = selectedApplication, !app.windows.isEmpty else { return }
        selectWindow((selectedIndex + offset + app.windows.count) % app.windows.count)
    }

    func selectWindow(_ index: Int) {
        guard let app = selectedApplication, app.windows.indices.contains(index), selectedIndex != index else { return }
        selectedIndex = index
    }

    func selectApplication(_ id: String) {
        guard selectedApplicationID != id else { return }
        selectedApplicationID = id
        if selectedIndex != 0 { selectedIndex = 0 }
    }

    func activateSelectedWindow() {
        guard let selectedWindow else { return }
        activate(selectedWindow)
        dismissRing()
    }

    func splitSelectedWindow(to side: WindowSide) {
        guard let window = selectedWindow else { return }
        cancelWindowActions()
        let record = AccessibilityWindow(title: window.title, element: window.element)
        windowActionTask = Task { [weak self] in
            let frame = await WindowAccessibilityReader.shared.frame(of: record)
            guard !Task.isCancelled, let self, !window.application.isTerminated else { return }
            let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
            let cocoaFrame = frame.map { CGRect(x: $0.minX, y: mainTop - $0.maxY, width: $0.width, height: $0.height) }
            let screen = cocoaFrame.flatMap { frame in NSScreen.screens.first(where: { $0.frame.intersects(frame) }) }
                ?? self.screenUnderPointer()
            let visible = screen.visibleFrame
            let target = CGRect(x: side == .left ? visible.minX : visible.midX, y: mainTop - visible.maxY,
                                width: visible.width / 2, height: visible.height)
            await WindowAccessibilityReader.shared.setFrame(target, for: record)
            guard !Task.isCancelled else { return }
            window.application.activate(options: [])
            await WindowAccessibilityReader.shared.focus(record)
        }
        dismissRing()
    }

    func showDockPreview(for applicationID: String, at dockItemFrame: CGRect,
                         avoiding menuFrames: [CGRect] = [], labels labelFrames: [CGRect] = []) {
        guard hasAccessibilityPermission, !ringRequested, let pid = pid_t(applicationID),
              let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
            dismissDockPreview()
            return
        }
        guard preferences.allows(application) else { dismissDockPreview(); return }
        if dockPreviewRequestedApplicationID != applicationID {
            endDockSearch()
            dockPreviewContentWidth = nil
            thumbnail.hide()
            if !dockSearchText.isEmpty { dockSearchText = "" }
        }
        dockPreviewLoadTask?.cancel()
        dockPreviewLoadTask = nil
        dockPreviewRequestedApplicationID = applicationID
        dockPreviewAnchor = dockItemFrame
        dockPreviewMenuFrames = menuFrames
        dockPreviewLabelFrames = labelFrames
        if dockPreviewApplicationID != applicationID || dockPreviewPanel?.isVisible != true { rebuildApplications() }
        if windowCache[pid] != nil { presentDockPreview(for: applicationID) }
        if let time = windowCacheTimes[pid], ProcessInfo.processInfo.systemUptime - time < windowCacheLifetime { return }
        dockPreviewLoadTask = Task(priority: .userInitiated) { [weak self] in
            let snapshot = await WindowAccessibilityReader.shared.read(pid: pid)
            guard !Task.isCancelled, let self, self.dockPreviewRequestedApplicationID == applicationID,
                  !application.isTerminated else { return }
            self.dockPreviewLoadTask = nil
            guard let snapshot else { return }
            self.cache(snapshot, for: application)
            self.rebuildApplications()
            self.presentDockPreview(for: applicationID)
        }
    }

    private func presentDockPreview(for applicationID: String) {
        guard let app = applicationsByID[applicationID], !app.windows.isEmpty, let anchor = dockPreviewAnchor else {
            // 无窗口的应用不显示列表，但仍保留空结果缓存，避免反复读取。
            hideDockPreviewPanel()
            return
        }
        if dockPreviewApplicationID != app.id {
            dockPreviewApplicationID = app.id
            selectApplication(app.id)
        }
        updateDockPreviewWindows()
        updateDockPreviewFocusedWindow()
        let panel = dockPreviewPanel ?? makeDockPreviewPanel()
        dockPreviewPanel = panel
        if panel.contentView == nil { panel.contentView = makeDockPreviewContent() }
        positionDockPreview(at: anchor)
        if !panel.isVisible {
            panel.orderFrontRegardless()
            previewKeyboard.handleKey = { [weak self] code, text, flags in
                self?.handlePreviewKey(code, text: text, flags: flags) ?? false
            }
            previewKeyboard.start()
            isDockKeyboardAvailable = previewKeyboard.isActive
        }
    }

    func updateDockPreviewAnchor(_ frame: CGRect) {
        guard dockPreviewAnchor != frame else { return }
        dockPreviewAnchor = frame
        if dockPreviewPanel?.isVisible == true { positionDockPreview(at: frame) }
    }

    private func positionDockPreview(at anchor: CGRect) {
        guard let app = dockPreviewApplication, let panel = dockPreviewPanel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? screenUnderPointer()
        let visible = screen.visibleFrame
        let height = min(DockPreviewGeometry.height(windowCount: app.windows.count), visible.height)
        if dockPreviewContentWidth == nil {
            dockPreviewContentWidth = DockPreviewGeometry.width(for: app, availableWidth: visible.width)
        }
        let size = CGSize(width: min(dockPreviewContentWidth ?? DockPreviewGeometry.minimumWidth, visible.width), height: height)
        dockPreviewPreferredFrame = dockPreviewFrame(item: anchor, size: size, screen: screen, visible: visible)
        dockPreviewVisibleFrame = visible
        updateDockPreviewPosition(avoiding: dockPreviewMenuFrames, labels: dockPreviewLabelFrames,
                                  animated: panel.isVisible)
    }

    func dismissDockPreview() {
        dockPreviewLoadTask?.cancel()
        dockPreviewLoadTask = nil
        dockPreviewRequestedApplicationID = nil
        hideDockPreviewPanel()
        dockPreviewAnchor = nil
        dockPreviewMenuFrames = []
        dockPreviewLabelFrames = []
    }

    private func hideDockPreviewPanel() {
        stopDockPreviewMotion()
        previewKeyboard.stop()
        if isDockKeyboardAvailable { isDockKeyboardAvailable = false }
        endDockSearch()
        thumbnail.hide()
        dockPreviewPanel?.orderOut(nil)
        dockPreviewPanel?.contentView = nil
        if dockPreviewApplicationID != nil { dockPreviewApplicationID = nil }
        if dockPreviewFocusedWindowID != nil { dockPreviewFocusedWindowID = nil }
        dockPreviewTargetFrame = nil
        dockPreviewPreferredFrame = nil
        dockPreviewVisibleFrame = nil
        dockPreviewContentWidth = nil
        dockPreviewWindows = []
        dockKeyboardPointer = nil
        if !dockSearchText.isEmpty { dockSearchText = "" }
    }

    func updateDockPreviewPosition(avoiding menuFrames: [CGRect], labels labelFrames: [CGRect] = [],
                                   animated: Bool = true) {
        dockPreviewMenuFrames = menuFrames
        dockPreviewLabelFrames = labelFrames
        guard let panel = dockPreviewPanel, let preferred = dockPreviewPreferredFrame,
              let visible = dockPreviewVisibleFrame else { return }
        let frame = DockPreviewPlacement.frame(preferred: preferred, visible: visible,
                                              avoiding: menuFrames, labels: labelFrames)
        // 菜单出现时立即停止已有位移动画，直接定位到上方。
        let allowsMotion = animated && menuFrames.isEmpty
        guard !allowsMotion || dockPreviewTargetFrame != frame else { return }
        dockPreviewTargetFrame = frame
        let shouldAnimate = allowsMotion && panel.isVisible && panel.frame != frame
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate else {
            stopDockPreviewMotion()
            applyDockPreviewFrame(frame, to: panel)
            return
        }

        // 重定向只修改目标，保留屏幕上的当前位置和速度，不重新开始计时。
        if dockPreviewDisplayLink == nil, let contentView = panel.contentView {
            dockPreviewMotion = DockPreviewMotion(frame: panel.frame)
            dockPreviewLastFrameTime = 0
            let link = contentView.displayLink(target: self, selector: #selector(advanceDockPreviewMotion(_:)))
            let maximum: Float = ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : 120
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maximum, preferred: maximum)
            dockPreviewDisplayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    var isDockPreviewMoving: Bool { dockPreviewDisplayLink != nil }

    @objc private func advanceDockPreviewMotion(_ link: CADisplayLink) {
        guard let panel = dockPreviewPanel, panel.isVisible, let target = dockPreviewTargetFrame,
              var motion = dockPreviewMotion else {
            stopDockPreviewMotion()
            return
        }
        let elapsed = dockPreviewLastFrameTime == 0 ? link.targetTimestamp - link.timestamp
            : link.targetTimestamp - dockPreviewLastFrameTime
        dockPreviewLastFrameTime = link.targetTimestamp
        let next = motion.advance(towards: target, interval: min(max(elapsed, 1.0 / 240), 1.0 / 30))
        dockPreviewMotion = motion
        applyDockPreviewFrame(next.frame, to: panel)
        if next.isSettled { stopDockPreviewMotion() }
    }

    private func stopDockPreviewMotion() {
        dockPreviewDisplayLink?.invalidate()
        dockPreviewDisplayLink = nil
        dockPreviewMotion = nil
        dockPreviewLastFrameTime = 0
    }

    private func applyDockPreviewFrame(_ frame: CGRect, to panel: NSPanel) {
        thumbnail.updateAnchor(frame, avoiding: dockPreviewMenuFrames + dockPreviewLabelFrames)
        guard panel.frame != frame else { return }
        if panel.frame.size == frame.size {
            panel.setFrameOrigin(frame.origin)
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    func isPointInsideDockPreview(_ point: CGPoint) -> Bool {
        guard let panel = dockPreviewPanel, panel.isVisible else { return false }
        // 原生搜索及输入法候选词操作期间保持列表，Esc 或点击外部退出。
        if isDockSearchEditing && panel.isKeyWindow { return true }
        if panel.frame.insetBy(dx: -18, dy: -24).contains(point) || thumbnail.contains(point) { return true }
        guard let anchor = dockPreviewAnchor else { return false }
        // 名称气泡需要留白；在图标与预览之间保留窄通道，慢速移入列表也不会关闭。
        let destination = CGPoint(x: min(max(anchor.midX, panel.frame.minX), panel.frame.maxX),
                                  y: min(max(anchor.midY, panel.frame.minY), panel.frame.maxY))
        let source = CGPoint(x: anchor.midX, y: anchor.midY)
        let vector = CGPoint(x: destination.x - source.x, y: destination.y - source.y)
        let squaredLength = vector.x * vector.x + vector.y * vector.y
        guard squaredLength > 0 else { return false }
        let fraction = min(max(((point.x - source.x) * vector.x + (point.y - source.y) * vector.y) / squaredLength, 0), 1)
        return hypot(point.x - source.x - vector.x * fraction, point.y - source.y - vector.y * fraction) <= 24
    }

    private enum DockWindowAction { case toggle, open, minimizeOrRestore, close }

    func toggleDockWindow(_ id: String) { performDockWindowAction(id, action: .toggle) }
    func openDockWindow(_ id: String) { performDockWindowAction(id, action: .open) }
    func minimizeOrRestoreDockWindow(_ id: String) { performDockWindowAction(id, action: .minimizeOrRestore) }
    func closeDockWindow(_ id: String) { performDockWindowAction(id, action: .close) }

    private func recordWindowUse(_ id: String) {
        useSequence &+= 1
        recentWindowOrder[id] = useSequence
    }

    private func performDockWindowAction(_ id: String, action: DockWindowAction) {
        guard let window = windowsByID[id] else { return }
        endDockSearch()
        thumbnail.hide()
        let previousAction = windowActionTask
        let generation = windowActionGeneration
        let record = AccessibilityWindow(title: window.title, element: window.element)
        windowActionTask = Task { [weak self] in
            await previousAction?.value
            guard !Task.isCancelled, let self, generation == self.windowActionGeneration,
                  !window.application.isTerminated else { return }
            let state = await WindowAccessibilityReader.shared.state(of: record)
            guard !Task.isCancelled, generation == self.windowActionGeneration, !window.application.isTerminated else { return }
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == window.application.processIdentifier
            let shouldMinimize = action == .minimizeOrRestore ? !state.isMinimized
                : action == .toggle && isFrontmost && !window.application.isHidden && state.isFocused && !state.isMinimized
            if action == .close {
                await WindowAccessibilityReader.shared.close(record)
                await WindowThumbnailReader.shared.remove(id)
            } else if shouldMinimize {
                await WindowAccessibilityReader.shared.minimize(record)
            } else {
                self.recordWindowUse(id)
                self.endDockSearch()
                window.application.unhide()
                window.application.activate(options: [])
                await WindowAccessibilityReader.shared.focus(record)
            }
            guard !Task.isCancelled, generation == self.windowActionGeneration, !window.application.isTerminated else { return }
            self.windowCacheTimes[window.application.processIdentifier] = nil
            if let snapshot = await WindowAccessibilityReader.shared.read(pid: window.application.processIdentifier),
               !Task.isCancelled, generation == self.windowActionGeneration, !window.application.isTerminated {
                self.cache(snapshot, for: window.application)
                self.rebuildApplications()
                if self.dockPreviewRequestedApplicationID == String(window.application.processIdentifier) {
                    self.presentDockPreview(for: String(window.application.processIdentifier))
                }
            }
        }
    }

    @objc private func updateDockPreviewFocusedWindow() {
        let app = dockPreviewApplication
        let focusedID = app?.application.isActive == true && app?.application.isHidden == false
            ? app?.windows.first(where: { $0.isFocused && !$0.isMinimized })?.id : nil
        if dockPreviewFocusedWindowID != focusedID { dockPreviewFocusedWindowID = focusedID }
    }

    func refreshWindows() {
        guard refreshTask == nil else { return }
        guard AXIsProcessTrusted() else {
            updateAccessibilityPermission(false)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let generation = refreshGeneration
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted {
            $0.processIdentifier == ringFrontmostPID && $1.processIdentifier != ringFrontmostPID
        }
        let livePIDs = Set(running.map(\.processIdentifier))
        windowCache = windowCache.filter { livePIDs.contains($0.key) }
        windowCacheTimes = windowCacheTimes.filter { livePIDs.contains($0.key) }
        iconCache = iconCache.filter { livePIDs.contains($0.key) }
        refreshTask = Task(priority: .userInitiated) { [weak self] in
            for application in running {
                guard !Task.isCancelled, let self, self.refreshGeneration == generation else { return }
                let pid = application.processIdentifier
                if let time = self.windowCacheTimes[pid], now - time < self.windowCacheLifetime { continue }
                let snapshot = await WindowAccessibilityReader.shared.read(pid: pid)
                guard !Task.isCancelled, self.refreshGeneration == generation else { return }
                if let snapshot, !application.isTerminated {
                    self.cache(snapshot, for: application)
                }
            }
            guard let self, !Task.isCancelled, self.refreshGeneration == generation else { return }
            self.refreshTask = nil
            self.rebuildApplications()
            if self.ringRequested {
                if self.applications.isEmpty { self.dismissRing() }
                else { self.presentRing() }
            }
        }
    }

    private func cache(_ snapshot: [AccessibilityWindow], for application: NSRunningApplication) {
        let pid = application.processIdentifier
        windowCacheTimes[pid] = ProcessInfo.processInfo.systemUptime
        guard !snapshot.isEmpty else {
            windowCache[pid] = []
            iconCache[pid] = nil
            return
        }
        let old = Dictionary(grouping: windowCache[pid] ?? [], by: { CFHash($0.element) })
        let name = application.localizedName ?? "Application"
        let icon = cachedIcon(for: application)
        // 为仍然存在的无标题窗口保留编号，AXWindows 顺序改变时名称也不跳动。
        var reservedNumbers = Set(snapshot.filter { $0.title.isEmpty }.compactMap { record in
            old[CFHash(record.element)]?.first(where: { CFEqual($0.element, record.element) })?.unnamedWindowNumber
        })
        windowCache[pid] = snapshot.map { record in
            let previous = old[CFHash(record.element)]?.first(where: { CFEqual($0.element, record.element) })
            let id = previous?.id ?? "\(pid)-\(UUID().uuidString)"
            var title = record.title
            var unnamedNumber: Int?
            if title.isEmpty {
                var number = previous?.unnamedWindowNumber ?? 1
                if previous?.unnamedWindowNumber == nil {
                    while reservedNumbers.contains(number) { number += 1 }
                }
                reservedNumbers.insert(number)
                unnamedNumber = number
                title = "\(name) · 未命名窗口 \(number)" + (record.isMinimized ? "（已最小化）" : "")
            }
            return ManagedWindow(id: id, applicationName: name, title: title,
                                 applicationIcon: icon, element: record.element, application: application,
                                 unnamedWindowNumber: unnamedNumber, isMinimized: record.isMinimized,
                                 isFocused: record.isFocused)
        }
        if application.isActive, !application.isHidden,
           let focused = windowCache[pid]?.first(where: { $0.isFocused && !$0.isMinimized }),
           lastFocusedWindowByPID[pid] != focused.id {
            lastFocusedWindowByPID[pid] = focused.id
            recordWindowUse(focused.id)
        }
    }

    private func cachedIcon(for application: NSRunningApplication) -> NSImage {
        let pid = application.processIdentifier
        if let cached = iconCache[pid] { return cached }
        let source = application.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
        // 最大显示约 83pt，保留一份 192px 位图即可，不长期持有每个应用的 1024px 图标。
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 192, pixelsHigh: 192,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: 192, height: 192))
        NSGraphicsContext.restoreGraphicsState()
        let icon = NSImage(size: NSSize(width: 96, height: 96))
        icon.addRepresentation(bitmap)
        iconCache[pid] = icon
        return icon
    }

    private func rebuildApplications() {
        let frontmostPID = ringRequested ? ringFrontmostPID : NSWorkspace.shared.frontmostApplication?.processIdentifier
        let updated = windowCache.values.compactMap { windows -> WindowApplication? in
            guard let first = windows.first else { return nil }
            let id = String(first.application.processIdentifier)
            let freeze = (ringRequested && ringPanel?.isVisible == true)
                || (dockPreviewRequestedApplicationID == id && dockPreviewApplicationID == id && dockPreviewPanel?.isVisible == true)
            let previousOrder = Dictionary(uniqueKeysWithValues: (applicationsByID[id]?.windows ?? []).enumerated().map { ($0.element.id, $0.offset) })
            let ordered = windows.enumerated().sorted { left, right in
                if freeze {
                    let a = previousOrder[left.element.id] ?? Int.max
                    let b = previousOrder[right.element.id] ?? Int.max
                    if a != b { return a < b }
                }
                let a = recentWindowOrder[left.element.id] ?? 0
                let b = recentWindowOrder[right.element.id] ?? 0
                return a == b ? left.offset < right.offset : a > b
            }.map(\.element)
            return WindowApplication(id: id, name: first.applicationName,
                                     icon: first.applicationIcon, application: first.application, windows: ordered)
        }.sorted { left, right in
            if ringRequested, ringPanel?.isVisible == true {
                let a = applications.firstIndex(where: { $0.id == left.id }) ?? Int.max
                let b = applications.firstIndex(where: { $0.id == right.id }) ?? Int.max
                if a != b { return a < b }
            }
            let leftIsFrontmost = left.application.processIdentifier == frontmostPID
            let rightIsFrontmost = right.application.processIdentifier == frontmostPID
            if leftIsFrontmost != rightIsFrontmost { return leftIsFrontmost }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        let unchanged = applications.count == updated.count && zip(applications, updated).allSatisfy { left, right in
            left.id == right.id && left.name == right.name && left.windows.count == right.windows.count
                && zip(left.windows, right.windows).allSatisfy {
                    $0.id == $1.id && $0.title == $1.title
                        && $0.isMinimized == $1.isMinimized && $0.isFocused == $1.isFocused
                }
        }
        let previousSelectedID = selectedWindow?.id
        applicationsByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        windowsByID = Dictionary(uniqueKeysWithValues: updated.flatMap(\.windows).map { ($0.id, $0) })
        if !unchanged { applications = updated }
        let liveIDs = Set(windowsByID.keys)
        recentWindowOrder = recentWindowOrder.filter { liveIDs.contains($0.key) }
        updateDockPreviewWindows()
        updateDockPreviewFocusedWindow()
        if selectedApplicationID.flatMap({ applicationsByID[$0] }) == nil {
            let id = updated.first?.id
            if selectedApplicationID != id { selectedApplicationID = id }
            if selectedIndex != 0 { selectedIndex = 0 }
        } else {
            let index = selectedApplication?.windows.firstIndex(where: { $0.id == previousSelectedID })
                ?? min(max(selectedIndex, 0), max((selectedApplication?.windows.count ?? 1) - 1, 0))
            if selectedIndex != index { selectedIndex = index }
        }
        if dockPreviewApplicationID != nil,
           !dockPreviewWindows.contains(where: { $0.id == dockSelectedWindowID }),
           let first = dockPreviewWindows.first {
            selectDockWindow(first.id)
        }
    }

    @objc private func frontmostApplicationChanged() {
        updateDockPreviewFocusedWindow()
        guard hasAccessibilityPermission,
              let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if observedFocusPID != app.processIdentifier {
            stopFocusObservation()
            observedFocusPID = app.processIdentifier
            let generation = focusObservationGeneration
            focusObservationTask = Task { [weak self] in
                let observer = await WindowAccessibilityReader.shared.focusObserver(pid: app.processIdentifier)
                guard !Task.isCancelled, let self, generation == self.focusObservationGeneration else { return }
                self.focusedWindowObserver = observer
                if let observer {
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                }
                self.focusObservationTask = nil
            }
        }
        focusedWindowChanged()
    }

    func focusedWindowChanged() {
        guard focusRefreshTask == nil, hasAccessibilityPermission,
              let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let generation = focusObservationGeneration
        focusRefreshTask = Task { [weak self] in
            let element = await WindowAccessibilityReader.shared.focusedWindow(pid: app.processIdentifier)
            guard let self, generation == self.focusObservationGeneration else { return }
            guard !Task.isCancelled, !app.isTerminated, app.isActive else {
                self.focusRefreshTask = nil
                return
            }
            let pid = app.processIdentifier
            if let element, let known = self.windowCache[pid],
               let focused = known.first(where: { CFEqual($0.element, element) }) {
                // 焦点变化只读取一个属性；已知窗口无需重新枚举或读取全部标题。
                self.recordWindowUse(focused.id)
                self.lastFocusedWindowByPID[pid] = focused.id
                self.windowCache[pid] = known.map { window in
                    ManagedWindow(id: window.id, applicationName: window.applicationName, title: window.title,
                                  applicationIcon: window.applicationIcon, element: window.element,
                                  application: window.application, unnamedWindowNumber: window.unnamedWindowNumber,
                                  isMinimized: window.id == focused.id ? false : window.isMinimized,
                                  isFocused: window.id == focused.id)
                }
            } else if let snapshot = await WindowAccessibilityReader.shared.read(pid: pid),
                      !Task.isCancelled, generation == self.focusObservationGeneration, !app.isTerminated, app.isActive {
                self.cache(snapshot, for: app)
            }
            guard !Task.isCancelled, generation == self.focusObservationGeneration else { return }
            self.focusRefreshTask = nil
            self.rebuildApplications()
            if self.dockPreviewRequestedApplicationID == String(pid) {
                self.presentDockPreview(for: String(pid))
            }
        }
    }

    private func stopFocusObservation() {
        focusObservationGeneration &+= 1
        focusObservationTask?.cancel()
        focusObservationTask = nil
        focusRefreshTask?.cancel()
        focusRefreshTask = nil
        if let observer = focusedWindowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        focusedWindowObserver = nil
        observedFocusPID = nil
    }

    func start() {
        guard !isObservingApplications else { return }
        isObservingApplications = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(frontmostApplicationChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        preferencesObservation = preferences.objectWillChange.sink { [weak self] in
            // @Published 在写入之前发送通知，合并到下一次主队列处理。
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.thumbnail.releaseCache()
                if let app = self.dockPreviewApplication, !self.preferences.allows(app.application) {
                    self.dismissDockPreview()
                }
            }
        }
        frontmostApplicationChanged()
        center.addObserver(self, selector: #selector(applicationTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(suspendPanels), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(suspendPanels), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(invalidateWindowCache), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(invalidateWindowCache), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        isObservingApplications = false
        preferencesObservation = nil
        stopFocusObservation()
        suspendPanels()
        windowCache = [:]
        iconCache = [:]
        windowCacheTimes = [:]
        rebuildApplications()
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = application.processIdentifier
        windowCache[pid] = nil
        windowCacheTimes[pid] = nil
        iconCache[pid] = nil
        lastFocusedWindowByPID[pid] = nil
        if observedFocusPID == pid { stopFocusObservation() }
        thumbnail.releaseCache()
        if dockPreviewRequestedApplicationID == String(pid) { dismissDockPreview() }
        rebuildApplications()
    }

    @objc private func suspendPanels() {
        cancelWindowActions()
        windowActionTask = nil
        dismissDockPreview()
        dismissRing()
        thumbnail.releaseCache()
        stopFocusObservation()
    }

    private func cancelWindowActions() {
        windowActionGeneration &+= 1
        windowActionTask?.cancel()
        windowActionTask = nil
    }

    private func cancelWindowRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    @objc private func invalidateWindowCache() {
        windowCacheTimes = [:]
        frontmostApplicationChanged()
    }

    private func makeRingPanel() -> NSPanel {
        let panel = RingPanel(contentRect: NSRect(origin: .zero, size: WindowRingGeometry.panelSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        return panel
    }

    private func makeDockPreviewPanel() -> NSPanel {
        let panel = DockPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: DockPreviewGeometry.minimumWidth, height: 260),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 自动避让前也保持低于系统菜单，避免刚打开菜单时短暂遮挡。
        panel.level = .floating
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = makeDockPreviewContent()
        return panel
    }

    private func makeDockPreviewContent() -> NSView {
        let hostingView = NSHostingView(rootView: DockWindowPreviewView(manager: self))
        // 尺寸由位移动画控制，禁止 intrinsic size 抢先撑开面板。
        hostingView.sizingOptions = []
        return hostingView
    }

    private func dockPreviewFrame(item: CGRect, size: CGSize, screen: NSScreen, visible: CGRect) -> CGRect {
        let screenFrame = screen.frame
        let bottomDistance = abs(item.minY - screenFrame.minY)
        let topDistance = abs(screenFrame.maxY - item.maxY)
        let leftDistance = abs(item.minX - screenFrame.minX)
        let rightDistance = abs(screenFrame.maxX - item.maxX)
        let nearestEdge = min(min(bottomDistance, topDistance), min(leftDistance, rightDistance))
        // 为 Dock 原生应用名称（含箭头和阴影）预留空间，不把预览贴在图标上方。
        let name = dockPreviewApplication?.name ?? ""
        let labelWidth = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 36
        let gap = nearestEdge == leftDistance || nearestEdge == rightDistance ? max(52, labelWidth) : 52

        let origin: CGPoint
        if nearestEdge == leftDistance {
            origin = CGPoint(x: item.maxX + gap, y: item.midY - size.height / 2)
        } else if nearestEdge == rightDistance {
            origin = CGPoint(x: item.minX - size.width - gap, y: item.midY - size.height / 2)
        } else if nearestEdge == topDistance {
            origin = CGPoint(x: item.midX - size.width / 2, y: item.minY - size.height - gap)
        } else {
            origin = CGPoint(x: item.midX - size.width / 2, y: item.maxY + gap)
        }

        return CGRect(x: min(max(origin.x, visible.minX), visible.maxX - size.width),
                      y: min(max(origin.y, visible.minY), visible.maxY - size.height),
                      width: size.width, height: size.height)
    }

    private func activate(_ window: ManagedWindow) {
        guard !window.application.isTerminated else { return }
        cancelWindowActions()
        recordWindowUse(window.id)
        window.application.unhide()
        // 激活 App 后在后台恢复、聚焦并 raise；无响应的目标 App 不阻塞动画主线程。
        window.application.activate(options: [])
        let record = AccessibilityWindow(title: window.title, element: window.element)
        windowActionTask = Task(priority: .userInitiated) {
            await WindowAccessibilityReader.shared.focus(record)
        }
        windowCacheTimes[window.application.processIdentifier] = nil
    }

    private func screenUnderPointer() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

private nonisolated struct DockPreviewMotion {
    private var value: SIMD4<Double>
    private var velocity = SIMD4<Double>.zero

    init(frame: CGRect) {
        value = SIMD4(Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height))
    }

    mutating func advance(towards frame: CGRect, interval: TimeInterval) -> (frame: CGRect, isSettled: Bool) {
        let target = SIMD4(Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height))
        // 临界阻尼弹簧的解析解：x/y/宽/高各自保留速度，切换目标时连续衔接且不回弹。
        let frequency = 30.0
        let offset = value - target
        let coefficient = velocity + offset * frequency
        let decay = exp(-frequency * interval)
        value = target + (offset + coefficient * interval) * decay
        velocity = (velocity - coefficient * frequency * interval) * decay
        let isSettled = (0..<4).allSatisfy { abs(value[$0] - target[$0]) < 0.5 && abs(velocity[$0]) < 8 }
        let result = isSettled ? frame : CGRect(x: value[0], y: value[1], width: value[2], height: value[3])
        return (result, isSettled)
    }
}

enum DockPreviewPlacement {
    static func frame(preferred: CGRect, visible: CGRect, avoiding menuFrames: [CGRect],
                      labels labelFrames: [CGRect] = []) -> CGRect {
        func clamped(_ origin: CGPoint) -> CGRect {
            CGRect(x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - preferred.width)),
                   y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - preferred.height)),
                   width: preferred.width, height: preferred.height)
        }

        let menus = menuFrames.filter { $0.intersects(visible) }
        if let mainMenu = menus.first {
            // 与主菜单左边缘对齐；子菜单只影响向上避让的高度，不改变横坐标。
            let menuTop = menus.map(\.maxY).max() ?? mainMenu.maxY
            let labelTop = labelFrames.filter { $0.intersects(visible) }.map(\.maxY).max() ?? menuTop
            return clamped(CGPoint(x: mainMenu.minX, y: max(preferred.minY, max(menuTop, labelTop) + 12)))
        }

        let obstacles = labelFrames.filter { $0.intersects(visible) }.map { $0.insetBy(dx: -12, dy: -12) }
        guard obstacles.contains(where: { $0.intersects(preferred) }) else { return preferred }
        let bounds = obstacles.reduce(CGRect.null) { $0.union($1) }
        func distance(_ frame: CGRect) -> CGFloat {
            hypot(frame.minX - preferred.minX, frame.minY - preferred.minY)
        }
        func overlap(_ frame: CGRect) -> CGFloat {
            obstacles.reduce(0) { total, obstacle in
                let intersection = frame.intersection(obstacle)
                return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
        }

        // 优先左右，再尝试上下；所有候选位置限制在当前屏幕可用区域内。
        let horizontal = [CGPoint(x: bounds.minX - preferred.width, y: preferred.minY),
                          CGPoint(x: bounds.maxX, y: preferred.minY)].map(clamped).sorted { distance($0) < distance($1) }
        let vertical = [CGPoint(x: preferred.minX, y: bounds.maxY),
                        CGPoint(x: preferred.minX, y: bounds.minY - preferred.height)].map(clamped).sorted { distance($0) < distance($1) }
        let corners = [CGPoint(x: visible.minX, y: visible.minY),
                       CGPoint(x: visible.minX, y: visible.maxY - preferred.height),
                       CGPoint(x: visible.maxX - preferred.width, y: visible.minY),
                       CGPoint(x: visible.maxX - preferred.width, y: visible.maxY - preferred.height)]
            .map(clamped).sorted { distance($0) < distance($1) }
        let candidates = horizontal + vertical + corners
        if let clear = candidates.first(where: { overlap($0) == 0 }) { return clear }
        // 极小屏幕没有完全容纳两者的空间时，选择遮挡面积最小的位置。
        return ([preferred] + candidates).min {
            let leftOverlap = overlap($0)
            let rightOverlap = overlap($1)
            return leftOverlap == rightOverlap ? distance($0) < distance($1) : leftOverlap < rightOverlap
        } ?? preferred
    }
}

enum WindowSide {
    case left
    case right
}
