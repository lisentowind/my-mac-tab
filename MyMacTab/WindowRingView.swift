import AppKit
import SwiftUI

struct WindowRingView: View {
    @ObservedObject var manager: WindowManager
    @ObservedObject private var shortcuts = ShortcutConfiguration.shared
    let displayScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keyboardPointer: CGPoint? = NSEvent.mouseLocation

    var body: some View {
        ZStack {
            applicationRing
            windowList
                .frame(width: WindowRingGeometry.listFrame.width, height: WindowRingGeometry.listFrame.height)
                .position(x: WindowRingGeometry.listFrame.midX, y: WindowRingGeometry.listFrame.midY)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: manager.selectedApplicationID)
            Button(action: manager.dismissRing) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(RingControlStyle())
            .help("关闭 · \(shortcuts.binding(for: .dismissOverlay).displayName)")
            .position(x: WindowRingGeometry.panelSize.width - 26, y: 22)
        }
        .foregroundStyle(.white)
        .frame(width: WindowRingGeometry.panelSize.width, height: WindowRingGeometry.panelSize.height)
        .opacity(manager.isRingPresented ? 1 : 0)
        .scaleEffect(displayScale)
        .frame(width: WindowRingGeometry.panelSize.width * displayScale,
               height: WindowRingGeometry.panelSize.height * displayScale)
        .onChange(of: manager.selectedIndex) { _, _ in keyboardPointer = NSEvent.mouseLocation }
        .onChange(of: manager.selectedApplicationID) { _, _ in keyboardPointer = NSEvent.mouseLocation }
    }

    private var applicationRing: some View {
        ZStack {
            AdaptiveWindowSurface(shape: Circle(),
                                  tint: Color(red: 0.18, green: 0.28, blue: 0.6).opacity(0.42),
                                  opaqueColor: Color(red: 0.19, green: 0.28, blue: 0.56))
                .frame(width: WindowRingGeometry.circleRadius * 2, height: WindowRingGeometry.circleRadius * 2)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .position(WindowRingGeometry.center)
            Circle().strokeBorder(.white.opacity(0.07), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(width: WindowRingGeometry.appRadius * 2, height: WindowRingGeometry.appRadius * 2)
                .position(WindowRingGeometry.center)
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.1, green: 0.19, blue: 0.48).opacity(0.38),
                                             Color(red: 0.06, green: 0.13, blue: 0.38).opacity(0.54)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 170, height: 170)
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .position(WindowRingGeometry.center)
            ForEach(Array(manager.applications.enumerated()), id: \.element.id) { index, app in
                applicationIcon(app, count: manager.applications.count)
                    .position(WindowRingGeometry.applicationPosition(index: index, count: manager.applications.count))
            }
            VStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                Text(manager.selectedApplication?.name ?? "暂无窗口")
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.center)
                Text("\(shortcuts.binding(for: .previousApplication).displayName)  \(shortcuts.binding(for: .nextApplication).displayName)  或滚轮切换应用")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(width: 140, height: 140).position(WindowRingGeometry.center)
            Label("\(manager.applications.count) 个运行中应用", systemImage: "circle.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                .position(x: WindowRingGeometry.center.x, y: 444)
        }
    }

    private func applicationIcon(_ app: WindowApplication, count: Int) -> some View {
        let selected = app.id == manager.selectedApplication?.id
        let side = WindowRingGeometry.iconSize(count: count)
        return Button { selectApplication(app.id) } label: {
            Image(nsImage: app.icon).resizable().interpolation(.high)
                .frame(width: side, height: side).padding(5)
                .background(.white.opacity(selected ? 0.13 : 0), in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(selected ? 0.5 : 0), lineWidth: 1.5))
                .overlay(alignment: .topTrailing) {
                    if app.windows.count > 1 {
                        Text("\(app.windows.count)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color(red: 0.94, green: 0.28, blue: 0.33), in: Capsule())
                            .offset(x: 3, y: -3)
                    }
                }
                .scaleEffect(selected ? 1.1 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 1), value: selected)
                // 视觉尺寸不变，额外留白只扩大点击命中区，避免贴着图标点偏。
                .padding(WindowRingGeometry.iconHitPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(app.name)，\(app.windows.count) 个窗口")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help("点击切换到 \(app.name)")
    }

    private var windowList: some View {
        VStack(spacing: 0) {
            if let app = manager.selectedApplication {
                HStack(spacing: 10) {
                    Image(nsImage: app.icon).resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text("\(app.windows.count) 个窗口")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    navigationButton(-1, "chevron.left")
                    Text("\(app.windows.isEmpty ? 0 : manager.selectedIndex + 1) / \(app.windows.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    navigationButton(1, "chevron.right")
                }
                .padding(.horizontal, 16).frame(height: 72)
                Divider().padding(.horizontal, 16)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(app.windows.enumerated()), id: \.element.id) { index, window in
                                windowRow(window, index: index)
                                    .id(window.id)
                            }
                        }.padding(8)
                    }
                    .overlay {
                        if app.windows.isEmpty {
                            ContentUnavailableView("暂无可用窗口", systemImage: "macwindow",
                                                   description: Text("此应用暂未提供可管理的窗口"))
                        }
                    }
                    .scrollIndicators(.automatic)
                    .onAppear {
                        if let window = manager.selectedWindow { proxy.scrollTo(window.id) }
                    }
                    .onChange(of: manager.selectedIndex) { _, _ in
                        if let window = manager.selectedWindow { proxy.scrollTo(window.id) }
                    }
                    .onChange(of: app.id) { _, _ in
                        if let window = manager.selectedWindow { proxy.scrollTo(window.id, anchor: .top) }
                    }
                }
                Divider().padding(.horizontal, 16)
                HStack(spacing: 8) {
                    Text("\(shortcuts.binding(for: .previousWindow).displayName) \(shortcuts.binding(for: .nextWindow).displayName) 选择")
                    Text("\(shortcuts.binding(for: .activateWindow).displayName) 打开")
                    Spacer(minLength: 0)
                    Text("\(shortcuts.binding(for: .dismissOverlay).displayName) 关闭")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).frame(height: 36)
            }
        }
        .foregroundStyle(.primary)
        .background { AdaptiveWindowSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private func windowRow(_ window: ManagedWindow, index: Int) -> some View {
        let selected = manager.selectedIndex == index
        return RingWindowRow(window: window, selected: selected) {
            manager.activateRingWindow(window.id)
        }
        .onHover { inside in
            if inside, keyboardPointer != NSEvent.mouseLocation { manager.selectWindow(index) }
        }
        .accessibilityLabel("窗口 \(index + 1)：\(window.title)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(window.title)
    }

    private func navigationButton(_ offset: Int, _ symbol: String) -> some View {
        Button { manager.moveWindow(offset) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 26)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(RingControlStyle())
        .disabled((manager.selectedApplication?.windows.count ?? 0) < 2)
        .accessibilityLabel(offset < 0 ? "上一个窗口" : "下一个窗口")
    }

    private func selectApplication(_ id: String) {
        keyboardPointer = NSEvent.mouseLocation
        manager.selectApplication(id)
    }
}

private struct RingWindowRow: View {
    let window: ManagedWindow
    let selected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: window.isMinimized ? "minus.rectangle" : "macwindow")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(window.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2).truncationMode(.middle)
                    Text(window.isMinimized ? "已最小化" : window.isFocused ? "当前窗口" : "点击打开窗口")
                        .font(.system(size: 10))
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(selected ? 0.8 : 0)
                    .frame(width: 16)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if selected && contrast == .increased {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.8), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.14), value: selected)
        }
        .buttonStyle(RingWindowRowStyle())
        .focusEffectDisabled()
    }
}

private struct RingWindowRowStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 1),
                       value: configuration.isPressed)
    }
}

private struct RingControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(!isEnabled ? 0.3 : configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
    }
}

nonisolated enum WindowRingGeometry {
    static let panelSize = CGSize(width: 750, height: 470)
    static let center = CGPoint(x: 194, y: 230)
    static let circleRadius: CGFloat = 174
    static let appRadius: CGFloat = 130
    static let listFrame = CGRect(x: 398, y: 58, width: 316, height: 354)
    static let iconHitPadding: CGFloat = 9

    static func iconSize(count: Int) -> CGFloat {
        min(48, max(18, 2 * .pi * appRadius / CGFloat(max(count, 1)) - 18))
    }

    // 环带整段可点：图标轨道两侧留白也算命中，避免点到图标之间的空隙毫无反应。
    static func applicationHitRange(count: Int) -> ClosedRange<CGFloat> {
        let inner = max(0, appRadius - iconSize(count: count) / 2 - 20)
        return inner...circleRadius
    }

    static func applicationPosition(index: Int, count: Int) -> CGPoint {
        let angle = 2 * CGFloat.pi * CGFloat(index) / CGFloat(max(count, 1)) - .pi / 2
        return CGPoint(x: center.x + cos(angle) * appRadius, y: center.y + sin(angle) * appRadius)
    }
}

// 面板计算与视图共用尺寸，避免行高和留白调整后出现裁切或多余空白。
enum DockPreviewGeometry {
    static let minimumWidth: CGFloat = 248
    static let maximumWidth: CGFloat = 320
    static let cornerRadius: CGFloat = 18
    static let headerHeight: CGFloat = 68
    static let dividerHeight: CGFloat = 1
    static let searchHeight: CGFloat = 38
    static let footerHeight: CGFloat = 24
    static let rowHeight: CGFloat = 50
    static let rowSpacing: CGFloat = 6
    static let rowLeadingInset: CGFloat = 12
    static let rowTrailingInset: CGFloat = 8
    static let rowSymbolSize: CGFloat = 18
    static let rowContentSpacing: CGFloat = 10
    static let rowActionGap: CGFloat = 16
    static let actionSize: CGFloat = 28
    static let actionSpacing: CGFloat = 4
    static let listInset: CGFloat = 8
    static let maximumListHeight: CGFloat = 348

    static func width(for app: WindowApplication, availableWidth: CGFloat) -> CGFloat {
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let longestTitle = app.windows.reduce(CGFloat.zero) { width, window in
            max(width, (window.title as NSString).size(withAttributes: [.font: titleFont]).width)
        }
        let nameWidth = (app.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)]).width
        // 为图标、行内间距和操作符号保留空间；标题过长时截断，不随鼠标移动重新测量。
        let headerWidth = nameWidth + 32 + 36 + 11 + 76
        let rowWidth = longestTitle + listInset * 2 + rowLeadingInset + rowSymbolSize
            + rowContentSpacing + rowActionGap + actionSize * 2 + actionSpacing + rowTrailingInset
        return min(availableWidth, min(maximumWidth, max(minimumWidth, max(headerWidth, rowWidth))))
    }

    static func listHeight(windowCount: Int) -> CGFloat {
        let count = CGFloat(max(windowCount, 0))
        return min(count * rowHeight + max(count - 1, 0) * rowSpacing + listInset * 2,
                   maximumListHeight)
    }

    static func height(windowCount: Int) -> CGFloat {
        headerHeight + dividerHeight + searchHeight + footerHeight + listHeight(windowCount: windowCount)
    }
}

struct DockWindowPreviewView: View {
    @ObservedObject var manager: WindowManager
    @ObservedObject private var shortcuts = ShortcutConfiguration.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var app: WindowApplication? {
        manager.dockPreviewApplication
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let app {
                content(for: app)
                    .id(app.id)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { DockPreviewSurface() }
        .clipShape(RoundedRectangle(cornerRadius: DockPreviewGeometry.cornerRadius, style: .continuous))
        .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.16), value: manager.dockPreviewApplicationID)
    }

    private func content(for app: WindowApplication) -> some View {
        let isHidden = app.application.isHidden
        return VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.1), radius: 3, y: 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(app.windows.count) 个窗口")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isHidden {
                    Label("已隐藏", systemImage: "eye.slash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.primary.opacity(0.045), in: Capsule())
                        .fixedSize()
                }
            }
            .padding(.horizontal, 16)
            .frame(height: DockPreviewGeometry.headerHeight)
            .accessibilityElement(children: .combine)

            Rectangle()
                .fill(.primary.opacity(0.07))
                .frame(height: DockPreviewGeometry.dividerHeight)
                .padding(.horizontal, 16)
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                if manager.isDockSearchEditing {
                    PreviewSearchField(text: manager.dockSearchText, onChange: manager.setDockSearch,
                                       onCommand: manager.handleDockSearchCommand,
                                       onCompositionChange: manager.updateDockSearchComposition)
                } else {
                    Button(action: manager.beginDockSearch) {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11))
                            Text(manager.dockSearchText.isEmpty ? "键入以筛选窗口" : manager.dockSearchText)
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(manager.dockSearchText.isEmpty ? .secondary : .primary)
                        .padding(.horizontal, 9).frame(height: 25)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("输入标题筛选；点击可使用中文输入法")
                }
                if !manager.dockSearchText.isEmpty {
                    Button(action: manager.clearDockSearch) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("清除筛选")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: DockPreviewGeometry.searchHeight)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: DockPreviewGeometry.rowSpacing) {
                        ForEach(manager.dockPreviewWindows) { window in
                            DockWindowRow(window: window, isApplicationHidden: isHidden,
                                          isCurrentWindow: manager.dockPreviewFocusedWindowID == window.id,
                                          isSelected: manager.dockSelectedWindowID == window.id,
                                          action: manager.toggleDockWindow,
                                          minimize: manager.minimizeOrRestoreDockWindow,
                                          close: manager.closeDockWindow,
                                          hover: manager.hoverDockWindow, leave: manager.leaveDockWindow)
                                .id(window.id)
                        }
                    }
                    .padding(DockPreviewGeometry.listInset)
                }
                .overlay {
                    if manager.dockPreviewWindows.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 19))
                            Text("没有匹配的窗口").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
                .scrollIndicators(.automatic)
                .onChange(of: manager.selectedIndex) { _, _ in
                    if let id = manager.dockSelectedWindowID { proxy.scrollTo(id) }
                }
            }
            .frame(maxHeight: DockPreviewGeometry.listHeight(windowCount: app.windows.count))

            HStack(spacing: 6) {
                if manager.isDockKeyboardAvailable || manager.isDockSearchEditing {
                    Text("\(shortcuts.binding(for: .previewPreviousWindow).displayName)\(shortcuts.binding(for: .previewNextWindow).displayName) 选择")
                    Text("\(shortcuts.binding(for: .previewOpenWindow).displayName) 打开")
                    Spacer(minLength: 0)
                    Text("\(shortcuts.binding(for: .previewDismiss).displayName) 退出")
                } else {
                    Text("点击搜索框，使用键盘浏览")
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: DockPreviewGeometry.footerHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct DockPreviewSurface: View {
    var body: some View {
        AdaptiveWindowSurface(shape: RoundedRectangle(cornerRadius: DockPreviewGeometry.cornerRadius,
                                                       style: .continuous))
    }
}

private struct DockWindowRow: View {
    let window: ManagedWindow
    let isApplicationHidden: Bool
    let isCurrentWindow: Bool
    let isSelected: Bool
    let action: (String) -> Void
    let minimize: (String) -> Void
    let close: (String) -> Void
    let hover: (String) -> Void
    let leave: (String) -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    private var highlighted: Bool { isSelected }
    private var actionDescription: String {
        isCurrentWindow ? "最小化窗口" : window.isMinimized ? "恢复窗口" : "打开窗口"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { action(window.id) } label: {
                HStack(spacing: DockPreviewGeometry.rowContentSpacing) {
                    Image(systemName: window.isMinimized ? "minus.rectangle" : isCurrentWindow ? "checkmark.circle.fill" : "macwindow")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(highlighted ? Color.white.opacity(0.94)
                                             : isCurrentWindow ? Color.accentColor : Color.secondary)
                        .frame(width: DockPreviewGeometry.rowSymbolSize, height: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(window.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        if window.isMinimized || isCurrentWindow {
                            Text(window.isMinimized ? "已最小化" : "当前窗口")
                                .font(.system(size: 10))
                                .foregroundStyle(highlighted ? Color.white.opacity(0.76) : Color.secondary)
                        }
                    }
                    .foregroundStyle(highlighted ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, DockPreviewGeometry.rowLeadingInset)
                .padding(.trailing, DockPreviewGeometry.rowActionGap)
                .frame(maxWidth: .infinity).frame(height: DockPreviewGeometry.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(DockWindowContentStyle())
            .focusEffectDisabled()
            .accessibilityLabel(window.title)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityValue(window.isMinimized ? "已最小化" : isCurrentWindow ? "当前窗口" : "")
            .accessibilityAction(named: Text(window.isMinimized ? "恢复窗口" : "最小化窗口")) { minimize(window.id) }
            .accessibilityAction(named: Text("关闭窗口")) { close(window.id) }
            .accessibilityHint(isApplicationHidden ? "显示应用并打开窗口" : actionDescription)
            .help("\(window.title)\n单击\(actionDescription)")

            HStack(spacing: DockPreviewGeometry.actionSpacing) {
                WindowActionButton(symbol: window.isMinimized ? "arrow.up.right" : "minus",
                                   title: window.isMinimized ? "恢复窗口" : "最小化窗口", highlighted: highlighted) {
                    minimize(window.id)
                }
                WindowActionButton(symbol: "xmark", title: "关闭窗口", highlighted: highlighted, destructive: true) {
                    close(window.id)
                }
            }
            .opacity(highlighted ? 1 : 0)
            .allowsHitTesting(highlighted)
            .accessibilityHidden(!highlighted)
            .padding(.trailing, DockPreviewGeometry.rowTrailingInset)
        }
        .background(highlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if highlighted && contrast == .increased {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.7), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { inside in
            if inside { hover(window.id) } else { leave(window.id) }
        }
    }
}

private struct WindowActionButton: View {
    let symbol: String
    let title: String
    let highlighted: Bool
    var destructive = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: DockPreviewGeometry.actionSize, height: DockPreviewGeometry.actionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(WindowActionButtonStyle(isHovered: hovered, highlighted: highlighted, destructive: destructive))
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .help(title)
    }
}

// 主操作区不再单独画背景/边框；整行只有一层选中底色。
private struct DockWindowContentStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct WindowActionButtonStyle: ButtonStyle {
    let isHovered: Bool
    let highlighted: Bool
    let destructive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let engaged = isHovered || configuration.isPressed
        return configuration.label
            .foregroundStyle(engaged && destructive ? Color.white
                                 : highlighted ? Color.white.opacity(engaged ? 1 : 0.82) : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(engaged ? (destructive ? Color(nsColor: .systemRed)
                                       : highlighted ? Color.white.opacity(0.18) : Color.primary.opacity(0.08)) : .clear)
            }
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// 默认不夺走目标应用焦点；仅显式点击搜索框时允许原生输入法获得键盘焦点。
final class DockPreviewPanel: NSPanel {
    var allowsKeyboardFocus = false
    var onMouseDown: (() -> Void)?
    var handleKey: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onMouseDown?() }
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
}

final class RingPanel: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// 玻璃背景用了 allowsHitTesting(false)，圆环内的空白处 hitTest 会返回 nil，
// 系统随即把点击与滚轮转给下层窗口。这里兜底返回自身，保证整个面板都能收到鼠标和滚轮。
final class RingContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? self
    }
}
