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
}

public struct TerminalFileLinks {
    public let directory: String
    public let fileExists: ((String) -> Bool)?
    public let reveal: (String) -> Void

    public init(
        directory: String, fileExists: ((String) -> Bool)?,
        reveal: @escaping (String) -> Void
    ) {
        self.directory = directory
        self.fileExists = fileExists
        self.reveal = reveal
    }

    public func path(for rawValue: String) -> String? {
        var value = Self.trimmed(rawValue)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        let lowercase = value.lowercased()
        if lowercase.hasPrefix("file://") {
            guard let url = URL(string: value), url.isFileURL else { return nil }
            value = url.path
        } else if lowercase.contains("://") || Self.isLoopbackAddress(lowercase) {
            return nil
        }
        let candidates = Self.withoutLocations(value)
        guard let fileExists else {
            guard let bare = candidates.last, Self.looksLikePath(bare) else { return nil }
            return absolute(bare)
        }
        return candidates.compactMap { absolute($0) }.first(where: fileExists)
    }

    private var expandsHome: Bool { fileExists != nil }

    private func absolute(_ value: String) -> String? {
        if value == "~" || value.hasPrefix("~/") {
            return expandsHome ? NSString(string: value).expandingTildeInPath : value
        }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardized.path }
        let base = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(value).standardized.path
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
