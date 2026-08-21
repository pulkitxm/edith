import EdithKit
import SwiftUI

struct AttentionSetupView: View {
    @Bindable var store: AttentionMockStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var preset = "Deep Local"
    @State private var includeTitles = true
    @State private var includePaths = true
    @State private var historicalDays = "90 days"
    @State private var importActivityWatch = true
    @State private var encryptedBackup = true
    @State private var copiedRecoveryKey = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: 0) {
            setupSidebar
            Divider().overlay(DashSkin.line(dark))
            VStack(spacing: 0) {
                setupHeader
                Divider().overlay(DashSkin.line(dark))
                ScrollView {
                    stepContent
                        .padding(UIScale.pt(28))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider().overlay(DashSkin.line(dark))
                setupFooter
            }
        }
        .frame(width: UIScale.pt(920), height: UIScale.pt(650))
        .background(DashSkin.paper(dark))
    }

    private var setupSidebar: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack(spacing: UIScale.pt(9)) {
                Image(systemName: "scope").foregroundStyle(DashSkin.accentDeep(dark))
                Text("Attention setup").font(.system(size: UIScale.pt(13), weight: .semibold))
            }
            VStack(spacing: UIScale.pt(3)) {
                ForEach(Array(store.setupSteps.enumerated()), id: \.element.id) { index, step in
                    Button {
                        store.setupStepIndex = index
                    } label: {
                        HStack(spacing: UIScale.pt(9)) {
                            ZStack {
                                Circle()
                                    .fill(step.completed ? DashSkin.sage : index == store.setupStepIndex ? DashSkin.accentDeep(dark) : DashSkin.grid(dark))
                                    .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                                Image(systemName: step.completed ? "checkmark" : step.symbol)
                                    .font(.system(size: UIScale.pt(9), weight: .bold))
                                    .foregroundStyle(step.completed || index == store.setupStepIndex ? Color.white : DashSkin.inkFaint(dark))
                            }
                            Text(step.title)
                                .font(.system(size: UIScale.pt(10), weight: index == store.setupStepIndex ? .semibold : .regular))
                                .foregroundStyle(index == store.setupStepIndex ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                            Spacer()
                        }
                        .padding(.horizontal, UIScale.pt(8))
                        .frame(height: UIScale.pt(32))
                        .background(
                            index == store.setupStepIndex ? DashSkin.accent(dark).opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            Spacer()
            Text("Everything in this setup remains editable from Attention Settings.")
                .font(.system(size: UIScale.pt(9)))
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
        .padding(UIScale.pt(18))
        .frame(width: UIScale.pt(230))
        .background(DashSkin.paper2(dark).opacity(0.6))
    }

    private var setupHeader: some View {
        HStack(spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(store.currentSetupStep.title)
                    .font(DashSkin.serif(24))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(store.currentSetupStep.detail)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
            Spacer()
            Text("\(store.setupStepIndex + 1) of \(store.setupSteps.count)")
                .font(DashSkin.mono(9.5, weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").frame(width: UIScale.pt(26), height: UIScale.pt(26))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, UIScale.pt(24))
        .frame(height: UIScale.pt(76))
    }

    @ViewBuilder
    private var stepContent: some View {
        switch store.currentSetupStep.id {
        case "welcome": welcomeStep
        case "permissions": permissionsStep
        case "browsers": browsersStep
        case "history": historyStep
        case "identity": identityStep
        case "music": musicStep
        case "focus": focusStep
        case "backup": backupStep
        default: calibrationStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            Text("Choose how deeply Edith should understand your attention.")
                .font(.system(size: UIScale.pt(13), weight: .medium))
            HStack(spacing: UIScale.pt(10)) {
                ForEach(["Standard", "Detailed", "Deep Local"], id: \.self) { option in
                    Button {
                        preset = option
                    } label: {
                        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                            Image(systemName: option == "Standard" ? "app" : option == "Detailed" ? "doc.text.magnifyingglass" : "waveform.path.ecg")
                                .font(.system(size: UIScale.pt(20)))
                                .foregroundStyle(preset == option ? Color.white : DashSkin.accentDeep(dark))
                            Text(option).font(.system(size: UIScale.pt(11), weight: .semibold))
                            Text(presetDetail(option)).font(.system(size: UIScale.pt(9))).opacity(0.78)
                        }
                        .foregroundStyle(preset == option ? Color.white : DashSkin.ink(dark))
                        .padding(UIScale.pt(14))
                        .frame(maxWidth: .infinity, minHeight: UIScale.pt(125), alignment: .topLeading)
                        .background(
                            preset == option ? DashSkin.accentDeep(dark) : DashSkin.paper2(dark),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
                        .overlay {
                            if preset != option {
                                RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(DashSkin.line(dark))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            setupCheck("Stored locally under Edith Application Support", true)
            setupCheck("No telemetry or remote classification", true)
            setupCheck("Encrypted snapshots enter iCloud only when enabled", true)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            permissionRow("Application activity", "Frontmost application and activation changes", "Granted", DashSkin.sage)
            permissionRow("Idle and lock state", "Input age, screen lock, sleep, and wake", "Granted", DashSkin.sage)
            permissionRow("Accessibility", "Window titles and focused controls", includeTitles ? "Granted" : "Optional", includeTitles ? DashSkin.sage : DashSkin.warn)
            permissionRow("Screen recording", "Only required for optional local recall", "Not requested", DashSkin.inkFaint(dark))
            permissionRow("Camera", "Only required for experimental face presence", "Not requested", DashSkin.inkFaint(dark))
            Toggle("Include window and page titles", isOn: $includeTitles).toggleStyle(.switch)
            Toggle("Include sanitized URL paths", isOn: $includePaths).toggleStyle(.switch)
        }
    }

    private var browsersStep: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack {
                Text("Detected browser profiles").font(.system(size: UIScale.pt(12), weight: .semibold))
                Spacer()
                AttentionBadge(text: "NO TERMINAL REQUIRED", color: DashSkin.sage)
            }
            ForEach(store.browserProfiles) { profile in
                HStack(spacing: UIScale.pt(11)) {
                    Image(systemName: profile.symbol)
                        .frame(width: UIScale.pt(34), height: UIScale.pt(34))
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text("\(profile.browser) · \(profile.profile)").font(.system(size: UIScale.pt(10.5), weight: .semibold))
                        Text(profile.connected ? "Companion verified and receiving events" : "Open Extensions, choose Load unpacked, then return here")
                            .font(.system(size: UIScale.pt(9))).foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    Spacer()
                    Button(profile.connected ? "Verified" : "Guide me") {
                        if !profile.connected { store.toggleBrowser(profile.id) }
                    }
                    .controlSize(.small)
                    .disabled(profile.connected)
                    .pointerCursor()
                }
                .padding(UIScale.pt(10))
                .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
                .overlay(RoundedRectangle(cornerRadius: UIScale.pt(10)).strokeBorder(DashSkin.line(dark)))
            }
        }
    }

    private var historyStep: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            Picker("Import range", selection: $historicalDays) {
                ForEach(["30 days", "90 days", "1 year", "All available"], id: \.self) { Text($0) }
            }
            Toggle("Import ActivityWatch categories and events", isOn: $importActivityWatch).toggleStyle(.switch)
            setupCheck("5 Chrome profile databases found", true)
            setupCheck("8 Dia profile databases found", true)
            setupCheck("Imported duration will be labeled Historical Estimate", true)
            HStack(spacing: UIScale.pt(9)) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DashSkin.warn)
                Text("A browser visit is not proof of foreground attention. Historical imports never silently alter live focus metrics.")
                    .font(.system(size: UIScale.pt(10))).foregroundStyle(DashSkin.inkSoft(dark))
            }
            .padding(UIScale.pt(12))
            .background(DashSkin.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        }
    }

    private var identityStep: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Text("Suggested unified services").font(.system(size: UIScale.pt(12), weight: .semibold))
            identitySuggestion("WhatsApp", "Native app + web.whatsapp.com", "Communication / Work")
            identitySuggestion("Apple Music", "Music app + music.apple.com", "Entertainment / Music")
            identitySuggestion("GitHub", "github.com across Work profiles", "Work / Coding")
            identitySuggestion("YouTube", "youtube.com video and navigation", "Entertainment / Video")
            HStack {
                AttentionBadge(text: "14 READY", color: DashSkin.sage)
                AttentionBadge(text: "2 NEED REVIEW", color: DashSkin.warn)
                Spacer()
                Button("Review all mappings") { store.selectedSection = .library }
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
    }

    private var musicStep: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            sourceTest("Apple Music", "A Walk · Tycho", "Playing · exact progress", DashSkin.sage)
            sourceTest("Spotify", "Ready for playback", "Connected", DashSkin.sage)
            sourceTest("Dia browser media", "YouTube Music metadata", "Deep mode active", DashSkin.sage)
            sourceTest("Chrome browser media", "No active player", "Waiting", DashSkin.warn)
            Text("Tracks are ranked by played seconds. Background music remains concurrent and does not become primary attention.")
                .font(.system(size: UIScale.pt(10))).foregroundStyle(DashSkin.inkSoft(dark))
        }
    }

    private var focusStep: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Text("Choose a starting focus profile").font(.system(size: UIScale.pt(12), weight: .semibold))
            ForEach(store.focusTemplates) { template in
                HStack(spacing: UIScale.pt(10)) {
                    Image(systemName: template.symbol).foregroundStyle(DashSkin.accentDeep(dark)).frame(width: UIScale.pt(28))
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(template.name).font(.system(size: UIScale.pt(10.5), weight: .semibold))
                        Text("\(template.intervention) · \(template.graceSeconds)s grace · \(template.allowedCategoryIDs.count) allowed categories")
                            .font(.system(size: UIScale.pt(9))).foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    Spacer()
                    Image(systemName: template.id == "flow" ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(template.id == "flow" ? DashSkin.sage : DashSkin.inkFaint(dark))
                }
                .padding(UIScale.pt(10))
                .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
                .overlay(RoundedRectangle(cornerRadius: UIScale.pt(9)).strokeBorder(DashSkin.line(dark)))
            }
        }
    }

    private var backupStep: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            Toggle("Create encrypted iCloud backups", isOn: $encryptedBackup).toggleStyle(.switch)
            setupCheck("Live SQLite database remains local", true)
            setupCheck("Snapshots encrypted before entering iCloud Drive", true)
            setupCheck("Recovery key saved in synchronizable Keychain", true)
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                Text("Recovery key").font(.system(size: UIScale.pt(9.5), weight: .semibold)).foregroundStyle(DashSkin.inkFaint(dark))
                HStack {
                    Text("EDITH-7K4M-92PF-QX6R-18TW").font(DashSkin.mono(11, weight: .semibold))
                    Spacer()
                    Button(copiedRecoveryKey ? "Copied" : "Copy") { copiedRecoveryKey = true }
                        .controlSize(.small)
                        .pointerCursor()
                }
            }
            .padding(UIScale.pt(12))
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            .overlay(RoundedRectangle(cornerRadius: UIScale.pt(10)).strokeBorder(DashSkin.line(dark)))
        }
    }

    private var calibrationStep: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack {
                Text("Live signal check").font(.system(size: UIScale.pt(12), weight: .semibold))
                Spacer()
                AttentionBadge(text: "8 OF 8 RECEIVED", color: DashSkin.sage)
            }
            calibrationRow("Application activation", "Xcode", "now")
            calibrationRow("Browser context", "Dia · Work · github.com", "2s")
            calibrationRow("Input presence", "Interactive", "3s")
            calibrationRow("Media metadata", "A Walk · Tycho", "4s")
            calibrationRow("Audio process", "Music", "4s")
            calibrationRow("Profile identity", "Dia · Work", "5s")
            calibrationRow("Automation marker", "Browser event schema", "8s")
            calibrationRow("Backup capability", "iCloud available", "10s")
            Text("Attention is ready. You can change any decision later without losing raw mock observations.")
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                .foregroundStyle(DashSkin.sage)
        }
    }

    private var setupFooter: some View {
        HStack {
            Button("Back") {
                store.setupStepIndex = max(0, store.setupStepIndex - 1)
            }
            .disabled(store.setupStepIndex == 0)
            Spacer()
            Button(store.setupStepIndex == store.setupSteps.count - 1 ? "Finish" : "Continue") {
                store.advanceSetup()
                if !store.showSetup { dismiss() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, UIScale.pt(24))
        .frame(height: UIScale.pt(60))
    }

    private func presetDetail(_ option: String) -> String {
        switch option {
        case "Standard": "Applications, domains, presence, and music"
        case "Detailed": "Adds titles, paths, profiles, and media progress"
        default: "Adds local page context, history import, and rich classification"
        }
    }

    private func setupCheck(_ title: String, _ complete: Bool) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle").foregroundStyle(complete ? DashSkin.sage : DashSkin.inkFaint(dark))
            Text(title).font(.system(size: UIScale.pt(10.5)))
        }
    }

    private func permissionRow(_ title: String, _ detail: String, _ status: String, _ color: Color) -> some View {
        HStack(spacing: UIScale.pt(11)) {
            Circle().fill(color).frame(width: UIScale.pt(8), height: UIScale.pt(8))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title).font(.system(size: UIScale.pt(10.5), weight: .semibold))
                Text(detail).font(.system(size: UIScale.pt(9))).foregroundStyle(DashSkin.inkFaint(dark))
            }
            Spacer()
            Text(status).font(.system(size: UIScale.pt(9.5), weight: .semibold)).foregroundStyle(color)
        }
        .padding(UIScale.pt(11))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(9)).strokeBorder(DashSkin.line(dark)))
    }

    private func identitySuggestion(_ name: String, _ surfaces: String, _ category: String) -> some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(DashSkin.accentDeep(dark)).frame(width: UIScale.pt(28))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(name).font(.system(size: UIScale.pt(10.5), weight: .semibold))
                Text(surfaces).font(.system(size: UIScale.pt(9))).foregroundStyle(DashSkin.inkFaint(dark))
            }
            Spacer()
            Text(category).font(.system(size: UIScale.pt(9.5), weight: .medium)).foregroundStyle(DashSkin.sage)
        }
        .padding(UIScale.pt(10))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(9)).strokeBorder(DashSkin.line(dark)))
    }

    private func sourceTest(_ name: String, _ track: String, _ status: String, _ color: Color) -> some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(systemName: "music.note").foregroundStyle(Color.pink).frame(width: UIScale.pt(30), height: UIScale.pt(30)).background(Color.pink.opacity(0.1), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(name).font(.system(size: UIScale.pt(10.5), weight: .semibold))
                Text(track).font(.system(size: UIScale.pt(9))).foregroundStyle(DashSkin.inkFaint(dark))
            }
            Spacer()
            Text(status).font(.system(size: UIScale.pt(9.5), weight: .medium)).foregroundStyle(color)
        }
        .padding(UIScale.pt(11))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(9)).strokeBorder(DashSkin.line(dark)))
    }

    private func calibrationRow(_ signal: String, _ value: String, _ age: String) -> some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DashSkin.sage)
            Text(signal).font(.system(size: UIScale.pt(10.5), weight: .medium))
            Spacer()
            Text(value).font(.system(size: UIScale.pt(9.5))).foregroundStyle(DashSkin.inkSoft(dark))
            Text(age).font(DashSkin.mono(8.5)).foregroundStyle(DashSkin.inkFaint(dark)).frame(width: UIScale.pt(24), alignment: .trailing)
        }
        .padding(.vertical, UIScale.pt(5))
    }
}
