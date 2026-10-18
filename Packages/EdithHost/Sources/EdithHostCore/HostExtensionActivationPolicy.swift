import Foundation

public enum HostExtensionActivationPolicy {
    public static let onDemandIDs: Set<String> = [
        "appMaintenance", "blitztree", "cleaner", "database", "docs", "downloads", "homebrew",
        "jev", "latex", "plugins", "quinjet", "seoAudit", "studio", "terminal",
    ]

    public static func startsAtLaunch(_ id: String) -> Bool {
        !onDemandIDs.contains(id)
    }
}
