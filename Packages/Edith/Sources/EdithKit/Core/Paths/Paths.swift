import EdithCore
import Foundation

public enum RestoredPathVerdict: Equatable {
    case keep
    case drop
}

public enum RestoredPathValidation {
    public static func verdict(
        for path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> RestoredPathVerdict {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL
            .resolvingSymlinksInPath().path
        let homePath = homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        if standardizedPath == homePath || standardizedPath.hasPrefix(homePath + "/") {
            return .keep
        }
        if standardizedPath == "/Volumes" || standardizedPath.hasPrefix("/Volumes/") {
            return .drop
        }
        return .keep
    }
}

public enum AppData {
    public static let supportDir: URL = {
        let dir = DataRoot.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static let cloudOverrideVariable = "EDITH_CLOUD_ROOT"
    public static let cloudDir = resolveCloudDirectory()

    public static func resolveCloudDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let path = environment[cloudOverrideVariable], !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return homeDirectory.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/Edith")
    }

    public static var cloudAvailable: Bool {
        if let path = ProcessInfo.processInfo.environment[cloudOverrideVariable], !path.isEmpty {
            return FileManager.default.fileExists(atPath: cloudDir.path)
        }
        return FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path)
    }

    public static var cloudBackupExists: Bool {
        guard cloudAvailable else { return false }
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: cloudDir.path)) ?? []
        return names.contains { $0 != ".DS_Store" }
    }
}

public enum Repo {
    public static let musicFolderPathKey = "musicFolderPath"
    public static let musicFolderStaleKey = "musicFolderStale"
    private static let musicFolderConfirmationKey = "musicFolderExternalConfirmation"

    public static var dataDir: URL { DataRoot.usage }
    public static var usageJSON: URL { dataDir.appendingPathComponent("usage.json") }
    public static var limitsJSONL: URL { dataDir.appendingPathComponent("limits-history.jsonl") }
    public static var musicDir: URL {
        selectedMusicDirectory() ?? DataRoot.music
    }

    public static func selectedMusicDirectory(
        defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        confirmedPath(
            forKey: musicFolderPathKey, confirmationKey: musicFolderConfirmationKey,
            defaults: defaults, homeDirectory: homeDirectory)
    }

    public static func prepareStoredPaths(
        defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        validateStoredPath(
            forKey: musicFolderPathKey, confirmationKey: musicFolderConfirmationKey,
            marksMusicStale: true, defaults: defaults, homeDirectory: homeDirectory)
    }

    public static func setMusicDirectory(
        _ url: URL, defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        setConfirmedPath(
            url.path, forKey: musicFolderPathKey, confirmationKey: musicFolderConfirmationKey,
            defaults: defaults, homeDirectory: homeDirectory)
        defaults.set(false, forKey: musicFolderStaleKey)
    }

    private static func confirmedPath(
        forKey key: String, confirmationKey: String, defaults: UserDefaults,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard let path = defaults.string(forKey: key), !path.isEmpty else { return nil }
        if RestoredPathValidation.verdict(for: path, homeDirectory: homeDirectory) == .keep
            || defaults.string(forKey: confirmationKey) == path
        {
            return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        }
        return nil
    }

    private static func validateStoredPath(
        forKey key: String, confirmationKey: String, marksMusicStale: Bool,
        defaults: UserDefaults, homeDirectory: URL
    ) {
        guard let path = defaults.string(forKey: key), !path.isEmpty,
            RestoredPathValidation.verdict(for: path, homeDirectory: homeDirectory) == .drop,
            defaults.string(forKey: confirmationKey) != path
        else { return }
        defaults.removeObject(forKey: key)
        if marksMusicStale {
            defaults.set(true, forKey: musicFolderStaleKey)
        }
    }

    private static func setConfirmedPath(
        _ path: String?, forKey key: String, confirmationKey: String,
        defaults: UserDefaults, homeDirectory: URL
    ) {
        guard let path, !path.isEmpty else {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: confirmationKey)
            return
        }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL
            .resolvingSymlinksInPath().path
        defaults.set(standardizedPath, forKey: key)
        if RestoredPathValidation.verdict(
            for: standardizedPath, homeDirectory: homeDirectory) == .drop
        {
            defaults.set(standardizedPath, forKey: confirmationKey)
        } else {
            defaults.removeObject(forKey: confirmationKey)
        }
    }
}

public enum ClipboardPaths {
    nonisolated(unsafe) public static var root: URL = DataRoot.support

    public static var dir: URL {
        root.appendingPathComponent("clipboard")
    }
    public static var indexFile: URL {
        dir.appendingPathComponent("index.jsonl")
    }
    public static var blobsDir: URL {
        dir.appendingPathComponent("blobs")
    }
    public static var lockFile: URL {
        dir.appendingPathComponent(".lock")
    }
    public static func blobFile(sha256: String, ext: String) -> URL {
        blobsDir.appendingPathComponent("\(sha256).\(ext)")
    }
}
