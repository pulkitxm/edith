import Foundation

enum TerminalLinkTarget: Equatable {
    case url(URL)
    case file(String)

    var openTitle: String {
        switch self {
        case .url: "Open Link"
        case .file: "Show in Files"
        }
    }

    var revealsFile: Bool {
        if case .file = self { true } else { false }
    }
}

public struct TerminalFileSystem {
    public let fileExists: (String) -> Bool
    public let contents: (String) -> [String]

    public init(fileExists: @escaping (String) -> Bool, contents: @escaping (String) -> [String]) {
        self.fileExists = fileExists
        self.contents = contents
    }

    public static let local = TerminalFileSystem(
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        contents: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] })
}

public struct TerminalFileLinks {
    public static let elision: Character = "…"

    public let directory: String
    public let fileSystem: TerminalFileSystem?
    public let reveal: (String) -> Void

    public init(
        directory: String, fileSystem: TerminalFileSystem?,
        reveal: @escaping (String) -> Void
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.reveal = reveal
    }

    public func path(for rawValue: String, reportedDirectory: String? = nil) -> String? {
        var value = Self.trimmed(rawValue)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        let lowercase = value.lowercased()
        if lowercase.hasPrefix("file://") {
            guard let url = URL(string: value), url.isFileURL else { return nil }
            value = url.path
        } else if lowercase.contains("://") || Self.isLoopbackAddress(lowercase) {
            return nil
        }
        let leadingElided = value.first == Self.elision
        if leadingElided {
            value.removeFirst()
            while value.first == "/" { value.removeFirst() }
        }
        let trailingElided = value.last == Self.elision
        if trailingElided { value.removeLast() }
        guard !value.isEmpty, !value.contains(Self.elision) else { return nil }
        let spellings = trailingElided ? [value] : Self.withoutLocations(value)
        guard let fileSystem else {
            guard let bare = spellings.last, Self.looksLikePath(bare),
                let path = absolute(bare, base: directory, relative: leadingElided)
            else { return nil }
            return trailingElided ? path + String(Self.elision) : path
        }
        for base in bases(reportedDirectory: reportedDirectory, fileSystem: fileSystem) {
            for spelling in spellings {
                guard let path = absolute(spelling, base: base, relative: leadingElided)
                else { continue }
                if trailingElided {
                    if let match = Self.prefixMatch(path, fileSystem: fileSystem) { return match }
                } else if fileSystem.fileExists(path) {
                    return path
                }
            }
        }
        return nil
    }

    private func bases(reportedDirectory: String?, fileSystem: TerminalFileSystem) -> [String] {
        var bases: [String] = []
        for candidate in [reportedDirectory, directory].compactMap({ $0 }) {
            let base = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard base.hasPrefix("/") else { continue }
            let standardized = URL(fileURLWithPath: base).standardized.path
            for folder in [standardized, Self.gitRoot(above: standardized, fileSystem: fileSystem)]
            {
                if let folder, !bases.contains(folder) { bases.append(folder) }
            }
        }
        return bases.isEmpty ? [""] : bases
    }

    private func absolute(_ value: String, base: String, relative: Bool) -> String? {
        if !relative {
            if value == "~" || value.hasPrefix("~/") {
                return fileSystem == nil ? value : NSString(string: value).expandingTildeInPath
            }
            if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardized.path }
        }
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(value).standardized.path
    }

    static func prefixMatch(_ path: String, fileSystem: TerminalFileSystem) -> String? {
        let url = URL(fileURLWithPath: path)
        let stem = url.lastPathComponent
        let parent = url.deletingLastPathComponent().path
        guard !stem.isEmpty,
            let name = fileSystem.contents(parent).filter({ $0.hasPrefix(stem) }).sorted().first
        else { return nil }
        return URL(fileURLWithPath: parent).appendingPathComponent(name).path
    }

    static func gitRoot(above directory: String, fileSystem: TerminalFileSystem) -> String? {
        var folder = directory
        while true {
            if fileSystem.fileExists((folder as NSString).appendingPathComponent(".git")) {
                return folder == directory ? nil : folder
            }
            let parent = (folder as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != folder else { return nil }
            folder = parent
        }
    }

    static func trimmed(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("`", "`"), ("<", ">"), ("(", ")"), ("[", "]"),
        ]
        var previous: String?
        while previous != value {
            previous = value
            while let last = value.last, ".,;:!?".contains(last) { value.removeLast() }
            for wrapper in wrappers
            where value.count > 1 && value.first == wrapper.0 && value.last == wrapper.1 {
                value.removeFirst()
                value.removeLast()
            }
        }
        return value
    }

    static func isLoopbackAddress(_ lowercase: String) -> Bool {
        lowercase.hasPrefix("localhost:") || lowercase.hasPrefix("127.0.0.1:")
            || lowercase.hasPrefix("[::1]:")
    }

    static func withoutLocations(_ value: String) -> [String] {
        var candidates = [value]
        var components = value.split(separator: ":", omittingEmptySubsequences: false)
        while components.count > 1, Int(components.last ?? "") != nil {
            components.removeLast()
            candidates.append(components.joined(separator: ":"))
        }
        return candidates
    }

    static func looksLikePath(_ value: String) -> Bool {
        guard value != "/", value != "~", !value.allSatisfy({ $0 == "." || $0 == "/" }) else {
            return false
        }
        if value.contains("/") { return true }
        let name = value as NSString
        let pathExtension = name.pathExtension
        return !name.deletingPathExtension.isEmpty && !pathExtension.isEmpty
            && pathExtension.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
