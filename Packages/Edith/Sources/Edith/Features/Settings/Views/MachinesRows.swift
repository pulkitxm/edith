import EdithKit
import SwiftUI

struct MachinesRows: View {
    @State private var model = MachinesModel.shared
    @State private var addSheetPresented = false
    @AppStorage(AppStorageKeys.Machines.notifyDown, store: SharedDefaults.store) private
        var notifyDown = true
    @AppStorage(AppStorageKeys.Machines.notifyDiskFull, store: SharedDefaults.store) private
        var notifyDisk = true
    @AppStorage(AppStorageKeys.Machines.diskThreshold, store: SharedDefaults.store) private
        var diskThreshold =
        FleetMath.diskWarningPercent
    @AppStorage(AppStorageKeys.Machines.autoConnect, store: SharedDefaults.store) private
        var autoConnect = true

    var body: some View {
        Section {
            Toggle(
                "Connect when the page opens",
                isOn: $autoConnect.configured(AppStorageKeys.Machines.autoConnect))
            Toggle(
                "Notify when a machine goes offline",
                isOn: $notifyDown.configured(AppStorageKeys.Machines.notifyDown))
            Toggle(
                "Notify when a disk is nearly full or stalled",
                isOn: $notifyDisk.configured(AppStorageKeys.Machines.notifyDiskFull))
            if notifyDisk {
                HStack {
                    Text("Warn above")
                    Slider(
                        value: $diskThreshold.configured(AppStorageKeys.Machines.diskThreshold),
                        in: 70...98, step: 1)
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

        Section("Setup") {
            HStack {
                Button("Add machine...") { addSheetPresented = true }
                Button("Open Machines") { SectionWindow.open(.machines) }
            }
            Text("Add an SSH host here or manage existing connections on the Machines page.")
                .settingsCaption()
        }

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
        .sheet(isPresented: $addSheetPresented) {
            AddMachineSheet { machine, secrets in
                model.add(machine, secrets: changes(secrets))
            }
        }
    }

    private func changes(_ secrets: AddMachineSheet.Secrets) -> MachineSecretChanges {
        MachineSecretChanges(
            login: secrets.login, sudoPassword: secrets.sudo,
            forgetSudoPassword: secrets.forgetSudo)
    }
}
