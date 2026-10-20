import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

nonisolated struct ThumbnailBitmap: @unchecked Sendable {
    let image: CGImage
    let isCached: Bool
}

nonisolated enum ThumbnailResult: Sendable {
    case image(ThumbnailBitmap)
    case permission, minimized, unavailable
}

private nonisolated final class ThumbnailCacheEntry {
    let image: CGImage
    let created = ProcessInfo.processInfo.systemUptime
    let requestedWidth: Int
    init(_ image: CGImage, requestedWidth: Int) {
        self.image = image
        self.requestedWidth = requestedWidth
    }
}

// 不创建 SCStream。一次只允许一个系统截图请求；缓存有成本上限，内存压力时可回收。
actor WindowThumbnailReader {
    static let shared = WindowThumbnailReader()
    private let cache = NSCache<NSString, ThumbnailCacheEntry>()
    private var content: SCShareableContent?
    private var contentTime: TimeInterval = 0
    private var busy = false
    private var generation: UInt = 0

    init() {
        cache.totalCostLimit = 8 * 1_024 * 1_024
        cache.countLimit = 12
    }

    func clear() {
        generation &+= 1
        cache.removeAllObjects()
        content = nil
        contentTime = 0
    }

    func remove(_ id: String) { cache.removeObject(forKey: id as NSString) }

    func image(id: String, pid: pid_t, title: String?, record: AccessibilityWindow,
               pixelWidth: Int) async -> ThumbnailResult {
        guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return .permission }
        let now = ProcessInfo.processInfo.systemUptime
        let cached = cache.object(forKey: id as NSString)
        if record.isMinimized {
            if let cached, now - cached.created < 60 {
                return .image(ThumbnailBitmap(image: cached.image, isCached: true))
            }
            return .minimized
        }
        if let cached, now - cached.created < 3, cached.requestedWidth >= pixelWidth {
            return .image(ThumbnailBitmap(image: cached.image, isCached: true))
        }
        guard !busy else { return .unavailable }
        busy = true
        let requestGeneration = generation
        defer { busy = false }
        do {
            let frame = await WindowAccessibilityReader.shared.frame(of: record)
            guard !Task.isCancelled, requestGeneration == generation else { return .unavailable }
            if content == nil || now - contentTime > 1 {
                let updated = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard !Task.isCancelled, requestGeneration == generation else { return .unavailable }
                content = updated
                contentTime = ProcessInfo.processInfo.systemUptime
            }
            guard !Task.isCancelled, requestGeneration == generation else { return .unavailable }
            let candidates = content?.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0
            } ?? []
            // 只用公开 API。尺寸/位置或唯一标题不能可靠对应时，不显示另一扇窗口的画面。
            let sameFrame = candidates.filter { candidate in
                guard let frame else { return false }
                return abs(candidate.frame.minX - frame.minX) < 3 && abs(candidate.frame.minY - frame.minY) < 3
                    && abs(candidate.frame.width - frame.width) < 3 && abs(candidate.frame.height - frame.height) < 3
            }
            let sameTitle = candidates.filter { title != nil && $0.title == title }
            let target: SCWindow?
            if sameFrame.count == 1 { target = sameFrame.first }
            else {
                let exact = sameFrame.filter { title != nil && $0.title == title }
                target = exact.count == 1 ? exact.first : (sameTitle.count == 1 ? sameTitle.first : nil)
            }
            guard let target, target.frame.width > 0, target.frame.height > 0 else { return .unavailable }
            let configuration = SCStreamConfiguration()
            let scale = min(CGFloat(pixelWidth) / target.frame.width, 420 / target.frame.height, 1)
            configuration.width = max(1, Int(target.frame.width * scale))
            configuration.height = max(1, Int(target.frame.height * scale))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.scalesToFit = true
            configuration.captureResolution = .nominal
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard !Task.isCancelled, generation == requestGeneration else { return .unavailable }
            cache.setObject(ThumbnailCacheEntry(image, requestedWidth: pixelWidth), forKey: id as NSString,
                            cost: image.bytesPerRow * image.height)
            return .image(ThumbnailBitmap(image: image, isCached: false))
        } catch {
            return CGPreflightScreenCaptureAccess() ? .unavailable : .permission
        }
    }
}

@MainActor
final class WindowThumbnailPresenter: ObservableObject {
    @Published private(set) var window: ManagedWindow?
    @Published private(set) var image: NSImage?
    @Published private(set) var message = ""
    @Published private(set) var isCached = false
    @Published private(set) var needsPermission = false
    private var panel: DockPreviewPanel?
    private var request: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var requestedID: String?
    private var anchor: CGRect?
    private var obstacles: [CGRect] = []
    private var level: NSWindow.Level = .floating

    func updateAnchor(_ frame: CGRect, avoiding obstacles: [CGRect], level: NSWindow.Level = .floating) {
        anchor = frame
        self.obstacles = obstacles
        self.level = level
        panel?.level = level
        if panel?.isVisible == true { position() }
    }

    func hover(_ window: ManagedWindow, preferences: PreviewPreferences) {
        dismissal?.cancel()
        cleanup?.cancel()
        guard preferences.thumbnailsEnabled else { hide(); return }
        guard requestedID != window.id else { return }
        request?.cancel()
        panel?.orderOut(nil)
        requestedID = window.id
        request = Task { [weak self] in
            try? await Task.sleep(for: .seconds(preferences.thumbnailDelay))
            guard !Task.isCancelled, let self, self.requestedID == window.id else { return }
            self.window = window
            self.image = nil
            self.message = "正在获取预览…"
            self.isCached = false
            self.needsPermission = false
            guard self.show() else { return }
            let record = AccessibilityWindow(title: window.title, element: window.element,
                                             isMinimized: window.isMinimized, isFocused: window.isFocused)
            let result = await WindowThumbnailReader.shared.image(
                id: window.id, pid: window.application.processIdentifier,
                title: window.unnamedWindowNumber == nil ? window.title : nil, record: record,
                pixelWidth: Int(preferences.thumbnailSize.width * 2))
            guard !Task.isCancelled, self.requestedID == window.id else { return }
            switch result {
            case .image(let bitmap):
                self.image = NSImage(cgImage: bitmap.image, size: .zero)
                self.isCached = bitmap.isCached
                self.message = window.isMinimized ? "已最小化 · 上次预览" : bitmap.isCached ? "最近预览" : "窗口预览"
            case .permission:
                self.message = "允许屏幕录制后，可查看窗口画面"
                self.needsPermission = true
            case .minimized: self.message = "已最小化，恢复后可获取预览"
            case .unavailable: self.message = "此窗口暂时无法预览"
            }
        }
    }

    func leaveRow(_ id: String? = nil) {
        guard requestedID != nil, id == nil || id == requestedID else { return }
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self else { return }
            if self.contains(NSEvent.mouseLocation) { return }
            self.hide()
        }
    }

    func contains(_ point: CGPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -10, dy: -10).contains(point)
    }

    func hide() {
        guard requestedID != nil || window != nil || panel?.isVisible == true else { return }
        request?.cancel()
        request = nil
        dismissal?.cancel()
        dismissal = nil
        requestedID = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        window = nil
        image = nil
        cleanup?.cancel()
        cleanup = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await WindowThumbnailReader.shared.clear()
        }
    }

    func releaseCache() {
        hide()
        cleanup?.cancel()
        Task { await WindowThumbnailReader.shared.clear() }
    }

    private func show() -> Bool {
        if panel == nil {
            let panel = DockPreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.level = level
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        if panel?.contentView == nil {
            let view = NSHostingView(rootView: WindowThumbnailView(presenter: self))
            view.sizingOptions = []
            panel?.contentView = view
        }
        guard position() else { return false }
        panel?.orderFrontRegardless()
        return true
    }

    @discardableResult private func position() -> Bool {
        guard let anchor, let panel,
              let visible = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame else { return false }
        let width = min(PreviewPreferences.shared.thumbnailSize.width, visible.width - 24)
        let size = CGSize(width: width, height: width * 0.625 + 76)
        let y = min(max(anchor.maxY - size.height, visible.minY), visible.maxY - size.height)
        let candidates = [CGRect(x: anchor.maxX + 10, y: y, width: size.width, height: size.height),
                          CGRect(x: anchor.minX - size.width - 10, y: y, width: size.width, height: size.height),
                          CGRect(x: min(max(anchor.minX, visible.minX), visible.maxX - size.width),
                                 y: anchor.maxY + 10, width: size.width, height: size.height)]
        guard let frame = candidates.first(where: { candidate in
            visible.contains(candidate) && !obstacles.contains { $0.insetBy(dx: -6, dy: -6).intersects(candidate) }
        }) else {
            panel.orderOut(nil)
            return false
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        return true
    }
}

private struct WindowThumbnailView: View {
    @ObservedObject var presenter: WindowThumbnailPresenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.primary.opacity(0.04)
                if let image = presenter.image {
                    Image(nsImage: image).resizable().interpolation(.medium).scaledToFit()
                        .padding(8).transition(.opacity)
                } else if let window = presenter.window {
                    VStack(spacing: 8) {
                        Image(nsImage: window.applicationIcon).resizable().frame(width: 44, height: 44)
                        Image(systemName: presenter.needsPermission ? "lock.shield" : window.isMinimized ? "minus.rectangle" : "macwindow")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 5) {
                Text(presenter.window?.title ?? "").font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(presenter.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.horizontal, 14).frame(height: 68, alignment: .leading)
        }
        .padding(4)
        .background { AdaptiveWindowSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: presenter.image != nil)
        .onHover { if !$0 { presenter.leaveRow() } }
        .accessibilityElement(children: .combine)
    }
}
