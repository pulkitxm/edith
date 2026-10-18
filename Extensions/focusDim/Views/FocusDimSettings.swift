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

    var body: some View {
        Form {
            Section {
                Toggle("Dim now", isOn: $active.notifyingSettingsChange())
                Text(
                    "Turns the dimming on and off. The shortcut keeps working either way; removing the extension is a separate switch."
                )
                .settingsCaption()
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    LabeledContent("Intensity") {
                        Text("\(Int(intensity * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $intensity.notifyingSettingsChange(),
                        in: FocusDimMath.intensityRange)
                    Text("How dark the background gets.")
                        .settingsCaption()
                }
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    LabeledContent("Animation") {
                        Text(String(format: "%.2fs", animationDuration))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $animationDuration.notifyingSettingsChange(),
                        in: FocusDimMath.animationDurationRange)
                    Text("How quickly the dim follows you when switching apps.")
                        .settingsCaption()
                }
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    EdithSegmentedPicker(
                        "Other displays", selection: $mode.notifyingSettingsChange(),
                        options: FocusDimDisplayMode.allCases.map(\.rawValue),
                        label: {
                            $0 == FocusDimDisplayMode.perScreenFront.rawValue
                                ? "Highlight front window" : "Dim unfocused fully"
                        })
                    Text(
                        "Highlight the front window on each screen, or fully dim displays without keyboard focus so you can tell where you're typing."
                    )
                    .settingsCaption()
                }
                LabeledContent {
                    HotKeyRecorderControl(keyPrefix: "focusDimHotKey", defaultLabel: "⌥⌘F")
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Toggle hotkey")
                        InfoDot("Flip dimming on or off from anywhere.")
                    }
                }
                Button("Allow Screen Recording") { presentation.perform("screenRecording") }
                    .disabled(!presentation.active)
            }
            .disabled(!presentation.active)
            .opacity(presentation.active ? 1 : 0.5)
        }
        .edithForm()
    }
}
