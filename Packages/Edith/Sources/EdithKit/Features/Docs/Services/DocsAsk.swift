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
        defaults: UserDefaults = SharedDefaults.store
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
            JevRouteGroup(
                id: area, summary: library.command(area)?.summary ?? area,
                members: (byArea[area] ?? []).prefix(JevQuestion.maximumOptions).map {
                    JevRouteCandidate(id: $0.route, summary: $0.summary)
                })
        }
    }
}

struct DocsSearchIndex: Sendable {
    struct Document: Sendable {
        let command: DocsCommand
        let fields: [[String: Double]]
        let lengths: [Double]
        let isGroup: Bool
    }

    static let fieldWeights = [4.0, 2.0, 1.0]
    static let k1 = 1.2
    static let b = 0.75
    static let relatedWeight = 0.6
    static let groupPenalty = 0.65

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
            for term in Set(fields.flatMap(\.keys)) { frequency[term, default: 0] += 1 }
            documents.append(
                Document(
                    command: command, fields: fields,
                    lengths: fields.map { $0.values.reduce(0, +) },
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
            if collecting, case .paragraph = block {
                parts.append(block.plainText)
                if parts.count > 2 { break }
            }
        }
        return parts.joined(separator: " ")
    }

    func expansions(for request: String) -> (terms: [[String: Double]], words: Set<String>) {
        var words = DocsTerms.words(request)
        var index = 0
        while index + 1 < words.count {
            let joined = words[index] + words[index + 1]
            if frequency[DocsTerms.canonical(DocsTerms.stem(joined))] != nil {
                words.replaceSubrange(index...(index + 1), with: [joined])
            }
            index += 1
        }
        var seen: Set<String> = []
        let terms = DocsTerms.terms(words.joined(separator: " ")).compactMap {
            term -> [String: Double]? in
            guard seen.insert(term).inserted else { return nil }
            var expansion = [term: 1.0]
            for related in DocsTerms.related(to: term) { expansion[related] = Self.relatedWeight }
            return expansion
        }
        return (terms, Set(words))
    }

    func rank(_ request: String, limit: Int) -> [DocsPick] {
        let (expansions, words) = expansions(for: request)
        guard !expansions.isEmpty else { return [] }
        let count = Double(documents.count)
        var scored: [(Document, Double)] = []
        for document in documents {
            var score = 0.0
            var covered = 0.0
            for expansion in expansions {
                var best = 0.0
                for (term, weight) in expansion {
                    guard let df = frequency[term] else { continue }
                    let idf = log(1 + (count - Double(df) + 0.5) / (Double(df) + 0.5))
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
