import Carbon.HIToolbox
import EdithKit
import Foundation

struct CommandBarShortcutSlot: Identifiable, Sendable {
    let id: Int
    let shortcut: CommandBarResultShortcut

    static let all: [CommandBarShortcutSlot] = [
        slot(1, kVK_ANSI_1), slot(2, kVK_ANSI_2), slot(3, kVK_ANSI_3),
        slot(4, kVK_ANSI_4), slot(5, kVK_ANSI_5), slot(6, kVK_ANSI_6),
        slot(7, kVK_ANSI_7), slot(8, kVK_ANSI_8), slot(9, kVK_ANSI_9),
    ]

    private static func slot(_ number: Int, _ keyCode: Int) -> CommandBarShortcutSlot {
        CommandBarShortcutSlot(
            id: number,
            shortcut: CommandBarResultShortcut(
                keyCode: keyCode, modifiers: controlKey | optionKey, label: "⌃⌥\(number)"))
    }
}

@MainActor
enum CommandBarResultHotKeys {
    private static let baseID: UInt32 = 1_000
    private static var registeredIDs: [UInt32] = []

    static func sync(controller: CommandBarController) {
        clear()
        let shortcuts = CommandBarPreferences.decodeShortcuts(
            SharedDefaults.store.string(forKey: AppStorageKeys.CommandBar.resultShortcuts))
        for (index, entry) in shortcuts.sorted(by: { $0.key < $1.key }).enumerated() {
            let id = baseID + UInt32(index)
            let resultID = entry.key
            let shortcut = entry.value
            let status = GlobalHotKey.set(
                id: id, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers
            ) { [weak controller] in
                controller?.executeShortcut(id: resultID)
            }
            if status == noErr { registeredIDs.append(id) }
        }
    }

    static func clear() {
        for id in registeredIDs { GlobalHotKey.clear(id: id) }
        registeredIDs.removeAll()
    }
}
