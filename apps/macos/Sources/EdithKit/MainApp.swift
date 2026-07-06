import AppKit

@MainActor
public enum MainApp {
    public static let bundleIdentifier = "com.pulkit.edith"

    public static func openDashboard() {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier)
        else { return }
        NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
