import AppKit
import EdithKit
import SwiftUI

struct ICloudPane: View {
    @AppStorage("icloudBackup", store: SharedDefaults.store) private var icloudBackup = true
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
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var musicEnabled = false
    @AppStorage("clipboardEnabled", store: SharedDefaults.store) private var clipboardEnabled =
        false
    @AppStorage("tabUsageEnabled", store: SharedDefaults.store) private var usageEnabled = false

    private var cloudAvailable: Bool { icloudBackup && AppData.cloudAvailable }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $icloudBackup) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Back up to iCloud")
                        InfoDot(
                            "Keeps your data in iCloud Drive so a reinstall or another Mac can restore it. Newest copy wins - it's a backup, not a live sync."
                        )
                    }
                }
                .pointerCursor()
                Text(backupSubtitle).font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
            } header: {
                Text("iCloud backup")
            } footer: {
                if icloudBackup, !cloudAvailable {
                    Text("iCloud Drive is not available on this Mac.")
                }
            }

            Section {
                Toggle("Settings", isOn: $backupSettings)
                    .pointerCursor()
                    .disabled(!icloudBackup)
                Text("Every preference in this app: toggles, colors, shortcuts, and layouts.")
                    .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                if usageEnabled {
                    Toggle("Usage data", isOn: $backupUsage)
                        .pointerCursor()
                        .disabled(!icloudBackup)
                    Text("The token and cost history behind the Agent Usage charts.")
                        .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                    Toggle("Session history", isOn: $backupLimits)
                        .pointerCursor()
                        .disabled(!icloudBackup)
                    Text("Rate-limit snapshots that draw the session and weekly limit charts.")
                        .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                }
            } header: {
                Text("App data")
            } footer: {
                Text(
                    "Everything Edith can back up is listed on this page. Your data never leaves this Mac and your own iCloud Drive - and iCloud is entirely your choice."
                )
                .font(.system(size: UIScale.pt(10)))
            }

            if musicEnabled || clipboardEnabled {
                Section {
                    if musicEnabled {
                        Toggle("Music folder", isOn: $musicBackup)
                            .pointerCursor()
                            .disabled(!icloudBackup || !cloudAvailable)
                        Text(musicSubtitle).font(.system(size: UIScale.pt(10))).foregroundStyle(
                            .secondary)
                    }
                    if clipboardEnabled {
                        Toggle(isOn: $clipboardBackup) {
                            HStack(spacing: UIScale.pt(6)) {
                                Text("Clipboard history")
                                InfoDot(
                                    "Text history only, items up to 1 MB each - larger copies stay on this Mac."
                                )
                            }
                        }
                        .pointerCursor()
                        .disabled(!icloudBackup || !cloudAvailable)
                        Text(clipboardSubtitle).font(.system(size: UIScale.pt(10))).foregroundStyle(
                            .secondary)
                    }
                } header: {
                    Text("Extensions")
                }
            }

            Section {
                LabeledContent("App data folder") {
                    Button("Open") {
                        NSWorkspace.shared.open(AppData.supportDir)
                    }
                    .pointerCursor()
                }
                if icloudBackup, cloudAvailable {
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
        if !icloudBackup { return "Syncs via iCloud Drive; newest copy wins across Macs" }
        if !cloudAvailable { return "iCloud Drive is not available on this Mac" }
        if lastBackupAt > 0 {
            let at = Date(timeIntervalSince1970: lastBackupAt)
            return "Backed up \(at.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Waiting for first backup…"
    }

    private var musicSubtitle: String {
        if !icloudBackup { return "Turn on iCloud backup to back up your music folder" }
        if !cloudAvailable { return "iCloud Drive is not available on this Mac" }
        if musicBackup, lastMusicBackupAt > 0 {
            let at = Date(timeIntervalSince1970: lastMusicBackupAt)
            return "Backed up \(at.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Backs up your local music folder"
    }

    private var clipboardSubtitle: String {
        if !icloudBackup { return "Turn on iCloud backup to back up clipboard history" }
        if !cloudAvailable { return "iCloud Drive is not available on this Mac" }
        if clipboardBackup, lastClipboardBackupAt > 0 {
            let at = Date(timeIntervalSince1970: lastClipboardBackupAt)
            return "Backed up \(at.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Restores clipboard history on reinstall"
    }
}
