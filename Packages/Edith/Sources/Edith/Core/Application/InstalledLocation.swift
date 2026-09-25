import AppKit
import EdithCore

enum InstalledLocation {
    static func permitsLaunch(
        bundleURL: URL = Bundle.main.bundleURL,
        identifier: String? = Bundle.main.bundleIdentifier,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard identifier == AppBuildIdentity.production else { return true }
        let installed = [
            URL(fileURLWithPath: "/Applications"),
            homeDirectory.appendingPathComponent("Applications"),
        ]
        .map { canonicalPath($0.appendingPathComponent("Edith.app")) }
        return installed.contains(canonicalPath(bundleURL))
    }

    @MainActor static func refuseLaunch() {
        let alert = NSAlert()
        alert.messageText = "Open Edith from Applications"
        alert.informativeText =
            "This copy of Edith is at \(Bundle.main.bundlePath). Only the copy in your "
            + "Applications folder runs Edith's background agent and menu bar. Move Edith to "
            + "Applications and open it from there."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
