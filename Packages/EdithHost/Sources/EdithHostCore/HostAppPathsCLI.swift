import Foundation

public enum HostAppPathsCLI {
    public static func entries(identity: HostIdentity) -> [(id: String, label: String, url: URL)] {
        [
            ("app-data", "App data", identity.root),
            ("icloud", "iCloud", HostCoreCloud.directory(identity: identity)),
            ("data", "Usage data", identity.extensionDirectory("usage")),
            (
                "refresh-log", "Refresh log",
                identity.extensionDirectory("usage").appendingPathComponent("refresh.log")
            ),
            ("music", "Music", identity.extensionDirectory("music")),
            ("caches", "Caches", identity.root.appendingPathComponent("Caches")),
            ("logs", "Logs", identity.root.appendingPathComponent("Logs")),
        ]
    }

    public static func prepareOpen(_ id: String, identity: HostIdentity) throws -> (
        url: URL, reveal: Bool
    ) {
        guard let entry = entries(identity: identity).first(where: { $0.id == id }) else {
            throw HostCLIError.usage("Unknown app path.")
        }
        let manager = FileManager.default
        if ["icloud", "music"].contains(id), !manager.fileExists(atPath: entry.url.path) {
            try manager.createDirectory(at: entry.url, withIntermediateDirectories: true)
        }
        if id == "refresh-log" {
            if manager.fileExists(atPath: entry.url.path) { return (entry.url, true) }
            return (identity.extensionDirectory("usage"), false)
        }
        return (entry.url, false)
    }
}
