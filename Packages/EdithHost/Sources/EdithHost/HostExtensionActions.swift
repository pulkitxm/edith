import EdithHostCore

enum HostExtensionSettingsPolicy {
    case preferences, active, unavailable

    static func policy(for id: String) -> Self {
        switch id {
        case "colorPicker", "emoji", "focusDim", "keepAwake", "keystrokeHighlight", "micMute",
            "presenter", "systemStats", "windowSweaters":
            .preferences
        case "bifrost", "clipboard", "codeStats", "downloads", "jev", "lidAwake": .active
        default: .unavailable
        }
    }

    static func canPresent(id: String, active: Bool) -> Bool {
        switch policy(for: id) {
        case .preferences: true
        case .active: active
        case .unavailable: false
        }
    }
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
