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
    @State private var monitor: Any?

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
        }.buttonStyle(.edith(.secondary)).onDisappear { stop() }
    }
    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let characters = event.charactersIgnoringModifiers
            let handled = MainActor.assumeIsolated {
                if code == 53 { stop(); return true }
                guard
                    let shortcut = HostRecordedShortcut(
                        code: code, flags: flags, characters: characters)
                else { return false }
                defaults.set(Int(code), forKey: keyPrefix + "Code")
                defaults.set(shortcut.modifiers, forKey: keyPrefix + "Mods")
                label = shortcut.label; commit(); stop(); return true
            }
            return handled ? nil : event
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false
    }
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
