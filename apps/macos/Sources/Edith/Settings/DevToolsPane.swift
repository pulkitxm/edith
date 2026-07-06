import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct DevToolsPane: View {
    @AppStorage("colorPickerEnabled", store: SharedDefaults.store) private var colorPickerEnabled =
        false
    @AppStorage("colorPickerCopyFormat", store: SharedDefaults.store) private var copyFormat:
        ColorCopyFormat = .hex
    @AppStorage("colorPickerProfile", store: SharedDefaults.store) private var profile:
        ColorProfile = .sRGB
    @AppStorage("colorPickerHistorySize", store: SharedDefaults.store) private var historySize = 100
    @State private var history: [ColorSwatch] = ColorHistoryStore.load()

    var body: some View {
        Form {
            Section {
                Toggle("Color picker", isOn: $colorPickerEnabled)
                    .pointerCursor()
                Text(
                    "Summons the system loupe from a hotkey or the panel, then copies the sampled color to your clipboard."
                )
                .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Color Picker")
            }

            Section {
                HStack {
                    LabeledContent("Pick hotkey") { ColorPickerShortcutRecorder() }
                    InfoDot("Summons the magnifier from anywhere.")
                }
                Picker("Copy format", selection: $copyFormat) {
                    ForEach(ColorCopyFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pointerCursor()
                HStack {
                    Picker("Color profile", selection: $profile) {
                        ForEach(ColorProfile.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pointerCursor()
                    InfoDot(
                        "Compute values in sRGB or Display P3 — they differ on wide-gamut screens like this MacBook's."
                    )
                }
                HStack {
                    Stepper("History size: \(historySize)", value: $historySize, in: 1...100)
                    InfoDot("How many past colors to keep.")
                }
            }
            .disabled(!colorPickerEnabled)
            .opacity(colorPickerEnabled ? 1 : 0.5)

            if colorPickerEnabled, !history.isEmpty {
                Section {
                    ColorSwatchGrid(history: history, defaultFormat: copyFormat)
                } header: {
                    Text("Recent Colors")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dev Tools")
        .onAppear { history = ColorHistoryStore.load() }
    }
}

private struct ColorPickerShortcutRecorder: View {
    @State private var recording = false
    @State private var monitor: Any?
    @State private var label =
        SharedDefaults.store.string(forKey: "colorPickerHotKeyLabel") ?? "⌃⌥⌘C"

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press shortcut…" : label)
                .font(.system(size: 12, weight: .medium))
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
        }
        .pointerCursor()
        .onDisappear { if recording { stop() } }
        .help("Click, then press the new shortcut (Esc cancels)")
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
        label = SharedDefaults.store.string(forKey: "colorPickerHotKeyLabel") ?? "⌃⌥⌘C"
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
        if flags.contains(.control) { mods |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { mods |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { mods |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { mods |= cmdKey; symbols += "⌘" }
        let key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        SharedDefaults.store.set(Int(event.keyCode), forKey: "colorPickerHotKeyCode")
        SharedDefaults.store.set(mods, forKey: "colorPickerHotKeyMods")
        SharedDefaults.store.set(symbols + key, forKey: "colorPickerHotKeyLabel")
        stop()
    }
}

private struct ColorSwatchGrid: View {
    let history: [ColorSwatch]
    let defaultFormat: ColorCopyFormat

    private let columns = [GridItem(.adaptive(minimum: 28), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(history) { swatch in
                ColorSwatchChip(swatch: swatch, defaultFormat: defaultFormat)
            }
        }
    }
}

private struct ColorSwatchChip: View {
    let swatch: ColorSwatch
    let defaultFormat: ColorCopyFormat

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(swatch.color)
            .frame(width: 26, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12))
            )
            .contentShape(Rectangle())
            .onTapGesture { copy(defaultFormat) }
            .contextMenu {
                ForEach(ColorCopyFormat.allCases, id: \.self) { format in
                    Button(swatch.string(for: format)) { copy(format) }
                }
            }
            .help(swatch.string(for: defaultFormat))
            .pointerCursor()
    }

    private func copy(_ format: ColorCopyFormat) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(swatch.string(for: format), forType: .string)
    }
}
