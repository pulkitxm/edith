import EdithExtensionCore
import EdithIcons
import Foundation

public struct FilePlace: Identifiable, Equatable, Codable, Sendable {
    public var name: String
    public var path: String
    public var icon: EdithIcon

    public var id: String { path }

    public init(name: String, path: String, icon: EdithIcon) {
        self.name = name
        self.path = path
        self.icon = icon
    }

    private enum CodingKeys: String, CodingKey {
        case name, path, icon
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        icon = try container.decodeIfPresent(EdithIcon.self, forKey: .icon) ?? .folder
    }
}

public struct FilePlaceSection: Codable, Identifiable, Equatable, Sendable {
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
            FilePlace(name: "Home", path: home.path, icon: .home),
            FilePlace(
                name: "Desktop", path: home.appendingPathComponent("Desktop").path,
                icon: .menuBar),
            FilePlace(
                name: "Documents", path: home.appendingPathComponent("Documents").path,
                icon: .doc),
            FilePlace(
                name: "Downloads", path: home.appendingPathComponent("Downloads").path,
                icon: .arrowDown),
            FilePlace(name: "Applications", path: "/Applications", icon: .grid),
        ]
        var sections = [FilePlaceSection(title: "Favorites", places: favorites)]
        let locations =
            [FilePlace(name: "Macintosh HD", path: "/", icon: .drive)]
            + volumes.map {
                FilePlace(name: $0.lastPathComponent, path: $0.path, icon: .drive)
            }
        sections.append(FilePlaceSection(title: "Locations", places: locations))
        return sections
    }

    public static func remoteSections(
        home: String, extras: [String] = [], platform: RemoteMachinePlatform = .linux
    )
        -> [FilePlaceSection]
    {
        let favorites = [
            FilePlace(name: "Home", path: home, icon: .home),
            FilePlace(
                name: "Desktop", path: FileListing.join(parent: home, name: "Desktop"),
                icon: .menuBar),
            FilePlace(
                name: "Documents", path: FileListing.join(parent: home, name: "Documents"),
                icon: .doc),
            FilePlace(
                name: "Downloads", path: FileListing.join(parent: home, name: "Downloads"),
                icon: .arrowDown),
        ]
        var system =
            platform == .windows
            ? [
                FilePlace(
                    name: "Windows", path: String(home.prefix(3)), icon: .drive)
            ]
            : [
                FilePlace(name: "Root", path: "/", icon: .drive),
                FilePlace(name: "etc", path: "/etc", icon: .gear),
                FilePlace(name: "var/log", path: "/var/log", icon: .docText),
                FilePlace(name: "tmp", path: "/tmp", icon: .clock),
                FilePlace(name: "Media", path: "/media", icon: .drive),
            ]
        system.append(
            contentsOf: extras.map {
                FilePlace(name: ($0 as NSString).lastPathComponent, path: $0, icon: .folder)
            })
        return [
            FilePlaceSection(title: "Favorites", places: favorites),
            FilePlaceSection(title: "System", places: system),
        ]
    }

    public static func homeDirectoryCommand(
        platform: RemoteMachinePlatform = .linux
    ) -> String {
        platform == .windows ? WindowsFileCommands.home() : "echo $HOME"
    }
}

public enum FileClipboardOperation: String, Codable, Equatable, Sendable {
    case copy
    case move
}

public struct FileClipboard: Codable, Equatable, Sendable {
    public var paths: [String]
    public var machineID: UUID
    public var operation: FileClipboardOperation

    public init(paths: [String], machineID: UUID, operation: FileClipboardOperation) {
        self.paths = paths
        self.machineID = machineID
        self.operation = operation
    }

    public func command(
        intoDirectory directory: String, platform: RemoteMachinePlatform = .linux
    ) -> String? {
        guard !paths.isEmpty else { return nil }
        switch operation {
        case .copy:
            return FileOperations.copyCommand(
                paths: paths, toDirectory: directory, platform: platform)
        case .move:
            return FileOperations.moveCommand(
                paths: paths, toDirectory: directory, platform: platform)
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
        size =
            sizeOverride ?? (entry.isDirectory ? "\u{2014}" : ByteFormatter.string(entry.sizeBytes))
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
        return !trimmed.isEmpty && !trimmed.contains("/") && !trimmed.contains("\\")
            && trimmed != "." && trimmed != ".."
    }
}
