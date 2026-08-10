import Foundation

public enum MusicLibraryError: Error, Equatable {
    case emptyName
    case alreadyThere(String)
    case noSuchTrack(String)
    case noSuchFolder(String)
    case failed(String)
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
        let url = TrackMeta.url(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MusicLibraryError.noSuchTrack(relativePath)
        }
        return Track(url: url, relativePath: relativePath)
    }

    public static func folder(at relativePath: String) throws -> MusicFolder {
        guard !relativePath.isEmpty else {
            return MusicFolder(url: TrackMeta.url(for: ""), relativePath: "")
        }
        let url = TrackMeta.url(for: relativePath)
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
        do {
            try FileManager.default.trashItem(at: track.url, resultingItemURL: nil)
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
        let base = sanitized(name)
        guard !base.isEmpty else { throw MusicLibraryError.emptyName }
        let destination = folder.url.deletingLastPathComponent().appendingPathComponent(base)
        return try relocate(from: folder.url, to: destination)
    }

    public static func trashFolder(_ folder: MusicFolder) throws {
        guard !folder.relativePath.isEmpty else {
            throw MusicLibraryError.failed("the library root cannot be removed")
        }
        do {
            try FileManager.default.trashItem(at: folder.url, resultingItemURL: nil)
        } catch {
            throw MusicLibraryError.failed(error.localizedDescription)
        }
    }

    @discardableResult
    public static func relocate(from source: URL, to destination: URL) throws -> Move {
        let from = TrackMeta.relativePath(of: source)
        let to = TrackMeta.relativePath(of: destination)
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
}
