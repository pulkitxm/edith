import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct ShortcutsSettingsPane: View {
    @AppStorage(AppStorageKeys.Clipboard.enabled, store: SharedDefaults.store) private
        var clipboardEnabled =
        false
    @AppStorage(AppStorageKeys.ColorPicker.enabled, store: SharedDefaults.store) private
        var colorPickerEnabled =
        false
    @AppStorage(FocusDimState.enabledKey, store: SharedDefaults.store) private var focusDimEnabled =
        false
    @AppStorage(AppStorageKeys.Presenter.enabled, store: SharedDefaults.store) private
        var presenterEnabled =
        false

    private var extensionShortcuts: [ExtensionShortcut] {
        ExtensionShortcutVisibility.visible(
            clipboard: clipboardEnabled, focusDim: focusDimEnabled, presenter: presenterEnabled,
            colorPicker: colorPickerEnabled)
    }

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
                if extensionShortcuts.isEmpty {
                    Text("Extensions with shortcuts appear here when enabled.")
                        .settingsCaption()
                } else {
                    ForEach(extensionShortcuts, id: \.self) { shortcut in
                        extensionShortcutRow(shortcut)
                    }
                }
            } header: {
                Text("Extensions")
            }

            Section {
                LabeledContent("Toggle sidebar") {
                    Text("⌘B")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .kerning(2)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Close panel") {
                    Text("Esc")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Back") {
                    Text("⌘[")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .kerning(2)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Forward") {
                    Text("⌘]")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .kerning(2)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Fixed")
            } footer: {
                Text("Click a shortcut to record a new one; Esc cancels recording.")
                    .font(.system(size: UIScale.pt(10)))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }

    private func shortcutRow(
        _ title: String, subtitle: String, keyPrefix: String, defaultLabel: String
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title)
                Text(subtitle)
                    .settingsCaption()
            }
            Spacer()
            HotKeyRecorderControl(keyPrefix: keyPrefix, defaultLabel: defaultLabel)
        }
    }

    @ViewBuilder
    private func extensionShortcutRow(_ shortcut: ExtensionShortcut) -> some View {
        switch shortcut {
        case .clipboard:
            shortcutRow(
                "Clipboard history", subtitle: "Opens the clipboard history popup",
                keyPrefix: "clipboardHotKey", defaultLabel: "⌃⇧C")
        case .focusDim:
            shortcutRow(
                "Focus dim", subtitle: "Toggles background-window dimming",
                keyPrefix: "focusDimHotKey", defaultLabel: "⌥⌘F")
        case .presenter:
            shortcutRow(
                "Presenter mode", subtitle: "Forces presenter blur on or off",
                keyPrefix: "presenterHotKey", defaultLabel: "⇧⌥⌘P")
        case .colorPicker:
            shortcutRow(
                "Pick a color", subtitle: "Summons the color picker loupe",
                keyPrefix: "colorPickerHotKey", defaultLabel: "⌃⌥⌘C")
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
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .kerning(recording ? 0 : 2)
                .padding(.vertical, UIScale.pt(2))
                .padding(.horizontal, UIScale.pt(6))
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
        IPC.post(IPC.Name.settingsChanged)
        stop()
    }
}
