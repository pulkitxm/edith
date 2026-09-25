import AppKit
import EdithKit
import SwiftUI

struct AttentionPage: View {
    @State private var model: AttentionPageModel
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme
    @Environment(\.windowVisible) private var windowVisible

    @MainActor
    init(model: AttentionPageModel? = nil) {
        _model = State(initialValue: model ?? AttentionPageModel())
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageHeader(
                    title: { Text("Attention") },
                    trailing: {
                        if !model.needsSetup, model.section.usesPeriod {
                            AttentionPeriodControl(model: model)
                        }
                    },
                    accessory: {
                        if !model.needsSetup {
                            AttentionSectionBar(model: model)
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

                LoadingContainer(
                    state: model.loaded ? .content : .loading,
                    title: "No attention activity",
                    message: "Enable a tracking source to begin collecting activity."
                ) {
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
                            case .breakdown: AttentionBreakdownView(model: model)
                            case .agents: AttentionAgentsView(model: model)
                            case .focus: AttentionFocusView(model: model)
                            case .settings: AttentionSettingsView(model: model)
                            }
                        }
                    }
                } placeholder: {
                    AttentionPageSkeleton(model: model)
                }
                .pageContent(compact)
            }
        }
        .background(DashSkin.paper(scheme == .dark))
        .task(id: windowVisible) {
            guard windowVisible else { return }
            model.reload()
            await model.checkBrowser()
            while !Task.isCancelled {
                try? await Task.sleep(for: model.refreshInterval, tolerance: .seconds(2))
                guard !Task.isCancelled else { return }
                model.reload(preserveSettings: model.needsSetup || model.section == .settings)
                await model.checkBrowser()
            }
        }
    }
}

private struct AttentionPeriodControl: View {
    let model: AttentionPageModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: UIScale.pt(6)) {
            ForEach(AttentionScope.allCases) { scope in
                let active = model.period.scope == scope
                Button {
                    model.setScope(scope)
                } label: {
                    Text(scope.title)
                        .font(DashSkin.mono(11, weight: active ? .semibold : .regular))
                        .padding(.horizontal, UIScale.pt(10))
                        .padding(.vertical, UIScale.pt(5))
                        .widgetBar(
                            cornerRadius: 8,
                            fill: active
                                ? AnyShapeStyle(DashSkin.accent(dark))
                                : AnyShapeStyle(DashSkin.paper2(dark)),
                            stroke: active ? Color.clear : DashSkin.lineStrong(dark))
                        .foregroundStyle(
                            active ? AnyShapeStyle(.white) : AnyShapeStyle(DashSkin.ink(dark)))
                }
                .buttonStyle(.edith(.borderless))
            }
            Divider().frame(height: UIScale.pt(18)).padding(.horizontal, UIScale.pt(4))
            Button {
                model.step(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.edith(.iconOnly))
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
            if model.canStepForward {
                Button("Today") { model.showToday() }
                    .buttonStyle(.edith(.secondary))
            }
        }
    }
}

private struct AttentionSectionBar: View {
    @Bindable var model: AttentionPageModel
    @Environment(\.compactLayout) private var compact

    var body: some View {
        HStack(spacing: 0) {
            Picker("Section", selection: $model.section) {
                ForEach(AttentionPageSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: compact ? .infinity : UIScale.pt(620), alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AttentionPageSkeleton: View {
    let model: AttentionPageModel
    @Environment(\.compactLayout) private var compact

    var body: some View {
        SkeletonGroup {
            Group {
                if model.needsSetup {
                    AttentionSetupSkeleton()
                } else if model.hasActivity {
                    AttentionOverviewSkeleton(compact: compact)
                } else {
                    AttentionCollectingSkeleton()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: UIScale.pt(240), alignment: .topLeading)
        .accessibilityLabel("Loading attention activity")
    }
}

private struct AttentionSetupSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            VStack(alignment: .leading, spacing: UIScale.pt(9)) {
                SkeletonBlock(width: 312, height: 27)
                SkeletonBlock(height: 9)
                SkeletonBlock(width: 464, height: 9)
            }
            .padding(.bottom, UIScale.pt(4))

            AttentionSetupCardSkeleton(rows: 2)
            AttentionSetupCardSkeleton(rows: 1, includesSegmentedControl: true)
            AttentionSetupCardSkeleton(rows: 2)

            HStack {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    SkeletonBlock(width: 174, height: 10)
                    SkeletonBlock(width: 286, height: 8)
                }
                Spacer()
                SkeletonBlock(width: 112, height: 30, corner: 7)
            }
            .padding(.top, UIScale.pt(4))
        }
    }
}

private struct AttentionSetupCardSkeleton: View {
    let rows: Int
    var includesSegmentedControl = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(13)) {
            HStack(alignment: .top, spacing: UIScale.pt(11)) {
                SkeletonBlock(width: 26, height: 26, corner: 13)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    SkeletonBlock(width: 156, height: 12)
                    SkeletonBlock(width: 348, height: 8)
                }
            }
            Divider()
            if includesSegmentedControl {
                SkeletonBlock(height: 28, corner: 7)
                SkeletonBlock(width: 382, height: 8)
            } else {
                ForEach(0..<rows, id: \.self) { index in
                    HStack(spacing: UIScale.pt(10)) {
                        SkeletonBlock(width: 24, height: 24, corner: 6)
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            SkeletonBlock(width: index.isMultiple(of: 2) ? 112 : 138, height: 10)
                            SkeletonBlock(width: index.isMultiple(of: 2) ? 310 : 354, height: 8)
                        }
                        Spacer()
                        SkeletonBlock(width: 30, height: 18, corner: 9)
                    }
                }
            }
        }
        .padding(UIScale.pt(18))
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: UIScale.pt(15)))
    }
}

private struct AttentionCollectingSkeleton: View {
    var body: some View {
        VStack(spacing: UIScale.pt(18)) {
            SkeletonBlock(width: 76, height: 76, corner: 38)
            SkeletonBlock(width: 324, height: 23)
            VStack(spacing: UIScale.pt(5)) {
                SkeletonBlock(width: 494, height: 9)
                SkeletonBlock(width: 362, height: 9)
            }
            HStack(spacing: UIScale.pt(12)) {
                SkeletonBlock(width: 126, height: 25, corner: 13)
                SkeletonBlock(width: 112, height: 25, corner: 13)
            }
            SkeletonBlock(width: 96, height: 27, corner: 7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UIScale.pt(60))
        .padding(.horizontal, UIScale.pt(18))
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: UIScale.pt(15)))
    }
}

private struct AttentionOverviewSkeleton: View {
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: UIScale.pt(compact ? 145 : 180)),
                        spacing: UIScale.pt(12))
                ],
                spacing: UIScale.pt(12)
            ) {
                ForEach(0..<4, id: \.self) { index in
                    VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                        HStack {
                            SkeletonBlock(width: 16, height: 16, corner: 5)
                            Spacer()
                            SkeletonBlock(width: 72, height: 9)
                        }
                        SkeletonBlock(
                            width: index.isMultiple(of: 2) ? 92 : 64,
                            height: 20)
                        SkeletonBlock(width: 84, height: 8)
                    }
                    .padding(UIScale.pt(15))
                    .background(
                        Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
                }
            }

            AttentionSkeletonCard(rows: 1, includesBar: true)
            AttentionSkeletonCard(rows: 6, includesBar: false)
        }
    }
}

private struct AttentionSkeletonCard: View {
    let rows: Int
    let includesBar: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack {
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    SkeletonBlock(width: 136, height: 11)
                    SkeletonBlock(width: 188, height: 8)
                }
                Spacer()
                SkeletonBlock(width: 68, height: 9)
            }
            if includesBar {
                SkeletonBlock(height: 12, corner: 6)
                HStack(spacing: UIScale.pt(18)) {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonBlock(width: 76, height: 8)
                    }
                }
            } else {
                ForEach(0..<rows, id: \.self) { index in
                    if index > 0 { Divider() }
                    HStack(spacing: UIScale.pt(12)) {
                        SkeletonBlock(width: 24, height: 24, corner: 6)
                        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                            SkeletonBlock(
                                width: index.isMultiple(of: 2) ? 142 : 188,
                                height: 9)
                            SkeletonBlock(width: 96, height: 7)
                        }
                        Spacer()
                        SkeletonBlock(width: 54, height: 9)
                    }
                }
            }
        }
        .padding(UIScale.pt(16))
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
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
                .frame(maxWidth: 520)
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
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 42)
        }
    }
}

struct AttentionCard<Content: View>: View {
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

struct SetupStep: View {
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

struct SourceLabel: View {
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

struct SettingsTitle: View {
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

struct BrowserInstallCard: View {
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
                    Text("Local port").font(.system(size: 11, weight: .semibold))
                    Text(String(model.settings.serverPort))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
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
                "Version \(AttentionExtensionInstaller.version) reads the focused tab, page titles, searches, repositories, videos, playing media and typing, clicking and scrolling counts on every site. Updates install themselves when Edith ships a newer version."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
