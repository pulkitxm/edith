import EdithExtensionSupport
import Foundation

public enum MusicStorage {
    public static let musicFolderPathKey = AppStorageKeys.Music.folderPath
    public static let musicFolderStaleKey = "musicFolderStale"
    private static let confirmationKey = AppStorageKeys.Music.folderConfirmation

    public static var musicDir: URL {
        selectedMusicDirectory()
            ?? ExtensionData.productionDirectory(
                "music",
                fallback: ExtensionData.root.appendingPathComponent("library", isDirectory: true))
    }

    public static var dataDir: URL { ExtensionData.root }

    public static var downloadQueueFile: URL {
        resolvedDownloadQueueFile(environment: ProcessInfo.processInfo.environment)
    }

    public static func resolvedDownloadQueueFile(environment: [String: String]) -> URL {
        let root = ExtensionData.resolve(environment: environment, fallback: ExtensionData.root)
        return ExtensionData.productionDirectory(
            "data/downloads.json", fallback: root.appendingPathComponent("downloads.json"),
            environment: environment)
    }

    public static func selectedMusicDirectory(
        defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        ExtensionData.selectedMusicDirectory(defaults: defaults, homeDirectory: homeDirectory)
    }

    public static func prepareStoredPaths(
        defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        guard let path = defaults.string(forKey: musicFolderPathKey), !path.isEmpty,
            RestoredPathValidation.verdict(for: path, homeDirectory: homeDirectory) == .drop,
            defaults.string(forKey: confirmationKey) != path
        else { return }
        defaults.removeObject(forKey: musicFolderPathKey)
        defaults.set(true, forKey: musicFolderStaleKey)
    }

    public static func setMusicDirectory(
        _ url: URL, defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        defaults.set(path, forKey: musicFolderPathKey)
        if RestoredPathValidation.verdict(for: path, homeDirectory: homeDirectory) == .drop {
            defaults.set(path, forKey: confirmationKey)
        } else {
            defaults.removeObject(forKey: confirmationKey)
        }
        defaults.set(false, forKey: musicFolderStaleKey)
    }
}
