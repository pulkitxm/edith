import EdithKit
import SwiftUI

struct MachinesRows: View {
    @AppStorage("tabMachinesEnabled", store: SharedDefaults.store) private var enabled = false
    @AppStorage("machinesNotifyDown", store: SharedDefaults.store) private var notifyDown = true
    @AppStorage("machinesNotifyDiskFull", store: SharedDefaults.store) private var notifyDisk = true
    @AppStorage("machinesDiskThreshold", store: SharedDefaults.store) private var diskThreshold =
        90.0
    @AppStorage("machinesAutoConnect", store: SharedDefaults.store) private var autoConnect = true

    var body: some View {
        Section {
            Toggle("Connect when the page opens", isOn: $autoConnect)
            Toggle("Notify when a machine goes offline", isOn: $notifyDown)
            Toggle("Notify when a disk is nearly full or stalled", isOn: $notifyDisk)
            if notifyDisk {
                HStack {
                    Text("Warn above")
                    Slider(value: $diskThreshold, in: 70...98, step: 1)
                    Text("\(Int(diskThreshold))%")
                        .font(DashSkin.mono(11))
                        .monospacedDigit()
                        .frame(width: UIScale.pt(42), alignment: .trailing)
                }
            }
        } header: {
            Text("Monitoring")
        } footer: {
            Text(
                "Checks run in the background while Edith is open and notify once per change, "
                    + "not repeatedly.")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        Section {
            LabeledContent("Connections") {
                Text("System ssh with connection sharing")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Hosts") {
                Text("Imported from ~/.ssh/config")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Passwords") {
                Text("Stored in your login Keychain")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("How it connects")
        } footer: {
            Text(
                "Edith reuses your existing SSH setup, so agent keys, jump hosts, and per-host "
                    + "options in your config keep working. Host keys are pinned on first "
                    + "connection.")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
