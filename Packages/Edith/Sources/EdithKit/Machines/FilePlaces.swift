import Foundation

public struct FilePlace: Identifiable, Equatable, Codable, Sendable {
    public var name: String
    public var path: String
    public var symbol: String

    public var id: String { path }

    public init(name: String, path: String, symbol: String) {
        self.name = name
        self.path = path
        self.symbol = symbol
    }
}

public struct FilePlaceSection: Identifiable, Equatable, Sendable {
    public var title: String
    public var places: [FilePlace]

    public var id: String { title }

    public init(title: String, places: [FilePlace]) {
        self.title = title
        self.places = places
    }
}

public enum FilePlaces {
    public static func localSections(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumes: [URL] = []
    ) -> [FilePlaceSection] {
        let favorites = [
            FilePlace(name: "Home", path: home.path, symbol: "house"),
            FilePlace(
                name: "Desktop", path: home.appendingPathComponent("Desktop").path,
                symbol: "menubar.dock.rectangle"),
            FilePlace(
                name: "Documents", path: home.appendingPathComponent("Documents").path,
                symbol: "doc"),
            FilePlace(
                name: "Downloads", path: home.appendingPathComponent("Downloads").path,
                symbol: "arrow.down.circle"),
            FilePlace(name: "Applications", path: "/Applications", symbol: "square.grid.2x2"),
        ]
        var sections = [FilePlaceSection(title: "Favorites", places: favorites)]
        let locations =
            [FilePlace(name: "Macintosh HD", path: "/", symbol: "internaldrive")]
            + volumes.map {
                FilePlace(name: $0.lastPathComponent, path: $0.path, symbol: "externaldrive")
            }
        sections.append(FilePlaceSection(title: "Locations", places: locations))
        return sections
    }

    public static func remoteSections(home: String, extras: [String] = [])
        -> [FilePlaceSection]
    {
        let favorites = [
            FilePlace(name: "Home", path: home, symbol: "house"),
            FilePlace(name: "Desktop", path: home + "/Desktop", symbol: "menubar.dock.rectangle"),
            FilePlace(name: "Documents", path: home + "/Documents", symbol: "doc"),
            FilePlace(name: "Downloads", path: home + "/Downloads", symbol: "arrow.down.circle"),
        ]
        var system = [
            FilePlace(name: "Root", path: "/", symbol: "internaldrive"),
            FilePlace(name: "etc", path: "/etc", symbol: "gearshape"),
            FilePlace(name: "var/log", path: "/var/log", symbol: "doc.text"),
            FilePlace(name: "tmp", path: "/tmp", symbol: "clock"),
            FilePlace(name: "Media", path: "/media", symbol: "externaldrive"),
        ]
        system.append(
            contentsOf: extras.map {
                FilePlace(name: ($0 as NSString).lastPathComponent, path: $0, symbol: "folder")
            })
        return [
            FilePlaceSection(title: "Favorites", places: favorites),
            FilePlaceSection(title: "System", places: system),
        ]
    }

    public static func homeDirectoryCommand() -> String {
        "echo $HOME"
    }
}

public enum FileClipboardOperation: String, Equatable, Sendable {
    case copy
    case move
}

public struct FileClipboard: Equatable, Sendable {
    public var paths: [String]
    public var machineID: UUID
    public var operation: FileClipboardOperation

    public init(paths: [String], machineID: UUID, operation: FileClipboardOperation) {
        self.paths = paths
        self.machineID = machineID
        self.operation = operation
    }

    public func command(intoDirectory directory: String) -> String? {
        guard !paths.isEmpty else { return nil }
        switch operation {
        case .copy:
            return FileOperations.copyCommand(paths: paths, toDirectory: directory)
        case .move:
            return FileOperations.moveCommand(paths: paths, toDirectory: directory)
        }
    }
}

public struct FileInfoSummary: Equatable, Sendable {
    public var name: String
    public var path: String
    public var kind: String
    public var size: String
    public var modified: String
    public var permissions: String
    public var linkTarget: String?

    public init(entry: RemoteFileEntry, sizeOverride: String? = nil) {
        name = entry.name
        path = entry.path
        kind = entry.kindDescription
        size = sizeOverride ?? (entry.isDirectory ? "—" : ByteFormatter.string(entry.sizeBytes))
        modified =
            entry.modified.map { $0.formatted(date: .long, time: .standard) } ?? "Unknown"
        permissions = FileInfoSummary.describe(mode: entry.mode)
        linkTarget = entry.linkTarget
    }

    public static func describe(mode: String) -> String {
        let digits = mode.filter(\.isNumber)
        guard digits.count == 3 || digits.count == 4, let value = Int(digits, radix: 8) else {
            return mode.isEmpty ? "Unknown" : mode
        }
        let owner = (value >> 6) & 7
        let group = (value >> 3) & 7
        let other = value & 7
        return "\(digits)  ·  \(rwx(owner))\(rwx(group))\(rwx(other))"
    }

    private static func rwx(_ bits: Int) -> String {
        let read = bits & 4 != 0 ? "r" : "-"
        let write = bits & 2 != 0 ? "w" : "-"
        let execute = bits & 1 != 0 ? "x" : "-"
        return read + write + execute
    }
}

public enum RenameSelection {
    public static func baseNameRange(of name: String) -> Range<String.Index>? {
        let nsName = name as NSString
        let base = nsName.deletingPathExtension
        guard !base.isEmpty, base != name, let range = name.range(of: base) else { return nil }
        return range
    }

    public static func isValid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("/") && trimmed != "." && trimmed != ".."
    }
}
