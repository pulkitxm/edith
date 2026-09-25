import AppKit

enum BrowserShortcut: Equatable {
    case newTab, closeTab, reopenClosedTab, focusAddress
    case reload, hardReload, back, forward
    case nextTab, previousTab, selectTab(Int), lastTab
    case zoomIn, zoomOut, zoomReset
    case copy, cut, paste, selectAll, undo, redo

    static func match(characters: String, modifiers: NSEvent.ModifierFlags) -> BrowserShortcut? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        let key = characters.lowercased()
        if flags == .control { return key == "\t" ? .nextTab : nil }
        if flags == [.control, .shift] {
            return key == "\t" || key == "\u{19}" ? .previousTab : nil
        }
        if flags == .command { return command(key) }
        if flags == [.command, .shift] { return commandShift(key) }
        if flags == [.command, .option] {
            switch key {
            case "\u{F703}": return .nextTab
            case "\u{F702}": return .previousTab
            default: return nil
            }
        }
        return nil
    }

    private static func command(_ key: String) -> BrowserShortcut? {
        switch key {
        case "t": .newTab
        case "w": .closeTab
        case "l": .focusAddress
        case "r": .reload
        case "[", "\u{F702}": .back
        case "]", "\u{F703}": .forward
        case "=", "+": .zoomIn
        case "-": .zoomOut
        case "0": .zoomReset
        case "c": .copy
        case "x": .cut
        case "v": .paste
        case "a": .selectAll
        case "z": .undo
        case "9": .lastTab
        default:
            if let digit = Int(key), (1...8).contains(digit) { .selectTab(digit - 1) } else { nil }
        }
    }

    private static func commandShift(_ key: String) -> BrowserShortcut? {
        switch key {
        case "t": .reopenClosedTab
        case "r": .hardReload
        case "z": .redo
        case "[", "{": .previousTab
        case "]", "}": .nextTab
        case "=", "+": .zoomIn
        default: nil
        }
    }

    var editAction: Selector? {
        switch self {
        case .copy: #selector(NSText.copy(_:))
        case .cut: #selector(NSText.cut(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        case .undo: Selector(("undo:"))
        case .redo: Selector(("redo:"))
        default: nil
        }
    }
}
