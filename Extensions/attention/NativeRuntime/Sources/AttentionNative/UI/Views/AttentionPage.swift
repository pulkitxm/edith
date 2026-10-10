@_implementationOnly import EdithExtensionSupport_attention_native
@_implementationOnly import EdithExtensionUI_attention_native
import AppKit
import SwiftUI

struct AttentionPage: View {
    @State private var model: AttentionPageModel
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    @MainActor
    init(model: AttentionPageModel? = nil) {
        _model = State(initialValue: model ?? AttentionPageModel())
    }

    var body: some View {
        PageScaffold(pinnedHeader: true, scrollIdentity: model.section.rawValue) {
            PageHeader(
                title: { Text("Attention") },
                trailing: {
                    EmptyView()
                },
                accessory: {
                    if !model.needsSetup {
                        AttentionSectionBar(model: model)
                        if model.section.usesPeriod {
                            AttentionPeriodControl(model: model)
                        }
                    }
                })
        } content: {
            if model.uiClient?.available == false {
                PageNotice(
                    "Enable Attention in Extensions to use activity tracking and settings.",
                    tone: .information)
            }
            if let message = model.message {
                PageNotice(message, tone: .success)
            }
            if model.loaded, let error = model.errorMessage {
                PageNotice(
                    error, tone: .error,
                    actions: {
                        Button("Retry") { model.reload() }
                    })
            }

            PageLoading(
                state: model.loading.state,
                title: "No attention activity",
                message: model.loading.errorMessage
                    ?? "Enable a tracking source to begin collecting activity.",
                layout: .analytics, refreshing: model.loading.isRefreshing,
                retry: { model.reload() }
            ) {
                Group {
                    if model.needsSetup && model.uiClient?.available != false {
                        AttentionSetupView(model: model)
                    } else if model.section == .settings {
                        AttentionSettingsView(model: model)
                    } else {
                        Group {
                            switch model.section {
                            case .overview:
                                if model.hasActivity {
                                    AttentionOverview(model: model)
                                } else {
                                    AttentionCollectingView(model: model)
                                }
                            case .timeline: AttentionTimelineView(model: model)
                            case .breakdown: AttentionBreakdownView(model: model)
                            case .agents: AttentionAgentsView(model: model)
                            case .focus: AttentionFocusView(model: model)
                            case .settings: EmptyView()
                            }
                        }
                        .presenterCover(
                            SurfacePrivacyState.hides(
                                .ability("attention"),
                                values: ExtensionSharedState.current?.values(for: "presenter")
                                    ?? [:]))
                    }
                }
            }
        }
        .disabled(model.uiClient?.available == false || model.uiClient?.stopped == true)
        .environment(\.attentionUIClient, model.uiClient)
        .navigationRoute("section", selection: $model.section)
        .pageRefresh(interval: { model.refreshInterval }, cancel: model.cancelLoading) {
            guard model.uiClient?.available != false, model.uiClient?.stopped != true else {
                return
            }
            model.reload(
                preserveSettings: model.loaded && (model.needsSetup || model.section == .settings))
            await model.waitForReload()
            await model.checkBrowser()
        }
    }
}

private struct AttentionPeriodControl: View {
    let model: AttentionPageModel
    @State private var customOpen = false
    @State private var customFrom = Date()
    @State private var customTo = Date()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        let dark = scheme == .dark
        WrapHStack(spacing: UIScale.pt(6), lineSpacing: UIScale.pt(8)) {
            ForEach(
                compact
                    ? [AttentionRangePreset.today, .allTime] : [.today, .last7, .last30, .allTime],
                id: \.self
            ) { preset in
                chip(
                    preset == .last7 ? "7 days" : preset == .last30 ? "30 days" : preset.title,
                    active: preset == .allTime
                        ? model.period.preset == .allTime : model.period == AttentionPeriod(preset),
                    dark: dark
                ) { model.select(preset) }
            }
            Menu {
                ForEach(Array(AttentionRangePreset.groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { preset in
                            Button(preset.title) { model.select(preset) }
                        }
                    }
                }
                Button("Custom range…") {
                    customFrom = model.period.start
                    customTo = model.period.lastDay
                    customOpen = true
                }
            } label: {
                Label("Range", systemImage: "calendar")
            }
            .menuStyle(.button)
            .buttonStyle(.edith(.secondary))
            .fixedSize()
            .popover(isPresented: $customOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    Text("Custom range").font(.system(size: UIScale.pt(13), weight: .semibold))
                    DatePicker(
                        "From", selection: $customFrom, in: ...Date(), displayedComponents: .date)
                    DatePicker(
                        "To", selection: $customTo, in: ...Date(), displayedComponents: .date)
                    HStack {
                        Spacer()
                        Button("Show") {
                            model.selectRange(from: customFrom, to: customTo)
                            customOpen = false
                        }
                        .buttonStyle(.edith(.primary))
                    }
                }
                .padding(16)
                .frame(width: UIScale.pt(280))
            }
            AttentionWindowMenu(model: model)
            AttentionIdleMenu(model: model)
            HStack(spacing: UIScale.pt(6)) {
                Button {
                    model.step(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.edith(.iconOnly))
                .disabled(!model.canStepBackward)
                .help("Previous period")
                Text(model.period.title())
                    .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                    .frame(minWidth: UIScale.pt(96))
                Button {
                    model.step(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.edith(.iconOnly))
                .disabled(!model.canStepForward)
                .help("Next period")
            }
            .fixedSize()
        }
    }

    private func chip(_ title: String, active: Bool, dark: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Text(title)
                .font(DashSkin.mono(11, weight: active ? .semibold : .regular))
                .padding(.horizontal, UIScale.pt(10))
                .padding(.vertical, UIScale.pt(5))
                .widgetBar(
                    cornerRadius: 8,
                    fill: active
                        ? AnyShapeStyle(DashSkin.accent(dark))
                        : AnyShapeStyle(DashSkin.paper2(dark)),
                    stroke: active ? Color.clear : DashSkin.lineStrong(dark)
                )
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(DashSkin.ink(dark)))
        }
        .buttonStyle(.edith(.borderless))
        .fixedSize()
    }
}

private struct AttentionIdleMenu: View {
    @Bindable var model: AttentionPageModel

    var body: some View {
        Menu {
            Button {
                model.excludeIdleTime = true
            } label: {
                if model.excludeIdleTime {
                    Label("Exclude idle time", systemImage: "checkmark")
                } else {
                    Text("Exclude idle time")
                }
            }
            Button {
                model.excludeIdleTime = false
            } label: {
                if model.excludeIdleTime {
                    Text("Include idle time")
                } else {
                    Label("Include idle time", systemImage: "checkmark")
                }
            }
        } label: {
            Label(
                model.excludeIdleTime ? "Exclude idle" : "Include idle",
                systemImage: "moon.zzz")
        }
        .menuStyle(.button)
        .buttonStyle(.edith(model.excludeIdleTime ? .primary : .secondary))
        .fixedSize()
        .help("Filter screen time with or without idle and locked periods")
    }
}

private struct AttentionWindowMenu: View {
    let model: AttentionPageModel

    var body: some View {
        let window = model.window
        Menu {
            Section("Days") {
                ForEach(AttentionDayFilter.allCases) { filter in
                    toggle(
                        filter.title,
                        on: window.weekdays == filter.weekdays || (filter == .all && window.allDays)
                    ) {
                        model.setDays(filter.weekdays)
                    }
                }
                Menu("Pick days") {
                    let symbols = Calendar.current.weekdaySymbols
                    ForEach(1...7, id: \.self) { weekday in
                        toggle(symbols[weekday - 1], on: window.allows(weekday: weekday)) {
                            model.toggleDay(weekday)
                        }
                    }
                }
            }
            Section("Hours") {
                ForEach(AttentionHourFilter.allCases) { filter in
                    toggle(
                        filter.title,
                        on: window.startHour == filter.hours.0 && window.endHour == filter.hours.1
                    ) { model.setHours(start: filter.hours.0, end: filter.hours.1) }
                }
                Menu("Starting at") {
                    ForEach(0..<24, id: \.self) { hour in
                        toggle(String(format: "%02d:00", hour), on: window.startHour == hour) {
                            model.setHours(start: hour, end: window.endHour)
                        }
                    }
                }
                Menu("Ending at") {
                    ForEach(1...24, id: \.self) { hour in
                        toggle(String(format: "%02d:00", hour % 24), on: window.endHour == hour) {
                            model.setHours(start: window.startHour, end: hour)
                        }
                    }
                }
            }
            if !window.isAll {
                Button("Reset to all days and hours") { model.setWindow(.all) }
            }
        } label: {
            Label(window.isAll ? "All hours" : window.title, systemImage: "clock")
        }
        .menuStyle(.button)
        .buttonStyle(.edith(window.isAll ? .secondary : .primary))
        .fixedSize()
    }

    private func toggle(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

private struct AttentionSectionBar: View {
    @Bindable var model: AttentionPageModel
    @Environment(\.compactLayout) private var compact

    var body: some View {
        HStack(spacing: 0) {
            EdithSegmentedPicker(
                "Section", selection: $model.section, options: AttentionPageSection.allCases,
                label: { $0.title }
            )
            .labelsHidden()
            .frame(maxWidth: compact ? .infinity : UIScale.pt(620), alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(DashSkin.heading(28))
                Text(
                    "Edith records real foreground activity on this Mac. Start with applications, add browser detail if you want it, and change every rule later. Nothing leaves this Mac unless you enable iCloud backup."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            PageCard {
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

            PageCard {
                SetupStep(
                    number: "2", title: "Set the detail level",
                    subtitle:
                        "The browser extension and Mac collector apply this before writing to disk."
                )
                EdithSegmentedPicker(
                    "Privacy", selection: $model.settings.privacyLevel,
                    options: [AttentionPrivacyLevel.applications, .domains, .detailed],
                    label: {
                        switch $0 {
                        case .applications: "Applications only"
                        case .domains: "Domains"
                        case .detailed: "Detailed"
                        }
                    })
                Text(privacyDescription)
                    .font(.system(size: UIScale.pt(12)))
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
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                    Text("You will see a collecting state until genuine activity arrives.")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Begin tracking") {
                    model.completeSetup(
                        applicationTracking: applicationTracking,
                        browserTracking: browserTracking)
                }
                .buttonStyle(.edith(.primary))
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
        PageCard {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.12)).frame(
                        width: UIScale.pt(76), height: UIScale.pt(76))
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: UIScale.pt(30), weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                Text(
                    model.settings.isEnabled
                        ? "Collecting your first real activity" : "Attention is disabled"
                )
                .font(DashSkin.heading(24))
                Text(
                    model.settings.isEnabled
                        ? "Use your Mac normally. The overview appears after the first genuine foreground heartbeat arrives."
                        : "Attention is completely disabled. Existing history and settings remain on this Mac."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: UIScale.pt(520))
                HStack(spacing: 12) {
                    AttentionStatusPill(
                        title: "Applications",
                        state: model.settings.isEnabled && model.settings.trackingEnabled
                            ? "Listening" : "Off",
                        good: model.settings.isEnabled && model.settings.trackingEnabled)
                    AttentionStatusPill(
                        title: "Browser",
                        state: model.browserConnected
                            ? "Connected"
                            : model.settings.isEnabled && model.settings.browserTrackingEnabled
                                ? "Waiting" : "Off",
                        good: model.browserConnected)
                }
                Button("Review setup") { model.section = .settings }
                    .buttonStyle(.edith(.secondary))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 42)
        }
    }
}

struct SetupStep: View {
    let number: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text(number)
                .font(.system(size: UIScale.pt(12), weight: .bold, design: .rounded))
                .frame(width: UIScale.pt(26), height: UIScale.pt(26))
                .background(Color.accentColor.opacity(0.14), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: UIScale.pt(15), weight: .semibold))
                Text(subtitle).font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
            }
        }
    }
}

struct SourceLabel: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: UIScale.pt(24))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: UIScale.pt(13), weight: .semibold))
                Text(subtitle).font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
            }
        }
    }
}

struct GuideRow<Trailing: View>: View {
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
            Text(String(number)).font(.system(size: UIScale.pt(10), weight: .bold)).frame(
                width: UIScale.pt(21), height: UIScale.pt(21)
            )
            .background(.secondary.opacity(0.12), in: Circle())
            Text(text).font(.system(size: UIScale.pt(12)))
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

struct SettingsTitle: View {
    let title: String
    let subtitle: String

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: UIScale.pt(15), weight: .semibold))
            Text(subtitle).font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
        }
    }
}

struct BrowserInstallCard: View {
    @Bindable var model: AttentionPageModel
    let showToken: Bool

    var body: some View {
        PageCard {
            HStack(alignment: .top) {
                SetupStep(
                    number: "3", title: "Connect each browser profile",
                    subtitle:
                        "Chrome, Chromium, Brave, Edge, Opera and Dia can load the same local extension."
                )
                Spacer()
                AttentionStatusPill(
                    title: "Local server",
                    state: !model.settings.isEnabled
                        ? "Disabled" : model.browserConnected ? "Connected" : "Waiting",
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
                    Text("Local port").font(.system(size: UIScale.pt(11), weight: .semibold))
                    Text(String(model.settings.serverPort))
                        .font(.system(size: UIScale.pt(11), design: .monospaced))
                        .textSelection(.enabled)
                    Text("Private local token").font(
                        .system(size: UIScale.pt(11), weight: .semibold))
                    HStack {
                        Text(String(repeating: "•", count: 24))
                            .font(.system(size: UIScale.pt(11), design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button("Copy") { model.copyToken() }
                    }
                    Text(
                        "Paste this token into the extension settings for every profile. Each profile gets its own label and can import its own 30-day site inventory."
                    )
                    .font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
                }
            }
            Text(
                "Version \(AttentionExtensionInstaller.version) reads the focused tab, page titles, searches, repositories, videos, playing media and typing, clicking and scrolling counts on every site. Updates install themselves when Edith ships a newer version."
            )
            .font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
        }
    }
}
