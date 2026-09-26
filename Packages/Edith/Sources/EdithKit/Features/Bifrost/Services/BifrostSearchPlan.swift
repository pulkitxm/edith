import EdithCore
import Foundation

public enum BifrostSearchTarget: String, CaseIterable, Sendable {
    case name
    case contents

    public var title: String {
        switch self {
        case .name: "Names"
        case .contents: "Contents"
        }
    }
}

public enum BifrostSearchKind: String, CaseIterable, Sendable {
    case everything
    case images
    case documents
    case code

    public var title: String {
        switch self {
        case .everything: "All Kinds"
        case .images: "Images"
        case .documents: "Documents"
        case .code: "Code"
        }
    }

    public var extensions: [String] {
        switch self {
        case .everything: []
        case .images: BifrostFileSearch.imageExtensions
        case .documents: ["pdf", "doc", "docx", "pages", "txt", "md", "rtf", "csv", "xlsx", "key"]
        case .code:
            [
                "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "rb", "java", "kt", "c", "h",
                "cpp", "sh", "json", "yaml", "yml", "toml",
            ]
        }
    }
}

public struct BifrostSearchPlan: Equatable, Sendable {
    public let query: String
    public let root: String?
    public let target: BifrostSearchTarget
    public let kind: BifrostSearchKind
    public let machine: String?

    public init(
        query: String, root: String?, target: BifrostSearchTarget = .name,
        kind: BifrostSearchKind = .everything, machine: String? = nil
    ) {
        self.query = query
        self.root = root
        self.target = target
        self.kind = kind
        self.machine = machine
    }

    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isBrowsingRecents: Bool { trimmedQuery.isEmpty && machine == nil }
}

public enum BifrostRipgrep {
    public static let candidates = [
        "/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg",
    ]

    public static func executable(
        fileManager: FileManager = .default, paths: [String] = candidates
    ) -> URL? {
        for path in paths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static func arguments(for plan: BifrostSearchPlan) -> [String] {
        var arguments = ["--color", "never", "--no-messages", "--max-count", "1"]
        for value in plan.kind.extensions { arguments += ["--glob", "*.\(value)"] }
        switch plan.target {
        case .name:
            arguments += ["--files"]
        case .contents:
            arguments += ["--files-with-matches", "--smart-case", "--fixed-strings"]
            arguments.append(plan.trimmedQuery)
        }
        arguments.append(plan.root ?? NSHomeDirectory())
        return arguments
    }

    public static func remoteCommand(for plan: BifrostSearchPlan) -> String {
        let root = plan.root ?? "$HOME"
        let query = shellQuoted(plan.trimmedQuery)
        let globs = plan.kind.extensions.map { "--glob '*.\($0)'" }.joined(separator: " ")
        let limit = BifrostFileSearch.limit
        switch plan.target {
        case .name:
            let filter = plan.trimmedQuery.isEmpty ? "" : " | grep -i -- \(query)"
            return "rg --files --no-messages \(globs) \(root)\(filter) | head -n \(limit)"
        case .contents:
            return
                "rg --files-with-matches --no-messages --smart-case --fixed-strings \(globs) "
                + "-- \(query) \(root) | head -n \(limit)"
        }
    }

    public static func filterNames(_ paths: [String], query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return paths }
        return paths.filter {
            ($0 as NSString).lastPathComponent.lowercased().contains(needle)
        }
    }

    public static func shellQuoted(_ value: String) -> String {
        POSIXQuote.quote(value)
    }
}
