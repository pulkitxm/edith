import AppKit
import Carbon.HIToolbox
import EdithExtensionUI
import SwiftUI

struct HostHotKeyRecorder: View {
    let keyPrefix: String
    let defaults: UserDefaults
    var commit: () -> Void = {}
    @AppStorage private var label: String
    @State private var recording = false

    init(
        keyPrefix: String, defaultLabel: String, defaults: UserDefaults,
        commit: @escaping () -> Void = {}
    ) {
        self.keyPrefix = keyPrefix; self.defaults = defaults; self.commit = commit
        _label = AppStorage(wrappedValue: defaultLabel, keyPrefix + "Label", store: defaults)
    }
    var body: some View {
        Button(recording ? "Press a shortcut. Escape cancels." : label) {
            if recording { stop() } else { start() }
        }.buttonStyle(.edith(.secondary))
            .background(ShortcutKeyCapture(recording: $recording, handle: handle))
            .onDisappear { stop() }
    }
    private func start() { recording = true }
    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard
            let shortcut = HostRecordedShortcut(
                code: event.keyCode, flags: flags, characters: event.charactersIgnoringModifiers)
        else { return }
        defaults.set(Int(event.keyCode), forKey: keyPrefix + "Code")
        defaults.set(shortcut.modifiers, forKey: keyPrefix + "Mods")
        label = shortcut.label; commit(); stop()
    }
    private func stop() { recording = false }

}
struct HostRecordedShortcut: Equatable {
    let modifiers: Int
    let label: String
    init?(code: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        guard !flags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        var modifiers = 0
        var prefix = ""
        if flags.contains(.control) { modifiers |= controlKey; prefix += "⌃" }
        if flags.contains(.option) { modifiers |= optionKey; prefix += "⌥" }
        if flags.contains(.shift) { modifiers |= shiftKey; prefix += "⇧" }
        if flags.contains(.command) { modifiers |= cmdKey; prefix += "⌘" }
        let key = code == 49 ? "Space" : (characters ?? "").uppercased()
        guard !key.isEmpty, key.utf8.count <= 16 else { return nil }
        self.modifiers = modifiers; label = prefix + key
    }
}
