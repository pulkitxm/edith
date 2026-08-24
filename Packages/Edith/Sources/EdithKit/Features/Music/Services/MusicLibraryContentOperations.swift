import EdithCore
import Foundation

public enum MusicLibraryContentOperation: String, CaseIterable, Equatable, Sendable {
    case list
    case rescan
    case createFolder
    case move
    case rename
    case remove

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "music.library.content.\(identifier)"),
            summary: summary, cli: ["music", cliVerb], effect: effect,
            requiresPreview: self == .remove)
    }

    public var cliVerb: String {
        switch self {
        case .list: "ls"
        case .rescan: "rescan"
        case .createFolder: "mkdir"
        case .move: "mv"
        case .rename: "rename"
        case .remove: "rm"
        }
    }

    private var identifier: String {
        switch self {
        case .createFolder: "folder.create"
        default: cliVerb
        }
    }

    private var summary: String {
        switch self {
        case .list: "List music library contents."
        case .rescan: "Rescan the music library."
        case .createFolder: "Create a music library folder."
        case .move: "Move a track into a folder."
        case .rename: "Rename a track or folder."
        case .remove: "Move a track or folder to the Trash."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .list, .rescan: .read
        case .createFolder, .move, .rename: .write
        case .remove: .destructive
        }
    }
}

public struct MusicLibraryContentListing: Equatable, Sendable {
    public let folder: MusicFolder
    public let folders: [MusicFolder]
    public let tracks: [Track]

    public init(folder: MusicFolder, folders: [MusicFolder], tracks: [Track]) {
        self.folder = folder
        self.folders = folders
        self.tracks = tracks
    }
}

public enum MusicLibraryRenameTarget: Equatable, Sendable {
    case track(Track)
    case folder(MusicFolder)
}

public enum MusicLibraryRemovalTarget: Equatable, Sendable {
    case track(Track)
    case folder(MusicFolder)
}

public struct MusicLibraryRemovalPlan: Equatable, Sendable {
    public let target: MusicLibraryRemovalTarget
    public let path: String
    public let trackCount: Int

    public init(target: MusicLibraryRemovalTarget, path: String, trackCount: Int) {
        self.target = target
        self.path = path
        self.trackCount = trackCount
    }
}

public enum MusicLibraryContentOperationExecution {
    public typealias Entries = (String) -> (folders: [MusicFolder], tracks: [Track])
    public typealias RecursiveTracks = (String) -> [Track]

    public static func list(
        _ folder: MusicFolder, recursive: Bool = false,
        entries: Entries = TrackMeta.entries,
        recursiveTracks: RecursiveTracks = TrackMeta.tracks
    ) -> MusicLibraryContentListing {
        let contents = entries(folder.relativePath)
        return MusicLibraryContentListing(
            folder: folder, folders: contents.folders,
            tracks: recursive ? recursiveTracks(folder.relativePath) : contents.tracks)
    }

    public static func rescan(
        invalidate: () -> Void = TrackMeta.invalidateCaches,
        scan: () -> [Track] = TrackMeta.scanMusicFolder
    ) -> [Track] {
        invalidate()
        return scan()
    }

    @discardableResult
    public static func createFolder(
        named name: String, under parent: String,
        create: (String, String) throws -> MusicFolder = {
            try MusicLibrary.createFolder(named: $0, under: $1)
        }
    ) throws -> MusicFolder {
        try create(name, parent)
    }

    @discardableResult
    public static func move(
        _ track: Track, to folder: String,
        move: (Track, String) throws -> MusicLibrary.Move = {
            try MusicLibrary.move($0, toFolder: $1)
        }
    ) throws -> MusicLibrary.Move {
        try move(track, folder)
    }

    @discardableResult
    public static func rename(
        _ target: MusicLibraryRenameTarget, to name: String,
        renameTrack: (Track, String) throws -> MusicLibrary.Move = {
            try MusicLibrary.rename($0, to: $1)
        },
        renameFolder: (MusicFolder, String) throws -> MusicLibrary.Move = {
            try MusicLibrary.renameFolder($0, to: $1)
        }
    ) throws -> MusicLibrary.Move {
        switch target {
        case let .track(track): try renameTrack(track, name)
        case let .folder(folder): try renameFolder(folder, name)
        }
    }

    public static func removalPlan(
        _ target: MusicLibraryRemovalTarget,
        trackCount: (String) -> Int = TrackMeta.trackCount
    ) -> MusicLibraryRemovalPlan {
        switch target {
        case let .track(track):
            MusicLibraryRemovalPlan(target: target, path: track.relativePath, trackCount: 1)
        case let .folder(folder):
            MusicLibraryRemovalPlan(
                target: target, path: folder.relativePath,
                trackCount: trackCount(folder.relativePath))
        }
    }

    @discardableResult
    public static func remove(
        _ target: MusicLibraryRemovalTarget,
        trashTrack: (Track) throws -> Void = MusicLibrary.trash,
        trashFolder: (MusicFolder) throws -> Void = MusicLibrary.trashFolder,
        trackCount: (String) -> Int = TrackMeta.trackCount
    ) throws -> MusicLibraryRemovalPlan {
        let plan = removalPlan(target, trackCount: trackCount)
        switch target {
        case let .track(track): try trashTrack(track)
        case let .folder(folder): try trashFolder(folder)
        }
        return plan
    }
}
