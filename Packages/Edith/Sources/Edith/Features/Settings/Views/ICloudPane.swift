import AppKit
import EdithKit
import SwiftUI

struct ICloudPane: View {
    @AppStorage(AppStorageKeys.Backup.icloud, store: SharedDefaults.store) private
        var icloudBackup = true
    @AppStorage(AppStorageKeys.Backup.lastBackupAt, store: SharedDefaults.store) private
        var lastBackupAt = 0.0
    @AppStorage(AppStorageKeys.Backup.settings, store: SharedDefaults.store) private
        var backupSettings = true
    @AppStorage(AppStorageKeys.Backup.usage, store: SharedDefaults.store) private var backupUsage =
        true
    @AppStorage(AppStorageKeys.Backup.limits, store: SharedDefaults.store) private
        var backupLimits = true
    @AppStorage(AppStorageKeys.Music.backup, store: SharedDefaults.store) private var musicBackup =
        false
    @AppStorage(AppStorageKeys.Music.lastBackupAt, store: SharedDefaults.store) private
        var lastMusicBackupAt =
        0.0
    @AppStorage(AppStorageKeys.Clipboard.backup, store: SharedDefaults.store) private
        var clipboardBackup = false
    @AppStorage(AppStorageKeys.Clipboard.lastBackupAt, store: SharedDefaults.store)
    private var lastClipboardBackupAt = 0.0
    @AppStorage(AppStorageKeys.Tabs.musicEnabled, store: SharedDefaults.store) private
        var musicEnabled = false
    @AppStorage(AppStorageKeys.Clipboard.enabled, store: SharedDefaults.store) private
        var clipboardEnabled =
        false
    @AppStorage(AppStorageKeys.Tabs.usageEnabled, store: SharedDefaults.store) private
        var usageEnabled = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    private var dark: Bool { scheme == .dark }

    private var cloudAvailable: Bool { icloudBackup && AppData.cloudAvailable }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                SkinCard(
                    title: "iCloud backup",
                    note: icloudBackup && !cloudAvailable
                        ? "iCloud Drive is not available on this Mac." : nil,
                    dark: dark
                ) {
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        Toggle(isOn: $icloudBackup) {
                            HStack(spacing: UIScale.pt(6)) {
                                Text("Back up to iCloud")
                                InfoDot(
                                    "Keeps your data in iCloud Drive so a reinstall or another Mac can restore it. Newest copy wins - it's a backup, not a live sync."
                                )
                            }
                        }
                        .pointerCursor()
                        Text(backupSubtitle).settingsCaption()
                    }
                    .foregroundStyle(DashSkin.ink(dark))
                }

                SkinCard(
                    title: "App data",
                    note:
                        "Your data never leaves this Mac and your own iCloud Drive - iCloud is entirely your choice.",
                    dark: dark
                ) {
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        Toggle("Settings", isOn: $backupSettings)
                            .pointerCursor()
                            .disabled(!icloudBackup)
                        Text(
                            "Every preference in this app: toggles, colors, shortcuts, and layouts."
                        )
                        .settingsCaption()
                        if usageEnabled {
                            Toggle("Usage data", isOn: $backupUsage)
                                .pointerCursor()
                                .disabled(!icloudBackup)
                            Text("The token and cost history behind the Agent Usage charts.")
                                .settingsCaption()
                            Toggle("Session history", isOn: $backupLimits)
                                .pointerCursor()
                                .disabled(!icloudBackup)
                            Text(
                                "Rate-limit snapshots that draw the session and weekly limit charts."
                            )
                            .settingsCaption()
                        }
                    }
                    .foregroundStyle(DashSkin.ink(dark))
                }

                if musicEnabled || clipboardEnabled {
                    SkinCard(title: "Extensions", dark: dark) {
                        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                            if musicEnabled {
                                Toggle("Music folder", isOn: $musicBackup)
                                    .pointerCursor()
                                    .disabled(!icloudBackup || !cloudAvailable)
                                Text(musicSubtitle)
                                    .font(.system(size: UIScale.pt(10)))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
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
                                Text(clipboardSubtitle)
                                    .font(.system(size: UIScale.pt(10)))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                            }
                        }
                        .foregroundStyle(DashSkin.ink(dark))
                    }
                }

                SkinCard(title: "On disk", dark: dark) {
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
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
                    }
                    .foregroundStyle(DashSkin.ink(dark))
                }
            }
            .pageContent(compact)
            .padding(.top, UIScale.pt(16))
        }
        .background(DashSkin.paper(dark))
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
