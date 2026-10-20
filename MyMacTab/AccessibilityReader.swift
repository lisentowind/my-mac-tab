import ApplicationServices
import Foundation

// 一次消息读取一组属性，避免每个属性都往返目标应用进程。
nonisolated struct AccessibilityValues {
    private let names: [String]
    private let values: [AnyObject]
    let error: AXError

    init(_ element: AXUIElement, _ names: [String]) {
        self.names = names
        guard !Task.isCancelled else {
            values = []
            error = .cannotComplete
            return
        }
        var result: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result)
        error = status
        if status == .success, let result {
            values = result as [AnyObject]
        } else {
            values = []
        }
    }

    subscript(_ name: String) -> AnyObject? {
        guard let index = names.firstIndex(of: name), values.indices.contains(index) else { return nil }
        return values[index]
    }

    func point(_ name: String) -> CGPoint? {
        guard let value = self[name], CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    func size(_ name: String) -> CGSize? {
        guard let value = self[name], CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func attribute(_ name: String, of element: AXUIElement) -> AnyObject? {
        guard !Task.isCancelled else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

// AX 引用作为不透明窗口身份传递，跨进程读取与操作统一由后台 actor 执行。
nonisolated struct AccessibilityWindow: @unchecked Sendable {
    let title: String
    let element: AXUIElement
    var isMinimized = false
    var isFocused = false
}

nonisolated struct AccessibilityWindowState: Sendable {
    let isMinimized: Bool
    let isFocused: Bool
}

// 快速切换图标时串行读取，取消的请求不会继续枚举窗口，也不会堆积并发 AX 调用。
actor WindowAccessibilityReader {
    static let shared = WindowAccessibilityReader()

    func focusObserver(pid: pid_t) -> AXObserver? {
        guard !Task.isCancelled else { return nil }
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, _ in
            // 回调源仅加入主 RunLoop；只观察当前前台应用，没有后台轮询。
            MainActor.assumeIsolated { WindowManager.shared.focusedWindowChanged() }
        }, &observer) == .success, let observer else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        for notification in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            guard !Task.isCancelled else { return nil }
            _ = AXObserverAddNotification(observer, app, notification as CFString, nil)
        }
        return observer
    }

    func read(pid: pid_t) -> [AccessibilityWindow]? {
        guard !Task.isCancelled else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        let applicationValues = AccessibilityValues(application, [kAXWindowsAttribute, kAXFocusedWindowAttribute])
        guard let elements = applicationValues[kAXWindowsAttribute] as? [AXUIElement] else {
            return nil
        }
        let focusedWindow = applicationValues[kAXFocusedWindowAttribute].flatMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? $0 : nil
        }
        var windows: [AccessibilityWindow] = []
        var visited: Set<AXUIElement> = []
        windows.reserveCapacity(elements.count)
        for element in elements {
            guard !Task.isCancelled else { return nil }
            guard visited.insert(element).inserted else { continue }
            // 超时只对当前 AX 对象生效，应用根节点的设置不会继承给窗口。
            AXUIElementSetMessagingTimeout(element, 0.1)
            let values = AccessibilityValues(element, [kAXTitleAttribute, kAXMinimizedAttribute, kAXFocusedAttribute])
            if values.error == .cannotComplete || values.error == .apiDisabled { return nil }
            guard values.error == .success else { continue }
            let title = usableTitle(values[kAXTitleAttribute]) ?? alternateTitle(of: element)
            let minimized = (values[kAXMinimizedAttribute] as? NSNumber)?.boolValue ?? false
            let focused = focusedWindow.map { CFEqual($0, element) }
                ?? (values[kAXFocusedAttribute] as? NSNumber)?.boolValue ?? false
            windows.append(AccessibilityWindow(
                title: title ?? "", element: element, isMinimized: minimized, isFocused: focused
            ))
        }
        return windows
    }

    private func usableTitle(_ value: AnyObject?) -> String? {
        guard let title = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        let placeholders: Set<String> = ["untitled window", "unknown window", "minimized window",
                                         "未命名窗口", "未知窗口", "无标题窗口"]
        return placeholders.contains(title.lowercased()) ? nil : title
    }

    private func alternateTitle(of element: AXUIElement) -> String? {
        // 只在没有标题时补读元数据，不扫描窗口内部控件或截取屏幕。
        let values = AccessibilityValues(element, [kAXTitleUIElementAttribute, kAXDocumentAttribute,
                                                   kAXDescriptionAttribute, kAXRoleDescriptionAttribute])
        if let rawTitleElement = values[kAXTitleUIElementAttribute],
           CFGetTypeID(rawTitleElement) == AXUIElementGetTypeID() {
            let titleElement = rawTitleElement as! AXUIElement
            AXUIElementSetMessagingTimeout(titleElement, 0.1)
            let titleValues = AccessibilityValues(titleElement, [kAXTitleAttribute, kAXValueAttribute])
            if let title = usableTitle(titleValues[kAXTitleAttribute]) ?? usableTitle(titleValues[kAXValueAttribute]) {
                return title
            }
        }
        let document = (values[kAXDocumentAttribute] as? URL)
            ?? (values[kAXDocumentAttribute] as? String).flatMap(URL.init(string:))
        if let document, document.isFileURL, !document.lastPathComponent.isEmpty {
            return document.lastPathComponent
        }
        if let description = usableTitle(values[kAXDescriptionAttribute]) {
            let genericDescriptions: Set<String> = ["window", "standard window", "dialog", "窗口", "标准窗口", "对话框"]
            let roleDescription = values[kAXRoleDescriptionAttribute] as? String
            if description != roleDescription, !genericDescriptions.contains(description.lowercased()) {
                return description
            }
        }
        return nil
    }

    func focusedWindow(pid: pid_t) -> AXUIElement? {
        guard !Task.isCancelled else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let element = AccessibilityValues.attribute(kAXFocusedWindowAttribute, of: app),
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    func state(of window: AccessibilityWindow) -> AccessibilityWindowState {
        AXUIElementSetMessagingTimeout(window.element, 0.1)
        let values = AccessibilityValues(window.element, [kAXMinimizedAttribute, kAXFocusedAttribute])
        var pid: pid_t = 0
        var isFocused = (values[kAXFocusedAttribute] as? NSNumber)?.boolValue ?? false
        if AXUIElementGetPid(window.element, &pid) == .success {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.1)
            if let focused = AccessibilityValues.attribute(kAXFocusedWindowAttribute, of: application),
               CFGetTypeID(focused) == AXUIElementGetTypeID() {
                isFocused = CFEqual(focused, window.element)
            }
        }
        return AccessibilityWindowState(
            isMinimized: (values[kAXMinimizedAttribute] as? NSNumber)?.boolValue ?? false,
            isFocused: isFocused
        )
    }

    func minimize(_ window: AccessibilityWindow) {
        guard !Task.isCancelled else { return }
        let result = AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        if result != .success, !Task.isCancelled,
           let button = AccessibilityValues.attribute(kAXMinimizeButtonAttribute, of: window.element),
           CFGetTypeID(button) == AXUIElementGetTypeID() {
            let element = button as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.1)
            _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }

    func close(_ window: AccessibilityWindow) {
        guard !Task.isCancelled,
              let button = AccessibilityValues.attribute(kAXCloseButtonAttribute, of: window.element),
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return }
        let element = button as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        // 使用应用自己的关闭按钮，保留未保存文档的原生确认流程。
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    func focus(_ window: AccessibilityWindow) {
        guard !Task.isCancelled else { return }
        if (AccessibilityValues.attribute(kAXMinimizedAttribute, of: window.element) as? NSNumber)?.boolValue == true {
            _ = AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        for name in [kAXMainAttribute, kAXFocusedAttribute] {
            guard !Task.isCancelled else { return }
            _ = AXUIElementSetAttributeValue(window.element, name as CFString, kCFBooleanTrue)
        }
        guard !Task.isCancelled else { return }
        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    func frame(of window: AccessibilityWindow) -> CGRect? {
        let values = AccessibilityValues(window.element, [kAXPositionAttribute, kAXSizeAttribute])
        guard let position = values.point(kAXPositionAttribute), let size = values.size(kAXSizeAttribute) else { return nil }
        return CGRect(origin: position, size: size)
    }

    func setFrame(_ frame: CGRect, for window: AccessibilityWindow) {
        guard !Task.isCancelled else { return }
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        _ = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
        guard !Task.isCancelled else { return }
        _ = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
    }
}
