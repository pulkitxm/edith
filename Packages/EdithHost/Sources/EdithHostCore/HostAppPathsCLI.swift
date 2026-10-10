import EdithExtensionSupport
import Foundation

public enum HostAppPathsCLI {
    private static func usageDirectory(_ identity: HostIdentity) -> URL {
        identity.effectiveExtensionDirectory("usage").appendingPathComponent("data")
    }

    public static func entries(
        identity: HostIdentity, defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [(id: String, label: String, url: URL)] {
        [
            ("app-data", "App data", identity.root),
            ("icloud", "iCloud", HostCoreCloud.directory(identity: identity)),
            ("data", "Usage data", usageDirectory(identity)),
            (
                "refresh-log", "Refresh log",
                usageDirectory(identity).appendingPathComponent("refresh.log")
            ),
            (
                "music", "Music",
                ExtensionData.selectedMusicDirectory(
                    defaults: defaults, homeDirectory: homeDirectory)
                    ?? identity.persistentExtensionLocations("music")[0]
            ),
            ("caches", "Caches", identity.root.appendingPathComponent("Caches")),
            ("logs", "Logs", identity.root.appendingPathComponent("Logs")),
        ]
    }

    public static func prepareOpen(
        _ id: String, identity: HostIdentity, defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> (
        url: URL, reveal: Bool
    ) {
        guard
            let entry = entries(
                identity: identity, defaults: defaults, homeDirectory: homeDirectory
            ).first(where: { $0.id == id })
        else {
            throw HostCLIError.usage("Unknown app path.")
        }
        let manager = FileManager.default
        if ["icloud", "music"].contains(id), !manager.fileExists(atPath: entry.url.path) {
            try manager.createDirectory(at: entry.url, withIntermediateDirectories: true)
        }
        if id == "refresh-log" {
            if manager.fileExists(atPath: entry.url.path) { return (entry.url, true) }
            return (usageDirectory(identity), false)
        }
        return (entry.url, false)
    }
}
