import AppKit
import SwiftUI

// 系统负责材质外观；辅助显示设置优先于系统版本。
struct AdaptiveWindowSurface<SurfaceShape: Shape>: View {
    let shape: SurfaceShape
    var tint: Color?
    var opaqueColor = Color(nsColor: .windowBackgroundColor)

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                shape.fill(opaqueColor)
                    .overlay {
                        shape.stroke(tint == nil ? Color.primary.opacity(0.4) : Color.white.opacity(0.5),
                                     lineWidth: 1)
                    }
            } else if #available(macOS 26.0, *) {
                // regular 会跟随系统玻璃偏好，避免自行叠加固定白色蒙层。
                shape.fill(.clear)
                    .glassEffect(.regular.tint(tint), in: shape)
            } else {
                shape.fill(.regularMaterial)
                    .overlay { shape.fill(tint ?? .clear) }
                    .overlay { shape.stroke(.primary.opacity(0.12), lineWidth: 1) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
