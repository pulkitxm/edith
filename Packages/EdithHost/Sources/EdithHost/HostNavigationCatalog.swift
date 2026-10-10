import EdithExtensionSupport
import Foundation

struct HostNavigationSection: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let extensionID: String?
}

struct HostNavigationPage: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    var suite: String? = nil
    var parentID: String? = nil
    var extensionID: String? = nil
    var sections: [HostNavigationSection] = []
    var landing = false
    var detachable = true
}

enum HostNavigationCatalog {
    static let settings: [HostNavigationSection] = [
        .init(id: "general", title: "General", symbol: "gearshape", extensionID: nil),
        .init(id: "surfaces", title: "Home & Notch", symbol: "rectangle.3.group", extensionID: nil),
        .init(
            id: "agentActivity", title: "Agent connections", symbol: "terminal",
            extensionID: "herdr"),
        .init(id: "permissions", title: "Permissions", symbol: "hand.raised", extensionID: nil),
        .init(
            id: "agent", title: "Background agent", symbol: "bolt.horizontal.circle",
            extensionID: nil),
        .init(id: "jev", title: "Jev", symbol: "brain", extensionID: "jev"),
        .init(
            id: "data", title: "Data & backup", symbol: "externaldrive.badge.icloud",
            extensionID: nil),
        .init(id: "shortcuts", title: "Shortcuts", symbol: "keyboard", extensionID: nil),
        .init(id: "terminal", title: "Terminal", symbol: "apple.terminal", extensionID: "terminal"),
        .init(id: "icloud", title: "iCloud", symbol: "icloud", extensionID: nil),
        .init(
            id: "updates", title: "Updates", symbol: "arrow.triangle.2.circlepath", extensionID: nil
        ),
    ]
    static let maintenance: [HostNavigationSection] = [
        .init(
            id: "Updates", title: "Updates", symbol: "arrow.up.circle",
            extensionID: "appMaintenance"),
        .init(id: "Packages", title: "Packages", symbol: "shippingbox", extensionID: "homebrew"),
        .init(id: "Remove", title: "Remove", symbol: "trash", extensionID: "appMaintenance"),
        .init(
            id: "Cleaner", title: "Cleaner", symbol: "sparkles.rectangle.stack",
            extensionID: "cleaner"),
        .init(
            id: "History", title: "History", symbol: "clock.arrow.circlepath",
            extensionID: "appMaintenance"),
    ]
    static let pages: [HostNavigationPage] = [
        .init(id: "home", title: "Home", symbol: "house.fill"),
        .init(id: "machines", title: "Fleet", symbol: "server.rack", extensionID: "machines"),
        .init(id: "docs", title: "Docs", symbol: "book.closed", extensionID: "docs"),
        .init(id: "agents", title: "Agents", symbol: "sparkles", suite: "agents", landing: true),
        .init(
            id: "dashboard", title: "Usage", symbol: "chart.bar.fill", suite: "agents",
            parentID: "agents", extensionID: "usage"),
        .init(
            id: "herdr", title: "Sessions", symbol: "rectangle.split.3x1.fill", suite: "agents",
            parentID: "agents", extensionID: "herdr"),
        .init(
            id: "quinjet", title: "Review", symbol: "arrow.triangle.branch", suite: "agents",
            parentID: "agents", extensionID: "quinjet"),
        .init(
            id: "companion", title: "Memory", symbol: "brain.head.profile", suite: "agents",
            parentID: "agents", extensionID: "companion"),
        .init(
            id: "plugins", title: "Plugins", symbol: "square.stack.3d.up", suite: "agents",
            parentID: "agents", extensionID: "plugins"),
        .init(
            id: "appMaintenance", title: "Maintenance", symbol: "shippingbox.and.arrow.backward",
            suite: "maintenance", sections: maintenance, landing: true),
        .init(
            id: "blitztree", title: "BlitzTree", symbol: "square.grid.3x3.fill",
            suite: "maintenance", parentID: "appMaintenance", extensionID: "blitztree"),
        .init(id: "system", title: "System", symbol: "switch.2", suite: "system", landing: true),
        .init(
            id: "runningApps", title: "Running apps", symbol: "cpu", suite: "system",
            parentID: "system", extensionID: "system"),
        .init(id: "desk", title: "Desk", symbol: "hand.tap", suite: "desk", landing: true),
        .init(
            id: "media", title: "Media", symbol: "play.rectangle.on.rectangle", suite: "media",
            landing: true),
        .init(
            id: "studio", title: "Studio", symbol: "wand.and.stars", suite: "media",
            parentID: "media", extensionID: "studio"),
        .init(
            id: "latex", title: "LaTeX", symbol: "doc.richtext", suite: "media", parentID: "media",
            extensionID: "latex"),
        .init(
            id: "timeLapse", title: "Screen Recorder", symbol: "record.circle", suite: "media",
            parentID: "media", extensionID: "timeLapse"),
        .init(
            id: "downloads", title: "Downloads", symbol: "arrow.down.circle", suite: "media",
            parentID: "media", extensionID: "downloads"),
        .init(
            id: "music", title: "Music", symbol: "music.note", suite: "media", parentID: "media",
            extensionID: "music"),
        .init(
            id: "calendar", title: "Calendar", symbol: "calendar", suite: "media",
            parentID: "media", extensionID: "calendar"),
        .init(
            id: "virtualCamera", title: "Virtual Camera", symbol: "web.camera", suite: "media",
            parentID: "media", extensionID: "virtualCamera"),
        .init(
            id: "data", title: "Data", symbol: "cylinder.split.1x2", suite: "data", landing: true),
        .init(
            id: "database", title: "Database", symbol: "cylinder.fill", suite: "data",
            parentID: "data", extensionID: "database"),
        .init(
            id: "attention", title: "Attention", symbol: "hourglass", suite: "data",
            parentID: "data", extensionID: "attention"),
        .init(
            id: "seoAudit", title: "Site Audit", symbol: "doc.text.magnifyingglass", suite: "data",
            parentID: "data", extensionID: "seoAudit"),
        .init(
            id: "codeStats", title: "Code Stats", symbol: "chart.line.uptrend.xyaxis",
            suite: "data", parentID: "data", extensionID: "codeStats"),
        .init(id: "extensions", title: "Extensions", symbol: "puzzlepiece.extension"),
        .init(
            id: "settings", title: "Settings", symbol: "gearshape", sections: settings,
            detachable: false),
        .init(id: "about", title: "About", symbol: "info.circle", detachable: false),
    ]
    static let suiteProviders: [String: Set<String>] = [
        "agents": ["usage", "herdr", "quinjet", "companion", "plugins", "jev"],
        "maintenance": ["appMaintenance", "homebrew", "cleaner", "blitztree"],
        "system": [
            "system", "keepAwake", "lidAwake", "keyboardClean", "systemStats", "micMute", "bifrost",
        ],
        "desk": [
            "launcher", "clipboard", "colorPicker", "emoji", "keystrokeHighlight", "focusDim",
            "presenter", "windowSweaters",
        ],
        "media": [
            "studio", "latex", "timeLapse", "downloads", "music", "calendar", "virtualCamera",
            "audioMixer", "notchShelf",
        ],
        "data": ["database", "attention", "seoAudit", "codeStats"],
    ]
    static func page(_ id: String) -> HostNavigationPage { pages.first { $0.id == id } ?? pages[0] }
    static func visible(_ page: HostNavigationPage, active: Set<String>, defaults: UserDefaults)
        -> Bool
    {
        guard let suite = page.suite else { return true }
        let enabled =
            defaults.object(forKey: "suite" + suite.capitalized + "Enabled") as? Bool
            ?? !active.isDisjoint(with: suiteProviders[suite] ?? [])
        guard enabled else { return false }
        if let provider = page.extensionID { return active.contains(provider) }
        return true
    }
    static func expansionKey(_ page: HostNavigationPage) -> String? {
        if page.id == "settings" { return AppStorageKeys.General.settingsCategoriesExpanded }
        if page.landing, let suite = page.suite {
            return "sidebar" + suite.capitalized + "Expanded"
        }
        return nil
    }
    static func expanded(_ page: HostNavigationPage, defaults: UserDefaults) -> Bool {
        guard let key = expansionKey(page) else { return false }
        return defaults.object(forKey: key) as? Bool ?? true
    }
    static func resolve(_ id: String, active: Set<String>, defaults: UserDefaults) -> String {
        guard pages.contains(where: { $0.id == id }),
            visible(page(id), active: active, defaults: defaults)
        else { return "home" }
        return id
    }
}
