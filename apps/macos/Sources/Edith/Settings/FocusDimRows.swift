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

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Intensity") {
                    Text("\(Int(intensity * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $intensity, in: FocusDimMath.intensityRange)
                    .pointerCursor()
                Text("How dark the background gets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Animation") {
                    Text(String(format: "%.2fs", animationDuration))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $animationDuration, in: FocusDimMath.animationDurationRange)
                    .pointerCursor()
                Text("How quickly the dim follows you when switching apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Picker("Other displays", selection: $otherDisplaysMode) {
                    Text("Highlight front window").tag(FocusDimDisplayMode.perScreenFront)
                    Text("Dim unfocused fully").tag(FocusDimDisplayMode.dimUnfocused)
                }
                .pickerStyle(.segmented)
                .pointerCursor()
                Text(
                    "Highlight the front window on each screen, or fully dim displays without keyboard focus so you can tell where you're typing."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent {
                HotKeyRecorderControl(keyPrefix: "focusDimHotKey", defaultLabel: "⌥⌘F")
            } label: {
                HStack(spacing: 6) {
                    Text("Toggle hotkey")
                    InfoDot("Flip dimming on or off from anywhere.")
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
