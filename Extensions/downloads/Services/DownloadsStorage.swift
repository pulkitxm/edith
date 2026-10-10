import EdithExtensionSupport
import Foundation

public enum DownloadsStorage {
    public static let audioFolderPathKey = "downloadsAudioFolderPath"
    public static let audioFolderStaleKey = "downloadsAudioFolderStale"
    private static let confirmationKey = "downloadsAudioFolderExternalConfirmation"

    public static var audioDirectory: URL {
        selectedAudioDirectory()
            ?? ExtensionData.root.appendingPathComponent("library", isDirectory: true)
    }

    public static var dataDir: URL { ExtensionData.root }

    public static func selectedAudioDirectory(
        defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard let path = defaults.string(forKey: audioFolderPathKey), !path.isEmpty,
            RestoredPathValidation.verdict(for: path, homeDirectory: homeDirectory) == .keep
                || defaults.string(forKey: confirmationKey) == path
        else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func prepareStoredPaths(
        defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        guard let path = defaults.string(forKey: audioFolderPathKey), !path.isEmpty,
            RestoredPathValidation.verdict(for: path, homeDirectory: homeDirectory) == .drop,
            defaults.string(forKey: confirmationKey) != path
        else { return }
        defaults.removeObject(forKey: audioFolderPathKey)
        defaults.set(true, forKey: audioFolderStaleKey)
    }

    public static func setAudioDirectory(
        _ url: URL, defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        defaults.set(path, forKey: audioFolderPathKey)
        if RestoredPathValidation.verdict(for: path, homeDirectory: homeDirectory) == .drop {
            defaults.set(path, forKey: confirmationKey)
        } else {
            defaults.removeObject(forKey: confirmationKey)
        }
        defaults.set(false, forKey: audioFolderStaleKey)
    }
}
