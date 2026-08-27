import Foundation

public struct EmojiCatalog: Sendable {
    public let groups: [EmojiGroup]
    public let emoji: [Emoji]

    public init(groups: [EmojiGroup], emoji: [Emoji]) {
        self.groups = groups
        self.emoji = emoji
    }

    public static let resourceName = "emoji-catalog"

    public static let shared: EmojiCatalog = {
        guard let url = BundledResources.url(forResource: resourceName, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? decode(data)
        else { return EmojiCatalog(groups: [], emoji: []) }
        return decoded.filtered(by: EmojiGlyphSupport.isRenderable)
    }()

    public func group(at index: Int) -> EmojiGroup? {
        groups.indices.contains(index) ? groups[index] : nil
    }

    public func emoji(inGroup index: Int) -> [Emoji] {
        emoji.filter { $0.groupIndex == index }
    }

    public func emoji(matching character: String) -> Emoji? {
        emoji.first { $0.character == character || $0.toneVariants.contains(character) }
    }

    public func filtered(by isRenderable: (String) -> Bool) -> EmojiCatalog {
        let supported = emoji.compactMap { entry -> Emoji? in
            guard isRenderable(entry.character) else { return nil }
            guard !entry.toneVariants.allSatisfy(isRenderable) else { return entry }
            return Emoji(
                character: entry.character, name: entry.name, groupIndex: entry.groupIndex,
                unicodeVersion: entry.unicodeVersion, terms: entry.terms)
        }
        let usedGroups = Set(supported.map(\.groupIndex))
        var remapped: [Int: Int] = [:]
        var keptGroups: [EmojiGroup] = []
        for (index, group) in groups.enumerated() where usedGroups.contains(index) {
            remapped[index] = keptGroups.count
            keptGroups.append(group)
        }
        return EmojiCatalog(
            groups: keptGroups,
            emoji: supported.map {
                Emoji(
                    character: $0.character, name: $0.name,
                    groupIndex: remapped[$0.groupIndex] ?? 0,
                    unicodeVersion: $0.unicodeVersion, terms: $0.terms,
                    toneVariants: $0.toneVariants)
            })
    }

    public static func decode(_ data: Data) throws -> EmojiCatalog {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return EmojiCatalog(
            groups: payload.groups,
            emoji: payload.emoji.map {
                Emoji(
                    character: $0.e, name: $0.n, groupIndex: $0.g, unicodeVersion: $0.v,
                    terms: $0.t ?? [], toneVariants: $0.s ?? [])
            })
    }

    private struct Payload: Decodable {
        struct Entry: Decodable {
            let e: String
            let n: String
            let g: Int
            let v: Double
            let t: [String]?
            let s: [String]?
        }

        let schema: Int
        let source: String
        let groups: [EmojiGroup]
        let emoji: [Entry]
    }
}
