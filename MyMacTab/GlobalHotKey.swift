import Carbon
import Foundation

@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    func register(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        // Carbon 注册系统级快捷键，不依赖窗口是否在前台；组合键需避开 Finder 的 ⌘⌥Space。
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in hotKey.action?() }
            return noErr
        }, 1, &eventType, userData, &handlerRef)
        guard status == noErr else { return }

        let identifier = EventHotKeyID(signature: OSType(0x4D4D5442), id: 1)
        _ = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), identifier,
                                GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        action = nil
    }
}
