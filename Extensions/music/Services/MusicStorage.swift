import EdithExtensionSupport
import Foundation

public enum MusicStorage {
    public static let musicFolderPathKey = "musicFolderPath"
    public static let musicFolderStaleKey = "musicFolderStale"
    private static let confirmationKey = "musicFolderExternalConfirmation"

    public static var musicDir: URL {
        selectedMusicDirectory()
            ?? ExtensionData.root.appendingPathComponent("library", isDirectory: true)
    }

    public static var dataDir: URL { ExtensionData.root }

    public static func selectedMusicDirectory(
        defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard let path = defaults.string(forKey: musicFolderPathKey), !path.isEmpty,
            RestoredPathValidation.verdict(for: path, homeDirectory: homeDirectory) == .keep
                || defaults.string(forKey: confirmationKey) == path
        else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
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
