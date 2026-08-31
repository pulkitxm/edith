import Foundation

public struct KeystrokeModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = KeystrokeModifiers(rawValue: 1 << 0)
    public static let option = KeystrokeModifiers(rawValue: 1 << 1)
    public static let shift = KeystrokeModifiers(rawValue: 1 << 2)
    public static let command = KeystrokeModifiers(rawValue: 1 << 3)
    public static let function = KeystrokeModifiers(rawValue: 1 << 4)
}

public enum KeystrokeHighlightPosition: String, CaseIterable, Identifiable, Sendable {
    case top
    case bottom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }
}

public enum KeystrokeHighlightSettings {
    public static let defaultDuration = 1.5
    public static let durationRange = 0.5...3.0
    public static let maximumVisible = 6
}

public struct KeystrokeHighlightEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let keys: [String]
    public let expiresAt: Date

    public init(id: UUID = UUID(), keys: [String], expiresAt: Date) {
        self.id = id
        self.keys = keys
        self.expiresAt = expiresAt
    }
}

public struct KeystrokeHighlightQueue: Equatable, Sendable {
    public private(set) var entries: [KeystrokeHighlightEntry]
    public let maximumVisible: Int

    public init(entries: [KeystrokeHighlightEntry] = [], maximumVisible: Int = 6) {
        self.entries = Array(entries.suffix(max(1, maximumVisible)))
        self.maximumVisible = max(1, maximumVisible)
    }

    @discardableResult
    public mutating func append(
        keys: [String], now: Date = Date(), duration: TimeInterval
    ) -> KeystrokeHighlightEntry? {
        guard !keys.isEmpty else { return nil }
        let entry = KeystrokeHighlightEntry(
            keys: keys, expiresAt: now.addingTimeInterval(duration))
        entries.append(entry)
        entries = Array(entries.suffix(maximumVisible))
        return entry
    }

    public mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func removeExpired(at date: Date = Date()) {
        entries.removeAll { $0.expiresAt <= date }
    }
}

public enum KeystrokeLabelResolver {
    public static func labels(
        keyCode: UInt16, characters: String?, modifiers: KeystrokeModifiers
    ) -> [String]? {
        guard let key = keyLabel(keyCode: keyCode, characters: characters) else { return nil }
        var labels: [String] = []
        if modifiers.contains(.control) { labels.append("⌃") }
        if modifiers.contains(.option) { labels.append("⌥") }
        if modifiers.contains(.shift), !charactersCommunicateShift(characters) {
            labels.append("⇧")
        }
        if modifiers.contains(.command) { labels.append("⌘") }
        if modifiers.contains(.function),
            shouldDisplayFunction(keyCode: keyCode, characters: characters)
        {
            labels.append("fn")
        }
        labels.append(key)
        return labels
    }

    public static func keyLabel(keyCode: UInt16, characters: String?) -> String? {
        if let functionKey = functionKeyLabel(characters) { return functionKey }
        if let special = specialKeys[keyCode] { return special }
        guard let characters, let first = characters.first, !first.isWhitespace else {
            return fallbackKeys[keyCode]
        }
        let value = String(first)
        if first.isLetter { return value.uppercased() }
        if let ascii = first.asciiValue, ascii >= 32, ascii != 127 { return value }
        return fallbackKeys[keyCode]
    }

    private static func charactersCommunicateShift(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.count == 1
            && value.unicodeScalars.allSatisfy {
                CharacterSet.uppercaseLetters.contains($0)
            }
    }

    private static func shouldDisplayFunction(keyCode: UInt16, characters: String?) -> Bool {
        functionKeyLabel(characters) == nil && !implicitFunctionKeyCodes.contains(keyCode)
    }

    private static func functionKeyLabel(_ value: String?) -> String? {
        guard let value, value.count == 1, let character = value.first else { return nil }
        return functionKeyLabels[character]
    }

    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 71: "Clear", 76: "⌤",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        115: "Home", 116: "Page ↑", 117: "⌦", 118: "F4", 119: "End", 120: "F2",
        121: "Page ↓", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    private static let fallbackKeys: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
        9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]

    private static let implicitFunctionKeyCodes: Set<UInt16> = [
        71, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 115, 116, 117,
        118, 119, 120, 121, 122, 123, 124, 125, 126,
    ]

    private static let functionKeyLabels: [Character: String] = {
        var labels: [Character: String] = [
            "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
            "\u{F727}": "Insert", "\u{F728}": "⌦", "\u{F729}": "Home",
            "\u{F72A}": "Begin", "\u{F72B}": "End", "\u{F72C}": "Page ↑",
            "\u{F72D}": "Page ↓", "\u{F739}": "Clear", "\u{F746}": "Help",
        ]
        for offset in 0..<35 {
            guard let scalar = Unicode.Scalar(0xF704 + offset) else { continue }
            labels[Character(String(scalar))] = "F\(offset + 1)"
        }
        return labels
    }()
}
