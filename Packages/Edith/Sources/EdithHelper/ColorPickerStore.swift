import AppKit
import Carbon.HIToolbox
import EdithKit
import Observation

@MainActor
@Observable
final class ColorPickerStore: FeatureModule {
    private(set) var history: [ColorSwatch] = []

    init() {
        history = ColorHistoryStore.load()
    }

    func shutdown() {
        GlobalHotKey.clear(id: GlobalHotKey.ID.colorPicker)
    }

    func registerHotKey() {
        GlobalHotKey.set(
            id: GlobalHotKey.ID.colorPicker, keyCode: ColorPickerHotKey.code,
            modifiers: ColorPickerHotKey.mods
        ) { [weak self] in
            self?.pick()
        }
    }

    func pick() {
        NSColorSampler().show { [weak self] color in
            guard let color else { return }
            Task { @MainActor in
                self?.commit(color)
            }
        }
    }

    func copyDefault(_ swatch: ColorSwatch) {
        copyToPasteboard(swatch.string(for: format))
    }

    private func commit(_ color: NSColor) {
        guard let converted = color.usingColorSpace(profile.nsColorSpace) else { return }
        let swatch = ColorSwatch(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            profile: profile)
        copyToPasteboard(swatch.string(for: format))
        ColorHistoryStore.add(swatch, limit: historySize)
        history = ColorHistoryStore.load()
        IPC.post(IPC.Name.settingsChanged)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private var format: ColorCopyFormat {
        let raw = SharedDefaults.store.string(forKey: AppStorageKeys.ColorPicker.copyFormat) ?? ""
        return ColorCopyFormat(rawValue: raw) ?? .hex
    }

    private var profile: ColorProfile {
        ColorProfile(
            rawValue: SharedDefaults.store.string(forKey: AppStorageKeys.ColorPicker.profile) ?? "")
            ?? .sRGB
    }

    private var historySize: Int {
        let raw =
            SharedDefaults.store.object(forKey: AppStorageKeys.ColorPicker.historySize) as? Int
            ?? 100
        return min(max(raw, 1), 100)
    }
}

enum ColorPickerHotKey {
    static var code: Int {
        SharedDefaults.store.object(forKey: "colorPickerHotKeyCode") as? Int ?? kVK_ANSI_C
    }
    static var mods: Int {
        SharedDefaults.store.object(forKey: "colorPickerHotKeyMods") as? Int
            ?? (cmdKey | optionKey | controlKey)
    }
    static var label: String {
        SharedDefaults.store.string(forKey: "colorPickerHotKeyLabel") ?? "⌃⌥⌘C"
    }
}
