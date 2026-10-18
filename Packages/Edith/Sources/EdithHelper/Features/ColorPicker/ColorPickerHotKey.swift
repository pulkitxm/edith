import EdithKit

enum ColorPickerHotKey {
    private static var binding: HotKeyBinding {
        HotKeyCatalog.binding(HotKeyCatalog.colorPicker)!
    }

    static var code: Int { binding.code() }
    static var mods: Int { binding.mods() }
    static var label: String { binding.label() }
}
