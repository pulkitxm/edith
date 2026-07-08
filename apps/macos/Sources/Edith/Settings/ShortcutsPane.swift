import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct ShortcutsPane: View {
    @AppStorage("clipboardEnabled", store: SharedDefaults.store) private var clipboardEnabled =
        false
    @AppStorage("colorPickerEnabled", store: SharedDefaults.store) private var colorPickerEnabled =
        false
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var mainWindowSection =
        MainDestination.dashboard.rawValue

    var body: some View {
        Form {
            Section {
                shortcutRow(
                    "Open panel", subtitle: "Opens the menu bar panel from anywhere",
                    keyPrefix: "hotKey", defaultLabel: "⌥⌘E")
            } header: {
                Text("Global")
            }

            Section {
                shortcutRow(
                    "Clipboard history", subtitle: "Opens the clipboard history popup",
                    keyPrefix: "clipboardHotKey", defaultLabel: "⌃⇧C",
                    offExtension: !clipboardEnabled
                        ? (id: "clipboard", message: "Clipboard extension is off") : nil)
                shortcutRow(
                    "Focus dim", subtitle: "Toggles background-window dimming",
                    keyPrefix: "focusDimHotKey", defaultLabel: "⌥⌘F")
                shortcutRow(
                    "Presenter mode", subtitle: "Forces presenter blur on or off",
                    keyPrefix: "presenterHotKey", defaultLabel: "⇧⌥⌘P")
                shortcutRow(
                    "Pick a color", subtitle: "Summons the color picker loupe",
                    keyPrefix: "colorPickerHotKey", defaultLabel: "⌃⌥⌘C",
                    offExtension: !colorPickerEnabled
                        ? (id: "colorPicker", message: "Color Picker extension is off") : nil)
            } header: {
                Text("Extensions")
            }

            Section {
                LabeledContent("Toggle sidebar") {
                    Text("⌘B")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Close panel") {
                    Text("Esc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Fixed")
            } footer: {
                Text("Click a shortcut to record a new one; Esc cancels recording.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }

    private func shortcutRow(
        _ title: String, subtitle: String, keyPrefix: String, defaultLabel: String,
        offExtension: (id: String, message: String)? = nil
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let offExtension {
                    Button {
                        SharedDefaults.store.set(offExtension.id, forKey: "extensionsExpand")
                        mainWindowSection = MainDestination.extensions.rawValue
                    } label: {
                        Text("\(offExtension.message) - turn it on ›")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                } else {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HotKeyRecorderControl(keyPrefix: keyPrefix, defaultLabel: defaultLabel)
                .opacity(offExtension == nil ? 1 : 0.5)
        }
    }
}

struct HotKeyRecorderControl: View {
    let keyPrefix: String
    let defaultLabel: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var label = ""

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press shortcut…" : currentLabel)
                .font(.system(size: 12, weight: .medium))
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
        }
        .pointerCursor()
        .onAppear { label = currentLabel }
        .onDisappear { if recording { stop() } }
        .help("Click, then press the new shortcut (Esc cancels)")
    }

    private var currentLabel: String {
        SharedDefaults.store.string(forKey: keyPrefix + "Label") ?? defaultLabel
    }

    private func start() {
        recording = true
        NSApp.activate(ignoringOtherApps: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
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
        let key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        SharedDefaults.store.set(Int(event.keyCode), forKey: keyPrefix + "Code")
        SharedDefaults.store.set(mods, forKey: keyPrefix + "Mods")
        SharedDefaults.store.set(symbols + key, forKey: keyPrefix + "Label")
        stop()
    }
}
