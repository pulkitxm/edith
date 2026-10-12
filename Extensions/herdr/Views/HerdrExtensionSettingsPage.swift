import EdithExtensionUI
import SwiftUI

struct HerdrExtensionSettingsPage: View {
    let model: HerdrSessionSettingsModel

    var body: some View {
        Form {
            Section("Sessions") {
                LabeledContent("Sources", value: "This Mac and SSH machines")
                Text("Follow live agent sessions, inspect their state, and open workspace diffs.")
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                HStack {
                    Button("Check sessions") { model.checkSessions() }.disabled(model.checking)
                    Button("Open Herdr") { model.openHerdr() }
                    Button("Open setup guide") { model.openGuide() }
                }
                if model.checking {
                    SkeletonGroup { SkeletonBlock(width: 238, height: 9, corner: 4) }
                        .accessibilityLabel("Checking Herdr sessions")
                } else if let result = model.result {
                    Text(result.message).font(.edithText(.caption))
                        .foregroundStyle(result.failed ? .red : .green)
                }
                if let error = model.error {
                    Text(error).font(.edithText(.caption)).foregroundStyle(.red)
                }
            }
        }
        .edithForm()
    }
}

enum HerdrSettingsSection: String {
    case extensionSettings = "extension"
    case agentActivity
    case backgroundAgent
}

struct HerdrActivitySettingsPage: View {
    let store: HerdrStore
    let monitor: AgentActivityMonitor

    var body: some View {
        AgentConnectionsPane(monitor: monitor)
            .pageTask(cancel: store.stopWatching) { await store.watch() }
    }
}
