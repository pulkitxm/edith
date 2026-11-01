import AppKit
import Carbon.HIToolbox
import EdithExtensionCore
import SwiftUI

public struct HotKeyRecorderControl: View {
    private let keyPrefix: String
    private let defaultLabel: String
    @State private var recording = false
    @State private var label = ""

    public init(keyPrefix: String, defaultLabel: String) {
        self.keyPrefix = keyPrefix
        self.defaultLabel = defaultLabel
    }

    public var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press shortcut…" : label)
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .kerning(recording ? 0 : 2)
                .padding(.vertical, UIScale.pt(2))
                .padding(.horizontal, UIScale.pt(6))
        }
        .background(ShortcutKeyCapture(recording: $recording, handle: handle))
        .onAppear { label = currentLabel }
        .onDisappear { if recording { stop() } }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UserDefaults.didChangeNotification, object: ExtensionScope.installed.defaults()
            )
        ) { _ in
            if !recording { label = currentLabel }
        }
        .help("Click, then press the new shortcut (Esc cancels)")
    }

    private var currentLabel: String {
        ExtensionScope.installed.defaults().string(forKey: keyPrefix + "Label") ?? defaultLabel
    }

    private func start() {
        recording = true
        NSApp.activate(ignoringOtherApps: true)
    }

    private func stop() {
        recording = false
        label = currentLabel
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {
            stop()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
        else { return }
        var mods = 0
        var symbols = ""
        if flags.contains(.control) {
            mods |= controlKey
            symbols += "⌃"
        }
        if flags.contains(.option) {
            mods |= optionKey
            symbols += "⌥"
        }
        if flags.contains(.shift) {
            mods |= shiftKey
            symbols += "⇧"
        }
        if flags.contains(.command) {
            mods |= cmdKey
            symbols += "⌘"
        }
        let label = HotKeyGlyph.label(
            modifiers: symbols, keyCode: Int(event.keyCode),
            characters: event.charactersIgnoringModifiers)
        ExtensionScope.installed.defaults().set(Int(event.keyCode), forKey: keyPrefix + "Code")
        ExtensionScope.installed.defaults().set(mods, forKey: keyPrefix + "Mods")
        ExtensionScope.installed.defaults().set(label, forKey: keyPrefix + "Label")
        IPC.post(IPC.Name.settingsChanged)
        stop()
    }
}
