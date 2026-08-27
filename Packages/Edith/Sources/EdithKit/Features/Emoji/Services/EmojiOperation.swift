import EdithCore
import Foundation

public enum EmojiOperation: String, CaseIterable, Sendable {
    case pick
    case insert
    case tone
    case clear

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .pick:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "emoji.pick"),
                summary: "Open the emoji picker.", cli: ["emoji", rawValue],
                effect: .interactive)
        case .insert:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "emoji.insert"),
                summary: "Insert an emoji into the frontmost app.", cli: ["emoji", rawValue],
                effect: .write)
        case .tone:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "emoji.tone"),
                summary: "Set the default emoji skin tone.", cli: ["emoji", rawValue],
                effect: .write)
        case .clear:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "emoji.clear"),
                summary: "Forget the frequently used emoji.", cli: ["emoji", rawValue],
                effect: .write)
        }
    }
}

public enum EmojiOperationError: LocalizedError, Equatable {
    case unknownEmoji(String)
    case unknownTone(String)

    public var errorDescription: String? {
        switch self {
        case .unknownEmoji(let value):
            "No emoji in the catalog matches \u{201C}\(value)\u{201D}."
        case .unknownTone(let value):
            "\u{201C}\(value)\u{201D} is not one of: "
                + EmojiSkinTone.allCases.map(\.token).joined(separator: ", ") + "."
        }
    }
}

public enum EmojiOperationExecution {
    @discardableResult
    public static func request(
        _ operation: EmojiOperation, userInfo: [String: Any]? = nil,
        post: (Notification.Name, [String: Any]?) -> Void = { IPC.post($0, userInfo: $1) }
    ) -> UserOperationDescriptor {
        switch operation {
        case .pick: post(IPC.Name.requestEmojiPanel, nil)
        case .insert: post(IPC.Name.requestEmojiInsert, userInfo)
        case .tone, .clear: post(IPC.Name.settingsChanged, nil)
        }
        return operation.descriptor
    }

    @discardableResult
    public static func perform(
        _ operation: EmojiOperation, value: String = "",
        catalog: EmojiCatalog = .shared, store: UserDefaults = SharedDefaults.store
    ) throws -> String {
        switch operation {
        case .pick:
            request(.pick)
            return ""
        case .insert:
            let character = try resolve(value, in: catalog, store: store)
            request(.insert, userInfo: ["character": character])
            return character
        case .tone:
            guard let tone = EmojiSkinTone(token: value) else {
                throw EmojiOperationError.unknownTone(value)
            }
            store.set(tone.rawValue, forKey: AppStorageKeys.Emoji.skinTone)
            request(.tone)
            return tone.token
        case .clear:
            var ledger = EmojiUsageLedger.load(from: store, key: AppStorageKeys.Emoji.usage)
            let removed = ledger.entries.count
            ledger.clear()
            ledger.save(to: store, key: AppStorageKeys.Emoji.usage)
            request(.clear)
            return String(removed)
        }
    }

    public static func resolve(
        _ value: String, in catalog: EmojiCatalog, store: UserDefaults = SharedDefaults.store
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmojiOperationError.unknownEmoji(value) }
        let tone = EmojiSkinTone.stored(forKey: AppStorageKeys.Emoji.skinTone, store: store)
        for candidate in [trimmed, character(fromHexcode: trimmed)].compactMap({ $0 }) {
            if let match = catalog.emoji(matching: candidate) {
                return match.toneVariants.contains(candidate)
                    ? candidate : match.character(tone: tone)
            }
            if let match = presented(candidate, in: catalog) {
                return match.character(tone: tone)
            }
        }
        guard let first = EmojiSearch.results(in: catalog.emoji, query: trimmed, limit: 1).first
        else { throw EmojiOperationError.unknownEmoji(value) }
        return first.character(tone: tone)
    }

    public static func character(fromHexcode value: String) -> String? {
        let parts = value.uppercased().split(whereSeparator: { $0 == "-" || $0 == " " })
        guard !parts.isEmpty else { return nil }
        var scalars = String.UnicodeScalarView()
        for part in parts {
            guard let code = UInt32(part, radix: 16), let scalar = Unicode.Scalar(code) else {
                return nil
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func presented(_ value: String, in catalog: EmojiCatalog) -> Emoji? {
        let selector: Unicode.Scalar = "\u{FE0F}"
        var stripped = String.UnicodeScalarView()
        for scalar in value.unicodeScalars where scalar != selector { stripped.append(scalar) }
        return catalog.emoji.first {
            var candidate = String.UnicodeScalarView()
            for scalar in $0.character.unicodeScalars where scalar != selector {
                candidate.append(scalar)
            }
            return String(candidate) == String(stripped)
        }
    }
}

extension EmojiSkinTone {
    public var token: String {
        switch self {
        case .standard: "default"
        case .light: "light"
        case .mediumLight: "medium-light"
        case .medium: "medium"
        case .mediumDark: "medium-dark"
        case .dark: "dark"
        }
    }

    public init?(token: String) {
        let normalized = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = EmojiSkinTone.allCases.first(where: { $0.token == normalized })
        else { return nil }
        self = match
    }
}

public enum EmojiCatalogSummary {
    public static let maxFrequentCount = 24

    public static var availability: String {
        let catalog = EmojiCatalog.shared
        return
            "\(catalog.emoji.count) emoji across \(catalog.groups.count) categories render on this Mac."
    }

    public static func frequent(
        catalog: EmojiCatalog = .shared, store: UserDefaults = SharedDefaults.store,
        now: Date = Date()
    ) -> [String] {
        let stored = store.object(forKey: AppStorageKeys.Emoji.frequentCount) as? Int ?? 10
        let limit = min(max(stored, 0), maxFrequentCount)
        let ledger = EmojiUsageLedger.load(from: store, key: AppStorageKeys.Emoji.usage)
        return ledger.ranked(now: now, limit: limit).filter { catalog.emoji(matching: $0) != nil }
    }
}
