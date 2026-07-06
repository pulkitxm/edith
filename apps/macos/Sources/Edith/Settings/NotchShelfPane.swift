import EdithKit
import SwiftUI

struct NotchShelfPane: View {
    @AppStorage("notchShelfEnabled", store: SharedDefaults.store) private var enabled = false
    @AppStorage("notchShelfOpenOnDrag", store: SharedDefaults.store) private var openOnDrag = true
    @AppStorage("notchShelfOpenOnHover", store: SharedDefaults.store) private var openOnHover = true
    @AppStorage("notchShelfRequireOption", store: SharedDefaults.store) private var requireOption =
        false
    @AppStorage("notchShelfKeepDuration", store: SharedDefaults.store) private var keepDuration =
        "forever"
    @AppStorage("notchShelfRemoveAfterDragOut", store: SharedDefaults.store)
    private var removeAfterDragOut = true
    @AppStorage("notchShelfShowOnExternal", store: SharedDefaults.store)
    private var showOnExternal = false
    @AppStorage("notchShelfHaptics", store: SharedDefaults.store) private var haptics = true

    var body: some View {
        Form {
            Section {
                Toggle("Enable notch shelf", isOn: $enabled)
                    .pointerCursor()
                Text("Turns the shelf and its drag monitoring on or off.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open when dragging near the notch", isOn: $openOnDrag)
                    .pointerCursor()
                Text("The island slides out mid-drag so you can drop without clicking first.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open on hover", isOn: $openOnHover)
                    .pointerCursor()
                Text("Expand when the mouse rests on the notch, without a drag.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("Require \u{2325} to trigger", isOn: $requireOption)
                        .pointerCursor()
                    InfoDot(
                        "Only expand — on drag or on hover — while you're holding Option. Keeps accidental passes over the notch from opening it."
                    )
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Section {
                HStack {
                    Picker("Keep items for", selection: $keepDuration) {
                        Text("Forever").tag("forever")
                        Text("1 hour").tag("oneHour")
                        Text("1 day").tag("oneDay")
                        Text("1 week").tag("oneWeek")
                        Text("1 month").tag("oneMonth")
                    }
                    .pointerCursor()
                    InfoDot(
                        "Parked files auto-delete after this long. They're copies — originals are never touched."
                    )
                }
                Toggle("Remove after dragging out", isOn: $removeAfterDragOut)
                    .pointerCursor()
                Text("Treats the shelf as a hand-off tray rather than storage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Section {
                Toggle("Show on external displays", isOn: $showOnExternal)
                    .pointerCursor()
                Text("Draws a small pill at the top of screens without a notch.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Haptic feedback", isOn: $haptics)
                    .pointerCursor()
                Text("A small trackpad tap when the shelf reacts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
        .formStyle(.grouped)
        .navigationTitle("Notch Shelf")
    }
}
