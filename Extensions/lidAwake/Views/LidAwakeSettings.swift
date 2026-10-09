import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

extension Binding {
    func lidAwakeSetting(_ key: String) -> Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { value in
                wrappedValue = value; SharedDefaults.store.set(value, forKey: key);
                NotificationCenter.default.post(
                    name: Notification.Name("lidAwakeSettingsChanged"), object: nil)
            })
    }
}

struct LidAwakeSettings: View {
    let worker: LidAwakeWorker
    @State private var approvalError: String?
    var body: some View {
        PageWorkspace {
            PageHeader("Lid Awake")
        } content: {
            Form {
                Section("Administrator approval") {
                    LabeledContent(
                        "Privileged carrier", value: worker.engine.snapshot().helperStatus)
                    Button("Approve Lid Awake") {
                        do { try worker.requestApproval(); approvalError = nil } catch {
                            approvalError = error.localizedDescription
                        }
                    }
                    if let approvalError { Text(approvalError).foregroundStyle(.red) }
                }
                LidAwakeRows(operations: worker.operations)
                Section {
                    Text(
                        "Disabling or updating Lid Awake restores the sleep policy before its worker exits. If restoration fails, the extension stays enabled and reports the error."
                    ).font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
    }
}
