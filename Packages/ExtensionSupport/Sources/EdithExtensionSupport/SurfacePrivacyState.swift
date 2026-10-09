import Foundation
import Observation

@MainActor @Observable
public final class SurfacePrivacyState {
    public private(set) var values: [String: String] = [:]
    @ObservationIgnored private let channel: ExtensionSharedState
    @ObservationIgnored private nonisolated(unsafe) var observer: NSObjectProtocol?
    @ObservationIgnored private var stopped = false

    public init(channel: ExtensionSharedState) {
        self.channel = channel
        refresh()
        observer = channel.observe { [weak self] owner in
            guard owner == "presenter" || owner == "host" else { return }
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit { channel.stopObserving(observer) }

    public func refresh() {
        guard !stopped else { return }
        values = channel.values(for: "presenter")
    }

    public func shutdown() {
        stopped = true
        channel.stopObserving(observer); observer = nil; values = [:]
    }

    public func hides(_ widget: SurfaceWidget) -> Bool {
        Self.hides(widget, values: values)
    }

    public static func hides(_ widget: SurfaceWidget, values: [String: String]) -> Bool {
        guard values["active"] == "1", widget != .clocks, widget != .actions else { return false }
        let categories: [String]
        switch widget {
        case .music: categories = ["Music"]
        case .calendar: categories = ["Calendar"]
        case .activity, .usage: categories = ["Money", "Usage"]
        case .limits, .codeStats: categories = ["Usage"]
        case .agents: categories = ["Agents"]
        case .focus: categories = ["Attention"]
        case .databases: categories = ["Database"]
        case .machines: categories = ["Fleet"]
        case .github: categories = ["Review"]
        case .media: categories = ["Studio"]
        case .ability(let id):
            categories = [Self.category(id)]
        default: categories = ["Shelf"]
        }
        return categories.contains {
            values["blur" + $0].map { $0 != "0" } ?? ($0 != "Usage")
        }
    }

    private static func category(_ id: String) -> String {
        switch id {
        case "music": "Music"
        case "calendar": "Calendar"
        case "usage", "codeStats": "Usage"
        case "herdr": "Agents"
        case "attention": "Attention"
        case "database": "Database"
        case "machines": "Fleet"
        case "quinjet": "Review"
        case "seoAudit": "SiteAudit"
        case "companion": "Memory"
        case "system", "bifrost": "RunningApps"
        case "virtualCamera": "Camera"
        case "studio", "downloads", "timeLapse", "audioMixer": "Studio"
        default: "Shelf"
        }
    }
}
