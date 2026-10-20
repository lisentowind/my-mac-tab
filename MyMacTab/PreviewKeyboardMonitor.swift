import AppKit
import ApplicationServices

// 只在浮层显示期间安装；面板没有键盘焦点时也能收到按键，回调返回 true 的按键会被吞掉。
@MainActor
final class PreviewKeyboardMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedKeys: Set<Int64> = []
    var isActive: Bool { tap != nil }
    var handleKey: ((Int64, String, CGEventFlags) -> Bool)?

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                         callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            if event.getIntegerValueField(.eventSourceUserData) == SwitcherKeyboardMonitor.cancellationEventTag {
                return Unmanaged.passUnretained(event)
            }
            let swallowed = MainActor.assumeIsolated {
                let monitor = Unmanaged<PreviewKeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return false
                }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                if type == .keyUp {
                    return monitor.swallowedKeys.remove(code) != nil
                }
                var characters = [UniChar](repeating: 0, count: 64)
                var count = 0
                event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &count,
                                               unicodeString: &characters)
                let text = String(utf16CodeUnits: characters, count: min(count, characters.count))
                if monitor.handleKey?(code, text, event.flags) == true {
                    monitor.swallowedKeys.insert(code)
                    return true
                }
                return false
            }
            return swallowed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: context) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        swallowedKeys = []
    }
}
