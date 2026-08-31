import Foundation
import Testing

@testable import EdithKit

@Suite struct KeystrokeHighlightTests {
    @Test func resolvesPrintableAndSpecialKeys() {
        #expect(KeystrokeLabelResolver.keyLabel(keyCode: 0, characters: "a") == "A")
        #expect(KeystrokeLabelResolver.keyLabel(keyCode: 18, characters: "!") == "!")
        #expect(KeystrokeLabelResolver.keyLabel(keyCode: 49, characters: " ") == "Space")
        #expect(KeystrokeLabelResolver.keyLabel(keyCode: 123, characters: nil) == "←")
        #expect(KeystrokeLabelResolver.keyLabel(keyCode: 255, characters: nil) == nil)
    }

    @Test func ordersShortcutModifiersLikeMacOS() {
        let modifiers: KeystrokeModifiers = [.command, .shift, .option, .control]
        #expect(
            KeystrokeLabelResolver.labels(keyCode: 40, characters: "k", modifiers: modifiers)
                == ["⌃", "⌥", "⇧", "⌘", "K"])
    }

    @Test func omitsShiftWhenCharacterAlreadyCommunicatesUppercase() {
        #expect(
            KeystrokeLabelResolver.labels(
                keyCode: 0, characters: "A", modifiers: [.shift]) == ["A"])
        #expect(
            KeystrokeLabelResolver.labels(
                keyCode: 18, characters: "!", modifiers: [.shift]) == ["⇧", "!"])
    }

    @Test func arrowKeysDoNotClaimTheFunctionKeyWasPressed() {
        let modifiers: KeystrokeModifiers = [.option, .command, .function]
        #expect(
            KeystrokeLabelResolver.labels(
                keyCode: 123, characters: "\u{F702}", modifiers: modifiers)
                == ["⌥", "⌘", "←"])
        #expect(
            KeystrokeLabelResolver.labels(keyCode: 123, characters: nil, modifiers: modifiers)
                == ["⌥", "⌘", "←"])
        #expect(
            KeystrokeLabelResolver.labels(
                keyCode: 122, characters: "\u{F704}", modifiers: [.function]) == ["F1"])
    }

    @Test func functionModifiedNavigationKeysUseTheirLogicalKey() {
        #expect(
            KeystrokeLabelResolver.labels(
                keyCode: 123, characters: "\u{F729}", modifiers: [.function]) == ["Home"])
    }

    @Test func functionRemainsVisibleForOrdinaryKeys() {
        #expect(
            KeystrokeLabelResolver.labels(
                keyCode: 0, characters: "a", modifiers: [.function]) == ["fn", "A"])
    }

    @Test func queueLimitsAndExpiresEntries() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var queue = KeystrokeHighlightQueue(maximumVisible: 2)
        _ = queue.append(keys: ["A"], now: now, duration: 1)
        _ = queue.append(keys: ["B"], now: now.addingTimeInterval(0.2), duration: 1)
        let appended = queue.append(
            keys: ["C"], now: now.addingTimeInterval(0.4), duration: 1)
        let latest = try #require(appended)

        #expect(queue.entries.map(\.keys) == [["B"], ["C"]])
        queue.removeExpired(at: now.addingTimeInterval(1.3))
        #expect(queue.entries.map(\.keys) == [["C"]])
        queue.remove(id: latest.id)
        #expect(queue.entries.isEmpty)
    }

    @Test func queueRejectsEmptyPresses() {
        var queue = KeystrokeHighlightQueue()
        #expect(queue.append(keys: [], duration: 1) == nil)
        #expect(queue.entries.isEmpty)
    }
}
