import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct PresenterPane: View {
    @AppStorage("presenterMode", store: SharedDefaults.store) private var presenterMode = false
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store) private var presenterBlurMusic =
        true
    @AppStorage("presenterBlurMoney", store: SharedDefaults.store) private var presenterBlurMoney =
        true
    @AppStorage("presenterAutoEnabled", store: SharedDefaults.store) private var autoEnabled = false
    @AppStorage("presenterHideMenuBarNumbers", store: SharedDefaults.store)
    private var hideMenuBarNumbers = true
    @AppStorage("presenterDetectRecording", store: SharedDefaults.store)
    private var detectRecording = true
    @AppStorage("presenterDetectScreenSharing", store: SharedDefaults.store)
    private var detectScreenSharing = true
    @AppStorage("presenterDetectMirroring", store: SharedDefaults.store)
    private var detectMirroring = true

    var body: some View {
        Form {
            Section {
                HStack {
                    Toggle("Manual presenter mode", isOn: $presenterMode)
                        .pointerCursor()
                    InfoDot(
                        "Blurs sensitive numbers and track names everywhere in Edith until you turn it back off."
                    )
                }
                Toggle("Blur music", isOn: $presenterBlurMusic)
                    .pointerCursor()
                    .disabled(!presenterMode && !autoEnabled)
                Toggle("Blur cost and usage figures", isOn: $presenterBlurMoney)
                    .pointerCursor()
                    .disabled(!presenterMode && !autoEnabled)
            } header: {
                Text("Manual")
            }

            Section {
                HStack {
                    Toggle("Auto presenter mode", isOn: $autoEnabled)
                        .pointerCursor()
                    InfoDot(
                        "Automatically blurs Edith when your screen looks like it's being shared or recorded. Manual presenter mode keeps working independently."
                    )
                }
                Group {
                    HStack {
                        Toggle("Hide menu bar numbers", isOn: $hideMenuBarNumbers)
                            .pointerCursor()
                        InfoDot(
                            "Replaces the usage percentages in the menu bar while presenting - they're visible in every screen share otherwise."
                        )
                    }
                    HStack {
                        Toggle("Detect screen recordings", isOn: $detectRecording)
                            .pointerCursor()
                        InfoDot("Also blur during QuickTime or ⇧⌘5 recordings.")
                    }
                    HStack {
                        Toggle("Detect macOS Screen Sharing", isOn: $detectScreenSharing)
                            .pointerCursor()
                        InfoDot(
                            "Also blur when someone views this Mac via Screen Sharing or Remote Management."
                        )
                    }
                    HStack {
                        Toggle("Mirrored display counts", isOn: $detectMirroring)
                            .pointerCursor()
                        InfoDot("Blur when your display mirrors to a projector, TV, or AirPlay.")
                    }
                }
                .disabled(!autoEnabled)
                .opacity(autoEnabled ? 1 : 0.5)
            } header: {
                Text("Auto detection")
            } footer: {
                Text(
                    "Recognizing a share's window title (e.g. \"Zoom share statusbar window\") needs Screen Recording access for EdithMenuBar. Without it, detection falls back to coarser app + window position heuristics."
                )
                .font(.caption)
            }

            Section {
                Button("Open Screen Recording Settings…") {
                    NSWorkspace.shared.open(
                        URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                        )!)
                }
                .pointerCursor()
            }

            Section {
                HStack {
                    LabeledContent("Toggle hotkey") { PresenterShortcutRecorder() }
                    InfoDot(
                        "Forces presenter mode on or off from anywhere - a manual escape hatch for when auto-detection guesses wrong."
                    )
                }
            } header: {
                Text("Shortcut")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Presenter")
    }
}

private struct PresenterShortcutRecorder: View {
    @State private var recording = false
    @State private var monitor: Any?
    @State private var label =
        SharedDefaults.store.string(forKey: "presenterHotKeyLabel")
        ?? "⇧⌥⌘P"

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
        label = SharedDefaults.store.string(forKey: "presenterHotKeyLabel") ?? "⇧⌥⌘P"
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
        SharedDefaults.store.set(Int(event.keyCode), forKey: "presenterHotKeyCode")
        SharedDefaults.store.set(mods, forKey: "presenterHotKeyMods")
        SharedDefaults.store.set(symbols + key, forKey: "presenterHotKeyLabel")
        stop()
    }
}
