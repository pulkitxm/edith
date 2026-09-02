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
    let detachable: Bool
    let expansionKey: String?
    let selectionKey: String?
    let children: [SidebarChild]

    init(
        id: String, title: String, symbolName: String, logoName: String? = nil,
        band: SidebarBand, abilityIDs: [String] = [], parentID: String? = nil,
        detachable: Bool = true, expansionKey: String? = nil, selectionKey: String? = nil,
        children: [SidebarChild] = []
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.logoName = logoName
        self.band = band
        self.abilityIDs = abilityIDs
        self.parentID = parentID
        self.detachable = detachable
        self.expansionKey = expansionKey
        self.selectionKey = selectionKey
        self.children = children
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

enum NavigationCatalog {
    static let pages: [SidebarPage] = [
        SidebarPage(
            id: "home", title: "Home", symbolName: "house.fill", band: .core),
        SidebarPage(
            id: "machines", title: "Fleet", symbolName: "server.rack", band: .core),
        SidebarPage(
            id: "dashboard", title: "Usage", symbolName: "chart.bar.fill",
            band: .suite(.agents), abilityIDs: ["usage"]),
        SidebarPage(
            id: "herdr", title: "Sessions", symbolName: "rectangle.split.3x1.fill",
            logoName: "herdr", band: .suite(.agents), abilityIDs: ["herdr"]),
        SidebarPage(
            id: "quinjet", title: "Review", symbolName: "arrow.triangle.branch",
            band: .suite(.agents), abilityIDs: ["quinjet"]),
        SidebarPage(
            id: "companion", title: "Memory", symbolName: "brain.head.profile",
            band: .suite(.agents), abilityIDs: ["companion"]),
        SidebarPage(
            id: "appMaintenance", title: "Maintenance",
            symbolName: "shippingbox.and.arrow.backward", band: .suite(.maintenance),
            abilityIDs: ["appMaintenance", "homebrew", "cleaner"],
            expansionKey: AppStorageKeys.AppMaintenance.categoriesExpanded,
            selectionKey: AppStorageKeys.AppMaintenance.section,
            children: AppMaintenanceSection.allCases.map { section in
                SidebarChild(
                    id: section.rawValue, title: section.rawValue, symbolName: section.symbol,
                    summary: section.summary, abilityID: section.abilityID)
            }),
        SidebarPage(
            id: "system", title: "System", symbolName: "cpu", band: .suite(.system),
            abilityIDs: ["system"]),
        SidebarPage(
            id: "music", title: "Music", symbolName: "music.note", band: .suite(.media),
            abilityIDs: ["music"]),
        SidebarPage(
            id: "calendar", title: "Calendar", symbolName: "calendar", band: .suite(.media),
            abilityIDs: ["calendar"]),
        SidebarPage(
            id: "database", title: "Database", symbolName: "cylinder.fill", band: .suite(.data),
            abilityIDs: ["database"]),
        SidebarPage(
            id: "attention", title: "Attention", symbolName: "hourglass", band: .suite(.data),
            abilityIDs: ["attention"]),
        SidebarPage(
            id: "seoAudit", title: "Site Audit", symbolName: "doc.text.magnifyingglass",
            band: .suite(.data), abilityIDs: ["seoAudit"]),
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

    static func mainPages(in band: SidebarBand) -> [SidebarPage] {
        pages.filter { $0.band == band && $0.parentID == nil }
    }

    static func visiblePages(in defaults: UserDefaults = SharedDefaults.store) -> [SidebarPage] {
        pages.filter { $0.isVisible(in: defaults) }
    }

    static func rows(in defaults: UserDefaults = SharedDefaults.store) -> [SidebarRow] {
        var rows: [SidebarRow] = []
        for page in pages where page.parentID == nil && page.isVisible(in: defaults) {
            rows.append(.page(page))
            for child in page.visibleChildren(in: defaults) {
                rows.append(.section(parent: page.id, child: child))
            }
            for nested in pages
            where nested.parentID == page.id && nested.isVisible(in: defaults) {
                rows.append(.page(nested))
            }
        }
        return rows
    }

    static func destinations(in defaults: UserDefaults = SharedDefaults.store)
        -> [MainDestination]
    {
        visiblePages(in: defaults).compactMap { MainDestination(rawValue: $0.id) }
    }
}

enum MainDestination: String, CaseIterable, Identifiable {
    case home, machines, dashboard, herdr, quinjet, companion, appMaintenance, system
    case music, calendar, database, attention, seoAudit, extensions, settings, about

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
