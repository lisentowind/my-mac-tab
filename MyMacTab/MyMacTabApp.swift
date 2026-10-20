import AppKit
import SwiftUI

@main
struct MyMacTabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let manager = WindowManager.shared

    var body: some Scene {
        MenuBarExtra("窗口切换", systemImage: "circle.hexagongrid.fill") {
            MenuBarControls(manager: manager)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            ContentView(manager: manager)
                .navigationTitle("设置")
                .background(SettingsWindowAccessor())
        }
    }
}

private struct MenuBarControls: View {
    let manager: WindowManager
    @ObservedObject private var shortcuts = ShortcutConfiguration.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("显示窗口环") { manager.showRing() }
            .keyboardShortcut(shortcuts.binding(for: .showRing).keyEquivalent, modifiers: shortcuts.binding(for: .showRing).eventModifiers)
        Divider()
        Button("设置…") {
            // 等菜单结束 tracking 后再激活 accessory 应用，首次打开也能取得窗口焦点。
            DispatchQueue.main.async {
                manager.dismissRing()
                manager.dismissDockPreview()
                SettingsWindowPresenter.shared.open { openSettings() }
            }
        }
        .keyboardShortcut(shortcuts.binding(for: .openSettings).keyEquivalent, modifiers: shortcuts.binding(for: .openSettings).eventModifiers)
        Button("退出") { NSApp.terminate(nil) }
            .keyboardShortcut(shortcuts.binding(for: .quit).keyEquivalent, modifiers: shortcuts.binding(for: .quit).eventModifiers)
    }
}

// SwiftUI 异步创建设置窗口，取得实际窗口后再激活和前置。
@MainActor
private final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()
    private weak var window: NSWindow?
    private var presentationRequested = false

    func open(_ action: () -> Void) {
        presentationRequested = true
        action()
        DispatchQueue.main.async { self.bringToFrontIfRequested() }
    }

    func register(_ window: NSWindow) {
        self.window = window
        DispatchQueue.main.async { self.bringToFrontIfRequested() }
    }

    private func bringToFrontIfRequested() {
        guard presentationRequested, let window else { return }
        presentationRequested = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ nsView: WindowView, context: Context) {}

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { SettingsWindowPresenter.shared.register(window) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKey = GlobalHotKey()
    private var dockHover: DockHoverController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        WindowManager.shared.start()
        ShortcutConfiguration.shared.onGlobalShortcutsChanged = { [weak self] in self?.registerHotKey() }
        registerHotKey()
        let dockHover = DockHoverController(manager: WindowManager.shared)
        self.dockHover = dockHover
        dockHover.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShortcutConfiguration.shared.onGlobalShortcutsChanged = nil
        hotKey.unregister()
        dockHover?.stop()
        WindowManager.shared.stop()
    }

    private func registerHotKey() {
        let configuration = ShortcutConfiguration.shared
        guard configuration.recordingAction == nil else { hotKey.unregister(); return }
        let status = hotKey.register(binding: configuration.binding(for: .showRing)) { WindowManager.shared.showRing() }
        configuration.registrationError = status == 0 ? nil : "全局快捷键注册失败（\(status)），可能已被系统或其他应用占用，请更换组合。"
    }
}
