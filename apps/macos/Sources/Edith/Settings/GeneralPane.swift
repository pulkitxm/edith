import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct GeneralPane: View {
    @AppStorage("appearance", store: SharedDefaults.store) private var appearance = "system"
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @AppStorage("lastPaletteTheme", store: SharedDefaults.store) private var lastPaletteTheme =
        "blue"
    @AppStorage("showDockIcon", store: SharedDefaults.store) private var showDockIcon = true

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pointerCursor()
                .onChange(of: appearance) { _, value in applyAppearance(value) }

                LabeledContent("Theme") {
                    HStack(spacing: 10) {
                        Toggle(
                            "Use accent",
                            isOn: Binding(
                                get: { themeName == "accent" },
                                set: { themeName = $0 ? "accent" : lastPaletteTheme })
                        )
                        .toggleStyle(.switch)
                        .pointerCursor()
                        ForEach(themePalette, id: \.name) { entry in
                            swatch(entry.name, color: entry.color)
                        }
                    }
                    .opacity(themeName == "accent" ? 0.5 : 1)
                }
            } header: {
                Text("Appearance")
            }

            Section {
                Toggle("Show Dock icon", isOn: $showDockIcon)
                    .pointerCursor()
                    .onChange(of: showDockIcon) { _, on in
                        NSApp.setActivationPolicy(on ? .regular : .accessory)
                    }
                HStack {
                    LabeledContent("Panel shortcut") { MainShortcutRecorder() }
                    InfoDot(
                        "The keyboard shortcut that opens Edith's menu bar panel, from anywhere."
                    )
                }
            } header: {
                Text("Window")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private func swatch(_ name: String, color: Color) -> some View {
        Button {
            themeName = name
            lastPaletteTheme = name
        } label: {
            ZStack {
                Circle().fill(color).frame(width: 20, height: 20)
                if themeName == name {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

private struct MainShortcutRecorder: View {
    @State private var recording = false
    @State private var monitor: Any?
    @State private var label = SharedDefaults.store.string(forKey: "hotKeyLabel") ?? "⌥⌘E"

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
        label = SharedDefaults.store.string(forKey: "hotKeyLabel") ?? "⌥⌘E"
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
        SharedDefaults.store.set(Int(event.keyCode), forKey: "hotKeyCode")
        SharedDefaults.store.set(mods, forKey: "hotKeyMods")
        SharedDefaults.store.set(symbols + key, forKey: "hotKeyLabel")
        stop()
    }
}
