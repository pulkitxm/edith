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
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let homePath = homeDirectory.standardizedFileURL.path
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
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0
        ]
        .appendingPathComponent("Edith")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static let cloudDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Edith")

    public static var cloudAvailable: Bool {
        FileManager.default.fileExists(
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
    private static let repoPathConfirmationKey = "repoPathExternalConfirmation"

    public static var devRoot: URL? {
        confirmedPath(forKey: "repoPath", confirmationKey: repoPathConfirmationKey)
    }

    public static var dataDir: URL {
        devRoot?.appendingPathComponent("apps/dashboard/data")
            ?? AppData.supportDir.appendingPathComponent("data")
    }
    public static var usageJSON: URL { dataDir.appendingPathComponent("usage.json") }
    public static var limitsJSONL: URL { dataDir.appendingPathComponent("limits-history.jsonl") }
    public static var musicDir: URL {
        confirmedPath(forKey: musicFolderPathKey, confirmationKey: musicFolderConfirmationKey)
            ?? devRoot?.appendingPathComponent("local/music")
            ?? AppData.supportDir.appendingPathComponent("music")
    }

    public static func prepareStoredPaths() {
        validateStoredPath(
            forKey: "repoPath", confirmationKey: repoPathConfirmationKey, marksMusicStale: true)
        validateStoredPath(
            forKey: musicFolderPathKey, confirmationKey: musicFolderConfirmationKey,
            marksMusicStale: true)
    }

    public static func setDevRootPath(_ path: String?) {
        setConfirmedPath(path, forKey: "repoPath", confirmationKey: repoPathConfirmationKey)
    }

    public static func setMusicDirectory(_ url: URL) {
        setConfirmedPath(
            url.path, forKey: musicFolderPathKey, confirmationKey: musicFolderConfirmationKey)
        SharedDefaults.store.set(false, forKey: musicFolderStaleKey)
    }

    private static func confirmedPath(forKey key: String, confirmationKey: String) -> URL? {
        guard let path = SharedDefaults.store.string(forKey: key), !path.isEmpty else { return nil }
        if RestoredPathValidation.verdict(for: path) == .keep
            || SharedDefaults.store.string(forKey: confirmationKey) == path
        {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return nil
    }

    private static func validateStoredPath(
        forKey key: String, confirmationKey: String, marksMusicStale: Bool
    ) {
        guard let path = SharedDefaults.store.string(forKey: key), !path.isEmpty,
            RestoredPathValidation.verdict(for: path) == .drop,
            SharedDefaults.store.string(forKey: confirmationKey) != path
        else { return }
        SharedDefaults.store.removeObject(forKey: key)
        if marksMusicStale {
            SharedDefaults.store.set(true, forKey: musicFolderStaleKey)
        }
    }

    private static func setConfirmedPath(
        _ path: String?, forKey key: String, confirmationKey: String
    ) {
        guard let path, !path.isEmpty else {
            SharedDefaults.store.removeObject(forKey: key)
            SharedDefaults.store.removeObject(forKey: confirmationKey)
            return
        }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        SharedDefaults.store.set(standardizedPath, forKey: key)
        if RestoredPathValidation.verdict(for: standardizedPath) == .drop {
            SharedDefaults.store.set(standardizedPath, forKey: confirmationKey)
        } else {
            SharedDefaults.store.removeObject(forKey: confirmationKey)
        }
    }
}

public enum ClipboardPaths {
    nonisolated(unsafe) public static var root: URL = AppData.supportDir

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
