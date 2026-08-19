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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    private var dark: Bool { scheme == .dark }

    private var extensionShortcuts: [ExtensionShortcut] {
        ExtensionShortcutVisibility.visible(
            clipboard: clipboardEnabled, focusDim: focusDimEnabled, presenter: presenterEnabled,
            colorPicker: colorPickerEnabled)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                SkinCard(title: "Global", dark: dark) {
                    shortcutRow(
                        "Open panel", subtitle: "Opens the menu bar panel from anywhere",
                        keyPrefix: "hotKey", defaultLabel: "⌥⌘E")
                }

                SkinCard(title: "Extensions", dark: dark) {
                    if extensionShortcuts.isEmpty {
                        Text("Extensions with shortcuts appear here when enabled.")
                            .settingsCaption()
                    } else {
                        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                            ForEach(extensionShortcuts, id: \.self) { shortcut in
                                extensionShortcutRow(shortcut)
                            }
                        }
                    }
                }

                SkinCard(
                    title: "Fixed",
                    note: "Click a shortcut to record a new one; Esc cancels recording.",
                    dark: dark
                ) {
                    VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                        fixedRow("Toggle sidebar", "⌘B")
                        fixedRow("Close panel", "Esc")
                        fixedRow("Back", "⌘[")
                        fixedRow("Forward", "⌘]")
                    }
                }
            }
            .pageContent(compact)
            .padding(.top, UIScale.pt(16))
        }
        .background(DashSkin.paper(dark))
    }

    private func fixedRow(_ title: String, _ key: String) -> some View {
        LabeledContent(title) {
            Text(key)
                .font(DashSkin.mono(12, weight: .medium))
                .kerning(1.5)
                .foregroundStyle(DashSkin.inkSoft(dark))
        }
        .foregroundStyle(DashSkin.ink(dark))
    }

    private func shortcutRow(
        _ title: String, subtitle: String, keyPrefix: String, defaultLabel: String
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title)
                    .foregroundStyle(DashSkin.ink(dark))
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
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press shortcut…" : currentLabel)
                .font(DashSkin.mono(12, weight: .medium))
                .kerning(recording ? 0 : 1.5)
                .foregroundStyle(recording ? DashSkin.accent(dark) : DashSkin.ink(dark))
                .padding(.vertical, UIScale.pt(3))
                .padding(.horizontal, UIScale.pt(9))
                .background(
                    DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(6))
                        .strokeBorder(
                            recording ? DashSkin.accent(dark) : DashSkin.lineStrong(dark),
                            lineWidth: UIScale.pt(1))
                }
        }
        .buttonStyle(.plain)
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
