import AppKit
import Carbon
import Combine
import SwiftUI

enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case showRing, openSettings, quit
    case previousApplication, nextApplication, previousWindow, nextWindow
    case activateWindow, dismissOverlay, tileLeft, tileRight
    case previewPreviousWindow, previewNextWindow, previewOpenWindow, previewDismiss, previewDeleteCharacter
    case previewPreviousTab, previewNextTab, previewOpenKeypad, previewDeleteForward
    case minimizeWindow, closeWindow, previewMinimizeWindow, previewCloseWindow, previewSearch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .showRing: "呼出窗口环"
        case .openSettings: "打开设置"
        case .quit: "退出应用"
        case .previousApplication: "上一个应用"
        case .nextApplication: "下一个应用"
        case .previousWindow: "上一个窗口"
        case .nextWindow: "下一个窗口"
        case .activateWindow: "打开选中窗口"
        case .dismissOverlay: "关闭窗口环"
        case .tileLeft: "窗口贴靠左侧"
        case .tileRight: "窗口贴靠右侧"
        case .previewPreviousWindow: "列表中选择上一个窗口"
        case .previewNextWindow: "列表中选择下一个窗口"
        case .previewOpenWindow: "打开列表中选中的窗口"
        case .previewDismiss: "清除筛选或关闭列表"
        case .previewDeleteCharacter: "删除筛选文字"
        case .previewPreviousTab: "上一个窗口（备用）"
        case .previewNextTab: "下一个窗口（备用）"
        case .previewOpenKeypad: "打开窗口（数字键盘）"
        case .previewDeleteForward: "删除筛选文字（备用）"
        case .minimizeWindow, .previewMinimizeWindow: "最小化或恢复选中窗口"
        case .closeWindow, .previewCloseWindow: "关闭选中窗口"
        case .previewSearch: "编辑窗口筛选"
        }
    }

    var group: String {
        switch self {
        case .showRing: "全局"
        case .openSettings, .quit: "菜单"
        case .previousApplication, .nextApplication, .previousWindow, .nextWindow,
             .activateWindow, .dismissOverlay, .tileLeft, .tileRight, .minimizeWindow, .closeWindow: "窗口环"
        case .previewPreviousWindow, .previewNextWindow, .previewOpenWindow,
             .previewDismiss, .previewDeleteCharacter, .previewPreviousTab, .previewNextTab,
             .previewOpenKeypad, .previewDeleteForward, .previewMinimizeWindow, .previewCloseWindow, .previewSearch: "Dock 列表"
        }
    }

    var requiresModifier: Bool { self == .showRing || self == .openSettings || self == .quit }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .showRing: ShortcutBinding(keyCode: 49, modifiers: [.control, .option])
        case .openSettings: ShortcutBinding(keyCode: 43, modifiers: [.command])
        case .quit: ShortcutBinding(keyCode: 12, modifiers: [.command])
        case .previousApplication: ShortcutBinding(keyCode: 123)
        case .nextApplication: ShortcutBinding(keyCode: 124)
        case .previousWindow, .previewPreviousWindow: ShortcutBinding(keyCode: 126)
        case .nextWindow, .previewNextWindow: ShortcutBinding(keyCode: 125)
        case .activateWindow, .previewOpenWindow: ShortcutBinding(keyCode: 36)
        case .dismissOverlay, .previewDismiss: ShortcutBinding(keyCode: 53)
        case .tileLeft: ShortcutBinding(keyCode: 123, modifiers: [.option])
        case .tileRight: ShortcutBinding(keyCode: 124, modifiers: [.option])
        case .previewDeleteCharacter: ShortcutBinding(keyCode: 51)
        case .previewPreviousTab: ShortcutBinding(keyCode: 48, modifiers: [.shift])
        case .previewNextTab: ShortcutBinding(keyCode: 48)
        case .previewOpenKeypad: ShortcutBinding(keyCode: 76)
        case .previewDeleteForward: ShortcutBinding(keyCode: 117)
        case .minimizeWindow, .previewMinimizeWindow: ShortcutBinding(keyCode: 46, modifiers: [.command])
        case .closeWindow, .previewCloseWindow: ShortcutBinding(keyCode: 51, modifiers: [.command])
        case .previewSearch: ShortcutBinding(keyCode: 3, modifiers: [.command])
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags = []

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .control, .option, .shift])
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try values.decode(UInt16.self, forKey: .keyCode)
        let rawValue = try values.decode(UInt.self, forKey: .modifiers)
        modifiers = NSEvent.ModifierFlags(rawValue: rawValue).intersection([.command, .control, .option, .shift])
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(keyCode, forKey: .keyCode)
        try values.encode(modifiers.rawValue, forKey: .modifiers)
    }

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers.intersection([.command, .control, .option, .shift])
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }

    var keyEquivalent: KeyEquivalent {
        let special: [UInt16: KeyEquivalent] = [36: .return, 48: .tab, 49: .space, 51: .delete, 53: .escape,
            123: .leftArrow, 124: .rightArrow, 125: .downArrow, 126: .upArrow]
        return special[keyCode] ?? KeyEquivalent(Self.keyName(keyCode).lowercased().first ?? "?")
    }

    var displayName: String {
        let prefix = [
            modifiers.contains(.control) ? "⌃" : nil,
            modifiers.contains(.option) ? "⌥" : nil,
            modifiers.contains(.shift) ? "⇧" : nil,
            modifiers.contains(.command) ? "⌘" : nil
        ].compactMap { $0 }.joined(separator: " ")
        let key = Self.keyName(keyCode)
        return prefix.isEmpty ? key : "\(prefix) \(key)"
    }

    private static func keyName(_ code: UInt16) -> String {
        let special: [UInt16: String] = [
            36: "↵", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘",
            116: "⇞", 121: "⇟", 117: "⌦"
        ]
        if let value = special[code] { return value }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(code)"
        }
        let data = unsafeBitCast(layout, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return "Key \(code)" }
        let keyboard = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(keyboard, code, UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &deadKey, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return "Key \(code)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

@MainActor
final class ShortcutConfiguration: ObservableObject {
    static let shared = ShortcutConfiguration()
    @Published private(set) var bindings: [ShortcutAction: ShortcutBinding]
    @Published private(set) var recordingAction: ShortcutAction?
    @Published var registrationError: String?
    @Published var assignmentError: String?
    var onGlobalShortcutsChanged: (() -> Void)?

    private var recordingMonitor: Any?
    private var recordingResignCancellable: AnyCancellable?

    private init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: "shortcuts.bindings"),
           let saved = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { action in
                (action, saved[action.rawValue] ?? action.defaultBinding)
            })
        } else {
            bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultBinding) })
        }
    }

    func binding(for action: ShortcutAction) -> ShortcutBinding { bindings[action] ?? action.defaultBinding }

    func action(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags, group: String) -> ShortcutAction? {
        guard recordingAction == nil else { return nil }
        return ShortcutAction.allCases.first { $0.group == group && binding(for: $0).matches(keyCode: keyCode, modifiers: modifiers) }
    }

    func conflict(for action: ShortcutAction) -> ShortcutAction? {
        let binding = binding(for: action)
        return ShortcutAction.allCases.first {
            $0 != action && ($0.group == action.group || $0 == .showRing || action == .showRing) && self.binding(for: $0) == binding
        }
    }

    // 录入由 ShortcutConfiguration 自己持有本地键盘监视器，不依赖某个 NSView 成为 first responder。
    // 设置窗口里的行视图可能被 SwiftUI 重建或抢走焦点，绑定到 first responder 会让按键永远收不到。
    func beginRecording(_ action: ShortcutAction) {
        guard recordingAction != action else { return }
        stopRecordingMonitor()
        recordingAction = action
        assignmentError = nil
        // 录入期间先注销 Carbon 全局快捷键，避免按下候选组合时先触发旧动作。
        onGlobalShortcutsChanged?()

        // 切到其他应用时结束录入，避免全局快捷键一直处于注销状态。
        recordingResignCancellable = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.cancelRecording() }

        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, self.recordingAction == action else { return event }
            switch event.type {
            case .keyDown:
                self.capture(ShortcutBinding(keyCode: event.keyCode, modifiers: event.modifierFlags), for: action)
                return nil
            case .leftMouseDown:
                // 点击设置页的其他位置视为取消；点击另一个录入框时，随后的按钮动作会重新开始录入。
                self.cancelRecording()
                return event
            default:
                return event
            }
        }
    }

    func cancelRecording() {
        guard recordingAction != nil || recordingMonitor != nil else { return }
        stopRecordingMonitor()
        recordingAction = nil
        onGlobalShortcutsChanged?()
    }

    private func capture(_ binding: ShortcutBinding, for action: ShortcutAction) {
        guard !action.requiresModifier || !binding.modifiers.isEmpty else {
            assignmentError = "全局快捷键需要至少一个修饰键，请重新按下组合键。"
            return
        }
        stopRecordingMonitor()
        recordingAction = nil
        _ = assign(binding, to: action)
        // 即使因为冲突保留旧组合，也要恢复 Carbon 全局注册。
        onGlobalShortcutsChanged?()
    }

    private func stopRecordingMonitor() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        recordingResignCancellable = nil
    }

    @discardableResult func assign(_ binding: ShortcutBinding, to action: ShortcutAction) -> ShortcutAction? {
        guard !action.requiresModifier || !binding.modifiers.isEmpty else {
            assignmentError = "全局快捷键需要至少一个修饰键。"
            return action
        }
        if let conflict = ShortcutAction.allCases.first(where: {
            $0 != action && ($0.group == action.group || $0 == .showRing || action == .showRing)
                && self.binding(for: $0) == binding
        }) {
            assignmentError = "与「\(conflict.title)」冲突，已保留原快捷键。"
            return conflict
        }
        if action == .showRing, binding.keyCode == 48, binding.modifiers.contains(.command) {
            assignmentError = "⌘Tab 由 macOS 原生切换器使用，请选择其他组合。"
            return action
        }
        assignmentError = nil
        bindings[action] = binding
        save()
        if action == .showRing { onGlobalShortcutsChanged?() }
        return conflict(for: action)
    }

    func restoreDefaults() {
        assignmentError = nil
        bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultBinding) })
        save()
        onGlobalShortcutsChanged?()
    }

    private func save() {
        let values = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(values) { UserDefaults.standard.set(data, forKey: "shortcuts.bindings") }
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject private var configuration = ShortcutConfiguration.shared

    var body: some View {
        Form {
            Section {
                ForEach(["全局", "菜单", "窗口环", "Dock 列表"], id: \.self) { group in
                    Section(group) {
                        ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                            shortcutRow(action)
                        }
                    }
                }
            } footer: {
                Text("全局快捷键需要至少一个修饰键；同一组内不能分配重复组合。系统的 ⌘Tab 由 macOS 管理，不可在此修改。")
            }
            if let error = configuration.assignmentError ?? configuration.registrationError {
                Text(error).foregroundStyle(.orange)
            }
            Section {
                Button("恢复默认快捷键") { configuration.restoreDefaults() }
            }
        }
        .formStyle(.grouped)
        .onDisappear { configuration.cancelRecording() }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        HStack {
            Text(action.title)
            Spacer()
            ShortcutRecorder(action: action)
            if let conflict = configuration.conflict(for: action) {
                Label("与\(conflict.title)冲突", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }
}

private struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ObservedObject private var configuration = ShortcutConfiguration.shared

    private var isRecording: Bool { configuration.recordingAction == action }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                configuration.beginRecording(action)
            } label: {
                Text(isRecording ? "按下快捷键…" : configuration.binding(for: action).displayName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(minWidth: 82, minHeight: 24)
                    .background(isRecording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isRecording ? Color.accentColor : Color.clear))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(action.title)快捷键")
            .accessibilityValue(isRecording ? "正在录入" : configuration.binding(for: action).displayName)
            .accessibilityHint("点击后按下新的快捷键组合")
            .help("点击后按下新的快捷键组合")

            if isRecording, let error = configuration.assignmentError {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
    }
}
