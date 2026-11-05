import EdithExtensionSupport
import EdithExtensionUI
import AppKit
import SwiftUI

struct KeystrokeHighlightRows: View {
    let presentation: ControlPresentation
    @AppStorage(AppStorageKeys.KeystrokeHighlight.enabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(AppStorageKeys.KeystrokeHighlight.active, store: SharedDefaults.store) private
        var active = false
    @AppStorage(AppStorageKeys.KeystrokeHighlight.duration, store: SharedDefaults.store) private
        var duration = KeystrokeHighlightSettings.defaultDuration
    @AppStorage(AppStorageKeys.KeystrokeHighlight.position, store: SharedDefaults.store) private
        var position = KeystrokeHighlightPosition.bottom.rawValue
    @AppStorage(
        AppStorageKeys.KeystrokeHighlight.runtimeActive, store: SharedDefaults.store
    ) private
        var runtimeActive = false
    @AppStorage(AppStorageKeys.KeystrokeHighlight.runtimeError, store: SharedDefaults.store) private
        var runtimeError = ""

    var body: some View {
        Group {
            Section("Control") {
                Text(
                    "Shows the keys you press as keycaps on screen, handy for demos and recordings. Passwords typed into secure fields are never shown."
                )
                .settingsCaption()
                if !presentation.active {
                    Label(
                        "Turn the Keystroke Highlight extension on to use it and change these settings.",
                        systemImage: "info.circle"
                    )
                    .settingsCaption()
                }
                Toggle(
                    "Show keystrokes",
                    isOn: $active.notifyingSettingsChange())
                Text(
                    "Turn this off to pause the overlay without disabling the extension. The shortcut flips it from any app."
                )
                .settingsCaption()
                LabeledContent {
                    HotKeyRecorderControl(
                        keyPrefix: "keystrokeHighlightHotKey", defaultLabel: "⌃⌥⌘K")
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Toggle shortcut")
                        InfoDot("Starts or pauses keystroke highlighting from anywhere.")
                    }
                }
            }

            Section("Display") {
                Picker(
                    "Position",
                    selection: $position.notifyingSettingsChange()
                ) {
                    ForEach(KeystrokeHighlightPosition.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                VStack(alignment: .leading, spacing: UIScale.pt(7)) {
                    LabeledContent("Visible for") {
                        Text(String(format: "%.2g seconds", duration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $duration.notifyingSettingsChange(),
                        in: KeystrokeHighlightSettings.durationRange, step: 0.25)
                }
                HStack(spacing: UIScale.pt(5)) {
                    ForEach(["⌘", "⇧", "A"], id: \.self) { key in
                        Text(key)
                            .font(
                                .system(
                                    size: UIScale.pt(14), weight: .semibold, design: .rounded)
                            )
                            .foregroundStyle(.white)
                            .frame(minWidth: UIScale.pt(34), minHeight: UIScale.pt(32))
                            .background(
                                Color(red: 0.08, green: 0.09, blue: 0.11),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(7))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: UIScale.pt(7))
                                    .strokeBorder(.white.opacity(0.3))
                            }
                    }
                    Spacer()
                    Text("keycap preview")
                        .settingsCaption()
                }
                Text("Secure keyboard input is never shown.")
                    .settingsCaption()
            }

            Section("Status") {
                if !active {
                    LabeledContent("Keyboard monitor", value: "Paused")
                    Text(
                        "Turn on Show keystrokes to start. Edith is not reading key presses while paused."
                    )
                    .settingsCaption()
                } else if runtimeError.isEmpty {
                    LabeledContent(
                        "Keyboard monitor", value: runtimeActive ? "Active" : "Starting")
                } else {
                    Label(runtimeError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(
                        "macOS needs your permission before Edith can see key presses. Choose Allow Input Monitoring, then switch Edith on in System Settings."
                    )
                    .settingsCaption()
                    Button("Allow Input Monitoring") {
                        presentation.perform("inputMonitoring")
                    }.disabled(!presentation.active)
                }
            }
        }
        .disabled(!presentation.active)
        .opacity(presentation.active ? 1 : 0.5)
    }
}
