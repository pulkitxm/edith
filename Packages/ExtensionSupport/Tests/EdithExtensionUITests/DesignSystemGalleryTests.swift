import EdithExtensionTestSupport
import AppKit
import SwiftUI
import Testing
@testable import EdithExtensionUI

@MainActor
struct DesignSystemGallery {
    static func render<V: View>(_ view: V, variant: RenderCapture.Variant, name: String)
        async throws -> NSView
    {
        let rendered = try await RenderCapture.render(name, variant: variant) { view }
        #expect(rendered.bitmap.pixelsWide >= Int(variant.width))
        #expect(
            edgeColors(rendered.bitmap) <= 3,
            "\(name) \(variant.name) draws into the trailing edge")
        return rendered.host
    }

    static func edgeColors(_ bitmap: NSBitmapImageRep) -> Int {
        let scale = Double(bitmap.pixelsWide) / Double(bitmap.size.width)
        let x = bitmap.pixelsWide - Int((6 * scale).rounded())
        var colors = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 1) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            let key =
                Int(color.redComponent * 20) * 441 + Int(color.greenComponent * 20) * 21
                + Int(color.blueComponent * 20)
            colors.insert(key)
        }
        return colors.count
    }

    static let steps = [
        PageGuideStep(
            symbolName: "folder.badge.plus", title: "Pick a folder",
            detail: "Choose where your projects live. Nothing leaves this Mac."),
        PageGuideStep(
            symbolName: "magnifyingglass", title: "Scan it",
            detail: "Edith looks for caches and build output you can safely remove."),
        PageGuideStep(
            symbolName: "trash", title: "Review and clean",
            detail: "Nothing is deleted until you confirm each item."),
    ]

    static func header(trailingPrimary: Bool = true, filters: Bool = true) -> some View {
        PageHeader(
            "Synthetic Stats",
            subtitle: "Commits, pull requests and reviews across the sample repositories.",
            divider: true
        ) {
            HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                PageToolbarButton(action: {}, systemImage: "terminal", helperText: "Show log")
                Button {
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if trailingPrimary {
                    Button {
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.edith(.primary))
                }
            }
        } accessory: {
            if filters {
                PageFilterBar {
                    PageFilterRow("Range") {
                        PageChip("Today") {}
                        PageChip("This week", active: true) {}
                        PageChip("This month") {}
                        PageChip("All time") {}
                        PageMenuChip("Browse months", systemImage: "calendar") {
                            Button("October") {}
                        }
                        PageChip("Custom range", systemImage: "calendar.badge.clock") {}
                    }
                    PageFilterRow("Scope") {
                        PageMenuChip("All repositories", dot: .blue) { Button("sample/app") {} }
                        PageMenuChip("All owners", dot: .purple, active: true) {
                            Button("octo") {}
                        }
                        PageMenuChip("All models") { Button("Model A") {} }
                        PageMenuChip("All agents") { Button("Agent A") {} }
                    }
                }
            }
        }
    }

    static var populated: some View {
        PageScaffold(pinnedHeader: true) {
            header()
        } content: {
            PageNotice(
                "The last refresh skipped 2 repositories because the token expired.",
                title: "Some repositories were skipped", tone: .warning
            ) {
                Button("Reconnect") {}
                Button("Dismiss") {}
            }
            PageMetricGrid {
                PageMetric(
                    title: "Commits", value: "1,284", detail: "Across 12 repositories",
                    symbol: "arrow.triangle.branch", trend: "12%")
                PageMetric(
                    title: "Pull requests", value: "86", detail: "71 merged",
                    symbol: "arrow.triangle.pull", trend: "4%", trendPositive: false)
                PageMetric(title: "Reviews", value: "142", symbol: "eye")
                PageMetric(title: "Lines changed", value: "48.2K", symbol: "plusminus")
            }
            PageCard(title: "Recent activity", note: "Last 7 days") {
                ForEach(0..<4, id: \.self) { index in
                    HStack {
                        Text("sample/repository-\(index + 1)").font(.edithText(.body))
                        Spacer()
                        Text("\(120 - index * 17) commits").font(.edithText(.callout))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            PageSectionHeader("Controls", subtitle: "Every shared button role and chip state.") {
                PageChip("Filter", systemImage: "line.3.horizontal.decrease") {}
            }
            PageCard {
                WrapHStack(spacing: 8, lineSpacing: 8) {
                    Button("Primary") {}.buttonStyle(.edith(.primary))
                    Button("Secondary") {}.buttonStyle(.edith(.secondary))
                    Button("Destructive") {}.buttonStyle(.edith(.destructive))
                    Button("Disabled") {}.buttonStyle(.edith(.secondary)).disabled(true)
                    Button("Borderless") {}.buttonStyle(.edith(.borderless))
                    PageToolbarButton(
                        action: {}, systemImage: "arrow.clockwise", helperText: "Refresh")
                    PageChip("Chip") {}
                    PageChip("Active chip", active: true) {}
                    PageChip("Disabled chip") {}.disabled(true)
                    PageIconChip(systemImage: "line.3.horizontal.decrease", label: "Filter") {}
                    PageIconChip(systemImage: "star", label: "Favorite", active: true) {}
                }
            }
            PageNotice("Usage is collected every 5 minutes while Edith is open.")
            PageNotice("All repositories are up to date.", tone: .success)
            PageNotice(
                "GitHub rejected the token. Sign in again to resume collecting.",
                title: "Could not reach GitHub", tone: .error
            ) {
                Button("Sign in again") {}
            }
            PageColumns {
                PageCard(title: "Split pane", note: "Compact empty state") {
                    PageEmptyState(
                        symbolName: "tray", title: "No session selected",
                        message: "Pick a session on the left to see its details.",
                        primary: PageAction("New session") {}, style: .compact)
                }
                PageCard(title: "Skeleton rows") {
                    SkeletonGroup { PageSkeletonRows(count: 3) }
                }
            }
            HStack {
                EmptyStateText("No repositories match these filters.")
            }
            .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
        }
    }

    static var empty: some View {
        PageScaffold(pinnedHeader: true) {
            PageHeader(
                "Cleaner", subtitle: "Find caches and build output that are safe to remove.",
                divider: true,
                trailing: {
                    Button {
                    } label: {
                        Label("Choose folder", systemImage: "folder")
                    }
                }
            )
        } content: {
            PageEmptyState(
                symbolName: "externaldrive", title: "Free up space on this Mac",
                message:
                    "Cleaner scans a folder for caches, build output and other files that apps recreate on their own.",
                steps: steps,
                primary: PageAction("Scan home folder", symbolName: "magnifyingglass") {},
                footnote:
                    "Scans run on this Mac only. Nothing is deleted without your confirmation."
            )
            .pageFillViewport()
        }
    }

    static func loading(_ state: ContentLoadingState) -> some View {
        PageScaffold(pinnedHeader: true) {
            header(filters: state == .loading)
        } content: {
            PageLoading(
                state: state,
                message: "GitHub did not respond. Check your connection and try again.",
                layout: .analytics, showsSkeletonControls: false, retry: {}
            ) {
                EmptyView()
            }
        }
    }

    static var intro: some View {
        PageIntro(
            symbolName: "chart.bar.xaxis", title: "Synthetic Stats",
            tagline: "See how your code moves across every repository.",
            summary:
                "Synthetic Stats reads commit history from the folders you choose and builds a private report on this Mac.",
            steps: Array(steps.prefix(2)) + [
                PageGuideStep(
                    symbolName: "square.and.arrow.up", title: "Share a card",
                    detail: "Export a summary image when you want to show progress.")
            ],
            examples: ["ed stats refresh", "ed stats report --range week"],
            start: PageAction("Get started") {}, skip: PageAction("Not now") {},
            skipAll: PageAction("Skip all introductions") {}
        )
        .pageSurface()
    }

    static var metrics: some View {
        PageScaffold(pinnedHeader: true) {
            PageHeader("Metric tiles", divider: true)
        } content: {
            PageMetricGrid {
                PageMetric(
                    title: "Commits", value: "1,284", detail: "Across 12 repositories",
                    symbol: "arrow.triangle.branch", tint: .blue, trend: "12%")
                PageMetric(title: "Pull requests", value: "86", detail: "71 merged")
                PageMetric(
                    title: "Reviews", value: "142", symbol: "eye", trend: "4%",
                    trendPositive: false)
                PageMetric(
                    title: "Active days", value: "23",
                    detail: "A long synthetic detail that has to wrap on to a second line",
                    symbol: "calendar")
                PageMetric(title: "Lines changed", value: "48.2K", symbol: "plusminus")
            }
            PageMetricGrid {
                ForEach(0..<4, id: \.self) { _ in PageMetricSkeleton() }
            }
            PageCard(title: "Contributions", note: "Fills the card") {
                GalleryCalendar(weeks: 53)
            }
            PageCard(title: "Last 13 weeks", note: "Short ranges still fill the card") {
                GalleryCalendar(weeks: 13)
            }
        }
    }

    struct GalleryCalendar: View {
        let weeks: Int
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            ActivityCalendarGrid(
                weeks: DesignSystemGallery.calendarWeeks(weeks), dark: scheme == .dark,
                calendar: DesignSystemGallery.galleryCalendar, fillsWidth: true
            ) { _ in EmptyView() }
        }
    }

    static var galleryCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }

    static func calendarWeeks(_ count: Int) -> [ActivityCalendarWeek] {
        (0..<count).map { week in
            ActivityCalendarWeek(
                id: week, monthLabel: week % 4 == 0 ? "Sep" : "",
                cells: (0..<7).map { day in
                    ActivityCalendarDay(
                        id: "\(week)-\(day)", date: Date(timeIntervalSince1970: 0),
                        value: Double(week + day), level: (week * 3 + day * 2) % 7)
                })
        }
    }

    struct SettingsForm: View {
        @State var slider = 0.4
        @State var stepper = 2_500
        @State var checked = true
        @State var unchecked = false
        @State var empty = ""
        @State var filled = "Synthetic value"
        @State var secret = "synthetic"
        @State var tab = 0

        var body: some View {
            Form {
                SettingsIssueSectionPreview()
                Section("Rows") {
                    SettingsRow("Launch at login", subtitle: "Start this tool with your Mac.") {
                        Toggle("Launch at login", isOn: $checked).labelsHidden()
                    }
                    SettingsNoticeRow(
                        "Engine is off", message: "Turn the extension on to change this.",
                        symbol: "power.circle.fill")
                    SettingsErrorRow(
                        "Could not read the shortcut", message: "Synthetic failure.", retry: {})
                    SettingsShortcutRow(
                        keyPrefix: "gallery.shortcut", defaultLabel: "Option Space",
                        purpose: "Opens the panel from anywhere.")
                    SettingsSliderRow(
                        "Dim amount", subtitle: "How dark other windows become.", value: $slider,
                        in: 0...1, readout: "40%")
                    SettingsStepperRow(
                        "History size", subtitle: "Items kept on this Mac.", value: $stepper,
                        in: 100...5_000, step: 100, unit: "items")
                }
                Section("Fields") {
                    EdithTextField(placeholder: "Placeholder text", text: $empty)
                    EdithTextField(placeholder: "Placeholder text", text: $filled)
                    EdithSecureField(placeholder: "Access token", text: $empty, icon: "key")
                    EdithSecureField(placeholder: "Access token", text: $secret, icon: "key")
                    EdithCheckbox("Include archived repositories", isOn: $checked)
                    EdithCheckbox("Include forks", isOn: $unchecked)
                    PageTabPicker(
                        "Section", selection: $tab, options: [0, 1, 2],
                        label: { ["Overview", "History", "Settings"][$0] })
                }
            }
            .settingsForm()
        }
    }

    struct SettingsIssueSectionPreview: View {
        var body: some View {
            SettingsIssueSection()
                .environment(
                    \.settingsIssue,
                    SettingsIssue(message: "The engine did not respond.", retry: {}))
        }
    }

    static var fullList: some View {
        PageWorkspace {
            PageHeader("Packages", divider: true)
        } content: {
            PageSkeleton(layout: .fullList, showsControls: false)
                .pageGutter(false)
                .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
        }
    }

    static var formSkeleton: some View {
        PageSkeleton(layout: .form)
            .padding(PageMetrics.gutter(false))
            .pageSurface()
    }

    static var splitPane: some View {
        PageWorkspace {
            PageHeader(
                "Sessions", divider: true,
                trailing: {
                    Button {
                    } label: {
                        Label("New session", systemImage: "plus")
                    }
                    .buttonStyle(.edith(.primary))
                })
        } content: {
            HStack(spacing: 0) {
                PageEmptyState(
                    symbolName: "list.bullet.rectangle", title: "No sessions yet",
                    message: "Sessions you start appear here.",
                    primary: PageAction("New session") {}, style: .compact
                )
                .frame(width: UIScale.pt(260))
                Rectangle().fill(DashSkin.hairline).frame(width: 1)
                PageEmptyState(
                    symbolName: "rectangle.dashed", title: "Nothing selected",
                    message: "Choose a session to see its output and history.", style: .compact)
            }
        }
    }
}

@MainActor
@Suite(.serialized)
struct DesignSystemGalleryTests {
    @Test func galleryRendersEveryComponentWithoutHorizontalOverflow() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        let screens: [(String, AnyView)] = [
            ("populated", AnyView(DesignSystemGallery.populated)),
            ("gallery", AnyView(DesignSystemGallery.populated)),
            ("empty", AnyView(DesignSystemGallery.empty)),
            ("loading", AnyView(DesignSystemGallery.loading(.loading))),
            ("error", AnyView(DesignSystemGallery.loading(.error))),
            ("intro", AnyView(DesignSystemGallery.intro)),
            ("split", AnyView(DesignSystemGallery.splitPane)),
            ("metrics", AnyView(DesignSystemGallery.metrics)),
            ("settings", AnyView(DesignSystemGallery.SettingsForm())),
            ("form-skeleton", AnyView(DesignSystemGallery.formSkeleton)),
            ("full-list", AnyView(DesignSystemGallery.fullList)),
        ]
        for (name, screen) in screens {
            let variants =
                name == "gallery"
                ? [
                    RenderCapture.Variant(
                        name: "tall-light", width: 1100, height: 1900, zoom: 1, scheme: .light),
                    RenderCapture.Variant(
                        name: "tall-dark", width: 1100, height: 1900, zoom: 1, scheme: .dark),
                    RenderCapture.Variant(
                        name: "tall-compact", width: 640, height: 2300, zoom: 1, scheme: .light),
                ] : RenderCapture.variants
            for variant in variants {
                _ = try await DesignSystemGallery.render(screen, variant: variant, name: name)
            }
        }
    }

    private func fitting<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view.environment(\.automaticViewActionsEnabled, false))
        return host.fittingSize
    }

    @Test func chipsShareOneHeightAcrossButtonsMenusAndZoom() {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for zoom in [1.0, 1.6] {
            UIScale.apply(zoom)
            let expected = UIScale.pt(PageMetrics.chipHeight)
            let plain = fitting(PageChip("Today") {})
            let symbol = fitting(PageChip("Custom range", systemImage: "calendar") {})
            let dot = fitting(PageChip("All owners", dot: .purple, active: true) {})
            let menu = fitting(PageMenuChip("All models") { Button("Model A") {} })
            for size in [plain, symbol, dot, menu] {
                #expect(abs(size.height - expected) < 1, "zoom \(zoom): \(size.height)")
            }
            #expect(menu.width > fitting(PageChip("All models") {}).width)
        }
    }

    @Test func compactEmptyStateDropsStepsAndShrinks() {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        UIScale.apply(1)
        let regular = fitting(
            PageEmptyState(
                symbolName: "tray", title: "Nothing here", message: "Synthetic message.",
                steps: DesignSystemGallery.steps, footnote: "Synthetic footnote."
            ).frame(width: 640))
        let compact = fitting(
            PageEmptyState(
                symbolName: "tray", title: "Nothing here", message: "Synthetic message.",
                steps: DesignSystemGallery.steps, footnote: "Synthetic footnote.", style: .compact
            ).frame(width: 640))
        let compactWithoutSteps = fitting(
            PageEmptyState(
                symbolName: "tray", title: "Nothing here", message: "Synthetic message.",
                style: .compact
            ).frame(width: 640))
        #expect(compact.height < regular.height / 2)
        #expect(abs(compact.height - compactWithoutSteps.height) < 1)
    }

    @Test func wrapStackReportsSingleLineIdealWidthAndWrapsWhenNarrow() {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        UIScale.apply(1)
        let chips = WrapHStack(spacing: 8, lineSpacing: 8) {
            ForEach(0..<6, id: \.self) { _ in Color.red.frame(width: 50, height: 20) }
        }
        let ideal = fitting(chips.fixedSize())
        let idealWidth: CGFloat = 6 * 50 + 5 * 8
        let wrappedHeight: CGFloat = 3 * 20 + 2 * 8
        #expect(abs(ideal.width - idealWidth) < 1)
        #expect(abs(ideal.height - 20) < 1)
        let narrow = fitting(chips.frame(width: 120))
        #expect(abs(narrow.height - wrappedHeight) < 1)
    }

    @Test func headerSubtitleAndFiltersStackOnTheFourPointRhythm() {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        UIScale.apply(1)
        let bare = fitting(PageHeader("Synthetic").frame(width: 900))
        let subtitled = fitting(
            PageHeader("Synthetic", subtitle: "One synthetic line.").frame(width: 900))
        let filtered = fitting(
            PageHeader(
                "Synthetic", subtitle: "One synthetic line.",
                accessory: { PageFilterBar { PageFilterRow("Range") { PageChip("Today") {} } } }
            ).frame(width: 900))
        let divided = fitting(
            PageHeader("Synthetic", subtitle: "One synthetic line.", divider: true)
                .frame(width: 900))
        #expect(subtitled.height > bare.height + PageMetrics.subtitleSpacing)
        let filterGrowth: CGFloat = PageMetrics.headerSpacing + PageMetrics.chipHeight
        #expect(abs(filtered.height - subtitled.height - filterGrowth) < 1)
        #expect(abs(divided.height - subtitled.height - 1) < 0.5)
    }
}
