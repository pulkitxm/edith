import Foundation

public enum FileEntryKind: String, Equatable, Sendable {
    case directory
    case file
    case symlink
    case other

    public init(findType: String) {
        switch findType {
        case "d": self = .directory
        case "f": self = .file
        case "l": self = .symlink
        default: self = .other
        }
    }
}

public struct RemoteFileEntry: Identifiable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var kind: FileEntryKind
    public var sizeBytes: Int64
    public var modified: Date?
    public var mode: String
    public var linkTarget: String?

    public var id: String { path }

    public init(
        name: String, path: String, kind: FileEntryKind, sizeBytes: Int64,
        modified: Date? = nil, mode: String = "", linkTarget: String? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modified = modified
        self.mode = mode
        self.linkTarget = linkTarget
    }

    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }

    public var fileExtension: String {
        let standard = (name as NSString).pathExtension.lowercased()
        guard standard.isEmpty, name.hasPrefix("."), name.count > 1 else { return standard }
        return String(name.dropFirst()).lowercased()
    }
}

public enum FileListing {
    public static let separator = "\u{1F}"

    public static func command(path: String, showHidden: Bool) -> String {
        let quoted = ShellQuote.quote(path)
        let printf = "%y\(separator)%s\(separator)%T@\(separator)%m\(separator)%f\(separator)%l\\n"
        let find =
            "find \(quoted) -mindepth 1 -maxdepth 1 -printf \(ShellQuote.quote(printf))"
        let fallback = "ls -lAn --time-style=+%s \(quoted)"
        return "\(find) 2>/dev/null || \(fallback) 2>/dev/null"
    }

    public static func parse(output: String, parent: String) -> [RemoteFileEntry] {
        let lines = output.split(separator: "\n").map(String.init)
        let findEntries = lines.compactMap { parseFindLine($0, parent: parent) }
        if !findEntries.isEmpty { return sorted(findEntries) }
        return sorted(lines.compactMap { parseLSLine($0, parent: parent) })
    }

    public static func join(parent: String, name: String) -> String {
        if parent == "/" { return "/" + name }
        return parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    public static func parentPath(of path: String) -> String? {
        guard path != "/" else { return nil }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return nil }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    public static func breadcrumbs(for path: String) -> [(name: String, path: String)] {
        guard path.hasPrefix("/") else { return [] }
        var crumbs: [(String, String)] = [("/", "/")]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            crumbs.append((String(component), current))
        }
        return crumbs
    }

    static func parseFindLine(_ line: String, parent: String) -> RemoteFileEntry? {
        let fields = line.components(separatedBy: separator)
        guard fields.count >= 5 else { return nil }
        let kind = FileEntryKind(findType: fields[0])
        let name = fields[4]
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let target = fields.count > 5 && !fields[5].isEmpty ? fields[5] : nil
        return RemoteFileEntry(
            name: name, path: join(parent: parent, name: name), kind: kind,
            sizeBytes: Int64(fields[1]) ?? 0,
            modified: Double(fields[2]).map { Date(timeIntervalSince1970: $0) },
            mode: fields[3], linkTarget: target)
    }

    static func parseLSLine(_ line: String, parent: String) -> RemoteFileEntry? {
        guard let first = line.first, "-dlbcps".contains(first) else { return nil }
        let epochFields = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard epochFields.count == 7 else { return nil }
        let stampsAreEpoch = Double(epochFields[5]) != nil
        let nameIndex = stampsAreEpoch ? 6 : 8
        let fields =
            stampsAreEpoch
            ? epochFields
            : line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count == nameIndex + 1 else { return nil }
        var name = String(fields[nameIndex])
        var target: String?
        if first == "l", let range = name.range(of: " -> ") {
            target = String(name[range.upperBound...])
            name = String(name[..<range.lowerBound])
        }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let kind: FileEntryKind =
            first == "d" ? .directory : (first == "l" ? .symlink : (first == "-" ? .file : .other))
        return RemoteFileEntry(
            name: name, path: join(parent: parent, name: name), kind: kind,
            sizeBytes: Int64(fields[4]) ?? 0,
            modified: stampsAreEpoch
                ? Double(fields[5]).map { Date(timeIntervalSince1970: $0) } : nil,
            mode: String(fields[0]), linkTarget: target)
    }

    static func sorted(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

public enum FilePreviewKind: Equatable, Sendable {
    case text
    case image
    case pdf
    case media
    case quickLook
    case unsupported

    public static func kind(forExtension ext: String) -> FilePreviewKind {
        let lowered = ext.lowercased()
        if textExtensions.contains(lowered) { return .text }
        if imageExtensions.contains(lowered) { return .image }
        if lowered == "pdf" { return .pdf }
        if mediaExtensions.contains(lowered) { return .media }
        if unsupportedMediaExtensions.contains(lowered) { return .unsupported }
        return .quickLook
    }

    public static func isPlainTextName(_ name: String) -> Bool {
        let lowered = (name as NSString).lastPathComponent.lowercased()
        return extensionlessTextNames.contains(lowered)
    }

    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rst", "log", "json", "jsonl", "yml", "yaml", "toml", "ini",
        "cfg", "conf", "env", "xml", "html", "htm", "css", "scss", "less", "js", "mjs", "cjs",
        "jsx", "ts", "tsx", "swift", "py", "rb", "go", "rs", "java", "kt", "kts", "c", "h",
        "cpp", "cc", "hpp", "cs", "php", "pl", "lua", "sh", "bash", "zsh", "fish", "sql",
        "graphql", "proto", "dockerfile", "gradle", "tf", "hcl", "vim", "diff", "patch", "csv",
        "tsv", "svelte", "vue", "astro", "ex", "exs", "erl", "hs", "scala", "clj", "r", "m",
        "mm", "gitignore", "editorconfig", "properties", "service", "socket", "timer", "rules",
    ]

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "ico", "icns",
    ]

    static let mediaExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf",
    ]

    static let unsupportedMediaExtensions: Set<String> = [
        "mkv", "webm", "avi", "flv", "wmv", "ogv", "ogg", "opus", "3gp", "mpg", "mpeg",
    ]

    static let extensionlessTextNames: Set<String> = [
        "dockerfile", "makefile", "readme", "license", "changelog", "authors", "notice",
        "procfile", "gemfile", "rakefile", "vagrantfile", "brewfile", "justfile",
    ]
}

public enum ByteFormatter {
    public static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 { return "\(Int(value)) B" }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        string(Int64(max(0, bytesPerSecond))) + "/s"
    }

    public static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

public enum FilePathKey {
    public static func canonical(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }

    public static func anchor(_ path: String, to root: String) -> String {
        let canonicalPath = canonical(path)
        let canonicalRoot = canonical(root)
        guard canonicalRoot != root, canonicalPath.hasPrefix(canonicalRoot) else {
            return canonicalPath
        }
        return root + canonicalPath.dropFirst(canonicalRoot.count)
    }
}
