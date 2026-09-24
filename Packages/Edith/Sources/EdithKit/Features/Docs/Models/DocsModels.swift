import Foundation

public enum DocsLink: Sendable, Hashable {
    case page(path: String, anchor: String?)
    case external(URL)
}

public struct DocsSpan: Sendable, Hashable {
    public struct Style: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let strong = Style(rawValue: 1)
        public static let emphasis = Style(rawValue: 2)
        public static let code = Style(rawValue: 4)
        public static let strikethrough = Style(rawValue: 8)
    }

    public var text: String
    public var style: Style
    public var link: DocsLink?

    public init(_ text: String, style: Style = [], link: DocsLink? = nil) {
        self.text = text
        self.style = style
        self.link = link
    }

    public static func plain(_ spans: [DocsSpan]) -> String {
        spans.map(\.text).joined()
    }
}

public struct DocsHeading: Sendable, Hashable, Identifiable {
    public let level: Int
    public let spans: [DocsSpan]
    public let anchor: String

    public var id: String { anchor }
    public var text: String { DocsSpan.plain(spans) }
}

public enum DocsAlignment: Sendable, Hashable {
    case leading, center, trailing
}

public struct DocsTable: Sendable, Hashable {
    public let alignments: [DocsAlignment]
    public let header: [[DocsSpan]]
    public let rows: [[[DocsSpan]]]
}

public struct DocsList: Sendable, Hashable {
    public let ordered: Bool
    public let start: Int
    public let items: [[DocsBlock]]
}

public indirect enum DocsBlock: Sendable, Hashable {
    case heading(DocsHeading)
    case paragraph([DocsSpan])
    case code(language: String?, text: String)
    case list(DocsList)
    case table(DocsTable)
    case quote([DocsBlock])
    case rule

    public var plainText: String {
        switch self {
        case .heading(let heading): heading.text
        case .paragraph(let spans): DocsSpan.plain(spans)
        case .code(_, let text): text
        case .list(let list): list.items.flatMap { $0 }.map(\.plainText).joined(separator: "\n")
        case .table(let table):
            ([table.header] + table.rows).map { $0.map(DocsSpan.plain).joined(separator: " | ") }
                .joined(separator: "\n")
        case .quote(let blocks): blocks.map(\.plainText).joined(separator: "\n")
        case .rule: ""
        }
    }
}

public struct DocsPage: Sendable, Hashable, Identifiable {
    public let path: String
    public let markdown: String
    public let blocks: [DocsBlock]
    public let headings: [DocsHeading]

    public var id: String { path }

    public var group: String {
        path.contains("/") ? String(path.split(separator: "/")[0]) : ""
    }

    public var title: String {
        headings.first { $0.level == 1 }?.text ?? path
    }

    public var command: String? {
        guard let heading = headings.first(where: { $0.level == 1 }),
            heading.spans.count == 1, heading.spans[0].style.contains(.code)
        else { return nil }
        return DocsCommandText.path(in: heading.text)
    }

    public var abstract: String {
        for block in blocks {
            if case .paragraph(let spans) = block { return DocsSpan.plain(spans) }
        }
        return ""
    }

    public var outline: [DocsHeading] {
        headings.filter { $0.level == 2 || $0.level == 3 }
    }
}

public struct DocsLocation: Sendable, Hashable {
    public let path: String
    public let anchor: String?

    public init(path: String, anchor: String? = nil) {
        self.path = path
        self.anchor = anchor
    }
}

public struct DocsCommand: Sendable, Hashable, Identifiable {
    public let path: String
    public let summary: String
    public let location: DocsLocation

    public var id: String { path }
    public var route: String { String(path.dropFirst(DocsCommandText.prefix.count)) }
    public var area: String { route.split(separator: " ").first.map(String.init) ?? route }
}

public struct DocsGroup: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let pages: [DocsPage]
}

public enum DocsCommandText {
    public static let prefix = "ed "

    public static func path(in code: String) -> String? {
        let tokens = code.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.first == "ed", tokens.count > 1 else { return nil }
        let words = tokens.dropFirst().prefix { isWord($0) }
        return words.isEmpty ? nil : (["ed"] + words).joined(separator: " ")
    }

    public static func synopsis(in line: String) -> String? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.first == "ed", tokens.count > 2 else { return nil }
        var words = ["ed"]
        for token in tokens.dropFirst() {
            if isWord(token) {
                words.append(token)
            } else {
                guard token.hasPrefix("[") || token.hasPrefix("<"), words.count > 1 else {
                    return nil
                }
                return words.joined(separator: " ")
            }
        }
        return nil
    }

    public static func normalized(_ raw: String) -> String {
        let words = raw.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return
            (words.first == "ed" || words.first == "edith"
            ? ["ed"] + words.dropFirst() : ["ed"] + words)
            .joined(separator: " ")
    }

    public static func mentions(_ text: String, _ command: String) -> Bool {
        var searched = text[...]
        while let found = searched.range(of: command) {
            let before =
                found.lowerBound == text.startIndex
                ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            let clearBefore = before.map { !$0.isLetter && !$0.isNumber && $0 != "-" } ?? true
            let clearAfter = after.map { !$0.isLetter && !$0.isNumber && $0 != "-" } ?? true
            if clearBefore && clearAfter { return true }
            searched = text[found.upperBound...]
        }
        return false
    }

    static func isWord(_ token: String) -> Bool {
        guard let first = token.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first)
        else { return false }
        return token.unicodeScalars.allSatisfy {
            CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0)
                || $0 == "-"
        }
    }
}

public enum DocsPath {
    public static func resolve(_ link: String, from page: String) -> String {
        var parts = page.split(separator: "/").dropLast().map(String.init)
        for piece in link.split(separator: "/").map(String.init) {
            if piece == "." { continue }
            if piece == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(piece)
        }
        return parts.joined(separator: "/")
    }

    public static func slug(_ text: String) -> String {
        var slug = ""
        for character in text.lowercased() {
            if character == " " {
                slug.append("-")
            } else if character.isLetter || character.isNumber || character == "-"
                || character == "_"
            {
                slug.append(character)
            }
        }
        return slug
    }
}
