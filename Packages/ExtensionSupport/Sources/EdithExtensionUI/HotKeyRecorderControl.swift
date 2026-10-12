import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import SwiftUI

public struct HotKeyRecorderControl: View {
    private let keyPrefix: String
    @AppStorage private var label: String
    @State private var recording = false
    @State private var monitor: Any?

    public init(keyPrefix: String, defaultLabel: String) {
        self.keyPrefix = keyPrefix
        _label = AppStorage(
            wrappedValue: defaultLabel, keyPrefix + "Label", store: SharedDefaults.store)
    }

    public var body: some View {
        Button(recording ? "Press a shortcut. Escape cancels." : label) {
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
            SharedDefaults.store.set(Int(event.keyCode), forKey: keyPrefix + "Code")
            SharedDefaults.store.set(modifiers, forKey: keyPrefix + "Mods")
            label = prefix + key
            IPC.post(IPC.Name.settingsChanged)
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
