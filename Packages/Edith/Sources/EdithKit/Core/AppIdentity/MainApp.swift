import EdithCore
import AppKit

@MainActor
public enum MainApp {
    public nonisolated static let bundleIdentifier = AppBuildIdentity.application
    public nonisolated static let statusBarBundleIdentifier = AppBuildIdentity.helper
    public nonisolated static let creatorSiteURLString = "https://pulkit.page"

    public static func openDashboard() {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier)
        else { return }
        NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    public static func open(section: String) {
        SharedDefaults.store.set(section, forKey: AppStorageKeys.General.mainWindowSection)
        openDashboard()
    }

    public static func openSettings(tab: String? = nil) {
        if let tab { SharedDefaults.store.set(tab, forKey: AppStorageKeys.General.settingsTab) }
        open(section: "settings")
    }
}
