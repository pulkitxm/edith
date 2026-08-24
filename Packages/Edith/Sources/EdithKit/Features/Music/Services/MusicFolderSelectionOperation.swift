import EdithCore
import Foundation

public enum MusicFolderSelectionOperation: String, CaseIterable, Equatable, Sendable {
    case select

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "music.library.folder.select"),
            summary: "Choose the music library folder.", cli: ["music", "library"],
            effect: .write)
    }
}

public struct MusicFolderSelectionResult: Equatable, Sendable {
    public let path: String
    public let changed: Bool
    public let confirmsExternalStorage: Bool

    public init(path: String, changed: Bool, confirmsExternalStorage: Bool) {
        self.path = path
        self.changed = changed
        self.confirmsExternalStorage = confirmsExternalStorage
    }
}

public enum MusicFolderSelectionError: LocalizedError, Equatable {
    case emptyPath
    case missing(String)
    case notDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPath: "the music folder path cannot be blank"
        case let .missing(path): "no folder exists at \(path)"
        case let .notDirectory(path): "\(path) is not a folder"
        }
    }
}

public enum MusicFolderSelectionOperationExecution {
    public static func select(
        _ rawPath: String,
        defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        validateDirectory: (URL) -> Bool = { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        },
        invalidate: () -> Void = TrackMeta.invalidateCaches,
        announce: () -> Void = { IPC.post(IPC.Name.musicFolderChanged) }
    ) throws -> MusicFolderSelectionResult {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw MusicFolderSelectionError.emptyPath }
        let url = standardizedURL(path, homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MusicFolderSelectionError.missing(url.path)
        }
        guard validateDirectory(url) else { throw MusicFolderSelectionError.notDirectory(url.path) }
        let previous = Repo.selectedMusicDirectory(
            defaults: defaults, homeDirectory: homeDirectory)?.path
        Repo.setMusicDirectory(url, defaults: defaults, homeDirectory: homeDirectory)
        defaults.synchronize()
        invalidate()
        announce()
        return MusicFolderSelectionResult(
            path: url.path, changed: previous != url.path,
            confirmsExternalStorage: RestoredPathValidation.verdict(
                for: url.path, homeDirectory: homeDirectory) == .drop)
    }

    public static func standardizedURL(_ path: String, homeDirectory: URL) -> URL {
        let expanded: String
        if path == "~" {
            expanded = homeDirectory.path
        } else if path.hasPrefix("~/") {
            expanded = homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        } else {
            expanded = path
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

}
