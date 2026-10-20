import AppKit
import ApplicationServices
import Combine

@MainActor
final class DockHoverController: NSObject {
    private weak var manager: WindowManager?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var watchdog: Timer?
    private var ringObservation: AnyCancellable?
    private var pendingUpdate: DispatchWorkItem?
    private var followupScan: DispatchWorkItem?
    private var dismissWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?
    private var pendingItemID: String?
    private var pendingItem: DockHoverItem?
    private var preferencesObservation: AnyCancellable?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration: UInt = 0
    private var axObserver: AXObserver?
    private var dockPID: pid_t?
    private var applicationIndex = DockApplicationIndex()
    private var screenFrames: [CGRect] = []
    private var mainDisplayTop: CGFloat = 0
    private var cachedItems: [DockHoverItem] = []
    private var cachedDockArea = CGRect.null
    private var cachedMenuFrames: [CGRect] = []
    private var cachedLabelFrames: [CGRect] = []
    private var lastScanTime: TimeInterval = 0
    private var lastPointer = CGPoint(x: -100_000, y: -100_000)
    private var lastButtons = 0
    private var lastPointerMovement: TimeInterval = 0
    private var activeItemID: String?
    private var needsScan = true
    private var isTrusted = false
    private var isSuspended = false

    init(manager: WindowManager) {
        self.manager = manager
        super.init()
    }

    func start() {
        guard watchdog == nil else { return }
        updateScreens()
        updateApplications()
        isTrusted = AXIsProcessTrusted()
        manager?.updateAccessibilityPermission(isTrusted)
        installDockObserver()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                          .leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerEvent(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.pointerEvent(event)
            return event
        }
        // accessory 应用偶尔漏收全局鼠标事件，每秒只补查坐标；远离 Dock 时不读取 AX。
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(self, selector: #selector(applicationsChanged), name: name, object: nil)
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(suspend), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(resume), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        ringObservation = manager?.$isRingPresented.removeDuplicates().sink { [weak self] isPresented in
            guard let self else { return }
            if isPresented { self.resetHover() }
            else { self.requestUpdate() }
        }
        preferencesObservation = PreviewPreferences.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.resetHover()
                self?.requestUpdate()
            }
        }
        requestUpdate()
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        ringObservation = nil
        preferencesObservation = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        removeDockObserver()
        resetHover()
    }

    private func cancelPendingShow() {
        showWork?.cancel()
        showWork = nil
        pendingItemID = nil
        pendingItem = nil
    }

    private func resetHover() {
        cancelPendingShow()
        pendingUpdate?.cancel()
        pendingUpdate = nil
        followupScan?.cancel()
        followupScan = nil
        dismissWork?.cancel()
        dismissWork = nil
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        cachedItems = []
        cachedDockArea = .null
        cachedMenuFrames = []
        cachedLabelFrames = []
        activeItemID = nil
        needsScan = true
        manager?.dismissDockPreview()
    }

    private func pointerEvent(_ event: NSEvent) {
        guard !isSuspended, isTrusted, PreviewPreferences.shared.dockPreviewEnabled, manager?.isRingActive != true else { return }
        let point = NSEvent.mouseLocation
        // 桌面上的普通移动只做矩形判断，不向主队列提交逐帧工作。
        if activeItemID == nil, cachedMenuFrames.isEmpty, !isNearDock(point) {
            lastPointer = point
            lastButtons = NSEvent.pressedMouseButtons
            return
        }
        if event.type == .rightMouseDown || event.type == .leftMouseDown {
            manager?.dismissDockSearchOnOutsideClick(point)
            needsScan = true
        }
        requestUpdate()
    }

    private func watchdogTick() {
        guard !isSuspended else { return }
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
            manager?.updateAccessibilityPermission(trusted)
            if trusted { installDockObserver() }
            else { removeDockObserver(); resetHover() }
        }
        if NSEvent.mouseLocation != lastPointer || NSEvent.pressedMouseButtons != lastButtons || needsScan {
            requestUpdate()
        }
    }

    private func requestUpdate() {
        guard watchdog != nil, !isSuspended, pendingUpdate == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingUpdate = nil
            self.updateHover()
        }
        pendingUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: work)
    }

    private func updateHover() {
        guard !isSuspended, isTrusted, PreviewPreferences.shared.dockPreviewEnabled, let manager, !manager.isRingActive else { return }
        let point = NSEvent.mouseLocation
        let buttons = NSEvent.pressedMouseButtons
        let now = ProcessInfo.processInfo.systemUptime
        if point != lastPointer { lastPointerMovement = now }
        lastPointer = point
        lastButtons = buttons
        let nearDock = isNearDock(point)
        let interval = buttons != 0 || !cachedMenuFrames.isEmpty ? 0.12 : 0.4
        if (nearDock || !cachedMenuFrames.isEmpty), needsScan || now - lastScanTime >= interval {
            scheduleDockScan(at: now)
        }
        if !cachedMenuFrames.isEmpty {
            cancelDismiss()
            // 菜单操作保持当前预览；名称提示不属于菜单，不会锁住 hover。
            if activeItemID == nil, let item = cachedItems.first(where: { $0.frame.contains(point) }) {
                show(item)
            }
            return
        }
        // 原生搜索输入（包括候选词）期间不因指针掠过其他图标而切换应用。
        if manager.isDockSearchEditing, manager.isPointInsideDockPreview(point) {
            cancelDismiss()
            return
        }
        // 图标命中优先于预览、通道和正在进行的动画。
        if let item = cachedItems.first(where: { $0.frame.contains(point) }) {
            cancelDismiss()
            show(item)
            return
        }
        cancelPendingShow()
        if manager.isPointInsideDockPreview(point) {
            cancelDismiss()
            return
        }
        if activeItemID != nil { scheduleDismiss() }
    }

    private func show(_ item: DockHoverItem) {
        guard let pid = pid_t(item.applicationID), let app = NSRunningApplication(processIdentifier: pid),
              PreviewPreferences.shared.allows(app) else {
            cancelPendingShow()
            activeItemID = nil
            manager?.dismissDockPreview()
            return
        }
        if activeItemID == item.applicationID, manager?.isDockPreviewRequested(for: item.applicationID) == true {
            manager?.updateDockPreviewAnchor(item.frame)
            return
        }
        pendingItem = item
        guard pendingItemID != item.applicationID else { return }
        cancelPendingShow()
        pendingItem = item
        pendingItemID = item.applicationID
        // 相邻图标切换立即响应；首次进入才使用用户设置的延迟。
        let delay = activeItemID == nil ? PreviewPreferences.shared.hoverDelay : 0
        if activeItemID != nil { manager?.dismissDockPreview() }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.pendingItem,
                  current.frame.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation) else { return }
            self.cancelPendingShow()
            self.activeItemID = current.applicationID
            self.manager?.showDockPreview(for: current.applicationID, at: current.frame,
                                          avoiding: self.cachedMenuFrames, labels: self.cachedLabelFrames)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelDismiss() {
        dismissWork?.cancel()
        dismissWork = nil
    }

    private func scheduleDismiss(after delay: TimeInterval = 0.18) {
        guard dismissWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let manager = self.manager else { return }
            self.dismissWork = nil
            let point = NSEvent.mouseLocation
            guard self.cachedMenuFrames.isEmpty, !manager.isPointInsideDockPreview(point) else { return }
            if self.cachedItems.contains(where: { $0.frame.contains(point) }) {
                self.updateHover()
                return
            }
            if manager.isDockPreviewMoving {
                self.scheduleDismiss(after: 0.08)
            } else {
                self.activeItemID = nil
                manager.dismissDockPreview()
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func isNearDock(_ point: CGPoint) -> Bool {
        if cachedDockArea.contains(point) { return true }
        return screenFrames.contains { frame in
            frame.contains(point) && (point.y - frame.minY < 160 || point.x - frame.minX < 160 || frame.maxX - point.x < 160)
        }
    }

    private func scheduleDockScan(at time: TimeInterval) {
        guard scanTask == nil, let dockPID else { return }
        lastScanTime = time
        needsScan = false
        let generation = scanGeneration
        let index = applicationIndex
        let top = mainDisplayTop
        scanTask = Task(priority: .userInitiated) { [weak self] in
            let snapshot = await DockAccessibilityReader.shared.scan(pid: dockPID, applications: index, mainDisplayTop: top)
            guard !Task.isCancelled, let self, self.scanGeneration == generation else { return }
            self.scanTask = nil
            self.lastScanTime = ProcessInfo.processInfo.systemUptime
            self.cachedItems = snapshot.items
            self.cachedDockArea = snapshot.items.reduce(CGRect.null) { $0.union($1.frame) }.insetBy(dx: -40, dy: -40)
            if self.cachedMenuFrames != snapshot.menuFrames || self.cachedLabelFrames != snapshot.labelFrames {
                self.cachedMenuFrames = snapshot.menuFrames
                self.cachedLabelFrames = snapshot.labelFrames
                self.manager?.updateDockPreviewPosition(avoiding: snapshot.menuFrames, labels: snapshot.labelFrames)
            }
            self.updateHover()
            // 仅跟随 Dock 放大、菜单展开及按键期间的变化；稳定悬停后停止重复扫描。
            if !snapshot.menuFrames.isEmpty || NSEvent.pressedMouseButtons != 0
                || ProcessInfo.processInfo.systemUptime - self.lastPointerMovement < 0.6 {
                self.scheduleFollowupScan()
            }
        }
    }

    private func scheduleFollowupScan() {
        followupScan?.cancel()
        let delay = cachedMenuFrames.isEmpty && NSEvent.pressedMouseButtons == 0 ? 0.4 : 0.12
        let work = DispatchWorkItem { [weak self] in
            self?.followupScan = nil
            self?.requestUpdate()
        }
        followupScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc private func applicationsChanged() {
        let previousPID = dockPID
        updateApplications()
        if previousPID != dockPID {
            removeDockObserver()
            resetHover()
            installDockObserver()
        }
        needsScan = true
        requestUpdate()
    }

    private func updateApplications() {
        let apps = NSWorkspace.shared.runningApplications
        dockPID = apps.first(where: { $0.bundleIdentifier == "com.apple.dock" })?.processIdentifier
        applicationIndex = DockApplicationIndex(apps.filter { $0.activationPolicy == .regular })
    }

    @objc private func screensChanged() {
        resetHover()
        updateScreens()
        requestUpdate()
    }

    private func updateScreens() {
        screenFrames = NSScreen.screens.map(\.frame)
        mainDisplayTop = screenFrames.first?.maxY ?? 0
    }

    @objc private func suspend() {
        isSuspended = true
        watchdog?.fireDate = .distantFuture
        resetHover()
    }

    @objc private func resume() {
        isSuspended = false
        watchdog?.fireDate = Date(timeIntervalSinceNow: 1)
        removeDockObserver()
        updateApplications()
        installDockObserver()
        screensChanged()
    }

    private func installDockObserver() {
        guard axObserver == nil, isTrusted, let dockPID else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let controller = Unmanaged<DockHoverController>.fromOpaque(context).takeUnretainedValue()
                controller.needsScan = true
                controller.requestUpdate()
            }
        }
        guard AXObserverCreate(dockPID, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(element, 0.08)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXHelpTagCreatedNotification] {
            _ = AXObserverAddNotification(observer, element, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
    }

    private func removeDockObserver() {
        guard let axObserver else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        self.axObserver = nil
    }
}

private nonisolated struct DockHoverItem: Sendable {
    let applicationID: String
    let frame: CGRect
}

private nonisolated struct DockApplicationIndex: Sendable {
    var bundleIDs: [String: String] = [:]
    var paths: [String: String] = [:]
    var names: [String: String] = [:]

    @MainActor init(_ applications: [NSRunningApplication]) {
        for app in applications {
            let id = String(app.processIdentifier)
            if let bundleID = app.bundleIdentifier { bundleIDs[bundleID.lowercased()] = id }
            if let path = app.bundleURL?.standardizedFileURL.path { paths[path.lowercased()] = id }
            if let name = app.localizedName { names[Self.normalized(name)] = id }
        }
    }

    init() {}

    static func normalized(_ name: String) -> String {
        let name = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

private nonisolated struct DockSnapshot: Sendable {
    var items: [DockHoverItem] = []
    var menuFrames: [CGRect] = []
    var labelFrames: [CGRect] = []
}

// 只在后台读取 Dock，节点有深度/数量限制，并且不遍历每个 Dock 图标的内部子树。
private actor DockAccessibilityReader {
    static let shared = DockAccessibilityReader()

    func scan(pid: pid_t, applications: DockApplicationIndex, mainDisplayTop: CGFloat) -> DockSnapshot {
        guard !Task.isCancelled else { return DockSnapshot() }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.08)
        var snapshot = DockSnapshot()
        var visited: Set<AXUIElement> = []

        func frame(_ element: AXUIElement) -> CGRect? {
            let values = AccessibilityValues(element, [kAXPositionAttribute, kAXSizeAttribute])
            guard let point = values.point(kAXPositionAttribute), let size = values.size(kAXSizeAttribute),
                  size.width > 0, size.height > 0 else { return nil }
            return CGRect(x: point.x, y: mainDisplayTop - point.y - size.height, width: size.width, height: size.height)
        }

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 8, visited.count < 160, !Task.isCancelled, visited.insert(element).inserted else { return }
            AXUIElementSetMessagingTimeout(element, 0.08)
            let values = AccessibilityValues(element, [kAXRoleAttribute, kAXSubroleAttribute, kAXShownMenuUIElementAttribute])
            guard values.error == .success else { return }
            let role = values[kAXRoleAttribute] as? String
            let subrole = values[kAXSubroleAttribute] as? String
            // 先记录主菜单，再读取它展开的子菜单，首个矩形始终作为左对齐基准。
            if role == kAXMenuRole {
                if let rect = frame(element), !snapshot.menuFrames.contains(rect) { snapshot.menuFrames.append(rect) }
            }
            if let shown = values[kAXShownMenuUIElementAttribute], CFGetTypeID(shown) == AXUIElementGetTypeID() {
                visit(shown as! AXUIElement, depth: depth + 1)
            }
            if role == kAXHelpTagRole || subrole?.contains("HelpTag") == true {
                if let rect = frame(element), !snapshot.labelFrames.contains(rect) { snapshot.labelFrames.append(rect) }
                return
            } else if role == "AXListItem" || subrole?.contains("DockItem") == true {
                let item = AccessibilityValues(element, [kAXPositionAttribute, kAXSizeAttribute, "AXIdentifier", "AXURL", kAXTitleAttribute])
                let bundleID = (item["AXIdentifier"] as? String)?.lowercased()
                let url = (item["AXURL"] as? URL) ?? (item["AXURL"] as? String).flatMap(URL.init(string:))
                let path = url?.standardizedFileURL.path.lowercased()
                let pathMatch = path.flatMap { path in
                    applications.paths[path] ?? applications.paths.first(where: { path.hasPrefix($0.key + "/") })?.value
                }
                let title = (item[kAXTitleAttribute] as? String).map(DockApplicationIndex.normalized)
                if let id = bundleID.flatMap({ applications.bundleIDs[$0] }) ?? pathMatch ?? title.flatMap({ applications.names[$0] }),
                   let point = item.point(kAXPositionAttribute), let size = item.size(kAXSizeAttribute), size.width > 0, size.height > 0 {
                    snapshot.items.append(DockHoverItem(applicationID: id,
                        frame: CGRect(x: point.x, y: mainDisplayTop - point.y - size.height, width: size.width, height: size.height)))
                }
                return
            }
            if let children = AccessibilityValues.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] {
                for child in children { visit(child, depth: depth + 1) }
            }
        }

        visit(root, depth: 0)
        // 部分 Dock 版本把名称气泡和菜单放在顶层 windows，而不是 children 中。
        if let windows = AccessibilityValues.attribute(kAXWindowsAttribute, of: root) as? [AXUIElement] {
            for window in windows { visit(window, depth: 1) }
        }
        return snapshot
    }
}
