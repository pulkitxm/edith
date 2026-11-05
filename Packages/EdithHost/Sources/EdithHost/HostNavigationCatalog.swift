import EdithExtensionCore
import EdithHostCore
import Foundation

struct HostNavigationSection: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let extensionID: String?
    var summary = ""
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
    var logoName: String? = nil
}

enum HostNavigationCatalog {
    static func route(extensionID: String) -> (page: String, section: String?)? {
        if let page = pages.first(where: { $0.extensionID == extensionID }) {
            return (page.id, nil)
        }
        if let section = maintenance.first(where: { $0.extensionID == extensionID }) {
            return ("appMaintenance", section.id)
        }
        return nil
    }
    static let settings: [HostNavigationSection] = [
        .init(
            id: "general", title: "General", symbol: "gearshape", extensionID: nil,
            summary: "Appearance, window, and welcome tour"),
        .init(
            id: "surfaces", title: "Home & Notch", symbol: "rectangle.3.group", extensionID: nil,
            summary: "Arrange widgets and build your own Home and Notch"),
        .init(
            id: "agentActivity", title: "Agent connections", symbol: "terminal",
            extensionID: "herdr",
            summary: "Live provider activity and explicit permission approvals"),
        .init(
            id: "permissions", title: "Permissions", symbol: "hand.raised", extensionID: nil,
            summary: "Privacy access used by enabled extensions"),
        .init(
            id: "agent", title: "Background agent", symbol: "bolt.horizontal.circle",
            extensionID: nil,
            summary: "Keeps your tools up to date while the Edith window is closed"),
        .init(
            id: "jev", title: "Jev", symbol: "brain", extensionID: "jev",
            summary: "Fast typed decisions from TypeSafe's Jev model"),
        .init(
            id: "data", title: "Data & backup", symbol: "externaldrive.badge.icloud",
            extensionID: nil, summary: "Where Edith keeps things, and what leaves this Mac"),
        .init(
            id: "storage", title: "Storage", symbol: "internaldrive", extensionID: nil,
            summary: "Disk space used by Edith and its extensions"),
        .init(
            id: "shortcuts", title: "Shortcuts", symbol: "keyboard", extensionID: nil,
            summary: "Global and application keyboard shortcuts"),
        .init(
            id: "terminal", title: "Terminal", symbol: "apple.terminal", extensionID: nil,
            summary: "Command line and terminal integration"),
        .init(
            id: "icloud", title: "iCloud", symbol: "icloud", extensionID: nil,
            summary: "Backup and synchronization"),
        .init(
            id: "updates", title: "Updates", symbol: "arrow.triangle.2.circlepath",
            extensionID: nil, summary: "Version and automatic update behavior"),
    ]
    static let entries = (try? HostIndex.bundled()) ?? []
    static let maintenance = sections(entries, page: "appMaintenance")
    static let pages = pages(entries)

    static func sections(_ entries: [HostExtension], page: String) -> [HostNavigationSection] {
        entries.flatMap { entry in
            entry.sections.filter { $0.page == page }.map { (entry.id, $0) }
        }
        .sorted { $0.1.order < $1.1.order }
        .map { owner, section in
            HostNavigationSection(
                id: section.id, title: section.title, symbol: section.symbolName,
                extensionID: owner, summary: section.summary)
        }
    }

    static func pages(_ entries: [HostExtension]) -> [HostNavigationPage] {
        func children(_ suite: String, parent: String) -> [HostNavigationPage] {
            entries.filter { $0.category == suite }
                .flatMap { entry in entry.pages.map { (entry.id, $0) } }
                .sorted { $0.1.order < $1.1.order }
                .map { owner, page in
                    HostNavigationPage(
                        id: page.id, title: page.title, symbol: page.symbolName, suite: suite,
                        parentID: parent, extensionID: owner, detachable: page.detachable,
                        logoName: page.logoName)
                }
        }
        return [
            .init(id: "home", title: "Home", symbol: "house.fill"),
            .init(
                id: "agents", title: "Agents & Terminal", symbol: "sparkles", suite: "agents",
                landing: true),
        ] + children("agents", parent: "agents") + [
            .init(
                id: "system", title: "Mac Utilities", symbol: "switch.2", suite: "utilities",
                landing: true)
        ] + children("utilities", parent: "system") + [
            .init(
                id: "appMaintenance", title: "Maintenance",
                symbol: "shippingbox.and.arrow.backward", suite: "utilities",
                sections: sections(entries, page: "appMaintenance"), landing: true),
            .init(id: "desk", title: "Desk", symbol: "hand.tap", suite: "desk", landing: true),
            .init(
                id: "media", title: "Media", symbol: "play.rectangle.on.rectangle",
                suite: "media", landing: true),
        ] + children("media", parent: "media") + [
            .init(
                id: "data", title: "Developer & Data", symbol: "cylinder.split.1x2",
                suite: "developer", landing: true)
        ] + children("developer", parent: "data") + [
            .init(id: "extensions", title: "Extensions", symbol: "puzzlepiece.extension"),
            .init(
                id: "settings", title: "Settings", symbol: "gearshape", sections: settings,
                detachable: false),
            .init(id: "about", title: "About", symbol: "info.circle", detachable: false),
        ]
    }
    static let suiteProviders = HostMarketplaceCatalog.providers(entries)
    static func page(_ id: String) -> HostNavigationPage { pages.first { $0.id == id } ?? pages[0] }
    static func visible(_ page: HostNavigationPage, active: Set<String>, defaults: UserDefaults)
        -> Bool
    {
        if let provider = page.extensionID, !active.contains(provider) { return false }
        guard let suite = page.suite else { return true }
        guard !active.isDisjoint(with: suiteProviders[suite] ?? []) else { return false }
        let sectionProviders = Set(page.sections.compactMap(\.extensionID))
        guard sectionProviders.isEmpty || !active.isDisjoint(with: sectionProviders) else {
            return false
        }
        let enabled =
            defaults.object(forKey: "suite" + suite.capitalized + "Enabled") as? Bool
            ?? true
        guard enabled else { return false }
        return true
    }
    static func maintenanceDestination(_ selection: String, active: Set<String>)
        -> HostNavigationSection?
    {
        let available = maintenance.filter { $0.extensionID.map(active.contains) ?? false }
        return available.first { $0.id == selection } ?? available.first
    }
    static func settingsSections(installed: Set<String>, pending: Set<String>)
        -> [HostNavigationSection]
    {
        settings.filter { section in
            section.extensionID.map { installed.contains($0) && !pending.contains($0) } ?? true
        }
    }
    static func expansionKey(_ page: HostNavigationPage) -> String? {
        if page.id == "settings" { return AppStorageKeys.General.settingsCategoriesExpanded }
        if page.landing { return "sidebar" + page.id.capitalized + "Expanded" }
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
