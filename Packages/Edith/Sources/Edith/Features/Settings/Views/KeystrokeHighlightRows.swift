import EdithKit
import SwiftUI

struct KeystrokeHighlightRows: View {
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
                Toggle(
                    "Show keystrokes",
                    isOn: $active.configured(AppStorageKeys.KeystrokeHighlight.active))
                Text(
                    "Pause the overlay without removing the extension. The shortcut keeps working while the extension is enabled."
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
                    selection: $position.configured(AppStorageKeys.KeystrokeHighlight.position)
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
                        value: $duration.configured(AppStorageKeys.KeystrokeHighlight.duration),
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
                } else if runtimeError.isEmpty {
                    LabeledContent(
                        "Keyboard monitor", value: runtimeActive ? "Active" : "Starting")
                } else {
                    Label(runtimeError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
