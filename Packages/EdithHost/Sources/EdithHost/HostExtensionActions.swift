import EdithHostCore
import ExtensionMarketplace
import Foundation

enum HostExtensionSettingsPolicy: Equatable {
    case preferences, active, unavailable

    static func route(for id: String) -> HostExtensionSettingsRoute? {
        switch id {
        case "colorPicker", "emoji", "focusDim", "keepAwake", "keystrokeHighlight", "micMute",
            "presenter", "systemStats", "windowSweaters":
            .init(section: "extension", policy: .preferences)
        case "bifrost", "clipboard", "codeStats", "downloads", "lidAwake", "attention",
            "appMaintenance", "studio":
            .init(section: "extension", policy: .active)
        case "jev": .init(section: "jev", policy: .active)
        case "usage": .init(section: "usage", policy: .active)
        case "music": .init(section: "music", policy: .active)
        default: nil
        }
    }

    static func policy(for id: String) -> Self { route(for: id)?.policy ?? .unavailable }

    static func request(
        id: String, installed: ExtensionPackage?, state: HostActivationState?,
        activeVersion: String?, pendingDisable: Bool, pendingRemoval: Bool,
        presentationID: UUID = UUID(),
        systemVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> HostExtensionContentRequest? {
        guard let route = route(for: id), let installed, installed.id == id,
            installed.isCompatible(
                hostABI: HostContract.compatibility, architecture: "arm64",
                systemVersion: systemVersion),
            !pendingDisable, !pendingRemoval, state != .stopping
        else { return nil }
        let active = state == .active && activeVersion == installed.version
        guard canPresent(id: id, active: active) else { return nil }
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
    static func open(
        _ entry: HostExtension, active: Bool, openPage: ((String) -> Void)?,
        showDetails: (HostExtension) -> Void
    ) {
        if active, HostNavigationCatalog.route(extensionID: entry.id) != nil,
            let openPage
        {
            openPage(entry.id)
        } else {
            showDetails(entry)
        }
    }
}
