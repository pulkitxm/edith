import EdithKit
import Foundation

enum SidebarBand: Equatable, Hashable {
    case core
    case suite(SuiteID)
    case app
}

struct SidebarChild: Identifiable, Equatable {
    let id: String
    let title: String
    let symbolName: String
    let summary: String
    let abilityID: String?

    init(
        id: String, title: String, symbolName: String, summary: String, abilityID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.summary = summary
        self.abilityID = abilityID
    }
}

struct SidebarPage: Identifiable, Equatable {
    let id: String
    let title: String
    let symbolName: String
    let logoName: String?
    let band: SidebarBand
    let abilityIDs: [String]
    let parentID: String?
    let isSuiteLanding: Bool
    let detachable: Bool
    let expansionKey: String?
    let selectionKey: String?
    let children: [SidebarChild]

    init(
        id: String, title: String, symbolName: String, logoName: String? = nil,
        band: SidebarBand, abilityIDs: [String] = [], parentID: String? = nil,
        isSuiteLanding: Bool = false, detachable: Bool = true, expansionKey: String? = nil,
        selectionKey: String? = nil, children: [SidebarChild] = []
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.logoName = logoName
        self.band = band
        self.abilityIDs = abilityIDs
        self.parentID = parentID
        self.isSuiteLanding = isSuiteLanding
        self.detachable = detachable
        self.expansionKey = expansionKey
        self.selectionKey = selectionKey
        self.children = children
    }

    var suite: SuiteID? {
        guard case let .suite(suite) = band else { return nil }
        return suite
    }

    func isVisible(in defaults: UserDefaults) -> Bool {
        switch band {
        case .core, .app:
            return true
        case let .suite(suite):
            guard SuiteRegistry.isEnabled(suite, in: defaults) else { return false }
            guard !abilityIDs.isEmpty else { return true }
            return abilityIDs.contains { abilityID in
                ExtensionRegistry.entry(abilityID)?.isEnabled(in: defaults) ?? false
            }
        }
    }

    func visibleChildren(in defaults: UserDefaults) -> [SidebarChild] {
        children.filter { child in
            guard let abilityID = child.abilityID else { return true }
            return ExtensionRegistry.entry(abilityID)?.isEnabled(in: defaults) ?? false
        }
    }
}

enum SidebarRow: Identifiable, Equatable {
    case page(SidebarPage)
    case section(parent: String, child: SidebarChild)

    var id: String {
        switch self {
        case let .page(page): "page:\(page.id)"
        case let .section(parent, child): "section:\(parent):\(child.id)"
        }
    }
}

enum SuiteExpansion {
    static func key(for suite: SuiteID) -> String {
        "sidebar\(suite.rawValue.capitalized)Expanded"
    }

    static var keys: [String] { SuiteID.allCases.map(key(for:)) }

    static func isExpanded(_ suite: SuiteID, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key(for: suite)) as? Bool ?? true
    }
}

enum NavigationCatalog {
    static let pages: [SidebarPage] = [
        SidebarPage(id: "home", title: "Home", symbolName: "house.fill", band: .core),
        SidebarPage(id: "machines", title: "Fleet", symbolName: "server.rack", band: .core),

        SidebarPage(
            id: "agents", title: "Agents", symbolName: "sparkles", band: .suite(.agents),
            isSuiteLanding: true, expansionKey: SuiteExpansion.key(for: .agents)),
        SidebarPage(
            id: "dashboard", title: "Usage", symbolName: "chart.bar.fill",
            band: .suite(.agents), abilityIDs: ["usage"], parentID: "agents"),
        SidebarPage(
            id: "herdr", title: "Sessions", symbolName: "rectangle.split.3x1.fill",
            logoName: "herdr", band: .suite(.agents), abilityIDs: ["herdr"], parentID: "agents"),
        SidebarPage(
            id: "quinjet", title: "Review", symbolName: "arrow.triangle.branch",
            band: .suite(.agents), abilityIDs: ["quinjet"], parentID: "agents"),
        SidebarPage(
            id: "companion", title: "Memory", symbolName: "brain.head.profile",
            band: .suite(.agents), abilityIDs: ["companion"], parentID: "agents"),

        SidebarPage(
            id: "appMaintenance", title: "Maintenance",
            symbolName: "shippingbox.and.arrow.backward", band: .suite(.maintenance),
            isSuiteLanding: true,
            expansionKey: SuiteExpansion.key(for: .maintenance),
            selectionKey: AppStorageKeys.AppMaintenance.section,
            children: AppMaintenanceSection.allCases.map { section in
                SidebarChild(
                    id: section.rawValue, title: section.rawValue, symbolName: section.symbol,
                    summary: section.summary, abilityID: section.abilityID)
            }),

        SidebarPage(
            id: "system", title: "System", symbolName: "switch.2", band: .suite(.system),
            isSuiteLanding: true, expansionKey: SuiteExpansion.key(for: .system)),
        SidebarPage(
            id: "runningApps", title: "Running apps", symbolName: "cpu",
            band: .suite(.system), abilityIDs: ["system"], parentID: "system"),

        SidebarPage(
            id: "desk", title: "Desk", symbolName: "hand.tap", band: .suite(.desk),
            isSuiteLanding: true, expansionKey: SuiteExpansion.key(for: .desk)),

        SidebarPage(
            id: "media", title: "Media", symbolName: "play.rectangle.on.rectangle",
            band: .suite(.media), isSuiteLanding: true,
            expansionKey: SuiteExpansion.key(for: .media)),
        SidebarPage(
            id: "music", title: "Music", symbolName: "music.note", band: .suite(.media),
            abilityIDs: ["music"], parentID: "media"),
        SidebarPage(
            id: "calendar", title: "Calendar", symbolName: "calendar", band: .suite(.media),
            abilityIDs: ["calendar"], parentID: "media"),

        SidebarPage(
            id: "data", title: "Data", symbolName: "cylinder.split.1x2", band: .suite(.data),
            isSuiteLanding: true, expansionKey: SuiteExpansion.key(for: .data)),
        SidebarPage(
            id: "database", title: "Database", symbolName: "cylinder.fill",
            band: .suite(.data), abilityIDs: ["database"], parentID: "data"),
        SidebarPage(
            id: "attention", title: "Attention", symbolName: "hourglass", band: .suite(.data),
            abilityIDs: ["attention"], parentID: "data"),
        SidebarPage(
            id: "seoAudit", title: "Site Audit", symbolName: "doc.text.magnifyingglass",
            band: .suite(.data), abilityIDs: ["seoAudit"], parentID: "data"),

        SidebarPage(
            id: "extensions", title: "Extensions", symbolName: "puzzlepiece.extension",
            band: .app),
        SidebarPage(
            id: "settings", title: "Settings", symbolName: "gearshape", band: .app,
            detachable: false,
            expansionKey: AppStorageKeys.General.settingsCategoriesExpanded,
            selectionKey: AppStorageKeys.General.settingsTab,
            children: SettingsPane.Tab.allCases.map { tab in
                SidebarChild(
                    id: tab.rawValue, title: tab.label, symbolName: tab.symbol,
                    summary: tab.summary)
            }),
        SidebarPage(
            id: "about", title: "About", symbolName: "info.circle", band: .app,
            detachable: false),
    ]

    static let byID: [String: SidebarPage] = Dictionary(
        uniqueKeysWithValues: pages.map { ($0.id, $0) })

    static func page(_ destination: MainDestination) -> SidebarPage {
        byID[destination.rawValue]!
    }

    static func landing(for suite: SuiteID) -> SidebarPage? {
        pages.first { $0.isSuiteLanding && $0.suite == suite }
    }

    static func mainPages(in band: SidebarBand) -> [SidebarPage] {
        pages.filter { $0.band == band && $0.parentID == nil }
    }

    static func children(of pageID: String) -> [SidebarPage] {
        pages.filter { $0.parentID == pageID }
    }

    static func visiblePages(in defaults: UserDefaults = SharedDefaults.store) -> [SidebarPage] {
        pages.filter { page in
            guard page.isVisible(in: defaults) else { return false }
            guard page.isSuiteLanding, let suite = page.suite else { return true }
            return SuiteRegistry.isEnabled(suite, in: defaults)
        }
    }

    static func rows(in defaults: UserDefaults = SharedDefaults.store) -> [SidebarRow] {
        var rows: [SidebarRow] = []
        for page in pages where page.parentID == nil {
            guard page.isVisible(in: defaults) else { continue }
            rows.append(.page(page))
            let expanded = isExpanded(page, in: defaults)
            guard expanded else { continue }
            for child in page.visibleChildren(in: defaults) {
                rows.append(.section(parent: page.id, child: child))
            }
            for nested in children(of: page.id) where nested.isVisible(in: defaults) {
                rows.append(.page(nested))
            }
        }
        return rows
    }

    static func isExpanded(_ page: SidebarPage, in defaults: UserDefaults) -> Bool {
        guard page.expansionKey != nil else { return true }
        if let suite = page.suite, page.isSuiteLanding {
            return SuiteExpansion.isExpanded(suite, in: defaults)
        }
        guard let key = page.expansionKey else { return true }
        return defaults.object(forKey: key) as? Bool ?? true
    }

    static func hasDisclosure(_ page: SidebarPage, in defaults: UserDefaults) -> Bool {
        !page.visibleChildren(in: defaults).isEmpty
            || children(of: page.id).contains { $0.isVisible(in: defaults) }
    }

    static func destinations(in defaults: UserDefaults = SharedDefaults.store)
        -> [MainDestination]
    {
        visiblePages(in: defaults).compactMap { MainDestination(rawValue: $0.id) }
    }
}

enum MainDestination: String, CaseIterable, Identifiable {
    case home, machines
    case agents, dashboard, herdr, quinjet, companion
    case appMaintenance
    case system, runningApps
    case desk
    case media, music, calendar
    case data, database, attention, seoAudit
    case extensions, settings, about

    var id: String { rawValue }

    var page: SidebarPage { NavigationCatalog.page(self) }

    var title: String { page.title }

    var icon: String { page.symbolName }

    var logoName: String? { page.logoName }

    static var homeItems: [MainDestination] {
        NavigationCatalog.pages
            .filter { $0.band != .app }
            .compactMap { MainDestination(rawValue: $0.id) }
    }

    static var appItems: [MainDestination] {
        NavigationCatalog.mainPages(in: .app).compactMap { MainDestination(rawValue: $0.id) }
    }

    static func resolve(_ raw: String) -> MainDestination {
        MainDestination(rawValue: raw) ?? .home
    }
}
