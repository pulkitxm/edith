import AppKit
import EdithExtensionUI
import SwiftUI

struct HostCloudPage: View {
    @Bindable var services: HostCoreServices
    @State private var revision = 0
    private var preferences: HostCloudPreferences { services.cloudPreferences }
    private var enabledIDs: Set<String> { services.marketplace.sessions.enabledIDs }
    private var cloudAvailable: Bool { services.snapshot?.cloudAvailable == true }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: binding(.icloud)) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Back up to iCloud")
                        InfoDot(
                            "Keeps your data in iCloud Drive so a reinstall or another Mac can restore it. Newest copy wins - it's a backup, not a live sync."
                        )
                    }
                }
                Text(subtitle(.settings)).settingsCaption()
            } header: {
                Text("iCloud backup")
            } footer: {
                if preferences.enabled(.icloud), !cloudAvailable {
                    Text("iCloud Drive is not available on this Mac.")
                }
            }
            Section {
                Toggle("Settings", isOn: binding(.settings)).disabled(!preferences.enabled(.icloud))
                Text("Every preference in this app: toggles, colors, shortcuts, and layouts.")
                    .settingsCaption()
                if enabledIDs.contains("usage") {
                    Toggle("Usage data", isOn: binding(.usage)).disabled(
                        !preferences.enabled(.icloud))
                    Text("The token and cost history behind the Agent Usage charts.")
                        .settingsCaption()
                    Toggle("Session history", isOn: binding(.limits)).disabled(
                        !preferences.enabled(.icloud))
                    Text("Rate-limit snapshots that draw the session and weekly limit charts.")
                        .settingsCaption()
                }
            } header: {
                Text("App data")
            } footer: {
                Text(
                    "Everything Edith can back up is listed on this page. Your data never leaves this Mac and your own iCloud Drive - and iCloud is entirely your choice."
                )
                .font(.system(size: UIScale.pt(10)))
            }
            if enabledIDs.contains("music") || enabledIDs.contains("clipboard") {
                Section("Extensions") {
                    if enabledIDs.contains("music") {
                        Toggle("Music folder", isOn: binding(.music))
                            .disabled(!preferences.enabled(.icloud) || !cloudAvailable)
                        Text(subtitle(.music)).settingsCaption()
                    }
                    if enabledIDs.contains("clipboard") {
                        Toggle(isOn: binding(.clipboard)) {
                            HStack(spacing: UIScale.pt(6)) {
                                Text("Clipboard history")
                                InfoDot(
                                    "Text history only, items up to 1 MB each - larger copies stay on this Mac."
                                )
                            }
                        }.disabled(!preferences.enabled(.icloud) || !cloudAvailable)
                        Text(subtitle(.clipboard)).settingsCaption()
                    }
                }
            }
            Section("On disk") {
                LabeledContent("App data folder") {
                    Button("Open") { NSWorkspace.shared.open(services.identity.root) }
                }
                if preferences.enabled(.icloud), cloudAvailable,
                    let directory = services.snapshot?.cloudDirectory
                {
                    LabeledContent("iCloud folder") {
                        Button("Open") { NSWorkspace.shared.open(directory) }
                    }
                }
            }
            if let failure = services.backupFailure {
                Section { Text(failure).settingsCaption().foregroundStyle(.orange) }
            }
        }.edithForm()
            .pageTask { await services.refresh() }
    }

    private func binding(_ option: HostCloudPreferences.Option) -> Binding<Bool> {
        Binding(
            get: {
                _ = revision; return preferences.enabled(option)
            },
            set: { value in
                preferences.set(option, enabled: value); revision += 1
                services.cloudPreferencesChanged()
            })
    }

    private func subtitle(_ option: HostCloudPreferences.Option) -> String {
        if !preferences.enabled(.icloud) {
            switch option {
            case .music: return "Turn on iCloud backup to back up your music folder"
            case .clipboard: return "Turn on iCloud backup to back up clipboard history"
            default: return "Syncs via iCloud Drive; newest copy wins across Macs"
            }
        }
        if !cloudAvailable { return "iCloud Drive is not available on this Mac" }
        if preferences.enabled(option), let at = preferences.lastBackup(option) {
            return "Backed up \(at.formatted(date: .abbreviated, time: .shortened))"
        }
        switch option {
        case .music: return "Backs up your local music folder"
        case .clipboard: return "Restores clipboard history on reinstall"
        default: return "Waiting for first backup…"
        }
    }
}
