import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct FocusDimPane: View {
    @AppStorage("focusDimEnabled", store: SharedDefaults.store) private var enabled = false
    @AppStorage("focusDimIntensity", store: SharedDefaults.store) private var intensity =
        FocusDimMath.defaultIntensity
    @AppStorage("focusDimAnimationDuration", store: SharedDefaults.store)
    private var animationDuration = FocusDimMath.defaultAnimationDuration
    @AppStorage("focusDimOtherDisplaysMode", store: SharedDefaults.store)
    private var otherDisplaysMode = FocusDimDisplayMode.perScreenFront

    var body: some View {
        Form {
            Section {
                HStack {
                    Toggle("Enable focus dim", isOn: $enabled)
                        .pointerCursor()
                    InfoDot(
                        "Dims everything behind your active app so the front window is the only bright thing."
                    )
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Intensity") {
                        Text("\(Int(intensity * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $intensity, in: FocusDimMath.intensityRange)
                        .pointerCursor()
                    Text("How dark the background gets.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Animation") {
                        Text(String(format: "%.2fs", animationDuration))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $animationDuration, in: FocusDimMath.animationDurationRange)
                        .pointerCursor()
                    Text("How quickly the dim follows you when switching apps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Other displays", selection: $otherDisplaysMode) {
                        Text("Highlight front window").tag(FocusDimDisplayMode.perScreenFront)
                        Text("Dim unfocused fully").tag(FocusDimDisplayMode.dimUnfocused)
                    }
                    .pickerStyle(.segmented)
                    .pointerCursor()
                    Text(
                        "Highlight the front window on each screen, or fully dim displays without keyboard focus so you can tell where you're typing."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    LabeledContent("Toggle hotkey") { FocusDimShortcutRecorder() }
                    InfoDot("Flip dimming on or off from anywhere.")
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
        .formStyle(.grouped)
        .navigationTitle("Focus Dim")
    }
}

private struct FocusDimShortcutRecorder: View {
    @State private var recording = false
    @State private var monitor: Any?
    @State private var label =
        SharedDefaults.store.string(forKey: "focusDimHotKeyLabel") ?? "⌥⌘F"

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
        label = SharedDefaults.store.string(forKey: "focusDimHotKeyLabel") ?? "⌥⌘F"
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
        SharedDefaults.store.set(Int(event.keyCode), forKey: "focusDimHotKeyCode")
        SharedDefaults.store.set(mods, forKey: "focusDimHotKeyMods")
        SharedDefaults.store.set(symbols + key, forKey: "focusDimHotKeyLabel")
        stop()
    }
}
