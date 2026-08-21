import AppKit
import EdithKit
import SwiftUI

struct AttentionPage: View {
    @State private var model = AttentionPageModel()
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageHeader(
                    title: { Text("Attention") },
                    trailing: {
                        if !model.needsSetup,
                            model.section == .overview || model.section == .timeline
                        {
                            Picker("Range", selection: $model.range) {
                                ForEach(AttentionViewRange.allCases) { range in
                                    Text(range.title).tag(range)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: compact ? 210 : 250)
                        }
                    },
                    accessory: {
                        if !model.needsSetup {
                            Picker("Section", selection: $model.section) {
                                ForEach(AttentionPageSection.allCases) { section in
                                    Text(section.title).tag(section)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 500)
                        }
                    })

                if let message = model.message {
                    AttentionNotice(text: message, error: false)
                        .pageGutter(compact)
                        .padding(.bottom, 10)
                }
                if let error = model.errorMessage {
                    AttentionNotice(text: error, error: true)
                        .pageGutter(compact)
                        .padding(.bottom, 10)
                }

                Group {
                    if model.needsSetup {
                        AttentionSetupView(model: model)
                    } else {
                        switch model.section {
                        case .overview:
                            if model.hasActivity {
                                AttentionOverview(model: model)
                            } else {
                                AttentionCollectingView(model: model)
                            }
                        case .timeline: AttentionTimelineView(model: model)
                        case .focus: AttentionFocusView(model: model)
                        case .settings: AttentionSettingsView(model: model)
                        }
                    }
                }
                .pageContent(compact)
            }
        }
        .background(DashSkin.paper(scheme == .dark))
        .onChange(of: model.range) { model.reload() }
        .task {
            await model.checkBrowser()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                model.reload(preserveSettings: model.needsSetup || model.section == .settings)
                await model.checkBrowser()
            }
        }
    }
}

private struct AttentionSetupView: View {
    @Bindable var model: AttentionPageModel
    @State private var applicationTracking = true
    @State private var browserTracking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                Text("See where your attention actually goes")
                    .font(DashSkin.serif(28))
                Text(
                    "Edith records real foreground activity on this Mac. Start with applications, add browser detail if you want it, and change every rule later. Nothing leaves this Mac unless you enable iCloud backup."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            AttentionCard {
                SetupStep(
                    number: "1", title: "Choose your sources",
                    subtitle:
                        "Both sources share one timeline and overlapping browser time is counted once."
                )
                Divider()
                Toggle(isOn: $applicationTracking) {
                    SourceLabel(
                        icon: "macwindow", title: "Applications",
                        subtitle: "Foreground app, active time, idle time, sleep and lock state")
                }
                Toggle(isOn: $browserTracking) {
                    SourceLabel(
                        icon: "globe", title: "Browser detail",
                        subtitle: "Focused site, tab changes, favicons, profiles and optional media"
                    )
                }
            }

            AttentionCard {
                SetupStep(
                    number: "2", title: "Set the detail level",
                    subtitle:
                        "The browser extension and Mac collector apply this before writing to disk."
                )
                Picker("Privacy", selection: $model.settings.privacyLevel) {
                    Text("Applications only").tag(AttentionPrivacyLevel.applications)
                    Text("Domains").tag(AttentionPrivacyLevel.domains)
                    Text("Detailed").tag(AttentionPrivacyLevel.detailed)
                }
                .pickerStyle(.segmented)
                Text(privacyDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if model.settings.privacyLevel == .detailed {
                    Toggle(
                        "Include window and page titles", isOn: $model.settings.windowTitlesEnabled)
                    if model.settings.windowTitlesEnabled {
                        Button("Grant Accessibility access") { model.requestAccessibility() }
                    }
                }
            }

            if browserTracking {
                BrowserInstallCard(model: model, showToken: true)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("The event store starts empty")
                        .font(.system(size: 12, weight: .semibold))
                    Text("You will see a collecting state until genuine activity arrives.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Begin tracking") {
                    model.completeSetup(
                        applicationTracking: applicationTracking,
                        browserTracking: browserTracking)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!applicationTracking && !browserTracking)
            }
            .padding(.top, 4)
        }
    }

    private var privacyDescription: String {
        switch model.settings.privacyLevel {
        case .applications:
            return
                "Stores only application and browser names. Site identity and page metadata are discarded."
        case .domains:
            return
                "Stores normalized domains and favicons. Paths, query strings, page titles and form contents are not stored."
        case .detailed:
            return
                "Stores sanitized paths and optional titles. Query strings and fragments are always removed."
        }
    }
}

private struct AttentionCollectingView: View {
    @Bindable var model: AttentionPageModel

    var body: some View {
        AttentionCard {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 76, height: 76)
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                Text("Collecting your first real activity")
                    .font(DashSkin.serif(24))
                Text(
                    "Use your Mac normally. The overview appears after the first genuine foreground heartbeat arrives."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                HStack(spacing: 12) {
                    StatusPill(
                        title: "Applications",
                        state: model.settings.trackingEnabled ? "Listening" : "Off",
                        good: model.settings.trackingEnabled)
                    StatusPill(
                        title: "Browser",
                        state: model.browserConnected
                            ? "Connected"
                            : model.settings.browserTrackingEnabled ? "Waiting" : "Off",
                        good: model.browserConnected)
                }
                Button("Review setup") { model.section = .settings }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 42)
        }
    }
}

private struct AttentionOverview: View {
    @Bindable var model: AttentionPageModel
    @Environment(\.compactLayout) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: compact ? 145 : 180), spacing: 12)],
                spacing: 12
            ) {
                AttentionMetricCard(
                    title: "Active", value: attentionDuration(model.summary.activeDuration),
                    detail: model.range.title, icon: "clock.fill", tint: .blue)
                AttentionMetricCard(
                    title: "Focused", value: attentionDuration(model.summary.focusedDuration),
                    detail: percent(model.summary.focusedDuration, model.summary.activeDuration),
                    icon: "scope", tint: .green)
                AttentionMetricCard(
                    title: "Entertainment",
                    value: attentionDuration(model.summary.entertainmentDuration),
                    detail: percent(
                        model.summary.entertainmentDuration, model.summary.activeDuration),
                    icon: "play.rectangle.fill", tint: .orange)
                AttentionMetricCard(
                    title: "Context switches", value: String(model.summary.contextSwitches),
                    detail: switchCadence, icon: "arrow.triangle.2.circlepath", tint: .purple)
            }

            AttentionCard {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Attention distribution").font(.system(size: 15, weight: .semibold))
                        Text("Only engaged foreground intervals")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(attentionDuration(model.summary.activeDuration))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                DistributionBar(summary: model.summary)
                HStack(spacing: 18) {
                    DistributionLegend(
                        label: "Focus", color: .green, duration: model.summary.focusedDuration)
                    DistributionLegend(
                        label: "Communication", color: .blue,
                        duration: model.summary.communicationDuration)
                    DistributionLegend(
                        label: "Entertainment", color: .orange,
                        duration: model.summary.entertainmentDuration)
                    DistributionLegend(label: "Other", color: .gray, duration: otherDuration)
                }
            }

            AttentionCard {
                HStack {
                    Text("Where time went").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("Category changes reclassify history")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if model.summary.entities.isEmpty {
                    EmptyInline(text: "No active destinations in this range")
                } else {
                    ForEach(Array(model.summary.entities.prefix(15).enumerated()), id: \.element.id)
                    { index, entity in
                        if index > 0 { Divider() }
                        EntityRow(entity: entity, total: model.summary.activeDuration, model: model)
                    }
                }
            }

            if !model.summary.music.isEmpty {
                AttentionCard {
                    HStack {
                        Text("Listening").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text(attentionDuration(model.summary.music.reduce(0) { $0 + $1.duration }))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.summary.music.prefix(8).enumerated()), id: \.element.id) {
                        index, item in
                        if index > 0 { Divider() }
                        HStack(spacing: 12) {
                            Image(systemName: "music.note")
                                .foregroundStyle(.pink).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1)
                                Text(
                                    [item.artist, item.album, item.service].compactMap { $0 }
                                        .joined(separator: " · ")
                                )
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(attentionDuration(item.duration))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }

    private var otherDuration: TimeInterval {
        max(
            0,
            model.summary.activeDuration - model.summary.focusedDuration
                - model.summary.communicationDuration - model.summary.entertainmentDuration)
    }

    private var switchCadence: String {
        guard model.summary.activeDuration > 0 else { return "No active time" }
        let hourly = Double(model.summary.contextSwitches) / model.summary.activeDuration * 3_600
        return String(format: "%.1f per hour", hourly)
    }

    private func percent(_ value: TimeInterval, _ total: TimeInterval) -> String {
        guard total > 0 else { return "0% of active time" }
        return "\(Int((value / total * 100).rounded()))% of active time"
    }
}

private struct AttentionTimelineView: View {
    @Bindable var model: AttentionPageModel

    var body: some View {
        AttentionCard {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Observed timeline").font(.system(size: 15, weight: .semibold))
                    Text(
                        "Native and browser observations are both retained; summaries resolve their overlap."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.events.count) events")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            if model.events.isEmpty {
                EmptyInline(text: "No events in \(model.range.title.lowercased())")
            } else {
                ForEach(Array(model.events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider() }
                    HStack(spacing: 12) {
                        Image(systemName: eventIcon(event))
                            .foregroundStyle(
                                event.presence == .active ? Color.accentColor : .secondary
                            )
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(eventTitle(event)).lineLimit(1)
                            Text(eventDetail(event))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(event.startedAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                            Text(attentionDuration(event.duration))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func eventIcon(_ event: AttentionEvent) -> String {
        switch event.source {
        case .application: return "macwindow"
        case .browser: return "globe"
        case .media: return event.media?.kind == "audio" ? "music.note" : "play.rectangle"
        case .manual: return "hand.tap"
        }
    }

    private func eventTitle(_ event: AttentionEvent) -> String {
        event.media?.title ?? event.domain ?? event.appName ?? "Unknown activity"
    }

    private func eventDetail(_ event: AttentionEvent) -> String {
        let parts = [
            event.source.rawValue, event.presence.rawValue, event.browserProfile,
            event.media?.artist, event.windowTitle,
        ].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}

private struct AttentionFocusView: View {
    @Bindable var model: AttentionPageModel
    @State private var focusName = ""
    @State private var focusMinutes = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AttentionCard {
                if let focus = model.activeFocus {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = context.date.timeIntervalSince(focus.startedAt)
                        let remaining = focus.plannedDuration - elapsed
                        VStack(spacing: 14) {
                            Image(systemName: "scope")
                                .font(.system(size: 28)).foregroundStyle(.green)
                            Text(focus.name).font(DashSkin.serif(25))
                            Text(
                                remaining >= 0
                                    ? attentionClock(remaining)
                                    : "Overtime \(attentionClock(abs(remaining)))"
                            )
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            ProgressView(value: min(1, elapsed / focus.plannedDuration))
                                .tint(.green).frame(maxWidth: 420)
                            Button("Finish focus session") { model.stopFocus() }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Start a focus session").font(.system(size: 16, weight: .semibold))
                        TextField("What are you focusing on?", text: $focusName)
                            .textFieldStyle(.roundedBorder)
                        Picker("Duration", selection: $focusMinutes) {
                            Text("25 minutes").tag(25)
                            Text("45 minutes").tag(45)
                            Text("60 minutes").tag(60)
                            Text("90 minutes").tag(90)
                        }
                        .pickerStyle(.segmented)
                        Button("Start focus") {
                            model.startFocus(
                                name: focusName, duration: TimeInterval(focusMinutes * 60))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            AttentionCard {
                Text("Completed sessions").font(.system(size: 15, weight: .semibold))
                if model.focusSessions.isEmpty {
                    EmptyInline(text: "No completed focus sessions in this range")
                } else {
                    ForEach(Array(model.focusSessions.enumerated()), id: \.element.id) {
                        index, session in
                        if index > 0 { Divider() }
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.name)
                                Text(
                                    session.startedAt.formatted(
                                        date: .abbreviated, time: .shortened)
                                )
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(
                                attentionDuration(
                                    (session.endedAt ?? session.startedAt).timeIntervalSince(
                                        session.startedAt))
                            )
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }
}

private struct AttentionSettingsView: View {
    @Bindable var model: AttentionPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AttentionCard {
                SettingsTitle(
                    "Sources",
                    subtitle: "Every setting required to start and stop collection is here.")
                Toggle("Track foreground applications", isOn: $model.settings.trackingEnabled)
                Toggle("Run local browser server", isOn: $model.settings.browserTrackingEnabled)
                Picker("Privacy level", selection: $model.settings.privacyLevel) {
                    Text("Applications only").tag(AttentionPrivacyLevel.applications)
                    Text("Domains").tag(AttentionPrivacyLevel.domains)
                    Text("Detailed").tag(AttentionPrivacyLevel.detailed)
                }
                Toggle("Store window and page titles", isOn: $model.settings.windowTitlesEnabled)
                HStack {
                    Picker("Idle after", selection: $model.settings.idleThreshold) {
                        Text("1 minute").tag(TimeInterval(60))
                        Text("3 minutes").tag(TimeInterval(180))
                        Text("5 minutes").tag(TimeInterval(300))
                        Text("10 minutes").tag(TimeInterval(600))
                        Text("15 minutes").tag(TimeInterval(900))
                    }
                    Spacer()
                    if model.settings.windowTitlesEnabled {
                        Button("Accessibility access") { model.requestAccessibility() }
                    }
                }
            }

            BrowserInstallCard(model: model, showToken: true)

            AttentionCard {
                SettingsTitle(
                    "iCloud backup",
                    subtitle: "Snapshots stay in your own iCloud Drive under Edith/Attention.")
                Toggle(
                    "Back up attention data every 15 minutes",
                    isOn: $model.settings.iCloudBackupEnabled)
                HStack {
                    Button("Back up now") { model.backupNow() }
                    Button("Restore before tracking") { model.restoreBackup() }
                        .disabled(!model.cloudBackup.available || model.hasStoredEvents)
                    Spacer()
                    if let date = model.cloudBackup.lastBackupAt {
                        Text("Last backup \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }

            AttentionCard {
                HStack {
                    SettingsTitle(
                        "Categories",
                        subtitle:
                            "Kinds drive focus and entertainment totals. Colors use six-digit hex.")
                    Spacer()
                    Button("Add category") { model.addCategory() }
                }
                ForEach(model.settings.categories.indices, id: \.self) { index in
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        TextField("Name", text: $model.settings.categories[index].name)
                        Picker("Kind", selection: $model.settings.categories[index].kind) {
                            ForEach(AttentionCategoryKind.allCases, id: \.self) { kind in
                                Text(kind.rawValue.capitalized).tag(kind)
                            }
                        }
                        .frame(width: 150)
                        TextField("Color", text: $model.settings.categories[index].color)
                            .frame(width: 90)
                        Button(role: .destructive) {
                            model.removeCategory(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }

            AttentionCard {
                HStack {
                    SettingsTitle(
                        "Identity rules",
                        subtitle:
                            "Unify native bundle IDs and web domains under one configurable name.")
                    Spacer()
                    Button("Add rule") { model.addRule() }
                }
                ForEach(model.settings.rules.indices, id: \.self) { index in
                    if index > 0 { Divider() }
                    RuleEditor(
                        rule: $model.settings.rules[index], categories: model.settings.categories
                    ) {
                        model.settings.rules.remove(at: index)
                    }
                    .padding(.vertical, 5)
                }
            }

            HStack {
                Text("Changes take effect in the menu bar collector after saving.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Save settings") { model.saveSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct BrowserInstallCard: View {
    @Bindable var model: AttentionPageModel
    let showToken: Bool

    var body: some View {
        AttentionCard {
            HStack(alignment: .top) {
                SetupStep(
                    number: "3", title: "Connect each browser profile",
                    subtitle:
                        "Chrome, Chromium, Brave, Edge, Opera and Dia can load the same local extension."
                )
                Spacer()
                StatusPill(
                    title: "Local server",
                    state: model.browserConnected ? "Connected" : "Waiting",
                    good: model.browserConnected)
            }
            Divider()
            GuideRow(number: 1, text: "Install and reveal Edith's packaged extension folder") {
                Button(model.extensionInstalled ? "Reveal folder" : "Install extension") {
                    model.installExtension()
                }
            }
            GuideRow(
                number: 2, text: "Open the browser extension manager and enable Developer mode"
            ) {
                Button("Open extensions") { model.openChromeExtensions() }
            }
            GuideRow(
                number: 3,
                text:
                    "Choose Load unpacked, select the revealed folder, then open Edith Attention settings"
            )
            if showToken {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("Private local token").font(.system(size: 11, weight: .semibold))
                    HStack {
                        Text(String(repeating: "•", count: 24))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button("Copy") { model.copyToken() }
                    }
                    Text(
                        "Paste this token into the extension settings for every profile. Each profile gets its own label and can import its own 30-day site inventory."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text(
                "Deep mode is enabled inside the extension. It asks separately for website access and reads only playing media metadata. Standard tab tracking does not need page access."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct AttentionCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 1))
    }
}

private struct SetupStep: View {
    let number: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.14), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SourceLabel: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AttentionMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Spacer()
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.16)))
    }
}

private struct DistributionBar: View {
    let summary: AttentionSummary

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                segment(summary.focusedDuration, color: .green, width: geometry.size.width)
                segment(summary.communicationDuration, color: .blue, width: geometry.size.width)
                segment(summary.entertainmentDuration, color: .orange, width: geometry.size.width)
                segment(other, color: .gray.opacity(0.55), width: geometry.size.width)
            }
            .clipShape(Capsule())
        }
        .frame(height: 12)
    }

    private var other: TimeInterval {
        max(
            0,
            summary.activeDuration - summary.focusedDuration - summary.communicationDuration
                - summary.entertainmentDuration)
    }

    private func segment(_ value: TimeInterval, color: Color, width: CGFloat) -> some View {
        color.frame(width: summary.activeDuration > 0 ? width * value / summary.activeDuration : 0)
    }
}

private struct DistributionLegend: View {
    let label: String
    let color: Color
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(label) \(attentionDuration(duration))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct EntityRow: View {
    let entity: AttentionEntity
    let total: TimeInterval
    @Bindable var model: AttentionPageModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(categoryColor.opacity(0.13))
                Image(systemName: entity.source == .browser ? "globe" : "app.fill")
                    .foregroundStyle(categoryColor)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entity.name).lineLimit(1)
                    Text(entity.category.name)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(categoryColor.opacity(0.12), in: Capsule())
                }
                ProgressView(value: total > 0 ? entity.duration / total : 0)
                    .tint(categoryColor)
            }
            Spacer()
            Text(attentionDuration(entity.duration))
                .font(.system(size: 12, weight: .medium, design: .rounded))
            Menu {
                ForEach(model.settings.categories) { category in
                    Button(category.name) { model.assign(entity: entity, to: category.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 5)
    }

    private var categoryColor: Color {
        colorFromHex(entity.category.color) ?? .secondary
    }
}

private struct RuleEditor: View {
    @Binding var rule: AttentionIdentityRule
    let categories: [AttentionCategory]
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Identity name", text: $rule.name)
                Picker("Category", selection: $rule.categoryID) {
                    ForEach(categories) { category in Text(category.name).tag(category.id) }
                }
                .frame(width: 180)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            HStack {
                TextField(
                    "Bundle IDs, comma separated",
                    text: arrayBinding(\AttentionIdentityRule.bundleIDs))
                TextField(
                    "Domains, comma separated", text: arrayBinding(\AttentionIdentityRule.domains))
            }
            .font(.system(size: 11))
        }
    }

    private func arrayBinding(_ keyPath: WritableKeyPath<AttentionIdentityRule, [String]>)
        -> Binding<String>
    {
        Binding(
            get: { rule[keyPath: keyPath].joined(separator: ", ") },
            set: { value in
                rule[keyPath: keyPath] = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            })
    }
}

private struct GuideRow<Trailing: View>: View {
    let number: Int
    let text: String
    @ViewBuilder var trailing: Trailing

    init(number: Int, text: String, @ViewBuilder trailing: () -> Trailing) {
        self.number = number
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(String(number)).font(.system(size: 10, weight: .bold)).frame(width: 21, height: 21)
                .background(.secondary.opacity(0.12), in: Circle())
            Text(text).font(.system(size: 12))
            Spacer()
            trailing
        }
    }
}

extension GuideRow where Trailing == EmptyView {
    init(number: Int, text: String) {
        self.init(number: number, text: text) { EmptyView() }
    }
}

private struct SettingsTitle: View {
    let title: String
    let subtitle: String

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct StatusPill: View {
    let title: String
    let state: String
    let good: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(good ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text("\(title): \(state)").font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background((good ? Color.green : Color.orange).opacity(0.1), in: Capsule())
    }
}

private struct AttentionNotice: View {
    let text: String
    let error: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(text).font(.system(size: 11, weight: .medium))
            Spacer()
        }
        .foregroundStyle(error ? Color.red : Color.green)
        .padding(10)
        .background(
            (error ? Color.red : Color.green).opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct EmptyInline: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

private func attentionDuration(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value.rounded()))
    let hours = seconds / 3_600
    let minutes = seconds % 3_600 / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "\(seconds)s"
}

private func attentionClock(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value.rounded()))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

private func colorFromHex(_ value: String) -> Color? {
    let text = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    guard text.count == 6, let number = UInt64(text, radix: 16) else { return nil }
    return Color(
        red: Double((number >> 16) & 0xFF) / 255,
        green: Double((number >> 8) & 0xFF) / 255,
        blue: Double(number & 0xFF) / 255)
}
