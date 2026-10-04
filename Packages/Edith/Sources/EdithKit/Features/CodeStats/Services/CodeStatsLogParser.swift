import Foundation

public struct CodeStatsLogParser {
    public static let prettyFormat = "C%x09%H%x09%aI%x09%an%x09%ae"

    private let repository: String
    private let isMine: (String, String) -> Bool
    private var commits: [CodeStatsCommit] = []
    private var current: CodeStatsCommit?
    private var inHunk = false
    private var language: String?
    private var fallbackPath = ""
    private var removed = 0
    private var inserted = 0

    public init(repository: String, isMine: @escaping (String, String) -> Bool) {
        self.repository = repository
        self.isMine = isMine
    }

    public static func parse(
        _ text: String, repository: String, isMine: @escaping (String, String) -> Bool
    ) -> [CodeStatsCommit] {
        var parser = CodeStatsLogParser(repository: repository, isMine: isMine)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            parser.push(line)
        }
        return parser.finish()
    }

    public mutating func push<Line: StringProtocol>(_ line: Line) {
        if line.hasPrefix("C\t") {
            finishCommit()
            startCommit(line.split(separator: "\t", omittingEmptySubsequences: false))
        } else if line.hasPrefix("diff --git ") {
            finishHunk()
            inHunk = false
            language = nil
            fallbackPath = ""
        } else if !inHunk, line.hasPrefix("--- ") {
            let path = line.dropFirst(4)
            fallbackPath = path == "/dev/null" ? "" : Self.strip(path, prefix: "a/")
        } else if !inHunk, line.hasPrefix("+++ ") {
            let path = line.dropFirst(4)
            let resolved = path == "/dev/null" ? fallbackPath : Self.strip(path, prefix: "b/")
            language = resolved.isEmpty ? nil : CodeStatsLanguage.classify(resolved)
        } else if line.hasPrefix("@@") {
            finishHunk()
            inHunk = true
        } else if inHunk, line.hasPrefix("+") {
            inserted += 1
        } else if inHunk, line.hasPrefix("-") {
            removed += 1
        }
    }

    public mutating func finish() -> [CodeStatsCommit] {
        finishCommit()
        defer { commits = [] }
        return commits
    }

    private mutating func startCommit<Field: StringProtocol>(_ fields: [Field]) {
        let field = { (index: Int) in fields.count > index ? String(fields[index]) : "" }
        let date = field(2)
        guard isMine(field(3), field(4)) else { return }
        let hour = date.count >= 13 ? Int(date.dropFirst(11).prefix(2)) ?? 0 : 0
        current = CodeStatsCommit(
            sha: field(1), day: String(date.prefix(10)), hour: min(max(hour, 0), 23),
            repository: repository)
    }

    private mutating func finishHunk() {
        guard inHunk else { return }
        if current != nil, let language, removed > 0 || inserted > 0 {
            current?.languages[language, default: .zero].addHunk(
                removed: removed, inserted: inserted)
        }
        removed = 0
        inserted = 0
    }

    private mutating func finishCommit() {
        finishHunk()
        if let current { commits.append(current) }
        current = nil
        inHunk = false
        language = nil
        fallbackPath = ""
    }

    private static func strip<Path: StringProtocol>(_ path: Path, prefix: String) -> String {
        var value = Substring(path)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = value.dropFirst().dropLast()
        }
        return String(value.hasPrefix(prefix) ? value.dropFirst(prefix.count) : value)
    }
}
