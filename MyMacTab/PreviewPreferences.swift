import AppKit
import Combine

enum ThumbnailSize: String, CaseIterable, Identifiable {
    case compact, regular, large
    var id: String { rawValue }
    var title: String {
        switch self { case .compact: "小"; case .regular: "中"; case .large: "大" }
    }
    var width: CGFloat {
        switch self { case .compact: 224; case .regular: 280; case .large: 336 }
    }
}

@MainActor
final class PreviewPreferences: ObservableObject {
    static let shared = PreviewPreferences()
    private let defaults: UserDefaults
    @Published var dockPreviewEnabled: Bool { didSet { defaults.set(dockPreviewEnabled, forKey: "preview.enabled") } }
    @Published var thumbnailsEnabled: Bool { didSet { defaults.set(thumbnailsEnabled, forKey: "preview.thumbnails") } }
    @Published var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "preview.delay") } }
    @Published var thumbnailDelay: Double { didSet { defaults.set(thumbnailDelay, forKey: "preview.thumbnailDelay") } }
    @Published var thumbnailSize: ThumbnailSize { didSet { defaults.set(thumbnailSize.rawValue, forKey: "preview.size") } }
    @Published private(set) var excludedApplications: [String: String] {
        didSet { defaults.set(excludedApplications, forKey: "preview.excluded") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dockPreviewEnabled = defaults.object(forKey: "preview.enabled") as? Bool ?? true
        thumbnailsEnabled = defaults.object(forKey: "preview.thumbnails") as? Bool ?? false
        hoverDelay = min(0.8, max(0, defaults.object(forKey: "preview.delay") as? Double ?? 0.15))
        thumbnailDelay = min(1.2, max(0.25, defaults.object(forKey: "preview.thumbnailDelay") as? Double ?? 0.45))
        thumbnailSize = ThumbnailSize(rawValue: defaults.string(forKey: "preview.size") ?? "") ?? .regular
        excludedApplications = defaults.dictionary(forKey: "preview.excluded") as? [String: String] ?? [:]
    }

    func key(for application: NSRunningApplication) -> String {
        application.bundleIdentifier ?? application.bundleURL?.path ?? "process:\(application.processIdentifier)"
    }

    func allows(_ application: NSRunningApplication) -> Bool {
        dockPreviewEnabled && excludedApplications[key(for: application)] == nil
    }

    func setAllowed(_ allowed: Bool, key: String, name: String) {
        if allowed { excludedApplications.removeValue(forKey: key) }
        else { excludedApplications[key] = name }
    }
}
