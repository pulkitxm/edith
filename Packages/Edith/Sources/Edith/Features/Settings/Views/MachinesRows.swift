import EdithKit
import SwiftUI

struct MachinesRows: View {
    @AppStorage(AppStorageKeys.Tabs.machinesEnabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(AppStorageKeys.Machines.notifyDown, store: SharedDefaults.store) private
        var notifyDown = true
    @AppStorage(AppStorageKeys.Machines.notifyDiskFull, store: SharedDefaults.store) private
        var notifyDisk = true
    @AppStorage(AppStorageKeys.Machines.diskThreshold, store: SharedDefaults.store) private
        var diskThreshold =
        FleetMath.diskWarningPercent
    @AppStorage(AppStorageKeys.Machines.autoConnect, store: SharedDefaults.store) private
        var autoConnect = true
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            SkinCard(
                title: "Monitoring",
                note:
                    "Checks run in the background while Edith is open and notify once per change, not repeatedly.",
                dark: dark
            ) {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    Toggle("Connect when the page opens", isOn: $autoConnect)
                    Toggle("Notify when a machine goes offline", isOn: $notifyDown)
                    Toggle("Notify when a disk is nearly full or stalled", isOn: $notifyDisk)
                    if notifyDisk {
                        HStack {
                            Text("Warn above")
                            Slider(value: $diskThreshold, in: 70...98, step: 1)
                                .tint(DashSkin.accent(dark))
                            Text("\(Int(diskThreshold))%")
                                .font(DashSkin.mono(11))
                                .monospacedDigit()
                                .frame(width: UIScale.pt(42), alignment: .trailing)
                        }
                    }
                }
                .foregroundStyle(DashSkin.ink(dark))
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
            }

            SkinCard(
                title: "How it connects",
                note:
                    "Edith reuses your existing SSH setup, so agent keys, jump hosts, and per-host options in your config keep working. Host keys are pinned on first connection.",
                dark: dark
            ) {
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    LabeledContent("Connections") {
                        Text("System ssh with connection sharing")
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    LabeledContent("Hosts") {
                        Text("Imported from ~/.ssh/config")
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    LabeledContent("Passwords") {
                        Text("Stored in your login Keychain")
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                }
                .foregroundStyle(DashSkin.ink(dark))
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
            }
        }
    }
}
