import EdithKit
import SwiftUI

struct CommandBarRows: View {
    @AppStorage(AppStorageKeys.CommandBar.enabled, store: SharedDefaults.store) private
        var enabled =
        false
    @AppStorage(AppStorageKeys.CommandBar.showApplications, store: SharedDefaults.store) private
        var showApplications = true
    @AppStorage(AppStorageKeys.CommandBar.learnRanking, store: SharedDefaults.store) private
        var learnRanking = true
    @AppStorage(AppStorageKeys.CommandBar.registrationStatus, store: SharedDefaults.store) private
        var registrationStatus = 0

    var body: some View {
        Group {
            Section {
                LabeledContent {
                    HotKeyRecorderControl(keyPrefix: "commandBarHotKey", defaultLabel: "⌥Space")
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Command Bar hotkey")
                        InfoDot("Opens the palette over the application you are using.")
                    }
                }
                Toggle(
                    "Show installed applications",
                    isOn: $showApplications.configured(AppStorageKeys.CommandBar.showApplications))
                Toggle(
                    "Learn result ranking",
                    isOn: $learnRanking.configured(AppStorageKeys.CommandBar.learnRanking))
                if registrationStatus != 0 {
                    Label(
                        "This shortcut is already in use. Record a different shortcut.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                }
            } header: {
                Text("Palette")
            } footer: {
                Text(
                    "Option-Space is the default and is separate from Edith's global panel shortcut."
                )
                .font(.system(size: UIScale.pt(10)))
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Section {
                LabeledContent("Search processing") {
                    Text("On this Mac")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Saved ranking data") {
                    Text("Result IDs and usage counts")
                        .foregroundStyle(.secondary)
                }
                Button("Clear learned ranking", role: .destructive) {
                    SharedDefaults.store.removeObject(forKey: AppStorageKeys.CommandBar.usage)
                    IPC.post(IPC.Name.settingsChanged)
                }
                .disabled(!learnRanking)
            } header: {
                Text("Privacy")
            } footer: {
                Text(
                    "Query text is never saved. Calculations, conversions, and application search stay local."
                )
                .font(.system(size: UIScale.pt(10)))
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
    }
}
