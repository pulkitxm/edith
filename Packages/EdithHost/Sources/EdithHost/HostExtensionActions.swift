import EdithHostCore
import ExtensionMarketplace
import Foundation

enum HostExtensionSettingsPolicy: Equatable {
    case preferences, active, unavailable

    static func route(for id: String) -> HostExtensionSettingsRoute? {
        switch id {
        case "audioMixer", "colorPicker", "emoji", "focusDim", "hinge", "keepAwake",
            "keystrokeHighlight", "micMute", "presenter", "systemStats", "windowSweaters":
            .init(section: "extension", policy: .preferences)
        case "bifrost", "clipboard", "codeStats", "downloads", "lidAwake", "attention",
            "appMaintenance", "studio", "quinjet", "notchShelf", "latex",
            "timeLapse", "socialManager":
            .init(section: "extension", policy: .active)
        case "calendar": .init(section: "calendar", policy: .active)
        case "jev": .init(section: "jev", policy: .active)
        case "blitztree": .init(section: "extension", policy: .active)
        case "usage": .init(section: "usage", policy: .active)
        case "music": .init(section: "music", policy: .active)
        case "system": .init(section: "extension", policy: .active)
        default: nil
        }
    }

    static func policy(for id: String) -> Self { route(for: id)?.policy ?? .unavailable }

    static func request(
        id: String, installed: ExtensionPackage?, state: HostActivationState?,
        activeVersion: String?, pendingDisable: Bool, pendingRemoval: Bool,
        presentationID: UUID = UUID(),
        systemVersion: ExtensionSystemVersion = .init(
            ProcessInfo.processInfo.operatingSystemVersion)
    ) -> HostExtensionContentRequest? {
        guard let route = route(for: id), let installed, installed.id == id,
            installed.isCompatible(
                hostABI: HostContract.compatibility, architecture: "arm64",
                systemVersion: systemVersion),
            !pendingDisable, !pendingRemoval, state != .stopping
        else { return nil }
        let active = state == .active && activeVersion == installed.version
        guard state != .active || active, canPresent(id: id, active: active) else { return nil }
        return .init(
            extensionID: id, location: "settings", section: route.section,
            presentationID: presentationID)
    }

    static func canPresent(id: String, active: Bool) -> Bool {
        switch policy(for: id) {
        case .preferences: true
        case .active: active
        case .unavailable: false
        }
    }
}

struct HostExtensionSettingsRoute: Equatable {
    let section: String
    let policy: HostExtensionSettingsPolicy
}

enum HostExtensionActions {
    struct OpenTarget: Equatable {
        let page: String
        let section: String?
    }

    static func openTarget(extensionID: String) -> OpenTarget? {
        HostNavigationCatalog.route(extensionID: extensionID).map {
            OpenTarget(page: $0.page, section: $0.section)
        }
    }

    static func pageTitles() -> [String: String] {
        Dictionary(
            HostNavigationCatalog.pages.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first })
    }

    static func sectionTitles() -> [String: String] {
        Dictionary(
            HostNavigationCatalog.maintenance.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first })
    }

    static func placements(for entry: HostExtension) -> [HostExtensionPlacement] {
        HostExtensionPlacements.placements(
            for: entry,
            hasSettings: HostExtensionSettingsPolicy.policy(for: entry.id) != .unavailable,
            route: HostNavigationCatalog.route(extensionID: entry.id), pageTitles: pageTitles(),
            sectionTitles: sectionTitles())
    }

    static func hint(for entry: HostExtension) -> String {
        HostExtensionPlacements.hint(
            for: entry, route: HostNavigationCatalog.route(extensionID: entry.id),
            pageTitles: pageTitles(), sectionTitles: sectionTitles())
    }

    static func open(
        _ entry: HostExtension, active: Bool, openPage: ((String) -> Void)?,
        showDetails: (HostExtension) -> Void
    ) {
        if active, openTarget(extensionID: entry.id) != nil,
            let openPage
        {
            openPage(entry.id)
        } else {
            showDetails(entry)
        }
    }
}
