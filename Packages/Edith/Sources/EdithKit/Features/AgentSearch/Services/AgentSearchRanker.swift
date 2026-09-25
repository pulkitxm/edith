import Foundation

struct AgentSearchDocument: Sendable {
    static let weights: [Double] = [3, 2, 1.5, 0.6]

    let counts: [[String: Int]]
    let lengths: [Int]
    let lastActivity: Double?

    init(fields: [String], lastActivity: Double?) {
        let terms = fields.map(AgentSearchTerms.terms)
        counts = terms.map { list in list.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
        lengths = terms.map(\.count)
        self.lastActivity = lastActivity
    }

    init(digest: AgentTranscriptDigest, title: String) {
        let components = digest.cwd.split(separator: "/").suffix(3).joined(separator: " ")
        let place = [
            components, digest.branch ?? "", digest.pullRequest ?? "", digest.kind.rawValue,
        ].joined(separator: " ")
        self.init(
            fields: [
                title, place, digest.prompts.joined(separator: " "),
                digest.replies.joined(separator: " "),
            ], lastActivity: digest.lastActivity)
    }
}

struct AgentSearchCorpus: Sendable {
    let documents: [AgentSearchDocument]
    let frequencies: [String: Int]
    let averages: [Double]

    init(_ documents: [AgentSearchDocument]) {
        self.documents = documents
        var frequencies: [String: Int] = [:]
        var totals = Array(repeating: 0.0, count: AgentSearchDocument.weights.count)
        for document in documents {
            var seen = Set<String>()
            for (field, counts) in document.counts.enumerated() {
                totals[field] += Double(document.lengths[field])
                seen.formUnion(counts.keys)
            }
            for term in seen { frequencies[term, default: 0] += 1 }
        }
        self.frequencies = frequencies
        let count = Double(max(documents.count, 1))
        averages = totals.map { max($0 / count, 1) }
    }
}

enum AgentSearchRanker {
    static let k1 = 1.2
    static let b = 0.75
    static let prefixWeight = 0.6
    static let recencyBoost = 0.2
    static let recencyDays = 14.0

    struct Scored: Equatable {
        let index: Int
        let score: Double
    }

    static func matches(_ word: String, _ query: String) -> Double {
        if word == query { return 1 }
        if query.unicodeScalars.count >= 4, word.hasPrefix(query) { return prefixWeight }
        if word.unicodeScalars.count >= 4, query.hasPrefix(word) { return prefixWeight }
        return 0
    }

    static func expansions(_ query: String, in frequencies: [String: Int]) -> [(String, Double)] {
        frequencies.keys.compactMap { term in
            let weight = matches(term, query)
            return weight > 0 ? (term, weight) : nil
        }
    }

    static func rank(_ query: [String], in corpus: AgentSearchCorpus, now: Double) -> [Scored] {
        var unique: [String] = []
        for term in query where !unique.contains(term) { unique.append(term) }
        guard !unique.isEmpty else { return [] }
        let total = Double(corpus.documents.count)
        let expanded = unique.map { term in
            expansions(term, in: corpus.frequencies).map { word, weight in
                let frequency = Double(corpus.frequencies[word] ?? 0)
                let idf = log(1 + (total - frequency + 0.5) / (frequency + 0.5))
                return (word, weight * idf)
            }
        }
        var scored: [Scored] = []
        for (index, document) in corpus.documents.enumerated() {
            var score = 0.0
            var matched = 0
            for options in expanded {
                var best = 0.0
                for (word, weight) in options {
                    let value = weight * saturation(word, in: document, averages: corpus.averages)
                    best = max(best, value)
                }
                if best > 0 {
                    matched += 1
                    score += best
                }
            }
            guard matched > 0 else { continue }
            score *= pow(Double(matched) / Double(unique.count), 1.5)
            if let last = document.lastActivity {
                let age = max(0, now - last) / 86_400
                score *= 1 + recencyBoost * exp(-age / recencyDays)
            }
            scored.append(Scored(index: index, score: score))
        }
        return scored.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.index < right.index
        }
    }

    static func saturation(
        _ word: String, in document: AgentSearchDocument, averages: [Double]
    ) -> Double {
        var weighted = 0.0
        for (field, counts) in document.counts.enumerated() {
            guard let count = counts[word] else { continue }
            let norm = 1 - b + b * Double(document.lengths[field]) / averages[field]
            weighted += AgentSearchDocument.weights[field] * Double(count) / norm
        }
        return weighted * (k1 + 1) / (weighted + k1)
    }

    static func snippet(from texts: [String], query: [String], limit: Int = 160) -> String {
        var best: (text: String, count: Int)?
        for text in texts {
            let stems = Set(AgentSearchTerms.terms(text))
            let count = query.filter { term in stems.contains { matches($0, term) > 0 } }.count
            if count > (best?.count ?? 0) { best = (text, count) }
        }
        guard let best else { return String((texts.first ?? "").prefix(limit)) }
        return window(best.text, around: query, limit: limit)
    }

    static func window(_ text: String, around query: [String], limit: Int) -> String {
        guard text.count > limit else { return text }
        var position = 0
        var start = text.startIndex
        while start < text.endIndex {
            guard let wordStart = text[start...].firstIndex(where: { $0.isLetter || $0.isNumber })
            else { break }
            let wordEnd =
                text[wordStart...].firstIndex(where: { !($0.isLetter || $0.isNumber) })
                ?? text.endIndex
            let stem = AgentSearchTerms.stem(text[wordStart..<wordEnd].lowercased())
            if query.contains(where: { matches(stem, $0) > 0 }) {
                position = text.distance(from: text.startIndex, to: wordStart)
                break
            }
            start = wordEnd
        }
        let lead = max(0, min(position - 50, text.count - limit))
        let from = text.index(text.startIndex, offsetBy: lead)
        let slice = text[from...].prefix(limit)
        let prefix = lead > 0 ? "…" : ""
        let suffix = lead + slice.count < text.count ? "…" : ""
        return prefix + slice.trimmingCharacters(in: .whitespaces) + suffix
    }
}
