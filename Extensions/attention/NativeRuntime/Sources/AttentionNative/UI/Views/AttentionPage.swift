internal import EdithExtensionSupport_attention_native
internal import EdithExtensionUI
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

    private var presenterHidden: Bool {
        SurfacePrivacyState.hides(
            .ability("attention"),
            values: ExtensionSharedState.current?.values(for: "presenter") ?? [:])
    }

    private var pageHeader: some View {
        PageHeader(
            divider: true,
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
    }

    @ViewBuilder private var notices: some View {
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
    }

    private var hasNotices: Bool {
        model.uiClient?.available == false || model.message != nil
            || (model.loaded && model.errorMessage != nil)
    }

    private var timelineListHeader: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
            notices
            if model.hasFilters {
                AttentionFilterScopeNotice(model: model)
            }
        }
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
        .padding(
            .bottom, hasNotices || model.hasFilters ? UIScale.pt(PageMetrics.sectionSpacing) : 0)
    }

    private var timelineList: some View {
        AttentionTimelineList(model: model) { timelineListHeader }
            .opacity(model.activity == .updating ? 0.45 : 1)
            .animation(.easeOut(duration: 0.15), value: model.activity == .updating)
            .overlay(alignment: .top) {
                ContentActivityBadge(model.activity).padding(.top, UIScale.pt(8))
            }
            .overlay {
                if presenterHidden {
                    AttentionPresenterCover()
                }
            }
    }

    var body: some View {
        Group {
            if model.showsTimelineList {
                PageWorkspace {
                    pageHeader
                } content: {
                    timelineList
                }
            } else {
                scaffold
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

    private var scaffold: some View {
        PageScaffold(
            pinnedHeader: true, scrollIdentity: model.section.rawValue, activity: model.activity
        ) {
            pageHeader
        } content: {
            notices

            PageLoading(
                state: model.loading.state,
                title: "No attention activity",
                message: model.loading.errorMessage
                    ?? "Enable a tracking source to begin collecting activity.",
                layout: .analytics, activity: model.activity,
                retry: { model.reload() }
            ) {
                Group {
                    if model.needsSetup && model.uiClient?.available != false {
                        AttentionSetupView(model: model)
                    } else if model.section == .settings {
                        AttentionSettingsView(model: model)
                            .buttonStyle(.edith(.secondary))
                    } else if model.hasFilters, !model.hasActivity, model.section != .focus {
                        AttentionNoMatchView(model: model)
                    } else {
                        if model.hasFilters {
                            AttentionFilterScopeNotice(model: model)
                        }
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
                        .presenterCover(presenterHidden)
                    }
                }
            }
        }
    }
}

private struct AttentionPresenterCover: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            DashSkin.paper(scheme == .dark)
            Label("Hidden while presenting", systemImage: "eye.slash")
                .font(.edithText(.callout))
                .foregroundStyle(.secondary)
        }
    }
}

private struct AttentionPeriodControl: View {
    @Bindable var model: AttentionPageModel
    @State private var customOpen = false
    @State private var customFrom = Date()
    @State private var customTo = Date()

    private static let presets: [AttentionRangePreset] = [.today, .last7, .last30, .allTime]

    var body: some View {
        PageFilterBar {
            PageFilterRow("Range") {
                ForEach(Self.presets, id: \.self) { preset in
                    PageChip(
                        preset == .last7 ? "7 days" : preset == .last30 ? "30 days" : preset.title,
                        active: preset == .allTime
                            ? model.period.preset == .allTime
                            : model.period == AttentionPeriod(preset)
                    ) { model.select(preset) }
                }
                moreRanges
                stepper
            }
            PageFilterRow("Show") {
                AttentionFilterMenu(model: model)
                AttentionWindowMenu(model: model)
                AttentionIdleMenu(model: model)
                SearchField(
                    placeholder: "Search names and titles", text: $model.searchText, compact: true
                )
                .frame(width: UIScale.pt(240))
                if model.hasFilters {
                    Button("Clear filters") { model.clearFilters() }
                        .buttonStyle(.edith(.borderless))
                        .font(PageMetrics.chipFont)
                        .frame(minHeight: UIScale.pt(PageMetrics.chipHeight))
                        .fixedSize()
                }
            }
        }
    }

    private var moreRanges: some View {
        PageMenuChip("More", systemImage: "calendar") {
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
        }
        .popover(isPresented: $customOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                Text("Custom range").font(.edithText(.headline))
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
            .padding(UIScale.pt(16))
            .frame(width: UIScale.pt(280))
        }
    }

    private var stepper: some View {
        HStack(spacing: UIScale.pt(4)) {
            Button {
                model.step(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .frame(width: UIScale.pt(10))
            }
            .buttonStyle(.pageChip())
            .disabled(!model.canStepBackward)
            .help("Previous period")
            .accessibilityLabel("Previous period")
            Text(model.period.title())
                .font(PageMetrics.chipFont)
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: UIScale.pt(88))
            Button {
                model.step(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .frame(width: UIScale.pt(10))
            }
            .buttonStyle(.pageChip())
            .disabled(!model.canStepForward)
            .help("Next period")
            .accessibilityLabel("Next period")
        }
        .fixedSize()
    }
}

private struct AttentionIdleMenu: View {
    @Bindable var model: AttentionPageModel

    var body: some View {
        PageMenuChip(
            model.excludeIdleTime ? "Exclude idle" : "Include idle", systemImage: "moon.zzz",
            active: !model.excludeIdleTime
        ) {
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
        }
        .help("Filter screen time with or without idle and locked periods")
    }
}

private struct AttentionWindowMenu: View {
    let model: AttentionPageModel

    var body: some View {
        let window = model.window
        PageMenuChip(
            window.isAll ? "All hours" : window.title, systemImage: "clock", active: !window.isAll
        ) {
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
        }
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
    @Environment(\.compactLayout) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
            VStack(spacing: UIScale.pt(16)) {
                PageGuideBadge(symbolName: "hourglass")
                Text("See where your attention actually goes")
                    .font(.edithText(.title2)).fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Attention measures how long each app and website is in front of you, so you can see where your day really goes. It runs quietly in the background and everything stays on this Mac unless you turn on iCloud backup."
                )
                .font(.edithText(.body)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: UIScale.pt(520))
                PageGuideSteps(
                    steps: [
                        PageGuideStep(
                            symbolName: "checklist", title: "Pick sources",
                            detail: "Apps, and optionally your browser."),
                        PageGuideStep(
                            symbolName: "lock.shield", title: "Set privacy",
                            detail: "Choose how much detail is stored."),
                        PageGuideStep(
                            symbolName: "play.circle", title: "Begin tracking",
                            detail: "Charts appear after a few minutes of use."),
                    ], columns: compact ? 1 : 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UIScale.pt(12))

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
                    .font(.edithText(.callout))
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

            HStack(spacing: UIScale.pt(16)) {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(
                        AttentionPageModel.setupBlocker(
                            applicationTracking: applicationTracking,
                            browserTracking: browserTracking) ?? "Nothing is recorded yet"
                    )
                    .font(.edithText(.callout).weight(.semibold))
                    Text(
                        "Tracking starts when you press Begin. You can pause or erase it any time in Settings."
                    )
                    .font(.edithText(.subheadline))
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
            .padding(.top, UIScale.pt(4))
        }
        .buttonStyle(.edith(.secondary))
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

private struct AttentionFilterScopeNotice: View {
    let model: AttentionPageModel

    var body: some View {
        let summary = model.summary
        PageNotice(
            "Every section shows only matching activity: "
                + AttentionFormat.duration(summary.activeDuration) + " of "
                + AttentionFormat.duration(summary.activeDuration + summary.unmatchedDuration)
                + " active time. Idle time is left out while filtering.",
            symbol: "line.3.horizontal.decrease.circle",
            actions: {
                Button("Clear filters") { model.clearFilters() }
            })
    }
}

private struct AttentionNoMatchView: View {
    let model: AttentionPageModel

    var body: some View {
        PageEmptyState(
            symbolName: "line.3.horizontal.decrease.circle",
            title: "Nothing matches these filters",
            message:
                "No activity in \(model.period.title()) matches the current filters. "
                + AttentionFormat.duration(model.summary.unmatchedDuration)
                + " of other activity is hidden.",
            primary: PageAction("Clear filters", symbolName: "xmark.circle") {
                model.clearFilters()
            }
        )
        .frame(minHeight: UIScale.pt(300))
    }
}

private struct AttentionCollectingView: View {
    @Bindable var model: AttentionPageModel

    private var enabled: Bool { model.settings.isEnabled }

    var body: some View {
        VStack(spacing: UIScale.pt(16)) {
            PageEmptyState(
                symbolName: enabled ? "waveform.path.ecg" : "pause.circle",
                title: enabled ? "Tracking is on, waiting for activity" : "Tracking is paused",
                message: enabled
                    ? "Use your Mac normally. Charts appear within a minute or two of the first app or site you use. This page updates by itself."
                    : "Attention is not recording. Your existing history and settings stay on this Mac.",
                primary: enabled
                    ? PageAction("Review sources", symbolName: "slider.horizontal.3") {
                        model.section = .settings
                    }
                    : PageAction("Turn tracking on", symbolName: "play.fill") {
                        model.setAttentionEnabled(true)
                    },
                secondary: enabled
                    ? nil
                    : PageAction("Open settings", symbolName: "gearshape") {
                        model.section = .settings
                    }
            )
            .frame(minHeight: UIScale.pt(240))
            HStack(spacing: 12) {
                AttentionStatusPill(
                    title: "Applications",
                    state: enabled && model.settings.trackingEnabled ? "Listening" : "Off",
                    good: enabled && model.settings.trackingEnabled)
                AttentionStatusPill(
                    title: "Browser",
                    state: model.browserConnected
                        ? "Connected"
                        : enabled && model.settings.browserTrackingEnabled
                            ? "Waiting for the extension" : "Off",
                    good: model.browserConnected)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct SetupStep: View {
    let number: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: UIScale.pt(12)) {
            Text(number)
                .font(.edithText(.callout).weight(.bold))
                .frame(width: UIScale.pt(26), height: UIScale.pt(26))
                .background(Color.themeAccent.opacity(0.14), in: Circle())
                .foregroundStyle(Color.themeAccent)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title).font(.edithText(.headline))
                Text(subtitle).font(.edithText(.callout)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SourceLabel: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: UIScale.pt(8)) {
            Image(systemName: icon).foregroundStyle(Color.themeAccent).frame(width: UIScale.pt(20))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title).font(.edithText(.body).weight(.semibold))
                Text(subtitle).font(.edithText(.subheadline)).foregroundStyle(.secondary)
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
        HStack(spacing: UIScale.pt(8)) {
            Text(String(number)).font(.edithText(.caption).weight(.bold)).frame(
                width: UIScale.pt(21), height: UIScale.pt(21)
            )
            .background(.secondary.opacity(0.12), in: Circle())
            Text(text).font(.edithText(.callout))
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
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(title).font(.edithText(.headline))
            Text(subtitle).font(.edithText(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    Text("Local port").font(.edithText(.subheadline).weight(.semibold))
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
                    .font(.edithText(.subheadline)).foregroundStyle(.secondary)
                }
            }
            Text(
                "Version \(AttentionExtensionInstaller.version) reads the focused tab, page titles, searches, repositories, videos, playing media and typing, clicking and scrolling counts on every site. Updates install themselves when Edith ships a newer version."
            )
            .font(.edithText(.subheadline)).foregroundStyle(.secondary)
        }
    }
}
