import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HingeRows: View {
    let presentation: ControlPresentation
    @AppStorage(HingeState.activeKey, store: SharedDefaults.store) private var active = false
    @AppStorage(HingeSettings.effectStrength, store: SharedDefaults.store) private var strength =
        1.0
    @AppStorage(HingeSettings.sideFill, store: SharedDefaults.store) private var sideFill =
        HingeSideFill.blur
    @AppStorage(HingeSettings.cropsTop, store: SharedDefaults.store) private var cropsTop = true
    @AppStorage(HingeSettings.blursByDistance, store: SharedDefaults.store) private
        var blursByDistance = true
    @AppStorage(HingeSettings.openAngle, store: SharedDefaults.store) private var openAngle = 100.0
    @AppStorage(HingeSettings.sensorAvailable, store: SharedDefaults.store) private
        var sensorAvailable = false
    @AppStorage(HingeSettings.status, store: SharedDefaults.store) private var status = ""

    var body: some View {
        Form {
            Section {
                Toggle("Fold the desktop", isOn: $active.notifyingSettingsChange())
                Text(
                    "Close the lid and the desktop bends with it. The shortcut keeps working either way."
                )
                .settingsCaption()
                if !status.isEmpty {
                    Text(status)
                        .settingsCaption()
                }
                LabeledContent("Open position") {
                    HStack(spacing: UIScale.pt(8)) {
                        Text("\(Int(openAngle.rounded()))°")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("Set") { presentation.perform("calibrate") }
                            .disabled(!sensorAvailable)
                    }
                }
                Text(
                    "Starts at 100°. Set the lid angle you actually sit at, and Hinge remembers it."
                )
                .settingsCaption()
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    LabeledContent("Strength") {
                        Text("\(Int(strength * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $strength.notifyingSettingsChange(),
                        in: HingeSettings.strengthRange
                    )
                    Text("How far the desktop folds as the lid closes.")
                        .settingsCaption()
                }
                EdithSegmentedPicker(
                    "Sides",
                    selection: $sideFill.notifyingSettingsChange(),
                    options: HingeSideFill.allCases,
                    label: { $0 == .blur ? "Blur" : "Black" }
                )
                Toggle("Crop the top", isOn: $cropsTop.notifyingSettingsChange())
                Toggle("Blur by distance", isOn: $blursByDistance.notifyingSettingsChange())
                LabeledContent {
                    HotKeyRecorderControl(keyPrefix: "hingeHotKey", defaultLabel: "⌃⌥H")
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Toggle hotkey")
                        InfoDot("Turn the fold on or off from anywhere.")
                    }
                }
            }
            .disabled(!presentation.active)
            .opacity(presentation.active ? 1 : 0.5)
        }
        .edithForm()
    }
}
