import Foundation

public enum MusicLibraryError: LocalizedError, Equatable {
    case emptyName
    case alreadyThere(String)
    case noSuchTrack(String)
    case noSuchFolder(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "a name cannot be blank"
        case let .alreadyThere(path): "\(path) is already there"
        case let .noSuchTrack(path): "no track exists at \(path)"
        case let .noSuchFolder(path): "no folder exists at \(path)"
        case let .failed(message): message
        }
    }
}

public enum MusicLibrary {
    public struct Move: Sendable, Equatable {
        public let from: String
        public let to: String
    }

    public static func sanitized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    public static func track(at relativePath: String) throws -> Track {
        try track(at: relativePath, root: Repo.musicDir)
    }

    static func track(at relativePath: String, root: URL) throws -> Track {
        let url = try validatedLibraryURL(
            TrackMeta.url(for: relativePath, base: root.standardizedFileURL.path), root: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            TrackMeta.playableExtensions.contains(url.pathExtension.lowercased())
        else {
            throw MusicLibraryError.noSuchTrack(relativePath)
        }
        return Track(url: url, relativePath: relativePath)
    }

    public static func folder(at relativePath: String) throws -> MusicFolder {
        try folder(at: relativePath, root: Repo.musicDir)
    }

    static func folder(at relativePath: String, root: URL) throws -> MusicFolder {
        guard !relativePath.isEmpty else {
            return MusicFolder(url: root.standardizedFileURL, relativePath: "")
        }
        let url = try validatedLibraryURL(
            TrackMeta.url(for: relativePath, base: root.standardizedFileURL.path), root: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw MusicLibraryError.noSuchFolder(relativePath) }
        return MusicFolder(url: url, relativePath: relativePath)
    }

    @discardableResult
    public static func rename(_ track: Track, to name: String) throws -> Move {
        let base = sanitized(name)
        guard !base.isEmpty else { throw MusicLibraryError.emptyName }
        let ext = track.url.pathExtension
        let destination = track.url.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        return try relocate(from: track.url, to: destination)
    }

    @discardableResult
    public static func move(_ track: Track, toFolder relativePath: String) throws -> Move {
        let folder = try folder(at: relativePath)
        let destination = folder.url.appendingPathComponent(track.url.lastPathComponent)
        return try relocate(from: track.url, to: destination)
    }

    public static func trash(_ track: Track) throws {
        try trash(track, root: Repo.musicDir)
    }

    static func trash(_ track: Track, root: URL) throws {
        let url = try validatedLibraryURL(track.url, root: root)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            throw MusicLibraryError.failed(error.localizedDescription)
        }
    }

    @discardableResult
    public static func createFolder(named name: String, under parent: String = "") throws
        -> MusicFolder
    {
        let base = sanitized(name)
        guard !base.isEmpty else { throw MusicLibraryError.emptyName }
        let directory = try folder(at: parent).url.appendingPathComponent(base)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw MusicLibraryError.alreadyThere(TrackMeta.relativePath(of: directory))
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw MusicLibraryError.failed(error.localizedDescription)
        }
        return MusicFolder(
            url: directory, relativePath: TrackMeta.relativePath(of: directory))
    }

    @discardableResult
    public static func renameFolder(_ folder: MusicFolder, to name: String) throws -> Move {
        guard !folder.relativePath.isEmpty else {
            throw MusicLibraryError.failed("the library root cannot be renamed")
        }
        let base = sanitized(name)
        guard !base.isEmpty else { throw MusicLibraryError.emptyName }
        let destination = folder.url.deletingLastPathComponent().appendingPathComponent(base)
        return try relocate(from: folder.url, to: destination)
    }

    public static func trashFolder(_ folder: MusicFolder) throws {
        try trashFolder(folder, root: Repo.musicDir)
    }

    static func trashFolder(_ folder: MusicFolder, root: URL) throws {
        guard !folder.relativePath.isEmpty else {
            throw MusicLibraryError.failed("the library root cannot be removed")
        }
        let url = try validatedLibraryURL(folder.url, root: root)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            throw MusicLibraryError.failed(error.localizedDescription)
        }
    }

    @discardableResult
    public static func relocate(from source: URL, to destination: URL) throws -> Move {
        try relocate(from: source, to: destination, root: Repo.musicDir)
    }

    @discardableResult
    static func relocate(from source: URL, to destination: URL, root: URL) throws -> Move {
        let source = try validatedLibraryURL(source, root: root)
        let destination = try validatedLibraryURL(destination, root: root)
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let from = TrackMeta.relativePath(of: source, base: base)
        let to = TrackMeta.relativePath(of: destination, base: base)
        guard destination != source else { throw MusicLibraryError.alreadyThere(to) }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MusicLibraryError.alreadyThere(to)
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw MusicLibraryError.failed(error.localizedDescription)
        }
        Favourites.repoint(from: from, to: to)
        return Move(from: from, to: to)
    }

    static func validatedLibraryURL(_ url: URL, root: URL, allowsRoot: Bool = false) throws -> URL {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path
        let path = resolved.path
        let isDescendant =
            rootPath == "/" ? path.hasPrefix("/") && path != "/" : path.hasPrefix(rootPath + "/")
        guard isDescendant || allowsRoot && path == rootPath else {
            throw MusicLibraryError.failed("\(url.path) is outside the music library")
        }
        return resolved
    }
}
