import AppKit
import ApplicationServices

// 只观察原生快捷键，不拦截或替换 Command-Tab。
@MainActor
final class SwitcherKeyboardMonitor {
    nonisolated static let cancellationEventTag: Int64 = 0x4D4D5453
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isActive: Bool { tap != nil }
    var handleEvent: ((CGEventType, Int64, CGEventFlags) -> Void)?

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                         callback: { _, type, event, context in
            if let context {
                MainActor.assumeIsolated {
                    let monitor = Unmanaged<SwitcherKeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    } else {
                        monitor.handleEvent?(type, event.getIntegerValueField(.keyboardEventKeycode), event.flags)
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    // 鼠标进入我们的预览时取消原生选择，随后可松开 Command 操作浮窗。
    static func cancelNativeSelection() {
        let source = CGEventSource(stateID: .privateState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: isDown)
            event?.flags = []
            event?.setIntegerValueField(.eventSourceUserData, value: cancellationEventTag)
            event?.post(tap: .cgSessionEventTap)
        }
    }
}
