import EdithKit
import SwiftUI

struct KeyboardToolsRows: View {
    @AppStorage(AppStorageKeys.KeyboardTools.enabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(AppStorageKeys.KeyboardTools.debounceEnabled, store: SharedDefaults.store) private
        var debounceEnabled = true
    @AppStorage(AppStorageKeys.KeyboardTools.debounceWindow, store: SharedDefaults.store) private
        var debounceWindow = KeyboardToolsSettings.defaultDebounceWindow
    @AppStorage(AppStorageKeys.KeyboardTools.superEnabled, store: SharedDefaults.store) private
        var superEnabled = true
    @AppStorage(AppStorageKeys.KeyboardTools.superTapAction, store: SharedDefaults.store) private
        var tapAction = KeyboardSuperTapAction.escape.rawValue
    @AppStorage(AppStorageKeys.KeyboardTools.superHoldAction, store: SharedDefaults.store) private
        var holdAction = KeyboardSuperHoldAction.hyper.rawValue
    @AppStorage(AppStorageKeys.KeyboardTools.runtimeActive, store: SharedDefaults.store) private
        var runtimeActive = false
    @AppStorage(AppStorageKeys.KeyboardTools.runtimeError, store: SharedDefaults.store) private
        var runtimeError = ""

    var body: some View {
        Group {
            Section("Debounce") {
                Toggle(
                    "Suppress accidental duplicate key presses",
                    isOn: $debounceEnabled.configured(
                        AppStorageKeys.KeyboardTools.debounceEnabled))
                Stepper(
                    value: $debounceWindow.configured(
                        AppStorageKeys.KeyboardTools.debounceWindow),
                    in: KeyboardToolsSettings.debounceRange, step: 10
                ) {
                    LabeledContent("Debounce window", value: "\(debounceWindow) ms")
                }
                .disabled(!debounceEnabled)
                Text("Hardware key repeat and alternating keys remain responsive.")
                    .settingsCaption()
            }

            Section("Super key") {
                Toggle(
                    "Use Caps Lock as Super",
                    isOn: $superEnabled.configured(AppStorageKeys.KeyboardTools.superEnabled))
                Picker(
                    "Quick tap",
                    selection: $tapAction.configured(AppStorageKeys.KeyboardTools.superTapAction)
                ) {
                    ForEach(KeyboardSuperTapAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                .disabled(!superEnabled)
                Picker(
                    "Hold with another key",
                    selection: $holdAction.configured(AppStorageKeys.KeyboardTools.superHoldAction)
                ) {
                    ForEach(KeyboardSuperHoldAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                .disabled(!superEnabled)
                Text("Hold Caps Lock with a key or mouse button to apply the selected modifiers.")
                    .settingsCaption()
            }

            Section("Status") {
                if !runtimeError.isEmpty {
                    Label(runtimeError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    LabeledContent("Keyboard filter", value: runtimeActive ? "Active" : "Stopped")
                }
                Text("Accessibility is required. Input Monitoring may also be requested by macOS.")
                    .settingsCaption()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
