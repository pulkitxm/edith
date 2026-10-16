import AppKit
import Foundation
import Testing

@testable import EdithHelper
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

    @Test func everyPressedModifierGetsItsOwnMacKeycap() {
        #expect(
            KeystrokeLabelResolver.labels(
                keyCode: 35, characters: "P", unmodifiedCharacters: "p",
                modifiers: [.option, .shift, .command]) == ["⌥", "⇧", "⌘", "P"])
        #expect(
            KeystrokeLabelResolver.labels(
                keyCode: 18, characters: "!", unmodifiedCharacters: "1",
                modifiers: [.shift]) == ["⇧", "1"])
    }

    @Test func everyModifierCombinationUsesMacOSOrdering() {
        let ordered: [(KeystrokeModifiers, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
            (.function, "fn"),
        ]
        for rawValue in UInt8(0)..<UInt8(32) {
            let modifiers = KeystrokeModifiers(rawValue: rawValue)
            let expected = ordered.compactMap { modifiers.contains($0.0) ? $0.1 : nil } + ["P"]
            #expect(
                KeystrokeLabelResolver.labels(
                    keyCode: 35, characters: "P", unmodifiedCharacters: "p",
                    modifiers: modifiers) == expected)
        }
    }

    @Test func actualMacEventsPreserveEveryPressedModifier() throws {
        let plain = try event(keyCode: 35, flags: [.maskAlternate, .maskCommand])
        let shifted = try event(
            keyCode: 35, flags: [.maskAlternate, .maskShift, .maskCommand])
        let all = try event(
            keyCode: 35,
            flags: [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn])
        let shiftedNumber = try event(keyCode: 18, flags: [.maskShift])

        #expect(KeystrokeHighlightRuntime.labels(from: plain) == ["⌥", "⌘", "P"])
        #expect(
            KeystrokeHighlightRuntime.labels(from: shifted) == ["⌥", "⇧", "⌘", "P"])
        #expect(
            KeystrokeHighlightRuntime.labels(from: all)
                == ["⌃", "⌥", "⇧", "⌘", "fn", "P"])
        #expect(KeystrokeHighlightRuntime.labels(from: shiftedNumber) == ["⇧", "1"])
    }

    @Test func cgEventFlagsMapToMacModifiersWithoutDroppingBits() {
        let cases: [(CGEventFlags, KeystrokeModifiers)] = [
            (.maskControl, .control), (.maskAlternate, .option), (.maskShift, .shift),
            (.maskCommand, .command), (.maskSecondaryFn, .function),
        ]
        for (flag, modifier) in cases {
            #expect(KeystrokeHighlightRuntime.modifiers(from: flag) == modifier)
        }
        #expect(
            KeystrokeHighlightRuntime.modifiers(from: [
                .maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn,
            ]) == [.control, .option, .shift, .command, .function])
    }

    @Test func coversMacSpecialFunctionNavigationAndKeypadKeys() {
        let expected: [UInt16: String] = [
            10: "§", 36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 64: "F17",
            65: ".",
            67: "*", 69: "+", 71: "Clear", 72: "Volume ↑", 73: "Volume ↓", 74: "Mute",
            75: "/", 76: "⌤", 78: "-", 79: "F18", 80: "F19", 81: "=", 82: "0",
            83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 90: "F20",
            91: "8", 92: "9", 93: "¥", 94: "_", 95: ",", 96: "F5", 97: "F6",
            98: "F7", 99: "F3", 100: "F8", 101: "F9", 102: "英数", 103: "F11",
            104: "かな", 105: "F13",
            106: "F16", 107: "F14", 109: "F10", 110: "Menu", 111: "F12", 113: "F15",
            114: "Help", 115: "Home", 116: "Page ↑", 117: "⌦", 118: "F4", 119: "End",
            120: "F2", 121: "Page ↓", 122: "F1", 123: "←", 124: "→", 125: "↓",
            126: "↑",
        ]
        for (keyCode, label) in expected {
            #expect(KeystrokeLabelResolver.keyLabel(keyCode: keyCode, characters: nil) == label)
        }
    }

    @Test func everyMacCharacterAndSpecialKeyPreservesTheFullChord() throws {
        let keyCodes: [CGKeyCode] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
            19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
            36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 53,
            64, 65, 67, 69, 71, 72, 73, 74, 75, 76, 78, 79, 80, 81, 82, 83, 84,
            85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101,
            102, 103, 104, 105, 106, 107, 109, 110, 111, 113, 114, 115, 116, 117,
            118, 119, 120, 121, 122, 123, 124, 125, 126,
        ]
        for keyCode in keyCodes {
            let labels = try #require(
                KeystrokeHighlightRuntime.labels(
                    from: event(
                        keyCode: keyCode,
                        flags: [.maskControl, .maskAlternate, .maskShift, .maskCommand])))
            #expect(Array(labels.prefix(4)) == ["⌃", "⌥", "⇧", "⌘"])
            #expect(labels.count == 5)
        }
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

    private func event(keyCode: CGKeyCode, flags: CGEventFlags) throws -> CGEvent {
        let event = try #require(
            CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
        event.flags = flags
        return event
    }
}
