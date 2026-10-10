import Carbon.HIToolbox
import Foundation

@MainActor
public enum HotKeyRegistrar {
    private static var actions: [String: () -> Void] = [:]

    public static func install(_ id: String, action: @escaping () -> Void) {
        actions[id] = action
        apply(id)
    }

    public static func apply(_ id: String) {
        guard let binding = HotKeyCatalog.binding(id) else { return }
        guard let action = actions[id], binding.isEnabled() else {
            GlobalHotKey.clear(id: binding.carbonID)
            return
        }
        GlobalHotKey.set(
            id: binding.carbonID, keyCode: binding.code(), modifiers: binding.mods(),
            action: action)
    }

    public static func applyAll() {
        for binding in HotKeyCatalog.bindings { apply(binding.id) }
    }

    public static func clear(_ id: String) {
        actions.removeValue(forKey: id)
        guard let binding = HotKeyCatalog.binding(id) else { return }
        GlobalHotKey.clear(id: binding.carbonID)
    }

    public static func clearAll() {
        actions.removeAll()
        for binding in HotKeyCatalog.bindings { GlobalHotKey.clear(id: binding.carbonID) }
    }

    public static func save(_ id: String, code: Int, mods: Int, label: String) {
        HotKeyCatalog.binding(id)?.save(code: code, mods: mods, label: label)
        apply(id)
    }
}
