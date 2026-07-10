import AppKit
import EdithKit
import SwiftUI

struct ICloudPane: View {
    @AppStorage("icloudBackup", store: SharedDefaults.store) private var icloudBackup = false
    @AppStorage("lastBackupAt", store: SharedDefaults.store) private var lastBackupAt = 0.0
    @AppStorage("backupSettings", store: SharedDefaults.store) private var backupSettings = true
    @AppStorage("backupUsage", store: SharedDefaults.store) private var backupUsage = true
    @AppStorage("backupLimits", store: SharedDefaults.store) private var backupLimits = true
    @AppStorage("musicBackup", store: SharedDefaults.store) private var musicBackup = false
    @AppStorage("lastMusicBackupAt", store: SharedDefaults.store) private var lastMusicBackupAt =
        0.0
    @AppStorage("clipboardBackup", store: SharedDefaults.store) private var clipboardBackup = false
    @AppStorage("lastClipboardBackupAt", store: SharedDefaults.store)
    private var lastClipboardBackupAt = 0.0

    private var cloudAvailable: Bool { AppData.cloudAvailable }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $icloudBackup) {
                    HStack(spacing: 6) {
                        Text("Back up to iCloud")
                        InfoDot(
                            "Keeps your data in iCloud Drive so a reinstall or another Mac can restore it. Newest copy wins - it's a backup, not a live sync."
                        )
                    }
                }
                .pointerCursor()
                .disabled(!cloudAvailable)
                Text(backupSubtitle).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("iCloud backup")
            } footer: {
                if !cloudAvailable {
                    Text("iCloud Drive is not available on this Mac.")
                }
            }

            Section {
                Toggle("Settings", isOn: $backupSettings)
                    .pointerCursor()
                    .disabled(!icloudBackup)
                Text("Every preference in this app: toggles, colors, shortcuts, and layouts.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Usage data", isOn: $backupUsage)
                    .pointerCursor()
                    .disabled(!icloudBackup)
                Text("The Claude token and cost history behind the Agent Usage charts.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Session history", isOn: $backupLimits)
                    .pointerCursor()
                    .disabled(!icloudBackup)
                Text("Rate-limit snapshots that draw the session and weekly limit charts.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("App data")
            } footer: {
                Text(
                    "Everything Edith can back up is listed on this page. Your data never leaves this Mac and your own iCloud Drive - and iCloud is entirely your choice."
                )
                .font(.caption)
            }

            Section {
                Toggle("Music folder", isOn: $musicBackup)
                    .pointerCursor()
                    .disabled(!cloudAvailable)
                Text(musicSubtitle).font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: $clipboardBackup) {
                    HStack(spacing: 6) {
                        Text("Clipboard history")
                        InfoDot(
                            "Text history only, items up to 1 MB each - larger copies stay on this Mac."
                        )
                    }
                }
                .pointerCursor()
                .disabled(!cloudAvailable)
                Text(clipboardSubtitle).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Extensions")
            }

            Section {
                LabeledContent("App data folder") {
                    Button("Open") {
                        NSWorkspace.shared.open(AppData.supportDir)
                    }
                    .pointerCursor()
                }
                if cloudAvailable {
                    LabeledContent("iCloud folder") {
                        Button("Open") {
                            try? FileManager.default.createDirectory(
                                at: AppData.cloudDir, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(AppData.cloudDir)
                        }
                        .pointerCursor()
                    }
                }
            } header: {
                Text("On disk")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("iCloud")
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

    private var clipboardSubtitle: String {
        if !cloudAvailable { return "iCloud Drive is not available on this Mac" }
        if clipboardBackup, lastClipboardBackupAt > 0 {
            let at = Date(timeIntervalSince1970: lastClipboardBackupAt)
            return "Backed up \(at.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Restores clipboard history on reinstall"
    }
}
