import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct FocusDimRows: View {
    @AppStorage("focusDimEnabled", store: SharedDefaults.store) private var enabled = false
    @AppStorage("focusDimIntensity", store: SharedDefaults.store) private var intensity =
        FocusDimMath.defaultIntensity
    @AppStorage("focusDimAnimationDuration", store: SharedDefaults.store)
    private var animationDuration = FocusDimMath.defaultAnimationDuration
    @AppStorage("focusDimOtherDisplaysMode", store: SharedDefaults.store)
    private var otherDisplaysMode = FocusDimDisplayMode.perScreenFront
    @AppStorage(FocusDimState.activeKey, store: SharedDefaults.store) private var active = false

    var body: some View {
        Section {
            Toggle("Dim now", isOn: $active)
                .pointerCursor()
            Text(
                "Turns the dimming on and off. The shortcut keeps working either way; removing the extension is a separate switch."
            )
            .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                LabeledContent("Intensity") {
                    Text("\(Int(intensity * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $intensity, in: FocusDimMath.intensityRange)
                    .pointerCursor()
                Text("How dark the background gets.")
                    .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                LabeledContent("Animation") {
                    Text(String(format: "%.2fs", animationDuration))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $animationDuration, in: FocusDimMath.animationDurationRange)
                    .pointerCursor()
                Text("How quickly the dim follows you when switching apps.")
                    .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Picker("Other displays", selection: $otherDisplaysMode) {
                    Text("Highlight front window").tag(FocusDimDisplayMode.perScreenFront)
                    Text("Dim unfocused fully").tag(FocusDimDisplayMode.dimUnfocused)
                }
                .pickerStyle(.segmented)
                .pointerCursor()
                Text(
                    "Highlight the front window on each screen, or fully dim displays without keyboard focus so you can tell where you're typing."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
            }
            LabeledContent {
                HotKeyRecorderControl(keyPrefix: "focusDimHotKey", defaultLabel: "⌥⌘F")
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Toggle hotkey")
                    InfoDot("Flip dimming on or off from anywhere.")
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
