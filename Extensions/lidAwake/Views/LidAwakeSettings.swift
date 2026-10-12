import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct LidAwakeSettings: View {
    let model: LidAwakeSettingsModel
    var body: some View {
        PageWorkspace {
            PageHeader("Lid Awake")
        } content: {
            Form {
                Section("Administrator approval") {
                    LabeledContent(
                        "Privileged carrier",
                        value: model.operations.lastSnapshot?.helperStatus ?? "Checking")
                    Button("Approve Lid Awake") {
                        model.requestApproval()
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                }
                LidAwakeRows(operations: model.operations, chooseSession: model.setSession)
                Section {
                    Text(
                        "Disabling or updating Lid Awake restores the sleep policy before its worker exits. If restoration fails, the extension stays enabled and reports the error."
                    ).font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
    }
}
