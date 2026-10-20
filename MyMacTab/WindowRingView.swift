import AppKit
import SwiftUI

struct WindowRingView: View {
    @ObservedObject var manager: WindowManager
    let displayScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var windowBaseAngle: CGFloat?

    private let ringCenter = WindowRingGeometry.center

    var body: some View {
        ringContent
        .focusable()
        .focused($isFocused)
        // 保留方向键焦点，关闭系统沿透明浮层矩形绘制的蓝色焦点边框。
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onChange(of: manager.isRingPresented) { _, isPresented in
            if isPresented { isFocused = true }
            else { windowBaseAngle = nil }
        }
        .onChange(of: manager.selectedApplicationID) { _, _ in
            guard let index = manager.applications.firstIndex(where: { $0.id == manager.selectedApplication?.id }) else { return }
            let angle = appAngle(index: index, count: manager.applications.count)
            if let current = windowBaseAngle, abs(atan2(sin(angle - current), cos(angle - current))) < 0.001 { return }
            // 键盘切换直接对齐；hover 在 selectApplication 中设置连续角度和动画。
            windowBaseAngle = angle
        }
        .onChange(of: manager.applications.map(\.id)) { _, _ in
            if let index = manager.applications.firstIndex(where: { $0.id == manager.selectedApplication?.id }) {
                windowBaseAngle = appAngle(index: index, count: manager.applications.count)
            }
        }
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { key in
            if key.modifiers.contains(.option) { manager.splitSelectedWindow(to: .left) }
            else { manager.moveApplication(-1) }
            return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { key in
            if key.modifiers.contains(.option) { manager.splitSelectedWindow(to: .right) }
            else { manager.moveApplication(1) }
            return .handled
        }
        .onKeyPress(.upArrow) { manager.moveWindow(-1); return .handled }
        .onKeyPress(.downArrow) { manager.moveWindow(1); return .handled }
        .onKeyPress(.escape) { manager.dismissRing(); return .handled }
        .onKeyPress(.return) { manager.activateSelectedWindow(); return .handled }
    }

    private var ringContent: some View {
        ZStack {
            AdaptiveWindowSurface(shape: Circle(),
                                  tint: Color(red: 0.18, green: 0.28, blue: 0.6).opacity(0.42),
                                  opaqueColor: Color(red: 0.19, green: 0.28, blue: 0.56))
                .frame(width: WindowRingGeometry.circleRadius * 2, height: WindowRingGeometry.circleRadius * 2)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
                .position(ringCenter)

            Circle()
                .strokeBorder(.white.opacity(0.045), lineWidth: 1)
                .frame(width: WindowRingGeometry.appRadius * 2, height: WindowRingGeometry.appRadius * 2)
                .position(ringCenter)

            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.1, green: 0.19, blue: 0.48).opacity(0.38),
                                             Color(red: 0.06, green: 0.13, blue: 0.38).opacity(0.54)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: WindowRingGeometry.centerRadius * 2, height: WindowRingGeometry.centerRadius * 2)
                .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .position(ringCenter)

            ForEach(Array(manager.applications.enumerated()), id: \.element.id) { index, app in
                appIcon(app)
                    .position(position(for: index, count: manager.applications.count))
            }

            centerContent
                .frame(width: 216, height: 220)
                .position(ringCenter)

            windowCards
        }
        .opacity(manager.isRingPresented ? 1 : 0)
        .overlay(alignment: .topTrailing) {
            Button(action: manager.dismissRing) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(RingControlStyle())
            .accessibilityLabel("关闭窗口环")
            .help("关闭 · Esc")
            .padding(18)
        }
        .frame(width: WindowRingGeometry.panelSize.width,
               height: WindowRingGeometry.panelSize.height)
        .scaleEffect(displayScale)
        .frame(width: WindowRingGeometry.panelSize.width * displayScale,
               height: WindowRingGeometry.panelSize.height * displayScale)
        .background(Color.clear)
    }

    private func appIcon(_ app: WindowApplication) -> some View {
        let isSelected = app.id == manager.selectedApplication?.id
        return Button {
            selectApplication(app.id)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .padding(7)
                    .background(.white.opacity(isSelected ? 0.12 : 0),
                                in: RoundedRectangle(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(.white.opacity(isSelected ? 0.44 : 0), lineWidth: 1.25)
                    }
                if app.windows.count > 1 {
                    Text("\(app.windows.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 19, minHeight: 19)
                        .background(Color(red: 0.94, green: 0.28, blue: 0.33), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                        .offset(x: 3, y: -3)
                }
            }
            .shadow(color: .black.opacity(isSelected ? 0.22 : 0.10), radius: isSelected ? 10 : 4, y: 3)
            .scaleEffect(isSelected ? 1.14 : 1)
            .frame(width: 86, height: 86)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { selectApplication(app.id) }
        }
        .accessibilityLabel("\(app.name)，\(app.windows.count) 个窗口")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(app.name)
    }

    private var centerContent: some View {
        VStack(spacing: 10) {
            if let app = manager.selectedApplication {
                Text(app.name)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 180)
                    .id(app.id)
                    .transition(.opacity)
                Text(manager.selectedWindow?.title ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .frame(width: 176, height: 32)

                HStack(spacing: 10) {
                    windowNavigationButton(offset: -1, symbol: "chevron.left")
                    Text("\(manager.selectedIndex + 1) / \(app.windows.count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(.white.opacity(0.09), in: Capsule())
                    windowNavigationButton(offset: 1, symbol: "chevron.right")
                }

                HStack(spacing: 12) {
                    Text("← → 应用")
                    Text("↑ ↓ 窗口")
                    Text("↵ 打开")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            } else {
                Text("暂无打开的窗口")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.vertical, 12)
    }

    private func windowNavigationButton(offset: Int, symbol: String) -> some View {
        Button { manager.moveWindow(offset) } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.06), in: Circle())
        }
        .buttonStyle(RingControlStyle())
        .disabled((manager.selectedApplication?.windows.count ?? 0) < 2)
        .accessibilityLabel(offset < 0 ? "上一个窗口" : "下一个窗口")
        .help(offset < 0 ? "上一个窗口 · ↑" : "下一个窗口 · ↓")
    }

    private var windowCards: some View {
        Group {
            if let app = manager.selectedApplication,
               let appIndex = manager.applications.firstIndex(where: { $0.id == app.id }) {
                let baseAngle = windowBaseAngle ?? appAngle(index: appIndex, count: manager.applications.count)
                let visibleRange = WindowRingGeometry.visibleWindowRange(count: app.windows.count,
                                                                         selectedIndex: manager.selectedIndex)
                ZStack {
                    // 所有扇片共用一个模糊层，窗口数增加时不增加玻璃材质层数。
                    AdaptiveWindowSurface(
                        shape: WindowFanBackdrop(baseAngle: baseAngle,
                                                 step: WindowRingGeometry.sectorStep(count: visibleRange.count),
                                                 count: visibleRange.count),
                        tint: Color(red: 0.2, green: 0.32, blue: 0.6).opacity(0.3),
                        opaqueColor: Color(red: 0.18, green: 0.28, blue: 0.5)
                    )
                    // 用扇片位置保持身份，切换 App 时圆弧可以从旧角度连续移动到新角度。
                    ForEach(Array(visibleRange.enumerated()), id: \.offset) { slot, index in
                        let window = app.windows[index]
                        let angle = WindowRingGeometry.windowAngle(baseAngle: baseAngle,
                                                                 index: slot, count: visibleRange.count)
                        let sector = WindowRingGeometry.sector(baseAngle: baseAngle,
                                                              index: slot, count: visibleRange.count)
                        let isSelected = index == manager.selectedIndex
                        Button {
                            manager.selectWindow(index)
                            manager.activateSelectedWindow()
                        } label: {
                            ZStack {
                                sector
                                    .fill(LinearGradient(
                                        colors: [Color(red: 0.34, green: 0.47, blue: 0.77)
                                                    .opacity(isSelected ? 0.5 : 0.15),
                                                 Color(red: 0.14, green: 0.26, blue: 0.52)
                                                    .opacity(isSelected ? 0.6 : 0.25)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ))
                                    .overlay {
                                        sector.stroke(.white.opacity(isSelected ? 0.5 : 0.18),
                                                      lineWidth: isSelected ? 1.5 : 1)
                                    }
                                VStack(spacing: 6) {
                                    HStack(spacing: 5) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "macwindow")
                                            .font(.system(size: 10, weight: .medium))
                                        Text(String(format: "%02d", index + 1))
                                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                                            .monospacedDigit()
                                    }
                                    .foregroundStyle(.white.opacity(isSelected ? 0.92 : 0.48))
                                    Text(window.title)
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                        .lineLimit(3)
                                        .truncationMode(.middle)
                                        .multilineTextAlignment(.center)
                                        .foregroundStyle(.white.opacity(isSelected ? 0.98 : 0.78))
                                }
                                .id(window.id)
                                .transition(.opacity)
                                .modifier(WindowRingLabelPosition(angle: angle, count: visibleRange.count))
                            }
                            .frame(width: WindowRingGeometry.panelSize.width,
                                   height: WindowRingGeometry.panelSize.height)
                            // 透明矩形不拦截其他 App；整个扇区（包括文字周围）都支持 hover 和点击。
                            .contentShape(sector)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovering in
                            if isHovering {
                                withAnimation(.easeOut(duration: 0.14)) { manager.selectWindow(index) }
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97)))
                        .accessibilityLabel("窗口 \(index + 1)：\(window.title)")
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        .help(window.title)
                    }
                }
            }
        }
    }

    private func selectApplication(_ id: String) {
        let apps = manager.applications
        guard manager.selectedApplication?.id != id, let index = apps.firstIndex(where: { $0.id == id }) else { return }
        let target = appAngle(index: index, count: apps.count)
        let currentIndex = apps.firstIndex(where: { $0.id == manager.selectedApplication?.id }) ?? index
        let current = windowBaseAngle ?? appAngle(index: currentIndex, count: apps.count)
        var transaction = Transaction(animation: reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 1))
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) {
            // 顶部两侧的图标之间走最短圆弧，避免跨越 0/2π 时扇片绕一整圈。
            windowBaseAngle = current + atan2(sin(target - current), cos(target - current))
            manager.selectApplication(id)
        }
    }

    private func position(for index: Int, count: Int) -> CGPoint {
        pointOnRing(radius: WindowRingGeometry.appRadius, angle: appAngle(index: index, count: count))
    }

    private func appAngle(index: Int, count: Int) -> CGFloat {
        (2 * CGFloat.pi * CGFloat(index) / CGFloat(max(count, 1))) - (.pi / 2)
    }

    private func pointOnRing(radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: ringCenter.x + cos(angle) * radius,
                y: ringCenter.y + sin(angle) * radius)
    }
}

private struct RingControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(!isEnabled ? 0.3 : configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
    }
}

// 文字沿与扇片相同的圆弧移动；直接插值 CGPoint 会走弦线，短暂漂进圆环内部。
private struct WindowRingLabelPosition: AnimatableModifier {
    var angle: CGFloat
    let count: Int

    var animatableData: CGFloat {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: WindowRingGeometry.labelWidth(angle: angle, count: count), height: 68)
            .position(x: WindowRingGeometry.center.x + cos(angle) * WindowRingGeometry.labelRadius,
                      y: WindowRingGeometry.center.y + sin(angle) * WindowRingGeometry.labelRadius)
    }
}

// 视图、透明浮层尺寸和外部点击命中共用几何，避免扇片被裁切或点击扇片误关闭。
nonisolated enum WindowRingGeometry {
    static let panelSize = CGSize(width: 1000, height: 920)
    static let center = CGPoint(x: panelSize.width / 2, y: panelSize.height / 2)
    static let appRadius: CGFloat = 194
    static let circleRadius: CGFloat = 285
    static let centerRadius: CGFloat = 122
    static let innerRadius: CGFloat = 300
    static let outerRadius: CGFloat = 440
    static let labelRadius: CGFloat = 370
    static let maximumVisibleWindows = 5

    static func visibleWindowRange(count: Int, selectedIndex: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let selected = min(max(selectedIndex, 0), count - 1)
        let start = selected / maximumVisibleWindows * maximumVisibleWindows
        return start..<min(start + maximumVisibleWindows, count)
    }

    static func sectorStep(count: Int) -> CGFloat {
        min(0.62, 2.4 / CGFloat(max(count, 1)))
    }

    static func windowAngle(baseAngle: CGFloat, index: Int, count: Int) -> CGFloat {
        // 扇片围绕 App 的方向对称展开；同一页内的 hover 不重排位置。
        baseAngle + (CGFloat(index) - CGFloat(max(count - 1, 0)) / 2) * sectorStep(count: count)
    }

    static func labelWidth(angle: CGFloat, count: Int) -> CGFloat {
        // 水平文字框同时满足径向厚度和扇区角度；侧面、斜角的文字不会溢出扇片。
        let horizontal = abs(cos(angle))
        let vertical = abs(sin(angle))
        let halfHeight: CGFloat = 34
        let radialBudget = min(labelRadius - innerRadius, outerRadius - labelRadius) - 8
        let tangentialBudget = innerRadius * tan(sectorStep(count: count) * 0.47 - 0.02)
        let radialWidth = horizontal > 0.001 ? 2 * (radialBudget - vertical * halfHeight) / horizontal : 164
        let tangentialWidth = vertical > 0.001 ? 2 * (tangentialBudget - horizontal * halfHeight) / vertical : 164
        return min(164, min(radialWidth, tangentialWidth))
    }

    static func sector(baseAngle: CGFloat, index: Int, count: Int) -> FanWindowSector {
        let angle = windowAngle(baseAngle: baseAngle, index: index, count: count)
        let halfAngle = sectorStep(count: count) * 0.47
        return FanWindowSector(center: center, innerRadius: innerRadius, outerRadius: outerRadius,
                               startAngle: angle - halfAngle, endAngle: angle + halfAngle)
    }
}

nonisolated struct FanWindowSector: Shape {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let startAngle: CGFloat
    let endAngle: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(startAngle, endAngle) }
        set { self = FanWindowSector(center: center, innerRadius: innerRadius, outerRadius: outerRadius,
                                     startAngle: newValue.first, endAngle: newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corner = min(12, innerRadius * (endAngle - startAngle) / 4)
        let innerInset = corner / innerRadius
        let outerInset = corner / outerRadius
        let point: (CGFloat, CGFloat) -> CGPoint = { radius, angle in
            CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }

        // 内外边缘是共圆心的真圆弧；用二次曲线收圆四个角，匹配参考图的环形扇片。
        path.move(to: point(innerRadius + corner, startAngle))
        path.addLine(to: point(outerRadius - corner, startAngle))
        path.addQuadCurve(to: point(outerRadius, startAngle + outerInset),
                          control: point(outerRadius, startAngle))
        path.addArc(center: center, radius: outerRadius,
                    startAngle: .radians(Double(startAngle + outerInset)),
                    endAngle: .radians(Double(endAngle - outerInset)), clockwise: false)
        path.addQuadCurve(to: point(outerRadius - corner, endAngle),
                          control: point(outerRadius, endAngle))
        path.addLine(to: point(innerRadius + corner, endAngle))
        path.addQuadCurve(to: point(innerRadius, endAngle - innerInset),
                          control: point(innerRadius, endAngle))
        path.addArc(center: center, radius: innerRadius,
                    startAngle: .radians(Double(endAngle - innerInset)),
                    endAngle: .radians(Double(startAngle + innerInset)), clockwise: true)
        path.addQuadCurve(to: point(innerRadius + corner, startAngle),
                          control: point(innerRadius, startAngle))
        path.closeSubpath()
        return path
    }
}

private nonisolated struct WindowFanBackdrop: Shape {
    var baseAngle: CGFloat
    var step: CGFloat
    let count: Int

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(baseAngle, step) }
        set { baseAngle = newValue.first; step = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<count {
            let angle = baseAngle + (CGFloat(index) - CGFloat(max(count - 1, 0)) / 2) * step
            path.addPath(FanWindowSector(center: WindowRingGeometry.center,
                                         innerRadius: WindowRingGeometry.innerRadius,
                                         outerRadius: WindowRingGeometry.outerRadius,
                                         startAngle: angle - step * 0.47,
                                         endAngle: angle + step * 0.47).path(in: rect))
        }
        return path
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
                    Text("↑↓ 选择")
                    Text("↵ 打开")
                    Spacer(minLength: 0)
                    Text("Esc 退出")
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
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
}

final class RingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
