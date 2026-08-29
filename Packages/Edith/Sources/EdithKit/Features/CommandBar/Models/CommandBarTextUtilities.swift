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

public struct CommandBarEmoji: Equatable, Sendable {
    public let character: String
    public let keywords: [String]

    public init(character: String, keywords: [String]) {
        self.character = character
        self.keywords = keywords
    }

    public static let common: [CommandBarEmoji] = [
        CommandBarEmoji(character: "😀", keywords: ["grinning", "happy", "smile"]),
        CommandBarEmoji(character: "😂", keywords: ["joy", "laugh", "tears"]),
        CommandBarEmoji(character: "😍", keywords: ["love", "heart eyes"]),
        CommandBarEmoji(character: "🤔", keywords: ["thinking", "hmm"]),
        CommandBarEmoji(character: "🥳", keywords: ["party", "celebrate"]),
        CommandBarEmoji(character: "😎", keywords: ["cool", "sunglasses"]),
        CommandBarEmoji(character: "😭", keywords: ["cry", "sad"]),
        CommandBarEmoji(character: "🙏", keywords: ["please", "thanks", "pray"]),
        CommandBarEmoji(character: "👍", keywords: ["yes", "approve", "thumbs up"]),
        CommandBarEmoji(character: "👎", keywords: ["no", "disapprove", "thumbs down"]),
        CommandBarEmoji(character: "👏", keywords: ["clap", "applause"]),
        CommandBarEmoji(character: "👋", keywords: ["wave", "hello", "bye"]),
        CommandBarEmoji(character: "❤️", keywords: ["heart", "love", "red"]),
        CommandBarEmoji(character: "🔥", keywords: ["fire", "hot"]),
        CommandBarEmoji(character: "✨", keywords: ["sparkles", "magic"]),
        CommandBarEmoji(character: "🎉", keywords: ["party", "celebration", "tada"]),
        CommandBarEmoji(character: "🚀", keywords: ["rocket", "launch"]),
        CommandBarEmoji(character: "✅", keywords: ["check", "done", "yes"]),
        CommandBarEmoji(character: "❌", keywords: ["cross", "no", "wrong"]),
        CommandBarEmoji(character: "⚠️", keywords: ["warning", "alert"]),
        CommandBarEmoji(character: "💡", keywords: ["idea", "light"]),
        CommandBarEmoji(character: "📌", keywords: ["pin", "pushpin"]),
        CommandBarEmoji(character: "🔍", keywords: ["search", "magnify"]),
        CommandBarEmoji(character: "💻", keywords: ["computer", "laptop"]),
    ]
}
