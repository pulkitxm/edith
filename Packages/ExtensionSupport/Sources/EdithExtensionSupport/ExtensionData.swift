import Foundation

public enum ExtensionData {
    private static let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("edith-extension-\(UUID().uuidString)", isDirectory: true)

    public static var root: URL {
        resolve(environment: ProcessInfo.processInfo.environment, fallback: temporaryRoot)
    }

    public static let productionBases: [String: String] = [
        "usage": "", "herdr": "", "clipboard": "", "attention": "", "studio": "",
        "notchShelf": "", "latex": "", "calendar": "", "appMaintenance": "", "music": "",
        "seoAudit": "", "machines": "machines", "codeStats": "code-stats",
        "virtualCamera": "virtual-camera", "companion": "", "database": "database",
        "timeLapse": "", "downloads": "data", "homebrew": "",
    ]

    public static let productionLeaves: [String: [String]] = [
        "usage": ["data", "Snapshots/home-usage.json", "notifications.json"],
        "herdr": ["herdr", "provider-hook-ownership.json"],
        "clipboard": ["clipboard"], "attention": ["attention"], "studio": ["studio"],
        "notchShelf": ["Shelf", "notch-browser"], "latex": ["latex"],
        "calendar": ["Snapshots/calendar-agenda.json"],
        "appMaintenance": ["app-update-center.json", "app-maintenance-snapshot.json"],
        "homebrew": ["homebrew-listing.json"],
        "music": [
            "music", "thumbnails", "music-library-index.json", "shared-state",
            "data/downloads.json", "data/downloads.json.lock", "data/downloads.json.scheduler.lock",
            "data/downloads.json.activity.json", "data/downloads.json.activity.json.lock",
        ],
        "seoAudit": ["SEOAudit"], "machines": ["machines"], "codeStats": ["code-stats"],
        "virtualCamera": ["virtual-camera"],
        "companion": ["companion-config.json", "companion-deployment.json", "companion-outbox"],
        "database": ["database"], "timeLapse": ["video-projects/TimeLapses"],
        "downloads": [
            "data/downloads.json", "data/downloads.json.lock", "data/downloads.json.scheduler.lock",
            "data/downloads.json.activity.json", "data/downloads.json.activity.json.lock",
        ],
    ]

    public static func selectedMusicDirectory(defaults: UserDefaults, homeDirectory: URL) -> URL? {
        guard let path = defaults.string(forKey: AppStorageKeys.Music.folderPath), !path.isEmpty,
            RestoredPathValidation.verdict(for: path, homeDirectory: homeDirectory) == .keep
                || defaults.string(forKey: AppStorageKeys.Music.folderConfirmation) == path
        else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func productionDirectory(
        _ relative: String, fallback: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard environment["EDITH_APPLICATION_IDENTIFIER"] == "com.pulkit.edith",
            let path = environment["EDITH_EXTENSION_DATA_ROOT"], path.hasPrefix("/"),
            !path.utf8.contains(0),
            let owner = environment["EDITH_EXTENSION_ID"], productionBases[owner] != nil
        else { return fallback }
        let configured = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard configured.lastPathComponent == owner,
            configured.deletingLastPathComponent().lastPathComponent == "Data",
            configured.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                == "Edith",
            productionLeaves[owner]?.contains(relative) == true
                || (owner == "downloads" && relative == "music")
        else { return fallback }
        return configured.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative, isDirectory: true)
    }

    public static func resolve(environment: [String: String], fallback: URL) -> URL {
        guard let path = environment["EDITH_EXTENSION_DATA_ROOT"], path.hasPrefix("/"),
            !path.utf8.contains(0)
        else { return fallback }
        let configured = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard environment["EDITH_APPLICATION_IDENTIFIER"] == "com.pulkit.edith",
            let owner = environment["EDITH_EXTENSION_ID"], configured.lastPathComponent == owner,
            configured.deletingLastPathComponent().lastPathComponent == "Data",
            configured.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                == "Edith",
            let relative = productionBases[owner]
        else { return configured }
        let original = configured.deletingLastPathComponent().deletingLastPathComponent()
        return relative.isEmpty
            ? original : original.appendingPathComponent(relative, isDirectory: true)
    }
}
