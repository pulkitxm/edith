import AppKit

enum WindowWorkspaceCommand: Equatable {
    case nextTab, previousTab, nextPane, previousPane, closeTab, showLibrary, reopenTab, reload,
        focusAddress
    case selectTab(Int)
    case layout(HerdrLayoutKey)

    static func resolve(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
        -> Self?
    {
        let flags = modifiers.chordOnly
        if keyCode == 48, flags == .control || flags == [.control, .shift] {
            return flags.contains(.shift) ? .previousTab : .nextTab
        }
        if flags == [.command, .control] {
            if keyCode == 124 { return .nextPane }
            if keyCode == 123 { return .previousPane }
        }
        if let layout = HerdrLayoutKey.resolve(keyCode: keyCode, modifiers: modifiers) {
            return .layout(layout)
        }
        if flags == [.command, .shift], characters?.lowercased() == "t" { return .reopenTab }
        guard flags == .command, let key = characters?.lowercased() else { return nil }
        switch key {
        case "w": return .closeTab
        case "t", "0": return .showLibrary
        case "r": return .reload
        case "l": return .focusAddress
        default:
            guard let index = Int(key), (1...9).contains(index) else { return nil }
            return .selectTab(index - 1)
        }
    }
}
