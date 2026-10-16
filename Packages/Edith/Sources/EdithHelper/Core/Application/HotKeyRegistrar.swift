import Carbon.HIToolbox
import EdithKit
import Foundation

@MainActor
enum HotKeyRegistrar {
    private static var actions: [String: () -> Void] = [:]

    static func install(_ id: String, action: @escaping () -> Void) {
        actions[id] = action
        apply(id)
    }

    static func apply(_ id: String) {
        guard let binding = HotKeyCatalog.binding(id) else { return }
        guard let action = actions[id], binding.isEnabled() else {
            GlobalHotKey.clear(id: binding.carbonID)
            return
        }
        GlobalHotKey.set(
            id: binding.carbonID, keyCode: binding.code(), modifiers: binding.mods(),
            action: action)
    }

    static func applyAll() {
        for binding in HotKeyCatalog.bindings { apply(binding.id) }
    }

    static func clear(_ id: String) {
        guard let binding = HotKeyCatalog.binding(id) else { return }
        GlobalHotKey.clear(id: binding.carbonID)
    }

    static func clearAll() {
        for binding in HotKeyCatalog.bindings { GlobalHotKey.clear(id: binding.carbonID) }
    }

    static func save(_ id: String, code: Int, mods: Int, label: String) {
        HotKeyCatalog.binding(id)?.save(code: code, mods: mods, label: label)
        apply(id)
    }
}
