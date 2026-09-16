import Foundation

public struct BifrostMatchTarget: Equatable, Sendable {
    public let characters: [Character]
    public let wordStarts: [Bool]

    public init(_ text: String) {
        var folded: [Character] = []
        var starts: [Bool] = []
        var previous: Character?
        folded.reserveCapacity(text.count)
        starts.reserveCapacity(text.count)
        for character in text {
            let isBoundary =
                character == " " || character == "-" || character == "_"
                || character == "." || character == "/"
            if isBoundary {
                previous = character
                continue
            }
            let previousWasBoundary = previous.map {
                $0 == " " || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/"
            }
            let caseBoundary = previous.map { $0.isLowercase && character.isUppercase } ?? false
            let digitBoundary = previous.map { !$0.isNumber && character.isNumber } ?? false
            starts.append(
                folded.isEmpty || previousWasBoundary == true || caseBoundary || digitBoundary)
            folded.append(Character(character.lowercased()))
            previous = character
        }
        characters = folded
        wordStarts = starts
    }

    public var isEmpty: Bool { characters.isEmpty }
}

public enum BifrostMatcher {
    public static let exactBonus = 400
    public static let prefixBonus = 200
    public static let wordStartScore = 60
    public static let adjacentScore = 70
    public static let looseScore = 12
    public static let gapPenalty = 2
    public static let lengthPenalty = 1

    public static func normalize(_ query: String) -> [Character] {
        var folded: [Character] = []
        for character in query where !character.isWhitespace {
            folded.append(Character(character.lowercased()))
        }
        return folded
    }

    public static func score(_ target: BifrostMatchTarget, query: [Character]) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard !target.isEmpty, query.count <= target.characters.count else { return nil }
        var total = 0
        var cursor = 0
        var previousIndex = -1
        for character in query {
            guard let index = next(character, in: target, from: cursor, adjacentTo: previousIndex)
            else { return nil }
            if index == previousIndex + 1 {
                total += adjacentScore
            } else if target.wordStarts[index] {
                total += wordStartScore
            } else {
                total += looseScore
            }
            if previousIndex >= 0 {
                total -= min(index - previousIndex - 1, 8) * gapPenalty
            }
            previousIndex = index
            cursor = index + 1
        }
        if query.count == target.characters.count { return total + exactBonus }
        if matchesPrefix(target, query: query) { total += prefixBonus }
        return total - min(target.characters.count, 40) * lengthPenalty
    }

    private static func matchesPrefix(_ target: BifrostMatchTarget, query: [Character]) -> Bool {
        guard query.count <= target.characters.count else { return false }
        for offset in 0..<query.count where target.characters[offset] != query[offset] {
            return false
        }
        return true
    }

    private static func next(
        _ character: Character, in target: BifrostMatchTarget, from cursor: Int,
        adjacentTo previousIndex: Int
    ) -> Int? {
        guard cursor < target.characters.count else { return nil }
        if previousIndex >= 0, cursor == previousIndex + 1,
            target.characters[cursor] == character
        {
            return cursor
        }
        var firstMatch: Int?
        var index = cursor
        while index < target.characters.count {
            if target.characters[index] == character {
                if target.wordStarts[index] { return index }
                if firstMatch == nil { firstMatch = index }
            }
            index += 1
        }
        return firstMatch
    }
}
