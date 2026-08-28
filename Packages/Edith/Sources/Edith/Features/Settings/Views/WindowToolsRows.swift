import EdithKit
import SwiftUI

struct WindowToolsRows: View {
    @AppStorage(AppStorageKeys.WindowTools.enabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(
        AppStorageKeys.WindowTools.greenButtonMaximizes, store: SharedDefaults.store)
    private var greenButtonMaximizes = true

    private let columns = [
        GridItem(.adaptive(minimum: UIScale.pt(112)), spacing: UIScale.pt(8))
    ]

    var body: some View {
        Section("Arrange") {
            LazyVGrid(columns: columns, spacing: UIScale.pt(8)) {
                ForEach(WindowLayoutAction.allCases) { action in
                    Button {
                        WindowLayoutRequest.send(action)
                    } label: {
                        Label(action.title, systemImage: action.symbolName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("Actions apply to the active app, or the app you used before opening Edith.")
                .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        Section("Behavior") {
            Toggle(
                "Green button maximizes without another Space",
                isOn: $greenButtonMaximizes.configured(
                    AppStorageKeys.WindowTools.greenButtonMaximizes)
            )
            Text("Click the green button again to restore the previous window frame.")
                .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        Section("Shortcuts") {
            shortcut("Left half", prefix: "windowToolsLeftHotKey", label: "⌃⌥←")
            shortcut("Right half", prefix: "windowToolsRightHotKey", label: "⌃⌥→")
            shortcut("Maximize", prefix: "windowToolsMaximizeHotKey", label: "⌃⌥M")
            shortcut("Restore", prefix: "windowToolsRestoreHotKey", label: "⌃⌥R")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func shortcut(_ title: String, prefix: String, label: String) -> some View {
        LabeledContent(title) {
            HotKeyRecorderControl(keyPrefix: prefix, defaultLabel: label)
        }
    }
}
