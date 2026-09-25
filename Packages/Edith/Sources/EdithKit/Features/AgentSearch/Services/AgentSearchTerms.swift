import Foundation

public enum AgentSearchTerms {
    static let stopWords: Set<String> = [
        "a", "about", "after", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be",
        "been", "but", "by", "can", "could", "did", "do", "does", "for", "from", "had", "has",
        "have", "he", "her", "his", "how", "i", "if", "in", "into", "is", "it", "its", "just",
        "me", "my", "no", "not", "of", "on", "or", "our", "please", "she", "so", "than", "that",
        "the", "their", "them", "then", "there", "these", "they", "this", "those", "to", "too",
        "us", "was", "we", "were", "what", "when", "where", "which", "while", "who", "why",
        "will", "with", "would", "you", "your",
    ]

    static let suffixes = [
        "izations", "isations", "ization", "isation", "ational", "fulness", "ousness",
        "iveness", "ations", "ation", "ments", "ment", "ities", "ity", "izing", "ising", "izes",
        "ises", "ized", "ised", "ize", "ise", "ings", "ing", "ness", "ances", "ance", "ences",
        "ence", "ers", "er", "ies", "ied", "es", "ed", "ly", "s",
    ]

    public static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    public static func terms(_ text: String) -> [String] {
        words(text).compactMap { word in
            let scalars = word.unicodeScalars
            guard !stopWords.contains(word),
                scalars.count > 1 || scalars.first?.properties.numericType != nil
            else { return nil }
            return stem(word)
        }
    }

    public static func covers(_ text: String, all query: [String]) -> Bool {
        let words = Set(terms(text))
        return query.allSatisfy { term in
            words.contains { AgentSearchRanker.matches($0, term) > 0 }
        }
    }

    public static func matches(_ word: String, any query: [String]) -> Bool {
        let stemmed = stem(word.lowercased())
        return query.contains { AgentSearchRanker.matches(stemmed, $0) > 0 }
    }

    public static func stem(_ word: String) -> String {
        let scalars = word.unicodeScalars
        guard scalars.count > 3, scalars.allSatisfy(isLetter) else { return word }
        let keepsS = word.hasSuffix("ss") || word.hasSuffix("us") || word.hasSuffix("is")
        for suffix in suffixes where word.hasSuffix(suffix) {
            if suffix == "s", keepsS { continue }
            var root = String(String.UnicodeScalarView(scalars.dropLast(suffix.count)))
            if suffix == "ies" || suffix == "ied" { root += "y" }
            let minimum = suffix == "ed" || suffix == "ly" ? 4 : 3
            guard root.unicodeScalars.count >= minimum else { continue }
            return trimmingSilentE(root)
        }
        return trimmingSilentE(word)
    }

    static func trimmingSilentE(_ word: String) -> String {
        let scalars = word.unicodeScalars
        guard scalars.last == "e", scalars.count > 3 else { return word }
        return String(String.UnicodeScalarView(scalars.dropLast()))
    }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            true
        default:
            false
        }
    }
}
