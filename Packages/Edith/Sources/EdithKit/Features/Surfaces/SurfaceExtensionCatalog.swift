import Foundation

extension SurfaceWidget {
    public var usesExtensionCard: Bool {
        switch self {
        case .ability, .machines, .desk, .media, .github, .databases: true
        default: false
        }
    }
    public var supportsSourceFilters: Bool {
        switch self {
        case .github, .ability("quinjet"), .databases, .machines, .desk, .media,
            .ability("downloads"),
            .ability("clipboard"),
            .ability("attention"), .ability("appMaintenance"), .ability("homebrew"),
            .ability("seoAudit"), .ability("latex"):
            true
        default: false
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
        default: []
        }
    }
    public var sourceChoices: [SurfaceSourceChoice] {
        switch self {
        case .media, .ability("downloads"):
            DownloadKind.allCases.map { .init($0.rawValue, $0.title) }
        case .desk, .ability("clipboard"):
            ClipboardEntry.Kind.allCases.map { .init($0.rawValue, $0.rawValue.capitalized) }
        case .ability("attention"):
            AttentionEventSource.allCases.map { .init($0.rawValue, $0.rawValue.capitalized) }
        case .ability("appMaintenance"):
            AppUpdateSource.allCases.map { .init($0.rawValue, $0.title) }
        case .ability("homebrew"):
            HomebrewPackageKind.allCases.map { .init($0.rawValue, $0.pluralTitle) }
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
            case .desk, .ability("clipboard"), .ability("colorPicker"):
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
