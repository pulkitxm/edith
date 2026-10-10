import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import SwiftUI

struct ClipboardShortcutRecorder: View {
    @Binding var preferences: ClipboardPreferences
    let save: () -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press a shortcut. Escape cancels." : preferences.hotKeyLabel) {
            if recording { stop() } else { start() }
        }
        .buttonStyle(.edith(.secondary))
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !flags.isEmpty else { return nil }
            var modifiers = 0
            var prefix = ""
            if flags.contains(.control) { modifiers |= controlKey; prefix += "⌃" }
            if flags.contains(.option) { modifiers |= optionKey; prefix += "⌥" }
            if flags.contains(.shift) { modifiers |= shiftKey; prefix += "⇧" }
            if flags.contains(.command) { modifiers |= cmdKey; prefix += "⌘" }
            let key =
                event.keyCode == 49
                ? "Space" : (event.charactersIgnoringModifiers ?? "").uppercased()
            guard !key.isEmpty else { return nil }
            preferences.hotKeyCode = Int(event.keyCode)
            preferences.hotKeyMods = modifiers
            preferences.hotKeyLabel = prefix + key
            save()
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
