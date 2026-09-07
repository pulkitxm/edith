import Foundation

public enum CommandBarTextUtility: String, CaseIterable, Sendable {
    case uppercase
    case lowercase
    case titleCase
    case trimWhitespace
    case sortLines
    case countWords

    public var title: String {
        switch self {
        case .uppercase: "Make Uppercase"
        case .lowercase: "Make Lowercase"
        case .titleCase: "Make Title Case"
        case .trimWhitespace: "Trim Whitespace"
        case .sortLines: "Sort Lines"
        case .countWords: "Count Words"
        }
    }

    public var symbolName: String {
        switch self {
        case .uppercase: "textformat.size.larger"
        case .lowercase: "textformat.size.smaller"
        case .titleCase: "textformat"
        case .trimWhitespace: "arrow.left.and.right.text.vertical"
        case .sortLines: "text.line.first.and.arrowtriangle.forward"
        case .countWords: "number"
        }
    }

    public func transform(_ text: String, locale: Locale = .current) -> String {
        switch self {
        case .uppercase: text.uppercased(with: locale)
        case .lowercase: text.lowercased(with: locale)
        case .titleCase: text.capitalized(with: locale)
        case .trimWhitespace:
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .sortLines:
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: "\n")
        case .countWords:
            String(text.split(whereSeparator: \.isWhitespace).count)
        }
    }
}
