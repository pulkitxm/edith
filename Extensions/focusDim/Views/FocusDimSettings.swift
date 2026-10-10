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
                Toggle("Dim now", isOn: $active)
                LabeledContent("Intensity", value: "\(Int(intensity * 100))%")
                Slider(value: $intensity, in: FocusDimMath.intensityRange)
                LabeledContent("Animation", value: String(format: "%.2fs", animationDuration))
                Slider(value: $animationDuration, in: FocusDimMath.animationDurationRange)
                EdithSegmentedPicker(
                    "Other displays", selection: $mode,
                    options: FocusDimDisplayMode.allCases.map(\.rawValue),
                    label: {
                        $0 == FocusDimDisplayMode.perScreenFront.rawValue
                            ? "Highlight front window" : "Dim unfocused fully"
                    })
                LabeledContent("Toggle hotkey") {
                    HotKeyRecorderControl(keyPrefix: "focusDimHotKey", defaultLabel: "⌥⌘F")
                }
                Button("Allow Screen Recording") { presentation.perform("screenRecording") }
                    .disabled(!presentation.active)
            } header: {
                Text("Focus Dim").font(.edithText(.title)).bold()
            }
        }
        .formStyle(.grouped)
        .onChange(of: active) { changed() }
        .onChange(of: intensity) { changed() }
        .onChange(of: animationDuration) { changed() }
        .onChange(of: mode) { changed() }
    }

    private func changed() { IPC.post(IPC.Name.settingsChanged) }
}
