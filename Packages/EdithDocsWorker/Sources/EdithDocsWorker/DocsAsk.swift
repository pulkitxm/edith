import Foundation

public enum DocsAskEngine: String, Sendable, Codable {
    case jev
    case search

    public var label: String { self == .jev ? "Jev" : "Search" }
}

public struct DocsPick: Sendable, Hashable, Identifiable {
    public let command: DocsCommand
    public let probability: Double

    public var id: String { command.path }
}

public struct DocsAnswer: Sendable, Equatable {
    public let request: String
    public let engine: DocsAskEngine
    public let picks: [DocsPick]
    public let milliseconds: Int
}

public enum DocsAsk {
    public static let purpose = "docs.ask"
    public static let minimumConfidence = 0.15
    public static let limit = 5

    public static func answer(
        _ request: String, in library: DocsLibrary, decider: JevDeciding?,
        defaults: UserDefaults = UserDefaults.standard
    ) async -> DocsAnswer {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = Date()
        if let decider, !trimmed.isEmpty, JevAvailability.isConfigured(defaults),
            let routed = try? await JevRouter(groups: routeGroups(library)).route(
                String(trimmed.prefix(400)), using: decider, purpose: purpose)
        {
            let picks = routed.picks.compactMap { pick in
                library.command(pick.id).map {
                    DocsPick(command: $0, probability: pick.probability)
                }
            }
            if let best = picks.first, best.probability >= minimumConfidence {
                return DocsAnswer(
                    request: trimmed, engine: .jev, picks: Array(picks.prefix(limit)),
                    milliseconds: routed.milliseconds)
            }
        }
        return DocsAnswer(
            request: trimmed, engine: .search, picks: library.search.rank(trimmed, limit: limit),
            milliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    public static func routeGroups(_ library: DocsLibrary) -> [JevRouteGroup] {
        let byArea = Dictionary(grouping: library.commands, by: \.area)
        return byArea.keys.sorted().map { area in
            let commands = byArea[area] ?? []
            let leaves = commands.filter { $0.route != area }
            return JevRouteGroup(
                id: area, summary: library.command(area)?.summary ?? area,
                members: (leaves.isEmpty ? commands : leaves).prefix(JevQuestion.maximumOptions)
                    .map { JevRouteCandidate(id: $0.route, summary: $0.summary) })
        }
    }
}

struct DocsSearchIndex: Sendable {
    struct Passage: Sendable {
        let terms: Set<String>
        let keys: Set<String>
    }

    struct Document: Sendable {
        let command: DocsCommand
        let fields: [[String: Double]]
        let lengths: [Double]
        let passages: [Passage]
        let isGroup: Bool
    }

    static let fieldWeights = [4.0, 2.0, 1.0]
    static let k1 = 1.2
    static let b = 0.75
    static let relatedWeight = 0.6
    static let groupPenalty = 0.5
    static let passageWeight = 3.0
    static let keyWeight = 2.0

    let documents: [Document]
    let frequency: [String: Int]
    let averageLengths: [Double]

    init(commands: [DocsCommand], pages: [DocsPage], index: [String: Int]) {
        var parents: Set<String> = []
        for command in commands {
            var words = command.path.split(separator: " ")
            while words.count > 1 {
                words.removeLast()
                parents.insert(words.joined(separator: " "))
            }
        }
        let paths = Set(commands.map(\.path))
        var documents: [Document] = []
        var frequency: [String: Int] = [:]
        for command in commands {
            let page = index[command.location.path].map { pages[$0] }
            let texts = [
                command.route, command.summary,
                page.map { Self.context($0, anchor: command.location.anchor) } ?? "",
            ]
            let fields = texts.map { text in
                DocsTerms.terms(text).reduce(into: [String: Double]()) { $0[$1, default: 0] += 1 }
            }
            let passages =
                page.map {
                    Self.passages(Self.scope($0, of: command), of: command, among: paths)
                } ?? []
            let terms = Set(fields.flatMap(\.keys)).union(passages.flatMap(\.terms))
            for term in terms { frequency[term, default: 0] += 1 }
            documents.append(
                Document(
                    command: command, fields: fields,
                    lengths: fields.map { $0.values.reduce(0, +) }, passages: passages,
                    isGroup: parents.contains(command.path)))
        }
        self.documents = documents
        self.frequency = frequency
        averageLengths = Self.fieldWeights.indices.map { field in
            let total = documents.reduce(0.0) { $0 + $1.lengths[field] }
            return max(1, total / Double(max(1, documents.count)))
        }
    }

    static func context(_ page: DocsPage, anchor: String?) -> String {
        var collecting = anchor == nil
        var parts: [String] = anchor == nil ? [page.title] : []
        for block in page.blocks {
            if case .heading(let heading) = block {
                if collecting, anchor != nil || heading.level > 1 { break }
                collecting = collecting || heading.anchor == anchor
                if collecting { parts.append(heading.text) }
                continue
            }
            if collecting, case .paragraph(let spans) = block, !DocsSpan.isNavigation(spans) {
                parts.append(block.plainText)
                if parts.count > 2 { break }
            }
        }
        return parts.joined(separator: " ")
    }

    static func scope(_ page: DocsPage, of command: DocsCommand) -> [DocsBlock] {
        guard let anchor = command.location.anchor else {
            return page.command == command.path
                ? page.blocks : page.blocks.filter { mentions($0, command.path) }
        }
        var level: Int?
        var blocks: [DocsBlock] = []
        for block in page.blocks {
            if case .heading(let heading) = block {
                if let level, heading.level <= level { break }
                if level == nil, heading.anchor == anchor { level = heading.level }
                continue
            }
            if level != nil { blocks.append(block) }
        }
        return blocks
    }

    static func mentions(_ block: DocsBlock, _ command: String) -> Bool {
        switch block {
        case .paragraph, .list: DocsCommandText.mentions(block.plainText, command)
        case .table(let table):
            table.rows.contains {
                $0.first.flatMap { DocsCommandText.path(in: DocsSpan.plain($0)) } == command
            }
        case .code(_, let text):
            text.split(separator: "\n").contains { DocsCommandText.path(in: String($0)) == command }
        case .heading, .rule, .quote: false
        }
    }

    static func passages(
        _ blocks: [DocsBlock], of command: DocsCommand, among paths: Set<String>
    ) -> [Passage] {
        func foreign(_ text: String) -> Bool {
            guard let path = DocsCommandText.path(in: text), path != command.path else {
                return false
            }
            return paths.contains(path) || !path.hasPrefix(command.path + " ")
        }
        let route = Set(DocsTerms.terms(command.route))
        func passage(_ text: String, keys: String = "") -> Passage? {
            let terms = Set(DocsTerms.terms(text))
            return terms.isEmpty
                ? nil : Passage(terms: terms, keys: Set(DocsTerms.terms(keys)).subtracting(route))
        }
        var passages: [Passage] = []
        for block in blocks {
            switch block {
            case .paragraph(let spans):
                guard !DocsSpan.isNavigation(spans) else { continue }
                passages += passage(DocsSpan.plain(spans)).map { [$0] } ?? []
            case .list(let list):
                passages += list.items.compactMap {
                    passage($0.map(\.plainText).joined(separator: " "))
                }
            case .table(let table):
                for row in table.rows {
                    let first = row.first.map(DocsSpan.plain) ?? ""
                    guard !foreign(first) else { continue }
                    let keyed = row.first?.first?.style.contains(.code) == true
                    passages +=
                        passage(
                            row.map(DocsSpan.plain).joined(separator: " "),
                            keys: keyed ? first : ""
                        ).map { [$0] } ?? []
                }
            case .code(_, let text):
                for line in text.split(separator: "\n").map(String.init) where !foreign(line) {
                    passages += passage(line).map { [$0] } ?? []
                }
            case .quote(let inner):
                passages += Self.passages(inner, of: command, among: paths)
            case .heading, .rule:
                continue
            }
        }
        return passages
    }

    func expansions(for request: String) -> (terms: [[String: Double]], words: Set<String>) {
        let words = DocsTerms.words(request)
        var compounds: [String: [String]] = [:]
        for (left, right) in zip(words, words.dropFirst()) {
            let joined = DocsTerms.canonical(DocsTerms.stem(left + right))
            guard frequency[joined] != nil else { continue }
            for word in [left, right] where !DocsTerms.stopWords.contains(word) {
                compounds[DocsTerms.canonical(DocsTerms.stem(word)), default: []].append(joined)
            }
        }
        var seen: Set<String> = []
        let terms = DocsTerms.terms(words.joined(separator: " ")).compactMap {
            term -> [String: Double]? in
            guard seen.insert(term).inserted else { return nil }
            var expansion = [term: 1.0]
            for related in DocsTerms.related(to: term) { expansion[related] = Self.relatedWeight }
            for joined in compounds[term] ?? [] { expansion[joined] = 1.0 }
            return expansion
        }
        return (terms, Set(words))
    }

    func rank(_ request: String, limit: Int) -> [DocsPick] {
        let (expansions, words) = expansions(for: request)
        guard !expansions.isEmpty else { return [] }
        let count = Double(documents.count)
        func idf(_ term: String) -> Double? {
            frequency[term].map { log(1 + (count - Double($0) + 0.5) / (Double($0) + 0.5)) }
        }
        var scored: [(Document, Double)] = []
        for document in documents {
            var score = 0.0
            var covered = 0.0
            var passageScore = 0.0
            var passageCoverage = [Double](repeating: 0, count: expansions.count)
            for passage in document.passages {
                var values = [Double](repeating: 0, count: expansions.count)
                var coverage = values
                for (position, expansion) in expansions.enumerated() {
                    for (term, weight) in expansion where passage.terms.contains(term) {
                        guard let idf = idf(term) else { continue }
                        let key = passage.keys.contains(term) ? Self.keyWeight : 1
                        values[position] = max(values[position], weight * idf * key)
                        coverage[position] = max(coverage[position], weight)
                    }
                }
                let total = values.reduce(0, +)
                if total > passageScore {
                    passageScore = total
                    passageCoverage = coverage
                }
            }
            for (position, expansion) in expansions.enumerated() {
                var best = passageCoverage[position]
                for (term, weight) in expansion {
                    guard let idf = idf(term) else { continue }
                    var termScore = 0.0
                    for (field, terms) in document.fields.enumerated() {
                        guard let tf = terms[term] else { continue }
                        let norm =
                            Self.k1
                            * (1 - Self.b + Self.b * document.lengths[field] / averageLengths[field])
                        termScore +=
                            Self.fieldWeights[field] * idf * tf * (Self.k1 + 1) / (tf + norm)
                    }
                    if termScore > 0 { best = max(best, weight) }
                    score += weight * termScore
                }
                covered += best
            }
            score += Self.passageWeight * passageScore
            guard score > 0 else { continue }
            let verb = document.command.route.split(separator: " ").last.map(String.init) ?? ""
            let surface = words.contains(verb) ? 1.3 : 1
            score *= (0.5 + 0.5 * covered / Double(expansions.count)) * surface
            if document.isGroup { score *= Self.groupPenalty }
            scored.append((document, score))
        }
        scored.sort { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            let leftWords = left.0.command.path.split(separator: " ").count
            let rightWords = right.0.command.path.split(separator: " ").count
            return leftWords == rightWords
                ? left.0.command.path < right.0.command.path : leftWords < rightWords
        }
        let top = scored.prefix(limit)
        let total = top.reduce(0) { $0 + $1.1 * $1.1 }
        return top.map { DocsPick(command: $0.0.command, probability: $0.1 * $0.1 / total) }
    }
}

enum DocsTerms {
    static let stopWords: Set<String> = [
        "a", "an", "the", "my", "me", "i", "to", "of", "on", "in", "is", "it", "for", "how",
        "much", "what", "do", "does", "and", "or", "with", "this", "that", "from", "all", "can",
        "you", "please", "some", "any", "be", "are", "there", "at", "by", "as", "its", "want",
        "need", "get", "your", "we", "so", "out", "into", "about", "up", "ed", "edith", "command",
        "when", "which", "one", "every", "if", "not", "no", "just", "then", "than", "make", "turn",
    ]

    static let equivalents: [[String]] = [
        ["ls", "list"],
        ["rm", "remove", "delete"],
        ["machine", "server", "box", "host", "computer", "vps"],
        ["track", "song"],
        ["previous", "prev"],
        ["config", "setting", "preference"],
    ]

    static let relatedGroups: [[String]] = [
        ["stop", "pause", "halt", "suspend"],
        ["rm", "prune", "clean", "purge", "erase", "wipe", "free", "reclaim", "trash", "forget"],
        ["ls", "show", "display", "view", "see", "browse"],
        ["restart", "reboot", "relaunch", "reload"],
        ["track", "music", "playback", "tune"],
        ["space", "disk", "storage"],
        ["limit", "quota", "allowance"],
        ["start", "launch", "begin"],
        ["quit", "kill", "close", "terminate"],
        ["install", "setup"],
        ["next", "skip"],
        ["previous", "rewind"],
        ["cost", "spend", "spent", "money", "price", "bill"],
        ["log", "tail"],
        ["container", "docker"],
        ["agent", "daemon", "background"],
        ["shutdown", "poweroff"],
        ["key", "token", "credential"],
        ["clipboard", "paste", "copied"],
        ["cache", "junk"],
        ["set", "change", "save", "write", "store", "update", "edit"],
        ["volume", "loud", "louder", "quiet", "quieter"],
        ["calendar", "agenda", "meeting", "event", "schedule"],
        ["usage", "claude", "codex", "gemini", "cursor"],
        ["rmi", "image"],
        ["put", "upload", "send"],
        ["get", "download", "fetch"],
    ]

    static let canonicalIndex: [String: String] = {
        var index: [String: String] = [:]
        for group in equivalents {
            let target = stem(group[0])
            for word in group { index[stem(word)] = target }
        }
        return index
    }()

    static let relatedIndex: [String: [String]] = {
        var index: [String: Set<String>] = [:]
        for group in relatedGroups {
            let terms = group.map { canonical(stem($0)) }
            for term in terms { index[term, default: []].formUnion(terms.filter { $0 != term }) }
        }
        return index.mapValues { $0.sorted() }
    }()

    static func related(to term: String) -> [String] {
        relatedIndex[term] ?? []
    }

    static func canonical(_ stem: String) -> String {
        canonicalIndex[stem] ?? stem
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func terms(_ text: String) -> [String] {
        words(text).filter { !stopWords.contains($0) }.map { canonical(stem($0)) }
    }

    static func stem(_ word: String) -> String {
        if word.hasPrefix("setting") { return "setting" }
        var stem = word
        func strip(_ suffix: String, _ replacement: String = "") {
            guard stem.hasSuffix(suffix), stem.count - suffix.count >= 3 else { return }
            stem = String(stem.dropLast(suffix.count)) + replacement
        }
        if stem.hasSuffix("ies") {
            strip("ies", "y")
        } else if stem.hasSuffix("sses") {
            strip("es")
        } else if stem.hasSuffix("s"), !stem.hasSuffix("ss") {
            strip("s")
        }
        if stem.hasSuffix("ing") {
            strip("ing")
        } else if stem.hasSuffix("ed") {
            strip("ed")
        }
        strip("e")
        if let last = stem.last, stem.count > 3, stem.dropLast().last == last,
            !"lsz".contains(last), !"aeiou".contains(last)
        {
            stem.removeLast()
        }
        return stem
    }
}
