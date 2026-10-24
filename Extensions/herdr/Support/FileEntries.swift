import Foundation

public enum FileEntryKind: String, Codable, Equatable, Sendable {
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

public struct RemoteFileEntry: Codable, Identifiable, Equatable, Sendable {
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
    public var isHidden: Bool { name.hasPrefix(".") || mode.contains("Hidden") }
}

public enum WindowsFileCommands {
    public static func list(_ path: String) -> String {
        let value = PowerShell.literal(path)
        let separator = FileListing.separator
        return PowerShell.command(
            "$path=\(value); Get-ChildItem -LiteralPath $path -Force | ForEach-Object { "
                + "$kind=if ($_.PSIsContainer) {'d'} elseif ($_.Attributes -band "
                + "[IO.FileAttributes]::ReparsePoint) {'l'} else {'f'}; "
                + "$size=if ($_.PSIsContainer) {0} else {$_.Length}; "
                + "$epoch=([DateTimeOffset]$_.LastWriteTimeUtc).ToUnixTimeSeconds(); "
                + "$target=if ($_.Target) {$_.Target -join ','} else {''}; "
                + "[Console]::Out.WriteLine($kind+'\(separator)'+$size+'\(separator)'"
                + "+$epoch+'\(separator)'+$_.Attributes+'\(separator)'+$_.Name"
                + "+'\(separator)'+$target) }")
    }
}

extension FileListing {
    public static let separator = "\u{1F}"

    public static func command(path: String, platform: RemoteMachinePlatform) -> String {
        if platform == .windows { return WindowsFileCommands.list(path) }
        let quoted = ShellQuote.quote(path)
        let printf = "%y\(separator)%s\(separator)%T@\(separator)%m\(separator)%f\(separator)%l\\n"
        let find = "find \(quoted) -mindepth 1 -maxdepth 1 -printf \(ShellQuote.quote(printf))"
        let fallback = "ls -lAn --time-style=+%s \(quoted)"
        return "\(find) 2>/dev/null || \(fallback) 2>/dev/null"
    }

    public static func parse(output: String, parent: String) -> [RemoteFileEntry] {
        let lines = output.split(whereSeparator: \Character.isNewline).map(String.init)
        let findEntries = lines.compactMap { parseFindLine($0, parent: parent) }
        if !findEntries.isEmpty { return sorted(findEntries) }
        return sorted(lines.compactMap { parseLSLine($0, parent: parent) })
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
