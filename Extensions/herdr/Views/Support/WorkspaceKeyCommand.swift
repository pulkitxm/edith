import AppKit
import EdithExtensionSupport

extension NSEvent.ModifierFlags {
    public var chordOnly: NSEvent.ModifierFlags {
        intersection([.command, .option, .control, .shift])
    }
}

enum WindowTabKeyCommand: Equatable {
    case selectTab(index: Int)
    case nextTab
    case previousTab

    static func resolve(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, tabbed: Bool
    ) -> WindowTabKeyCommand? {
        guard tabbed else { return nil }
        let flags = modifiers.chordOnly
        if keyCode == 48, flags.contains(.control), !flags.contains(.command) {
            return flags.contains(.shift) ? .previousTab : .nextTab
        }
        guard flags == .command, let characters, let value = Int(characters), value >= 1,
            value <= 9
        else { return nil }
        return .selectTab(index: value - 1)
    }
}

enum WorkspaceKeyCommand: Equatable {
    case nextPaneTab
    case previousPaneTab
    case nextPane
    case previousPane
    case nextTerminalTab
    case previousTerminalTab

    static func resolve(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags
    ) -> WorkspaceKeyCommand? {
        let flags = modifiers.chordOnly
        if flags == [.command, .option] {
            if keyCode == 124 { return .nextPaneTab }
            if keyCode == 123 { return .previousPaneTab }
        }
        if flags == [.command, .control] {
            if keyCode == 124 { return .nextPane }
            if keyCode == 123 { return .previousPane }
        }
        if flags == [.command, .shift] {
            if keyCode == 30 { return .nextTerminalTab }
            if keyCode == 33 { return .previousTerminalTab }
        }
        return nil
    }
}
