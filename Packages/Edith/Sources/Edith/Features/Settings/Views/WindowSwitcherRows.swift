import EdithKit
import SwiftUI

struct WindowSwitcherRows: View {
    @AppStorage(AppStorageKeys.WindowSwitcher.enabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(AppStorageKeys.WindowSwitcher.grouped, store: SharedDefaults.store) private
        var grouped = true
    @AppStorage(AppStorageKeys.WindowSwitcher.includedApps, store: SharedDefaults.store) private
        var includedApps = ""
    @AppStorage(AppStorageKeys.WindowSwitcher.hiddenApps, store: SharedDefaults.store) private
        var hiddenApps = ""

    var body: some View {
        Section("Switcher") {
            Button("Open Window Switcher") {
                IPC.post(
                    IPC.Name.requestWindowSwitcherOperation,
                    userInfo: [
                        WindowSwitcherIPC.requestIDKey: UUID().uuidString,
                        WindowSwitcherIPC.operationKey: WindowSwitcherOperation.show.rawValue,
                    ])
            }
            Toggle(
                "Group windows by application",
                isOn: $grouped.configured(AppStorageKeys.WindowSwitcher.grouped))
            LabeledContent {
                HotKeyRecorderControl(
                    keyPrefix: "windowSwitcherShowHotKey", defaultLabel: "⌥Tab")
            } label: {
                Text("Show shortcut")
            }
            LabeledContent {
                HotKeyRecorderControl(
                    keyPrefix: "windowSwitcherCycleHotKey", defaultLabel: "⌥`")
            } label: {
                Text("Cycle front app")
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        Section("Application rules") {
            TextField(
                "com.example.Helper",
                text: $includedApps.configured(AppStorageKeys.WindowSwitcher.includedApps))
            Text("Always include these bundle identifiers, separated by commas.")
                .settingsCaption()
            TextField(
                "com.example.Private",
                text: $hiddenApps.configured(AppStorageKeys.WindowSwitcher.hiddenApps))
            Text("Hide these bundle identifiers, separated by commas. Hide rules take priority.")
                .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
