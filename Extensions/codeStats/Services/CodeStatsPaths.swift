import EdithExtensionSupport
import Foundation

public enum CodeStatsPaths {
    public static func prepare(
        defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = CodeStatsExecutionEnvironment.home
    ) {
        if selectedFolder(defaults: defaults, homeDirectory: homeDirectory) == nil {
            defaults.removeObject(forKey: AppStorageKeys.CodeStats.folder)
            defaults.removeObject(forKey: AppStorageKeys.CodeStats.folderConfirmation)
        }
    }

    public static func standardizedURL(_ path: String, homeDirectory: URL) -> URL {
        let expanded =
            path == "~"
            ? homeDirectory.path
            : path.hasPrefix("~/")
                ? homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
                : path
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func selectedFolder(
        defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard let path = defaults.string(forKey: AppStorageKeys.CodeStats.folder), !path.isEmpty,
            RestoredPathValidation.verdict(for: path, homeDirectory: homeDirectory) == .keep
                || defaults.string(forKey: AppStorageKeys.CodeStats.folderConfirmation) == path
        else { return nil }
        let normalized = standardizedURL(path, homeDirectory: homeDirectory).path
        if defaults === SharedDefaults.store,
            let fixture = CodeStatsExecutionEnvironment.fixtureHome,
            normalized != fixture.path && !normalized.hasPrefix(fixture.path + "/")
        {
            return nil
        }
        return normalized
    }

    public static func setFolder(
        _ path: String?, defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        guard let path, !path.isEmpty else {
            defaults.removeObject(forKey: AppStorageKeys.CodeStats.folder)
            defaults.removeObject(forKey: AppStorageKeys.CodeStats.folderConfirmation)
            return
        }
        let normalized = standardizedURL(path, homeDirectory: homeDirectory).path
        defaults.set(normalized, forKey: AppStorageKeys.CodeStats.folder)
        if RestoredPathValidation.verdict(for: normalized, homeDirectory: homeDirectory) == .drop {
            defaults.set(normalized, forKey: AppStorageKeys.CodeStats.folderConfirmation)
        } else {
            defaults.removeObject(forKey: AppStorageKeys.CodeStats.folderConfirmation)
        }
    }
}
