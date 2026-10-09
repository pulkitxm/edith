import Foundation

extension SurfaceWidget {
    public var usesExtensionCard: Bool {
        switch self {
        case .ability, .machines, .desk, .media, .github, .databases, .limits, .codeStats: true
        default: false
        }
    }
    public var supportsSourceFilters: Bool {
        switch self {
        case .calendar, .github, .ability("quinjet"), .databases, .machines, .desk, .media, .limits,
            .codeStats,
            .ability("downloads"),
            .ability("clipboard"),
            .ability("attention"), .ability("appMaintenance"), .ability("homebrew"),
            .ability("seoAudit"), .ability("latex"), .ability("audioMixer"), .ability("timeLapse"),
            .ability("companion"):
            true
        default: false
        }
    }
    public var sourceTitle: String {
        switch self {
        case .github, .ability("quinjet"), .codeStats: "Repositories"
        case .databases: "Connections"
        case .ability("audioMixer"): "Audio apps"
        case .ability("companion"): "Item kinds"
        case .limits, .agents: "Providers"
        case .clocks: "Cities"
        case .calendar: "Calendars"
        default: "Sources"
        }
    }
    public var contentChoices: [SurfaceSourceChoice] {
        switch self {
        case .github, .ability("quinjet"):
            [
                .init("authored", "My pull requests"), .init("review", "Review requests"),
                .init("assigned", "Assigned to me"),
            ]
        case .databases:
            [
                .init("connections", "Connections"), .init("queries", "Saved queries"),
                .init("operations", "Recent operations"),
            ]
        case .ability("companion"):
            [
                .init("health", "Service health"), .init("totals", "Library totals"),
                .init("recent", "Recent items"),
            ]
        case .ability("timeLapse"):
            [.init("active", "Live recorder"), .init("recordings", "Saved recordings")]
        default: []
        }
    }
    public var extensionFields: [(String, String)] {
        let metrics: [(String, String)] =
            switch self {
            case .github, .ability("quinjet"):
                [
                    ("pulls", "Pull request count"), ("review", "Review requests"),
                    ("failed", "Failing checks"), ("approved", "Approved pull requests"),
                ]
            case .databases:
                [
                    ("connections", "Connection count"), ("queries", "Saved query count"),
                    ("running", "Running operations"), ("failed", "Failed operations"),
                ]
            case .media, .ability("downloads"):
                [
                    ("running", "Downloading count"), ("queued", "Queued count"),
                    ("failed", "Retry count"), ("finished", "Completed count"),
                ]
            case .ability("audioMixer"):
                [
                    ("apps", "Playing app count"), ("muted", "Muted app count"),
                    ("volume", "Volume sliders"),
                ]
            case .ability("timeLapse"):
                [
                    ("state", "Recorder state"), ("elapsed", "Elapsed time"),
                    ("frames", "Captured frames"), ("size", "Captured size"),
                    ("recordings", "Saved recording count"),
                ]
            case .desk, .ability("clipboard"):
                [
                    ("total", "Recent item count"), ("pinned", "Pinned count"),
                    ("previews", "Image previews"),
                ]
            case .ability("colorPicker"):
                [("total", "Recent item count"), ("pinned", "Pinned count")]
            case .machines:
                [
                    ("online", "Reachable count"), ("offline", "Unreachable count"),
                    ("total", "Registered count"),
                ]
            case .ability("systemStats"):
                [("cpu", "CPU usage"), ("memory", "Memory usage"), ("disk", "Free storage")]
            case .ability("attention"):
                [
                    ("active", "Active time"), ("focus", "Focused time"),
                    ("switches", "App switch count"), ("agents", "Agent working time"),
                ]
            case .ability("appMaintenance"):
                [("updates", "Update count"), ("installed", "Installed app count")]
            case .ability("homebrew"):
                [("packages", "Installed package count"), ("updates", "Outdated package count")]
            case .ability("cleaner"), .ability("blitztree"):
                [("space", "Reclaimable space"), ("categories", "Category count")]
            case .ability("seoAudit"):
                [
                    ("projects", "Project count"), ("pages", "Audited page count"),
                    ("issues", "Issue count"),
                ]
            case .ability("latex"):
                [("projects", "Document count"), ("reviews", "Pull request count")]
            case .ability("bifrost"), .ability("system"):
                [("apps", "App count")]
            case .ability("companion"):
                [
                    ("episodes", "Indexed item count"), ("sources", "Source count"),
                    ("claims", "Claim count"), ("observations", "Observation count"),
                    ("pending", "Pending indexing count"),
                ]
            case .ability("plugins"):
                [("agents", "Detected agent count"), ("skills", "Available skill count")]
            case .ability("studio"), .ability("notchShelf"):
                [("files", "File count")]
            case .ability("virtualCamera"):
                [("scenes", "Scene count")]
            default: []
            }
        return metrics + [
            ("items", "Item list"), ("metadata", "Item details"), ("status", "Status"),
            ("progress", "Progress bars"), ("updated", "Last update"),
        ]
    }
}
