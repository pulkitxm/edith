import EdithKit

enum HingeHotKey {
    private static var binding: HotKeyBinding { HotKeyCatalog.binding(HotKeyCatalog.hinge)! }

    static var code: Int { binding.code() }
    static var mods: Int { binding.mods() }
    static var label: String { binding.label() }

    @MainActor
    static func register() {
        HotKeyRegistrar.install(HotKeyCatalog.hinge) { toggleHinge() }
    }

    @MainActor
    static func unregister() {
        HotKeyRegistrar.clear(HotKeyCatalog.hinge)
    }

    @MainActor
    static func save(code: Int, mods: Int, label: String) {
        HotKeyRegistrar.save(HotKeyCatalog.hinge, code: code, mods: mods, label: label)
    }
}

func toggleHinge() {
    let active = !HingeState.isActive()
    HingeState.setActive(active)
    IPC.post(IPC.Name.settingsChanged)
}
