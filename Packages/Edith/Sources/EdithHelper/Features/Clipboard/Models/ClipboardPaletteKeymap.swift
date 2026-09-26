import EdithKit
import SwiftUI

enum ClipboardPaletteCommand: Equatable {
    case move(Int)
    case jump(top: Bool)
    case cycleCategory(Int)
    case paste(plainText: Bool)
    case quickPaste(Int, plainText: Bool)
    case togglePin
    case delete
    case clearUnpinned
    case clearSearch
    case dismiss
    case preferences
}

enum ClipboardPaletteKeymap {
    private static let relevantModifiers: EventModifiers = [.command, .option, .control, .shift]

    static func command(
        key: KeyEquivalent, modifiers: EventModifiers, queryIsEmpty: Bool
    ) -> ClipboardPaletteCommand? {
        let held = modifiers.intersection(relevantModifiers)
        switch key {
        case .upArrow, .downArrow:
            let up = key == .upArrow
            if held == .command { return .jump(top: up) }
            return held.isEmpty ? .move(up ? -1 : 1) : nil
        case .leftArrow, .rightArrow:
            return held.isEmpty ? .cycleCategory(key == .leftArrow ? -1 : 1) : nil
        case .return:
            if held.isEmpty { return .paste(plainText: false) }
            return held == .option ? .paste(plainText: true) : nil
        case .escape:
            return queryIsEmpty ? .dismiss : .clearSearch
        case .delete, .deleteForward:
            if held == [.command, .option] { return .clearUnpinned }
            if held == .command || (held.isEmpty && queryIsEmpty) { return .delete }
            return nil
        default:
            return commandShortcut(key.character, held: held)
        }
    }

    private static func commandShortcut(_ character: Character, held: EventModifiers)
        -> ClipboardPaletteCommand?
    {
        guard held.contains(.command), !held.contains(.control), !held.contains(.shift)
        else { return nil }
        if let digit = character.wholeNumberValue, (1...ClipboardPalette.shortcutLimit).contains(digit) {
            return .quickPaste(digit, plainText: held.contains(.option))
        }
        guard held == .command else { return nil }
        switch character.lowercased() {
        case "p": return .togglePin
        case ",": return .preferences
        default: return nil
        }
    }
}
