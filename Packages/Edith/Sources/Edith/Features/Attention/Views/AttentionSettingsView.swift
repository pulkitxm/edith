import EdithKit
import SwiftUI

private enum AttentionSettingsSection: String, CaseIterable, Identifiable {
    case tracking
    case browsers
    case identities
    case music
    case presence
    case focus
    case privacy
    case backup
    case automation
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tracking: "Tracking"
        case .browsers: "Browsers & Profiles"
        case .identities: "Identities & Categories"
        case .music: "Music"
        case .presence: "Presence"
        case .focus: "Focus"
        case .privacy: "Privacy & Retention"
        case .backup: "iCloud Backup"
        case .automation: "CLI & Automation"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .tracking: "record.circle"
        case .browsers: "globe"
        case .identities: "square.grid.3x3"
        case .music: "music.note"
        case .presence: "person.crop.circle.badge.checkmark"
        case .focus: "scope"
        case .privacy: "lock.shield"
        case .backup: "icloud.and.arrow.up"
        case .automation: "terminal"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

struct AttentionSettingsView: View {
    @Bindable var store: AttentionMockStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compactLayout
    @State private var section: AttentionSettingsSection = .tracking
    @State private var trackingPreset = "Deep Local"
    @State private var trackTitles = true
    @State private var trackPaths = true
    @State private var trackIncognito = false
    @State private var importHistory = true
    @State private var appleMusic = true
    @State private var spotify = true
    @State private var browserMedia = true
    @State private var passiveVideo = true
    @State private var presenceCamera = false
    @State private var correctionPrompts = true
    @State private var focusNudges = true
    @State private var focusBlocking = false
    @State private var detailedRetention = "90 days"
    @State private var observationRetention = "1 year"
    @State private var backupEnabled = true
    @State private var backupDeepData = false
    @State private var cliAggregates = true
    @State private var cliDetails = false
    @State private var cliProposals = true
    @State private var cliWrites = false
    @State private var localSemanticClassification = true

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: UIScale.pt(16)) {
            settingsHeader
            if compactLayout {
                sectionPicker
                detail
            } else {
                HStack(alignment: .top, spacing: UIScale.pt(16)) {
                    navigation.frame(width: UIScale.pt(220))
                    detail.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text("Attention settings")
                    .font(DashSkin.serif(22))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("Every collector, permission, rule, and backup option is configured here.")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
            Spacer()
            Button("Run guided setup") { store.resetSetup() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointerCursor()
        }
    }

    private var sectionPicker: some View {
        Picker("Settings section", selection: $section) {
            ForEach(AttentionSettingsSection.allCases) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
        }
        .labelsHidden()
    }

    private var navigation: some View {
        VStack(spacing: UIScale.pt(3)) {
            ForEach(AttentionSettingsSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: UIScale.pt(9)) {
                        Image(systemName: item.symbol).frame(width: UIScale.pt(18))
                        Text(item.title)
                        Spacer()
                    }
                    .font(.system(size: UIScale.pt(10.5), weight: .medium))
                    .foregroundStyle(section == item ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                    .padding(.horizontal, UIScale.pt(10))
                    .frame(height: UIScale.pt(32))
                    .background(
                        section == item ? DashSkin.accent(dark).opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(UIScale.pt(8))
        .widgetBar(cornerRadius: 14, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark), shadow: .clear)
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .tracking: trackingSettings
        case .browsers: browserSettings
        case .identities: identitySettings
        case .music: musicSettings
        case .presence: presenceSettings
        case .focus: focusSettings
        case .privacy: privacySettings
        case .backup: backupSettings
        case .automation: automationSettings
        case .diagnostics: diagnosticsSettings
        }
    }

    private var trackingSettings: some View {
        settingsPanel("Tracking", "Choose the default level, then customize every capability") {
            Picker("Tracking preset", selection: $trackingPreset) {
                ForEach(["Standard", "Detailed", "Deep Local"], id: \.self) { Text($0) }
            }
            settingDivider
            settingToggle("Application and service activity", "Foreground context, duration, and native/web surface", .constant(true))
            settingDivider
            settingToggle("Window and page titles", "Encrypted detail for better categorization", $trackTitles)
            settingDivider
            settingToggle("URL paths", "Domains remain available when this is off", $trackPaths)
            settingDivider
            settingToggle("Local semantic classification", "Extract page type locally and discard source text", $localSemanticClassification)
            settingDivider
            settingToggle("Private browsing", "Off by default and excluded from backup", $trackIncognito)
        }
    }

    private var browserSettings: some View {
        settingsPanel("Browsers & Profiles", "Each profile is paired and controlled independently") {
            ForEach(store.browserProfiles) { profile in
                VStack(spacing: UIScale.pt(10)) {
                    HStack(spacing: UIScale.pt(11)) {
                        Image(systemName: profile.symbol)
                            .foregroundStyle(profile.connected ? DashSkin.sage : DashSkin.inkFaint(dark))
                            .frame(width: UIScale.pt(32), height: UIScale.pt(32))
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text("\(profile.browser) · \(profile.profile)")
                                .font(.system(size: UIScale.pt(11), weight: .semibold))
                            Text(profile.connected ? "\(profile.eventCount.formatted()) events · seen recently" : "Companion not connected")
                                .font(.system(size: UIScale.pt(9)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                        Spacer()
                        AttentionBadge(text: profile.connected ? "CONNECTED" : "PAUSED", color: profile.connected ? DashSkin.sage : DashSkin.warn)
                        Button(profile.connected ? "Pause" : "Connect") { store.toggleBrowser(profile.id) }
                            .controlSize(.small)
                            .pointerCursor()
                    }
                    HStack {
                        Toggle("Deep page context", isOn: Binding(
                            get: { store.browserProfiles.first { $0.id == profile.id }?.deepMode ?? false },
                            set: { _ in store.toggleDeepMode(profile.id) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Spacer()
                        if profile.historyImported {
                            Label("History imported", systemImage: "checkmark.circle.fill")
                                .font(.system(size: UIScale.pt(9.5)))
                                .foregroundStyle(DashSkin.sage)
                        } else {
                            Button("Import history") {
                                importHistory = true
                                store.toast = "History import preview ready"
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: UIScale.pt(9.5), weight: .medium))
                            .foregroundStyle(DashSkin.accentDeep(dark))
                        }
                    }
                }
                .padding(.vertical, UIScale.pt(7))
                if profile.id != store.browserProfiles.last?.id { settingDivider }
            }
        }
    }

    private var identitySettings: some View {
        settingsPanel("Identities & Categories", "Rules remain reversible and reclassify derived history") {
            settingLink("Services", "\(store.identities.count) unified identities", "square.grid.3x3") {
                store.selectedSection = .library
            }
            settingDivider
            settingLink("Categories", "\(store.categories.count) editable categories", "folder") {
                store.selectedSection = .library
            }
            settingDivider
            settingLink("Uncategorized", "\(store.identities.filter { $0.categoryID == "uncategorized" }.count) identities need review", "questionmark.square.dashed") {
                store.libraryKind = "All"
                store.librarySearch = ""
                store.selectedSection = .library
            }
            settingDivider
            settingToggle("Historical rule previews", "Always show affected segments and time before applying", .constant(true))
        }
    }

    private var musicSettings: some View {
        settingsPanel("Music", "Listening remains a concurrent lane and never inflates elapsed time") {
            settingToggle("Apple Music", "Track metadata, progress, pauses, skips, and repeats", $appleMusic)
            settingDivider
            settingToggle("Spotify", "Native playback notifications and played seconds", $spotify)
            settingDivider
            settingToggle("Browser media", "Media Session and HTML media progress", $browserMedia)
            settingDivider
            settingToggle("Associate music with focus", "Show correlations only when sample size is sufficient", .constant(true))
        }
    }

    private var presenceSettings: some View {
        settingsPanel("Presence", "Keep hard signals separate from likely and uncertain states") {
            settingToggle("Passive video detection", "Uses playback progress, visibility, audio, and display state", $passiveVideo)
            settingDivider
            settingToggle("Ask after uncertain intervals", "One small correction prompt when you return", $correctionPrompts)
            settingDivider
            settingToggle("Experimental camera presence", "Stores only face-present state and immediately discards frames", $presenceCamera)
            settingDivider
            settingValue("Interactive idle threshold", "3 minutes")
            settingDivider
            settingValue("Passive confirmation window", "12 minutes")
        }
    }

    private var focusSettings: some View {
        settingsPanel("Focus", "Define intent per session rather than judging every category globally") {
            settingToggle("Focus nudges", "Notify only after sustained off-intent activity", $focusNudges)
            settingDivider
            settingToggle("Browser blocking", "Requires an additional browser capability", $focusBlocking)
            settingDivider
            settingValue("Default grace period", "45 seconds")
            settingDivider
            settingValue("Recovery stability", "2 minutes")
            settingDivider
            settingLink("Focus templates", "\(store.focusTemplates.count) available", "scope") {
                store.selectedSection = .focus
            }
        }
    }

    private var privacySettings: some View {
        settingsPanel("Privacy & Retention", "Exclusions are applied before observations reach storage") {
            settingValuePicker("Core observations", $observationRetention, ["90 days", "1 year", "Forever"])
            settingDivider
            settingValuePicker("Titles and paths", $detailedRetention, ["7 days", "30 days", "90 days", "1 year"])
            settingDivider
            settingValue("Never track", "Password managers, banking, and 4 custom rules")
            settingDivider
            settingToggle("Include private browsing", "Requires separate opt-in in each browser", $trackIncognito)
            settingDivider
            Button("Review and delete data") { store.toast = "Mock deletion review opened" }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(DashSkin.danger)
                .pointerCursor()
        }
    }

    private var backupSettings: some View {
        settingsPanel("Encrypted iCloud Backup", "The live database remains local and only encrypted snapshots are copied") {
            settingToggle("Back up Attention data", "Last verified today at 6:42 PM · 184 MB", $backupEnabled)
            settingDivider
            settingToggle("Include deep page data", "Adds approximately 62 MB to this snapshot", $backupDeepData)
            settingDivider
            settingValue("Recovery key", "Saved in iCloud Keychain")
            settingDivider
            settingValue("Retention", "7 daily · 4 weekly")
            settingDivider
            HStack {
                Button("Back up now") { store.toast = "Encrypted snapshot verified" }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Test restore") { store.toast = "Restore test passed" }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Label("Integrity verified", systemImage: "checkmark.seal.fill")
                    .font(.system(size: UIScale.pt(9.5), weight: .medium))
                    .foregroundStyle(DashSkin.sage)
            }
            .pointerCursor()
        }
    }

    private var automationSettings: some View {
        settingsPanel("CLI & Automation", "Setup remains UI-only. These permissions apply after onboarding") {
            settingToggle("Read aggregate summaries", "Categories, services, domains, and durations", $cliAggregates)
            settingDivider
            settingToggle("Read detailed URLs and titles", "Sensitive detail remains off unless explicitly granted", $cliDetails)
            settingDivider
            settingToggle("Propose category rules", "Agents can create preview plans", $cliProposals)
            settingDivider
            settingToggle("Apply reviewed plans", "Transactions remain revisioned, idempotent, and undoable", $cliWrites)
            settingDivider
            HStack {
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text("Local command")
                        .font(.system(size: UIScale.pt(10.5), weight: .medium))
                    Text("ed attention summary --range 30d --json")
                        .font(DashSkin.mono(9.5))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
                Spacer()
                Button("Copy") { store.toast = "Command copied" }
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
    }

    private var diagnosticsSettings: some View {
        settingsPanel("Diagnostics", "Live health for each local observation source") {
            diagnosticRow("macOS context", "Receiving", "12 seconds ago", DashSkin.sage)
            settingDivider
            diagnosticRow("Input and presence", "Receiving", "3 seconds ago", DashSkin.sage)
            settingDivider
            diagnosticRow("Browser companions", "4 of 5 connected", "42 seconds ago", DashSkin.warn)
            settingDivider
            diagnosticRow("Music metadata", "Receiving", "1 minute ago", DashSkin.sage)
            settingDivider
            diagnosticRow("iCloud backup", "Verified", "Today, 6:42 PM", DashSkin.sage)
            settingDivider
            HStack {
                Button("Run two-minute calibration") { store.resetSetup(); store.setupStepIndex = store.setupSteps.count - 1 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Export redacted diagnostics") { store.toast = "Redacted diagnostic bundle prepared" }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }
            .pointerCursor()
        }
    }

    private func settingsPanel<Content: View>(
        _ title: String, _ subtitle: String, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        AttentionPanel(title: title, subtitle: subtitle, content: content)
    }

    private var settingDivider: some View {
        Divider().overlay(DashSkin.line(dark).opacity(0.65))
    }

    private func settingToggle(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: UIScale.pt(14)) {
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(title).font(.system(size: UIScale.pt(10.5), weight: .medium))
                Text(detail).font(.system(size: UIScale.pt(9))).foregroundStyle(DashSkin.inkFaint(dark))
            }
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, UIScale.pt(3))
    }

    private func settingValue(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: UIScale.pt(10.5), weight: .medium))
            Spacer()
            Text(value).font(.system(size: UIScale.pt(9.5))).foregroundStyle(DashSkin.inkSoft(dark))
        }
        .padding(.vertical, UIScale.pt(4))
    }

    private func settingValuePicker(_ title: String, _ binding: Binding<String>, _ values: [String]) -> some View {
        HStack {
            Text(title).font(.system(size: UIScale.pt(10.5), weight: .medium))
            Spacer()
            Picker(title, selection: binding) {
                ForEach(values, id: \.self) { Text($0) }
            }
            .labelsHidden()
            .frame(width: UIScale.pt(130))
        }
    }

    private func settingLink(
        _ title: String, _ detail: String, _ symbol: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(10)) {
                Image(systemName: symbol).foregroundStyle(DashSkin.accentDeep(dark)).frame(width: UIScale.pt(20))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(title).font(.system(size: UIScale.pt(10.5), weight: .medium))
                    Text(detail).font(.system(size: UIScale.pt(9))).foregroundStyle(DashSkin.inkFaint(dark))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: UIScale.pt(9), weight: .semibold)).foregroundStyle(DashSkin.inkFaint(dark))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func diagnosticRow(_ title: String, _ status: String, _ time: String, _ color: Color) -> some View {
        HStack(spacing: UIScale.pt(10)) {
            Circle().fill(color).frame(width: UIScale.pt(8), height: UIScale.pt(8))
            Text(title).font(.system(size: UIScale.pt(10.5), weight: .medium))
            Spacer()
            Text(status).font(.system(size: UIScale.pt(9.5), weight: .medium)).foregroundStyle(color)
            Text(time).font(.system(size: UIScale.pt(9))).foregroundStyle(DashSkin.inkFaint(dark)).frame(width: UIScale.pt(105), alignment: .trailing)
        }
        .padding(.vertical, UIScale.pt(4))
    }
}
