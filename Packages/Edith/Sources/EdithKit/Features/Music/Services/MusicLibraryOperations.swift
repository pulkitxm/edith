import AppKit
import EdithCore
import Foundation

public enum MusicLibraryOperation: String, CaseIterable, Sendable {
    case favorite
    case unfavorite
    case reveal
    case open

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "music.library.\(rawValue)"),
            summary: summary, cli: ["music", rawValue], effect: effect)
    }

    private var summary: String {
        switch self {
        case .favorite: return "Add a track to favourites."
        case .unfavorite: return "Remove a track from favourites."
        case .reveal: return "Reveal a track in Finder."
        case .open: return "Open the music library in Finder."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .favorite, .unfavorite: return .write
        case .reveal, .open: return .interactive
        }
    }
}

public struct MusicFavouriteResult: Equatable, Sendable {
    public let path: String
    public let isFavourite: Bool
    public let changed: Bool

    public init(path: String, isFavourite: Bool, changed: Bool) {
        self.path = path
        self.isFavourite = isFavourite
        self.changed = changed
    }
}

public enum MusicLibraryOperationExecution {
    public static func setFavourite(
        _ operation: MusicLibraryOperation, path: String,
        contains: (String) -> Bool = Favourites.contains,
        set: (String, Bool) -> Bool = Favourites.set
    ) -> MusicFavouriteResult {
        let wanted = operation == .favorite
        let before = contains(path)
        let changed = before == wanted ? false : set(path, wanted)
        return MusicFavouriteResult(path: path, isFavourite: wanted, changed: changed)
    }

    @MainActor
    @discardableResult
    public static func reveal(
        _ url: URL,
        using reveal: @MainActor ([URL]) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting($0)
        }
    ) -> URL {
        reveal([url])
        return url
    }

    @MainActor
    @discardableResult
    public static func openLibrary(
        _ url: URL = Repo.musicDir,
        createDirectory: (URL) throws -> Void = {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        },
        using open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) throws -> URL {
        try createDirectory(url)
        _ = open(url)
        return url
    }
}
