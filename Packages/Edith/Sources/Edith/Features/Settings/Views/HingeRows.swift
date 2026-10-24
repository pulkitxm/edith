import EdithKit
import SwiftUI

struct HingeRows: View {
    @AppStorage(HingeState.enabledKey, store: SharedDefaults.store) private var enabled = false
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
        Section {
            Toggle("Fold the desktop", isOn: $active.configured(HingeState.activeKey))
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
                    Button("Set") {
                        SharedDefaults.store.set(
                            UUID().uuidString, forKey: HingeSettings.calibrateRequest)
                        IPC.post(IPC.Name.settingsChanged)
                    }
                    .disabled(!sensorAvailable)
                }
            }
            Text("Starts at 100°. Set the lid angle you actually sit at, and Hinge remembers it.")
                .settingsCaption()
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                LabeledContent("Strength") {
                    Text("\(Int(strength * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $strength.configured(HingeSettings.effectStrength),
                    in: HingeSettings.strengthRange
                )
                Text("How far the desktop folds as the lid closes.")
                    .settingsCaption()
            }
            EdithSegmentedPicker(
                "Sides",
                selection: $sideFill.configured(HingeSettings.sideFill),
                options: HingeSideFill.allCases,
                label: { $0 == .blur ? "Blur" : "Black" }
            )
            Toggle("Crop the top", isOn: $cropsTop.configured(HingeSettings.cropsTop))
            Toggle(
                "Blur by distance",
                isOn: $blursByDistance.configured(HingeSettings.blursByDistance))
            LabeledContent {
                HotKeyRecorderControl(keyPrefix: "hingeHotKey", defaultLabel: "⌃⌥H")
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Toggle hotkey")
                    InfoDot("Turn the fold on or off from anywhere.")
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
