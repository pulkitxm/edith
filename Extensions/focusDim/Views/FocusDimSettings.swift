import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct FocusDimSettings: View {
    let presentation: ControlPresentation
    @AppStorage(FocusDimState.activeKey, store: SharedDefaults.store) private var active = false
    @AppStorage(AppStorageKeys.FocusDim.intensity, store: SharedDefaults.store) private
        var intensity = FocusDimMath.defaultIntensity
    @AppStorage(AppStorageKeys.FocusDim.animationDuration, store: SharedDefaults.store) private
        var animationDuration = FocusDimMath.defaultAnimationDuration
    @AppStorage(AppStorageKeys.FocusDim.otherDisplaysMode, store: SharedDefaults.store) private
        var mode = FocusDimDisplayMode.perScreenFront.rawValue

    private var displayMode: FocusDimDisplayMode { FocusDimDisplayMode.from(mode) }

    var body: some View {
        Form {
            if !presentation.active {
                Section {
                    SettingsNoticeRow(
                        "Focus Dim is off",
                        message: "Turn it on to dim background windows and change these settings.",
                        symbol: "power.circle.fill")
                }
            } else if presentation.ready, let error = presentation.error {
                Section {
                    SettingsErrorRow(
                        "Focus Dim is not responding", message: error,
                        retry: presentation.retry)
                }
            }
            Group {
                Section {
                    Toggle(isOn: $active.notifyingSettingsChange()) {
                        Text("Dim background windows")
                        Text(
                            "Darkens everything behind the window you are working in. Nothing is closed or moved."
                        )
                    }
                    SettingsShortcutRow(
                        keyPrefix: "focusDimHotKey", defaultLabel: "⌥⌘F",
                        purpose: "Turns dimming on or off from any app.")
                }
                Section("Appearance") {
                    SettingsSliderRow(
                        "Strength", subtitle: "How dark the background gets.",
                        value: $intensity.notifyingSettingsChange(),
                        in: FocusDimMath.intensityRange,
                        readout: "\(Int((intensity * 100).rounded()))%")
                    SettingsSliderRow(
                        "Fade speed",
                        subtitle: "How quickly the dimming follows you to another app.",
                        value: $animationDuration.notifyingSettingsChange(),
                        in: FocusDimMath.animationDurationRange,
                        readout: String(format: "%.2f s", animationDuration))
                    Picker(selection: $mode.notifyingSettingsChange()) {
                        Text("Keep front windows bright")
                            .tag(FocusDimDisplayMode.perScreenFront.rawValue)
                        Text("Dim them completely").tag(FocusDimDisplayMode.dimUnfocused.rawValue)
                    } label: {
                        Text("Other displays")
                        Text(
                            displayMode == .perScreenFront
                                ? "Each display keeps its front window bright."
                                : "Displays you are not typing on go fully dark, so you can see where your keyboard is."
                        )
                    }
                    .pickerStyle(.menu)
                }
                Section("Permission") {
                    LabeledContent {
                        Button("Allow Access") { presentation.perform("screenRecording") }
                            .buttonStyle(.edith(.secondary))
                    } label: {
                        Text("Screen Recording")
                        Text(
                            "macOS asks once so Focus Dim can see where your windows are. Nothing is recorded or saved."
                        )
                    }
                }
            }
            .disabled(!presentation.active)
            .opacity(presentation.active ? 1 : 0.5)
        }
        .settingsForm()
    }
}
