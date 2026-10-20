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
        }
    }
}

private struct MenuBarControls: View {
    let manager: WindowManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("显示窗口环") { manager.showRing() }
            .keyboardShortcut(" ", modifiers: [.control, .option])
        Divider()
        Button("设置…") {
            // 等菜单结束 tracking 后再激活 accessory 应用，首次打开也能取得窗口焦点。
            DispatchQueue.main.async {
                manager.dismissRing()
                manager.dismissDockPreview()
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("退出") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKey = GlobalHotKey()
    private var dockHover: DockHoverController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        WindowManager.shared.start()
        hotKey.register { WindowManager.shared.showRing() }
        let dockHover = DockHoverController(manager: WindowManager.shared)
        self.dockHover = dockHover
        dockHover.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.unregister()
        dockHover?.stop()
        WindowManager.shared.stop()
    }
}
