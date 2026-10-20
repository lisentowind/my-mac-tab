import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: WindowManager
    @ObservedObject private var preferences = PreviewPreferences.shared
    @State private var screenCaptureAllowed = CGPreflightScreenCaptureAccess()
    @State private var applicationOptions: [PreviewApplicationOption] = []

    var body: some View {
        TabView {
            general.tabItem { Label("通用", systemImage: "slider.horizontal.3") }
            ShortcutSettingsView().tabItem { Label("快捷键", systemImage: "keyboard") }
            preview.tabItem { Label("窗口预览", systemImage: "rectangle.on.rectangle") }
            applications.tabItem { Label("应用", systemImage: "square.grid.2x2") }
        }
        .padding(16)
        .frame(width: 640, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            manager.refreshPermission()
            refreshSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            manager.updateAccessibilityPermission(AXIsProcessTrusted())
            screenCaptureAllowed = CGPreflightScreenCaptureAccess()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshApplications()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshApplications()
        }
    }

    private var general: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 28, weight: .medium)).foregroundStyle(Color.accentColor)
                        .frame(width: 52, height: 52)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("窗口切换").font(.system(size: 20, weight: .semibold))
                        Text("在应用和窗口之间，轻快切换。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section("键盘快捷键") {
                Text("在「快捷键」页自定义呼出窗口环、切换应用和窗口、窗口操作及菜单快捷键。")
            }
            Section("辅助功能") {
                HStack {
                    Label(manager.hasAccessibilityPermission ? "已允许管理窗口" : "需要辅助功能权限",
                          systemImage: manager.hasAccessibilityPermission ? "checkmark.circle.fill" : "lock.shield")
                        .foregroundStyle(manager.hasAccessibilityPermission ? Color.green : Color.primary)
                    Spacer()
                    Button("系统设置…", action: manager.openAccessibilitySettings)
                }
                Text("用于读取窗口标题、切换、最小化和关闭窗口。关闭操作会保留应用自己的保存确认。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var preview: some View {
        Form {
            Section("悬浮窗口列表") {
                Toggle("悬停应用图标时显示窗口", isOn: $preferences.dockPreviewEnabled)
                Toggle("同时预览 ⌘Tab 中的应用", isOn: $preferences.switcherPreviewEnabled)
                    .disabled(!preferences.dockPreviewEnabled)
                delaySlider("显示延迟", value: $preferences.hoverDelay, range: 0...0.8)
                    .disabled(!preferences.dockPreviewEnabled)
                Text("列表按最近使用排序，显示期间保持位置稳定。点击当前窗口可最小化，再次打开可恢复。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("按住 ⌘ 悬停原生切换器图标；将鼠标移入浮窗后，即可松开 ⌘，点击窗口或长悬停查看缩略图。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("窗口缩略图") {
                Toggle("长悬停窗口条目时显示缩略图", isOn: $preferences.thumbnailsEnabled)
                    .disabled(!preferences.dockPreviewEnabled)
                delaySlider("悬停时间", value: $preferences.thumbnailDelay, range: 0.25...1.2)
                    .disabled(!preferences.thumbnailsEnabled)
                Picker("预览大小", selection: $preferences.thumbnailSize) {
                    ForEach(ThumbnailSize.allCases) { size in Text(size.title).tag(size) }
                }
                .pickerStyle(.segmented)
                .disabled(!preferences.thumbnailsEnabled)
                Text("停留后获取一张画面，短暂缓存；不会持续录屏。最小化窗口仅显示已有的预览。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("屏幕录制权限") {
                HStack {
                    Label(screenCaptureAllowed ? "已允许窗口预览" : "窗口画面需要额外授权",
                          systemImage: screenCaptureAllowed ? "checkmark.circle.fill" : "lock.shield")
                        .foregroundStyle(screenCaptureAllowed ? Color.green : Color.secondary)
                    Spacer()
                    if !screenCaptureAllowed {
                        Button("允许…") {
                            screenCaptureAllowed = CGRequestScreenCaptureAccess()
                            if !screenCaptureAllowed { openScreenCaptureSettings() }
                        }
                    } else {
                        Button("系统设置…", action: openScreenCaptureSettings)
                    }
                }
                Text("未授权也能正常查看窗口列表及管理窗口；悬停时不会自动弹出权限请求。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("按应用显示预览").font(.system(size: 18, weight: .semibold))
                Text("关闭后，悬停该应用的 Dock 或 ⌘Tab 图标时不显示列表和缩略图；快捷键窗口环仍可使用。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            List(applicationOptions) { option in
                Toggle(isOn: Binding(
                    get: { preferences.excludedApplications[option.id] == nil },
                    set: { preferences.setAllowed($0, key: option.id, name: option.name) }
                )) {
                    HStack(spacing: 10) {
                        ApplicationOptionIcon(application: option.application)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.name).font(.system(size: 12, weight: .medium))
                            if option.application == nil {
                                Text("未运行 · 已保留设置").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .toggleStyle(.switch)
                .padding(.vertical, 3)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("列出正在运行的应用和已排除的应用。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("刷新", action: refreshApplications).controlSize(.small)
            }
        }
        .padding(16)
    }

    private func shortcut(_ title: String, key: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(key).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func delaySlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 16) {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: value, in: range, step: 0.05).accessibilityLabel(title)
            Text("\(Int((value.wrappedValue * 1_000).rounded())) ms")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .monospacedDigit().frame(width: 62, alignment: .trailing)
        }
    }

    private func refreshSettings() {
        screenCaptureAllowed = CGPreflightScreenCaptureAccess()
        refreshApplications()
    }

    private func refreshApplications() {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        var options = Dictionary(preferences.excludedApplications.map {
            ($0.key, PreviewApplicationOption(id: $0.key, name: $0.value, application: nil))
        }, uniquingKeysWith: { first, _ in first })
        for app in running {
            let key = preferences.key(for: app)
            options[key] = PreviewApplicationOption(id: key, name: app.localizedName ?? "应用", application: app)
        }
        applicationOptions = options.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PreviewApplicationOption: Identifiable {
    let id: String
    let name: String
    let application: NSRunningApplication?
}

private struct ApplicationOptionIcon: View {
    let application: NSRunningApplication?
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable() }
            else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
        .onAppear { icon = smallIcon() }
        .onChange(of: application?.processIdentifier) { _, _ in icon = smallIcon() }
        .onDisappear { icon = nil }
    }

    private func smallIcon() -> NSImage? {
        guard let source = application?.icon,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(bitmap)
        return image
    }
}
