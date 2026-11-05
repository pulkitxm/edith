import EdithExtensionSupport
import EdithExtensionUI
import AppKit
import SwiftUI

struct KeystrokeHighlightRows: View {
    let presentation: ControlPresentation
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
            if !presentation.active {
                Section {
                    SettingsNoticeRow(
                        "Keystroke Highlight is off",
                        message: "Turn it on to show your key presses and change these settings.",
                        symbol: "power.circle.fill")
                }
            } else if presentation.ready, let error = presentation.error {
                Section {
                    SettingsErrorRow(
                        "Keystroke Highlight is not responding", message: error,
                        retry: presentation.retry)
                }
            }
            Group {
                Section {
                    Toggle(isOn: $active.notifyingSettingsChange()) {
                        Text("Show keystrokes")
                        Text(
                            "Draws the keys you press as keycaps on screen, handy for demos and recordings."
                        )
                    }
                    SettingsShortcutRow(
                        keyPrefix: "keystrokeHighlightHotKey",
                        defaultLabel: "\u{2303}\u{2325}\u{2318}K",
                        purpose: "Starts or pauses the keycaps from any app.")
                }
                Section("Keycaps") {
                    Picker(selection: $position.notifyingSettingsChange()) {
                        ForEach(KeystrokeHighlightPosition.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    } label: {
                        Text("Position")
                        Text("The edge of the screen where keycaps appear.")
                    }
                    SettingsSliderRow(
                        "Stay visible", subtitle: "How long each key stays before it fades.",
                        value: $duration.notifyingSettingsChange(),
                        in: KeystrokeHighlightSettings.durationRange, step: 0.25,
                        readout: String(format: "%.2g s", duration))
                    LabeledContent {
                        KeystrokeCapPreview()
                    } label: {
                        Text("Preview")
                        Text("Passwords typed into secure fields are never shown.")
                    }
                }
                Section("Status") {
                    status
                }
            }
            .disabled(!presentation.active)
            .opacity(presentation.active ? 1 : 0.5)
        }
    }

    @ViewBuilder private var status: some View {
        if !active {
            SettingsRow(
                "Keyboard monitoring",
                subtitle: "Edith is not reading key presses. Turn on Show keystrokes to start."
            ) {
                Text("Paused").foregroundStyle(.secondary)
            }
        } else if runtimeError.isEmpty {
            SettingsRow(
                "Keyboard monitoring",
                subtitle: "Key presses are only used to draw the keycaps and are never saved."
            ) {
                Label(
                    runtimeActive ? "Active" : "Starting",
                    systemImage: runtimeActive ? "checkmark.circle.fill" : "clock"
                )
                .foregroundStyle(runtimeActive ? Color.green : Color.secondary)
            }
        } else {
            LabeledContent {
                Button("Allow Access") { presentation.perform("inputMonitoring") }
                    .buttonStyle(.edith(.secondary))
            } label: {
                Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundColor(.orange)
                    + Text(" Input Monitoring is needed")
                Text(
                    "macOS asks before Edith can see key presses. Choose Allow Access, then switch on Edith in System Settings."
                )
            }
        }
    }
}

private struct KeystrokeCapPreview: View {
    var body: some View {
        HStack(spacing: UIScale.pt(4)) {
            ForEach(["\u{2318}", "\u{21E7}", "A"], id: \.self) { key in
                Text(key)
                    .font(.system(size: UIScale.pt(13), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: UIScale.pt(28), minHeight: UIScale.pt(28))
                    .background(
                        Color(red: 0.08, green: 0.09, blue: 0.11),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: UIScale.pt(6))
                            .strokeBorder(.white.opacity(0.24))
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keycap preview: Command, Shift, A")
    }
}
