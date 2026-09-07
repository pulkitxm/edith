import Carbon.HIToolbox
import EdithCore
import Foundation

public struct HotKeyBinding: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let carbonID: UInt32
    public let codeKey: String
    public let modsKey: String
    public let labelKey: String
    public let defaultCode: Int
    public let defaultMods: Int
    public let defaultLabel: String
    public let abilityID: String?

    public init(
        id: String, title: String, carbonID: UInt32, codeKey: String, modsKey: String,
        labelKey: String, defaultCode: Int, defaultMods: Int, defaultLabel: String,
        abilityID: String?
    ) {
        self.id = id
        self.title = title
        self.carbonID = carbonID
        self.codeKey = codeKey
        self.modsKey = modsKey
        self.labelKey = labelKey
        self.defaultCode = defaultCode
        self.defaultMods = defaultMods
        self.defaultLabel = defaultLabel
        self.abilityID = abilityID
    }

    public func code(in defaults: UserDefaults = SharedDefaults.store) -> Int {
        defaults.object(forKey: codeKey) as? Int ?? defaultCode
    }

    public func mods(in defaults: UserDefaults = SharedDefaults.store) -> Int {
        defaults.object(forKey: modsKey) as? Int ?? defaultMods
    }

    public func label(in defaults: UserDefaults = SharedDefaults.store) -> String {
        defaults.string(forKey: labelKey) ?? defaultLabel
    }

    public func isEnabled(in defaults: UserDefaults = SharedDefaults.store) -> Bool {
        guard let abilityID else { return true }
        guard let entry = ExtensionRegistry.entry(abilityID) else { return false }
        return entry.isEnabled(in: defaults)
    }

    public func save(
        code: Int, mods: Int, label: String, in defaults: UserDefaults = SharedDefaults.store
    ) {
        defaults.set(code, forKey: codeKey)
        defaults.set(mods, forKey: modsKey)
        defaults.set(label, forKey: labelKey)
    }
}

public enum HotKeyCatalog {
    public static let panel = "panel"
    public static let clipboard = "clipboard"
    public static let notchShelf = "notchShelf"
    public static let focusDim = "focusDim"
    public static let colorPicker = "colorPicker"
    public static let micMute = "micMute"
    public static let presenter = "presenter"
    public static let emoji = "emoji"
    public static let keystrokeHighlight = "keystrokeHighlight"

    public static let bindings: [HotKeyBinding] = [
        HotKeyBinding(
            id: panel, title: "Open the Edith panel", carbonID: 1, codeKey: "hotKeyCode",
            modsKey: "hotKeyMods", labelKey: "hotKeyLabel", defaultCode: kVK_ANSI_E,
            defaultMods: cmdKey | optionKey, defaultLabel: "⌥⌘E", abilityID: nil),
        HotKeyBinding(
            id: clipboard, title: "Clipboard history", carbonID: 2,
            codeKey: "clipboardHotKeyCode", modsKey: "clipboardHotKeyMods",
            labelKey: "clipboardHotKeyLabel", defaultCode: kVK_ANSI_C,
            defaultMods: controlKey | shiftKey, defaultLabel: "⌃⇧C", abilityID: "clipboard"),
        HotKeyBinding(
            id: emoji, title: "Emoji picker", carbonID: 8,
            codeKey: AppStorageKeys.Emoji.hotKeyCode, modsKey: AppStorageKeys.Emoji.hotKeyMods,
            labelKey: AppStorageKeys.Emoji.hotKeyLabel, defaultCode: kVK_ANSI_E,
            defaultMods: controlKey | shiftKey, defaultLabel: "⌃⇧E", abilityID: "emoji"),
        HotKeyBinding(
            id: colorPicker, title: "Color picker", carbonID: 5,
            codeKey: "colorPickerHotKeyCode", modsKey: "colorPickerHotKeyMods",
            labelKey: "colorPickerHotKeyLabel", defaultCode: kVK_ANSI_C,
            defaultMods: cmdKey | optionKey | controlKey, defaultLabel: "⌃⌥⌘C",
            abilityID: "colorPicker"),
        HotKeyBinding(
            id: micMute, title: "Mute every microphone", carbonID: 6, codeKey: "micHotKeyCode",
            modsKey: "micHotKeyMods", labelKey: "micHotKeyLabel", defaultCode: kVK_ANSI_M,
            defaultMods: cmdKey | shiftKey, defaultLabel: "⌘⇧M", abilityID: "micMute"),
        HotKeyBinding(
            id: focusDim, title: "Focus dim", carbonID: 4, codeKey: "focusDimHotKeyCode",
            modsKey: "focusDimHotKeyMods", labelKey: "focusDimHotKeyLabel",
            defaultCode: kVK_ANSI_F, defaultMods: cmdKey | optionKey, defaultLabel: "⌥⌘F",
            abilityID: "focusDim"),
        HotKeyBinding(
            id: presenter, title: "Presenter mode", carbonID: 7, codeKey: "presenterHotKeyCode",
            modsKey: "presenterHotKeyMods", labelKey: "presenterHotKeyLabel",
            defaultCode: kVK_ANSI_P, defaultMods: cmdKey | optionKey | shiftKey,
            defaultLabel: "⇧⌥⌘P", abilityID: "presenter"),
        HotKeyBinding(
            id: keystrokeHighlight, title: "Keystroke highlight", carbonID: 9,
            codeKey: AppStorageKeys.KeystrokeHighlight.hotKeyCode,
            modsKey: AppStorageKeys.KeystrokeHighlight.hotKeyMods,
            labelKey: AppStorageKeys.KeystrokeHighlight.hotKeyLabel, defaultCode: kVK_ANSI_K,
            defaultMods: controlKey | optionKey | cmdKey, defaultLabel: "⌃⌥⌘K",
            abilityID: "keystrokeHighlight"),
    ]

    public static func binding(_ id: String) -> HotKeyBinding? {
        bindings.first { $0.id == id }
    }

    public static func enabled(
        in defaults: UserDefaults = SharedDefaults.store
    ) -> [HotKeyBinding] {
        bindings.filter { $0.isEnabled(in: defaults) }
    }

    public static func conflicts(
        in defaults: UserDefaults = SharedDefaults.store
    ) -> [[HotKeyBinding]] {
        Dictionary(grouping: enabled(in: defaults)) {
            Combination(code: $0.code(in: defaults), mods: $0.mods(in: defaults))
        }
        .values.filter { $0.count > 1 }.map { $0.sorted { $0.id < $1.id } }
    }

    public struct Combination: Hashable, Sendable {
        public let code: Int
        public let mods: Int

        public init(code: Int, mods: Int) {
            self.code = code
            self.mods = mods
        }
    }
}
