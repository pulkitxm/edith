import AppKit
import EdithKit
import SwiftUI

struct BackupPane: View {
    @AppStorage("icloudBackup", store: SharedDefaults.store) private var icloudBackup = false
    @AppStorage("lastBackupAt", store: SharedDefaults.store) private var lastBackupAt = 0.0
    @AppStorage("musicBackup", store: SharedDefaults.store) private var musicBackup = false
    @AppStorage("lastMusicBackupAt", store: SharedDefaults.store) private var lastMusicBackupAt =
        0.0
    @AppStorage("backupSettings", store: SharedDefaults.store) private var backupSettings = true
    @AppStorage("backupUsage", store: SharedDefaults.store) private var backupUsage = true
    @AppStorage("backupLimits", store: SharedDefaults.store) private var backupLimits = true

    private var cloudAvailable: Bool { AppData.cloudAvailable }

    var body: some View {
        Form {
            Section {
                HStack {
                    Toggle("Back up settings to iCloud", isOn: $icloudBackup)
                        .pointerCursor()
                        .disabled(!cloudAvailable)
                    InfoDot(
                        "Keeps your settings in iCloud Drive so a reinstall or another Mac can restore them. Newest copy wins - it's a backup, not a live sync."
                    )
                }
                Text(backupSubtitle).font(.caption).foregroundStyle(.secondary)
                Toggle("Settings", isOn: $backupSettings)
                    .pointerCursor()
                    .disabled(!icloudBackup)
                Toggle("Usage data", isOn: $backupUsage)
                    .pointerCursor()
                    .disabled(!icloudBackup)
                Toggle("Session history", isOn: $backupLimits)
                    .pointerCursor()
                    .disabled(!icloudBackup)
            } header: {
                Text("iCloud backup")
            } footer: {
                if !cloudAvailable {
                    Text("iCloud Drive is not available on this Mac.")
                }
            }

            Section {
                Toggle("Back up music to iCloud", isOn: $musicBackup)
                    .pointerCursor()
                    .disabled(!cloudAvailable)
                Text(musicSubtitle).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Music")
            }

            Section {
                LabeledContent("App data") {
                    Button("Open") {
                        NSWorkspace.shared.open(AppData.supportDir)
                    }
                    .pointerCursor()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Backup")
    }

    private var backupSubtitle: String {
        if !cloudAvailable { return "iCloud Drive is not available on this Mac" }
        if !icloudBackup { return "Syncs via iCloud Drive; newest copy wins across Macs" }
        if lastBackupAt > 0 {
            let at = Date(timeIntervalSince1970: lastBackupAt)
            return "Backed up \(at.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Waiting for first backup…"
    }

    private var musicSubtitle: String {
        if !cloudAvailable { return "iCloud Drive is not available on this Mac" }
        if musicBackup, lastMusicBackupAt > 0 {
            let at = Date(timeIntervalSince1970: lastMusicBackupAt)
            return "Backed up \(at.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Backs up your local music folder"
    }
}
