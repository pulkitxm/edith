import EdithExtensionSupport
import Foundation

public enum DownloadsStorage {
    public static let audioFolderPathKey = "downloadsAudioFolderPath"
    public static let audioFolderStaleKey = "downloadsAudioFolderStale"
    private static let confirmationKey = "downloadsAudioFolderExternalConfirmation"

    public static var audioDirectory: URL {
        resolvedAudioDirectory(
            defaults: SharedDefaults.store,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment, root: ExtensionData.root)
    }

    public static func resolvedAudioDirectory(
        defaults: UserDefaults, homeDirectory: URL, environment: [String: String], root: URL
    ) -> URL {
        selectedAudioDirectory(defaults: defaults, homeDirectory: homeDirectory)
            ?? (environment["EDITH_APPLICATION_IDENTIFIER"] == "com.pulkit.edith"
                ? ExtensionData.selectedMusicDirectory(
                    defaults: defaults, homeDirectory: homeDirectory) : nil)
            ?? ExtensionData.productionDirectory(
                "music", fallback: root.appendingPathComponent("library", isDirectory: true),
                environment: environment)
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
