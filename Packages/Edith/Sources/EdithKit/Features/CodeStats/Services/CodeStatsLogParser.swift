import CryptoKit
import Foundation

public struct CodeStatsLogParser {
    public typealias Attribute = (String, String, [String]) -> CodeStatsCommitFlags?

    public static let prettyFormat =
        "C%x09%H%x09%aI%x09%an%x09%ae%x09%at"
        + "%x09%(trailers:key=Co-authored-by,valueonly,separator=%x1f)%x09%s"
    public static let trailerSeparator: Character = "\u{1f}"
    public static let headerPrefix = "C\t"
    static let markerLineLimit = 5
    static let formattingMinimumLines = 20
    static let formattingRatio = 0.2
    static let formatterTools = [
        "prettier", "biome", "reformat", "lint --fix", "lint:fix", "swiftformat",
        "swift-format", "swift format", "rustfmt", "gofmt", "clang-format", "black .",
    ]
    static let formatVerbs: Set<String> = ["format", "formatted", "formatting", "fmt"]
    static let formatObjects: Set<String> = [
        "code", "codebase", "files", "all", "with", "using", "project", "sources", "source",
        "everything", "repo", "repository", "workspace",
    ]

    private struct FileState {
        var language: String?
        var category = CodeStatsCategory.code
        var counts = CodeStatsLanguageCounts()
        var raw = CodeStatsLanguageCounts()
        var digest = SHA256()
        var hashed = false
        var markerLines = 0
    }

    private let repository: String
    private let attribute: Attribute
    private var commits: [CodeStatsCommit] = []
    private var current: CodeStatsCommit?
    private var author = ""
    private var file = FileState()
    private var fileDigests: [Data] = []
    private var inHunk = false
    private var hunkFromTop = false
    private var fallbackPath = ""
    private var removed = 0
    private var inserted = 0
    private var matched = 0
    private var removedLines: [[UInt8]: Int] = [:]

    public init(repository: String, attribute: @escaping Attribute) {
        self.repository = repository
        self.attribute = attribute
    }

    public init(repository: String, isMine: @escaping (String, String) -> Bool) {
        self.init(repository: repository) { name, email, _ in isMine(name, email) ? [] : nil }
    }

    public static func parse(
        _ text: String, repository: String, isMine: @escaping (String, String) -> Bool
    ) -> [CodeStatsCommit] {
        parse(text, repository: repository) { name, email, _ in isMine(name, email) ? [] : nil }
    }

    public static func parse(
        _ text: String, repository: String, attribute: @escaping Attribute
    ) -> [CodeStatsCommit] {
        var parser = CodeStatsLogParser(repository: repository, attribute: attribute)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            parser.push(line)
        }
        return parser.finish()
    }

    public mutating func push<Line: StringProtocol>(_ line: Line) {
        if line.hasPrefix("C\t") {
            finishCommit()
            startCommit(line.split(separator: "\t", omittingEmptySubsequences: false))
        } else if current == nil {
            return
        } else if line.hasPrefix("diff --git ") {
            finishFile()
            current?.files += 1
        } else if !inHunk, line.hasPrefix("--- ") {
            let path = line.dropFirst(4)
            fallbackPath = path == "/dev/null" ? "" : Self.strip(path, prefix: "a/")
        } else if !inHunk, line.hasPrefix("+++ ") {
            let path = line.dropFirst(4)
            let resolved = path == "/dev/null" ? fallbackPath : Self.strip(path, prefix: "b/")
            if !resolved.isEmpty {
                file.language = CodeStatsLanguage.language(resolved)
                file.category = CodeStatsLanguage.category(resolved)
            }
        } else if line.hasPrefix("@@") {
            finishHunk()
            inHunk = true
            hunkFromTop = Self.startsAtTop(line)
        } else if inHunk, line.hasPrefix("+") {
            inserted += 1
            let content = Self.normalized(line.dropFirst())
            if let count = removedLines[content], count > 0 {
                removedLines[content] = count - 1
                matched += 1
            }
            hash(content, sign: 0x2B)
            if hunkFromTop, file.markerLines < Self.markerLineLimit {
                file.markerLines += 1
                if file.category != .generated,
                    CodeStatsLanguage.hasGeneratedMarker(line.dropFirst())
                {
                    file.category = .generated
                }
            }
        } else if inHunk, line.hasPrefix("-") {
            removed += 1
            let content = Self.normalized(line.dropFirst())
            removedLines[content, default: 0] += 1
            hash(content, sign: 0x2D)
        }
    }

    public mutating func finish() -> [CodeStatsCommit] {
        finishCommit()
        defer { commits = [] }
        return commits
    }

    static func normalized<Content: StringProtocol>(_ content: Content) -> [UInt8] {
        content.utf8.filter { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D && $0 != 0x0B && $0 != 0x0C }
    }

    static func startsAtTop<Line: StringProtocol>(_ header: Line) -> Bool {
        guard let plus = header.firstIndex(of: "+") else { return false }
        let digits = header[header.index(after: plus)...].prefix { $0.isNumber }
        return (Int(digits) ?? 0) <= 1
    }

    public static func isFormatterSubject(_ subject: String) -> Bool {
        let lowered = subject.lowercased()
        if formatterTools.contains(where: lowered.contains) { return true }
        var rest = Substring(lowered)
        if let colon = rest.firstIndex(of: ":"), !rest[..<colon].contains(" "),
            rest.distance(from: rest.startIndex, to: colon) <= 24
        {
            rest = rest[rest.index(after: colon)...]
        }
        var words = rest.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if words.first == "run" { words.removeFirst() }
        guard let verb = words.first, formatVerbs.contains(String(verb)) else { return false }
        return words.count == 1 || formatObjects.contains(String(words[1]))
    }

    private mutating func hash(_ content: [UInt8], sign: UInt8) {
        file.digest.update(data: [sign])
        file.digest.update(data: content)
        file.digest.update(data: [0x0A])
        file.hashed = true
    }

    private mutating func startCommit<Field: StringProtocol>(_ fields: [Field]) {
        let field = { (index: Int) in fields.count > index ? String(fields[index]) : "" }
        let date = field(2)
        let coAuthors = field(6).split(separator: Self.trailerSeparator).map(String.init)
        guard let flags = attribute(field(3), field(4), coAuthors) else { return }
        let hour = date.count >= 13 ? Int(date.dropFirst(11).prefix(2)) ?? 0 : 0
        author = field(4).lowercased()
        current = CodeStatsCommit(
            sha: field(1), day: String(date.prefix(10)), hour: min(max(hour, 0), 23),
            repository: repository, timestamp: Int(field(5)) ?? 0,
            subject: fields.count > 7 ? fields[7...].joined(separator: "\t") : "",
            flags: flags)
    }

    private mutating func finishHunk() {
        guard inHunk else { return }
        if current != nil, removed > 0 || inserted > 0 {
            file.raw.addHunk(removed: removed, inserted: inserted)
            file.counts.addHunk(removed: removed - matched, inserted: inserted - matched)
        }
        removed = 0
        inserted = 0
        matched = 0
        removedLines.removeAll(keepingCapacity: true)
    }

    private mutating func finishFile() {
        finishHunk()
        if let language = file.language, !file.raw.isEmpty {
            current?.record(
                language: language, category: file.category, counts: file.counts, raw: file.raw)
        }
        if file.hashed { fileDigests.append(Data(file.digest.finalize())) }
        file = FileState()
        inHunk = false
        hunkFromTop = false
        fallbackPath = ""
    }

    private mutating func finishCommit() {
        finishFile()
        if var commit = current {
            if !fileDigests.isEmpty {
                var digest = SHA256()
                digest.update(data: Data(author.utf8))
                digest.update(data: [0])
                digest.update(data: Self.normalized(commit.subject.lowercased()))
                for part in fileDigests.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                    digest.update(data: [0])
                    digest.update(data: part)
                }
                commit.fingerprint = digest.finalize().map { String(format: "%02x", $0) }
                    .joined()
            }
            if Self.isFormatting(commit) { commit.flags.insert(.formatting) }
            commits.append(commit)
        }
        current = nil
        fileDigests = []
        author = ""
    }

    static func isFormatting(_ commit: CodeStatsCommit) -> Bool {
        let raw = commit.changes.filter { $0.category != .generated }.reduce(0) {
            $0 + $1.raw.authored
        }
        if raw >= formattingMinimumLines,
            Double(commit.totals.authored) <= Double(raw) * formattingRatio
        {
            return true
        }
        return isFormatterSubject(commit.subject)
    }

    private static func strip<Path: StringProtocol>(_ path: Path, prefix: String) -> String {
        var value = Substring(path)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = value.dropFirst().dropLast()
        }
        return String(value.hasPrefix(prefix) ? value.dropFirst(prefix.count) : value)
    }
}
