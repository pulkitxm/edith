import Foundation

public enum EmojiSkinTone: Int, CaseIterable, Identifiable, Sendable {
    case standard = 0
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .standard: "Default"
        case .light: "Light"
        case .mediumLight: "Medium light"
        case .medium: "Medium"
        case .mediumDark: "Medium dark"
        case .dark: "Dark"
        }
    }

    public var sample: String {
        switch self {
        case .standard: "✋"
        case .light: "✋🏻"
        case .mediumLight: "✋🏼"
        case .medium: "✋🏽"
        case .mediumDark: "✋🏾"
        case .dark: "✋🏿"
        }
    }

    public static func stored(forKey key: String) -> EmojiSkinTone {
        guard let raw = SharedDefaults.store.object(forKey: key) as? Int else { return .standard }
        return EmojiSkinTone(rawValue: raw) ?? .standard
    }
}

public struct EmojiGroup: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let symbolName: String

    public init(id: String, name: String, symbolName: String) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case symbolName = "symbol"
    }
}

public struct Emoji: Identifiable, Hashable, Sendable {
    public let character: String
    public let name: String
    public let groupIndex: Int
    public let unicodeVersion: Double
    public let terms: [String]
    public let toneVariants: [String]

    public var id: String { character }

    public var supportsSkinTones: Bool { !toneVariants.isEmpty }

    public init(
        character: String, name: String, groupIndex: Int, unicodeVersion: Double,
        terms: [String] = [], toneVariants: [String] = []
    ) {
        self.character = character
        self.name = name
        self.groupIndex = groupIndex
        self.unicodeVersion = unicodeVersion
        self.terms = terms
        self.toneVariants = toneVariants
    }

    public func character(tone: EmojiSkinTone) -> String {
        guard tone != .standard, toneVariants.count >= tone.rawValue else { return character }
        return toneVariants[tone.rawValue - 1]
    }
}
