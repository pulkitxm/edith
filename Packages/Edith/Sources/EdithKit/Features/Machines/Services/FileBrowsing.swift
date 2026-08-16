import Foundation

public enum FileSortKey: String, CaseIterable, Codable, Sendable {
    case name
    case size
    case modified
    case kind

    public var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Date Modified"
        case .kind: return "Kind"
        }
    }
}

public enum FileViewMode: String, CaseIterable, Codable, Sendable {
    case icon
    case list

    public var title: String {
        switch self {
        case .icon: return "Icons"
        case .list: return "List"
        }
    }

    public var symbol: String {
        switch self {
        case .icon: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

public enum FileSorting {
    public static func sort(
        _ entries: [RemoteFileEntry], by key: FileSortKey, ascending: Bool,
        foldersFirst: Bool = true
    ) -> [RemoteFileEntry] {
        entries.sorted { lhs, rhs in
            if foldersFirst, lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let ordered = compare(lhs, rhs, key: key)
            if ordered == .orderedSame {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return ascending ? ordered == .orderedAscending : ordered == .orderedDescending
        }
    }

    static func compare(
        _ lhs: RemoteFileEntry, _ rhs: RemoteFileEntry, key: FileSortKey
    ) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case .size:
            if lhs.sizeBytes == rhs.sizeBytes { return .orderedSame }
            return lhs.sizeBytes < rhs.sizeBytes ? .orderedAscending : .orderedDescending
        case .modified:
            let left = lhs.modified ?? .distantPast
            let right = rhs.modified ?? .distantPast
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        case .kind:
            let ordered = lhs.kindDescription.localizedCaseInsensitiveCompare(
                rhs.kindDescription)
            return ordered
        }
    }
}

extension RemoteFileEntry {
    public var kindDescription: String {
        if isDirectory { return "Folder" }
        if kind == .symlink { return "Alias" }
        let ext = fileExtension
        guard !ext.isEmpty else { return "Document" }
        return ext.uppercased() + " file"
    }
}

public enum FileSelectionMath {
    public static func rangeSelection(
        in entries: [RemoteFileEntry], from anchor: String?, to target: String
    ) -> Set<String> {
        guard let anchor,
            let start = entries.firstIndex(where: { $0.path == anchor }),
            let end = entries.firstIndex(where: { $0.path == target })
        else { return [target] }
        let bounds = start <= end ? start...end : end...start
        return Set(entries[bounds].map(\.path))
    }

    public static func toggled(_ selection: Set<String>, path: String) -> Set<String> {
        var next = selection
        if next.contains(path) {
            next.remove(path)
        } else {
            next.insert(path)
        }
        return next
    }

    public static func typeSelectMatch(
        in entries: [RemoteFileEntry], prefix: String, after current: String?
    ) -> String? {
        guard !prefix.isEmpty else { return nil }
        let matches = entries.filter {
            $0.name.lowercased().hasPrefix(prefix.lowercased())
        }
        guard !matches.isEmpty else { return nil }
        guard let current, let index = matches.firstIndex(where: { $0.path == current }),
            prefix.count == 1
        else { return matches.first?.path }
        return matches[(index + 1) % matches.count].path
    }
}

public enum FileOperations {
    public static func newFolderName(existing: [RemoteFileEntry]) -> String {
        let taken = Set(existing.map(\.name))
        guard taken.contains("untitled folder") else { return "untitled folder" }
        var index = 2
        while taken.contains("untitled folder \(index)") { index += 1 }
        return "untitled folder \(index)"
    }

    public static func duplicateName(of name: String, existing: [RemoteFileEntry]) -> String {
        let taken = Set(existing.map(\.name))
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = "\(base) copy\(suffix)"
        var index = 2
        while taken.contains(candidate) {
            candidate = "\(base) copy \(index)\(suffix)"
            index += 1
        }
        return candidate
    }

    public static func trashCommand(paths: [String]) -> String {
        let trashFiles = "$HOME/.local/share/Trash/files"
        let trashInfo = "$HOME/.local/share/Trash/info"
        var lines = ["mkdir -p \(trashFiles) \(trashInfo)"]
        for path in paths {
            let quoted = ShellQuote.quote(path)
            let base = "$(basename \(quoted))"
            let stamp = "$(date +%Y-%m-%dT%H:%M:%S)"
            let target = "\(trashFiles)/\(base)"
            lines.append(
                "n=\(ShellQuote.quote("")); t=\"\(target)\"; "
                    + "if [ -e \"$t\" ]; then t=\"$t.$(date +%s)\"; fi; "
                    + "printf '[Trash Info]\\nPath=%s\\nDeletionDate=%s\\n' \(quoted) \(stamp) "
                    + "> \"\(trashInfo)/$(basename \"$t\").trashinfo\" && "
                    + "mv \(quoted) \"$t\"")
        }
        return lines.joined(separator: "; ")
    }

    public static func deleteCommand(paths: [String]) -> String {
        "rm -rf " + paths.map(ShellQuote.quote).joined(separator: " ")
    }

    public static func copyCommand(paths: [String], toDirectory directory: String) -> String {
        "cp -a " + paths.map(ShellQuote.quote).joined(separator: " ") + " "
            + ShellQuote.quote(directory)
    }

    public static func moveCommand(paths: [String], toDirectory directory: String) -> String {
        "mv " + paths.map(ShellQuote.quote).joined(separator: " ") + " "
            + ShellQuote.quote(directory)
    }

    public static func renameCommand(
        path: String, to newPath: String, viaTemporary: Bool = false
    ) -> String {
        let source = ShellQuote.quote(path)
        let destination = ShellQuote.quote(newPath)
        guard viaTemporary else {
            return "if [ -e \(destination) ]; then exit 17; fi; mv \(source) \(destination)"
        }
        let staging = ShellQuote.quote(path + ".edith-rename")
        return "mv \(source) \(staging) && mv \(staging) \(destination)"
    }

    public static func makeDirectoryCommand(path: String) -> String {
        "mkdir -p \(ShellQuote.quote(path))"
    }

    public static func directorySizeCommand(path: String) -> String {
        "du -sk \(ShellQuote.quote(path)) 2>/dev/null | cut -f1"
    }

    public static func freeSpaceCommand(path: String) -> String {
        "df -Pk \(ShellQuote.quote(path)) 2>/dev/null | awk 'NR==2 {print $4}'"
    }

    public static func searchCommand(path: String, query: String, limit: Int = 300) -> String {
        "find \(ShellQuote.quote(path)) -iname \(ShellQuote.quote("*\(query)*")) "
            + "-not -path '*/.git/*' 2>/dev/null | head -\(limit)"
    }
}

public enum FinderMoveDirection: Equatable, Sendable {
    case up
    case down
    case left
    case right
}
