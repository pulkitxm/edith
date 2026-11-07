import AppKit
import EdithExtensionCore
import EdithExtensionTestSupport
import SwiftUI
import Testing
@testable import EdithExtensionUI

@MainActor @Suite(.serialized, .exclusiveScale) struct PageDateFilterRenderingTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }()

    private static let now =
        calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 5, hour: 12)) ?? Date()

    private static func day(_ string: String) -> DateFilterDay {
        DateFilterDay(string) ?? DateFilterDay(date: now, calendar: calendar)
    }

    private static func range(_ first: String, _ last: String) -> DateFilterRange {
        DateFilterRange(day(first), day(last))
    }

    private static var months: [DateFilterMonth] {
        ["2026-10", "2026-09", "2026-08", "2026-07"].compactMap(DateFilterMonth.init)
    }

    private static var states: [(String, DateFilterSelection)] {
        [
            ("Today", .preset(.today)),
            ("Quick", .preset(.last30)),
            ("Named", .preset(.lastMonth)),
            ("Month", .month(months[2])),
            ("Custom", .custom(range("2026-10-03", "2026-10-12"))),
            ("Years", .custom(range("2025-12-28", "2026-01-03"))),
            ("This year", .preset(.thisYear)),
            ("All", .preset(.allTime)),
        ]
    }

    private struct Scene: View {
        var body: some View {
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                PageFilterBar {
                    ForEach(states, id: \.0) { state in
                        PageFilterRow(state.0) {
                            PageDateFilter(
                                selection: .constant(state.1), months: months,
                                earliest: day("2024-01-01"), now: now, calendar: calendar)
                        }
                    }
                    PageFilterRow("Plain") {
                        PageDateFilter(
                            selection: .constant(.preset(.last7)), showsStepper: false, now: now,
                            calendar: calendar)
                    }
                }
            }
            .padding(UIScale.pt(PageMetrics.gutter))
        }
    }

    private func menuTitles(in host: NSView) -> [String] {
        let selector = NSSelectorFromString("accessibilityTitle")
        return (host.accessibilityChildren() as? [NSObject] ?? []).compactMap { node in
            guard node.responds(to: selector),
                let title = node.perform(selector)?.takeUnretainedValue()
            else { return nil }
            return (title as? NSAttributedString)?.string ?? title as? String
        }
    }

    private func withTheme<T>(_ theme: AppTheme, _ body: () async throws -> T) async rethrows -> T {
        let defaults = ExtensionScope.process.defaults()
        let prior = defaults.string(forKey: AppStorageKeys.General.theme)
        defaults.set(theme.rawValue, forKey: AppStorageKeys.General.theme)
        ThemeStore.shared.reload()
        defer {
            defaults.set(prior, forKey: AppStorageKeys.General.theme)
            ThemeStore.shared.reload()
        }
        return try await body()
    }

    private static let filterVariants =
        RenderCapture.variants + [
            RenderCapture.Variant(
                name: "zoom-dark", width: 1100, height: 760, zoom: 1.6, scheme: .dark),
            RenderCapture.Variant(
                name: "compact-zoom-light", width: 640, height: 900, zoom: 1.6, scheme: .light),
        ]

    private static func pickerVariants(height: Double) -> [RenderCapture.Variant] {
        [
            .init(name: "light", width: 320, height: height, zoom: 1, scheme: .light),
            .init(name: "dark", width: 320, height: height, zoom: 1, scheme: .dark),
            .init(
                name: "zoom-dark", width: 512, height: (height * 1.6).rounded(), zoom: 1.6,
                scheme: .dark),
        ]
    }

    private static var pickerDrafts: [(String, DateFilterDraft)] {
        var starting = DateFilterDraft(range: nil, earliest: nil, latest: day("2026-11-05"))
        starting.select(day("2026-11-03"))
        var spanning = DateFilterDraft(
            range: range("2026-09-21", "2026-10-12"), earliest: nil, latest: day("2026-11-05"))
        spanning.showMonth(offset: -1)
        return [
            ("empty", DateFilterDraft(range: nil, earliest: nil, latest: day("2026-11-05"))),
            ("start-only", starting),
            (
                "range",
                DateFilterDraft(
                    range: range("2026-10-03", "2026-10-12"), earliest: nil,
                    latest: day("2026-11-05"))
            ),
            ("spanning", spanning),
            (
                "bounded",
                DateFilterDraft(
                    range: range("2026-11-02", "2026-11-05"), earliest: day("2026-10-28"),
                    latest: day("2026-11-05"))
            ),
        ]
    }

    @Test func filterRendersAtEveryWidthZoomSchemeAndTheme() async throws {
        for theme in [AppTheme.accent, .teal] {
            try await withTheme(theme) {
                for variant in Self.filterVariants {
                    let rendered = try await RenderCapture.render(
                        "date-filter-\(theme.rawValue)", variant: variant
                    ) {
                        Scene()
                    }
                    #expect(rendered.host.fittingSize.width <= variant.width + 1)
                }
            }
        }
    }

    @Test func filterStaysInsideANarrowZoomedColumn() async throws {
        let variant = RenderCapture.Variant(
            name: "narrow-zoom", width: 540, height: 1400, zoom: 1.6, scheme: .dark)
        let rendered = try await RenderCapture.render("date-filter", variant: variant) {
            Scene()
        }
        #expect(DesignSystemGallery.edgeColors(rendered.bitmap) <= 3)
    }

    @Test func pickerRendersEveryState() async throws {
        for theme in [AppTheme.accent, .teal] {
            try await withTheme(theme) {
                for (name, draft) in Self.pickerDrafts {
                    for variant in Self.pickerVariants(height: 380) {
                        try await RenderCapture.render(
                            "date-picker-\(theme.rawValue)-\(name)", variant: variant
                        ) {
                            PageDateRangePicker(
                                draft: draft, today: Self.day("2026-11-05"),
                                calendar: Self.calendar, onApply: { _ in }, onCancel: {})
                        }
                    }
                }
            }
        }
    }

    private func picker(_ draft: DateFilterDraft) -> PageDateRangePicker {
        PageDateRangePicker(
            draft: draft, today: Self.day("2026-11-05"), calendar: Self.calendar,
            onApply: { _ in }, onCancel: {})
    }

    @Test func pickerNeverClipsAtAnySupportedZoomOrInASqueezedHost() async throws {
        let draft = DateFilterDraft(
            range: Self.range("2026-10-03", "2026-10-12"), earliest: nil,
            latest: Self.day("2026-11-05"))
        for zoom in stride(
            from: WindowZoom.range.lowerBound, through: WindowZoom.range.upperBound,
            by: WindowZoom.step)
        {
            let fitted = RenderCapture.Variant(
                name: "fit-\(Int((zoom * 100).rounded()))", width: (320 * zoom).rounded(),
                height: (400 * zoom).rounded(), zoom: (zoom * 100).rounded() / 100, scheme: .dark)
            let squeezed = RenderCapture.Variant(
                name: "squeezed-\(Int((zoom * 100).rounded()))", width: 300,
                height: (400 * zoom).rounded(), zoom: (zoom * 100).rounded() / 100, scheme: .dark)
            for variant in [fitted, squeezed] {
                let rendered = try await RenderCapture.render("date-picker", variant: variant) {
                    picker(draft)
                }
                #expect(
                    DesignSystemGallery.edgeColors(rendered.bitmap) <= 2,
                    "\(variant.name) draws into the trailing gutter")
            }
        }
    }

    @Test func pickerAsksForItsFullWidthSoAPopoverDoesNotShrinkIt() {
        let prior = UIScale.current
        defer { UIScale.apply(prior) }
        for zoom in [0.8, 1, 1.6] {
            UIScale.apply(zoom)
            let draft = DateFilterDraft(
                range: nil, earliest: nil, latest: Self.day("2026-11-05"))
            let host = NSHostingView(rootView: picker(draft))
            #expect(abs(host.fittingSize.width - 320 * zoom) < 1)
        }
    }

    @Test func filterExposesLabelsAndSelectedTraits() async throws {
        try await RenderCapture.withAccessibility {
            let variant = RenderCapture.variants[0]
            let rendered = try await RenderCapture.render("date-filter-a11y", variant: variant) {
                HStack {
                    PageDateFilter(
                        selection: .constant(.preset(.last7)), now: Self.now,
                        calendar: Self.calendar)
                }
            }
            let chip = try #require(RenderCapture.find(rendered.host, label: "Last 7 days"))
            #expect(chip.value(forKey: "isAccessibilitySelected") as? Bool == true)
            let other = try #require(RenderCapture.find(rendered.host, label: "Last 30 days"))
            #expect(other.value(forKey: "isAccessibilitySelected") as? Bool == false)
            #expect(RenderCapture.find(rendered.host, label: "7 days") == nil)
            #expect(menuTitles(in: rendered.host).contains("More date ranges"))
            #expect(RenderCapture.find(rendered.host, label: "Previous period") != nil)
            #expect(RenderCapture.find(rendered.host, label: "Next period") != nil)
            #expect(
                RenderCapture.find(rendered.host, label: "Period, 30 Oct to 5 Nov 2026") != nil)
        }
    }

    @Test func moreChipNamesTheActiveChoiceForVoiceOver() async throws {
        try await RenderCapture.withAccessibility {
            let rendered = try await RenderCapture.render(
                "date-filter-a11y-more", variant: RenderCapture.variants[0]
            ) {
                HStack {
                    PageDateFilter(
                        selection: .constant(.preset(.lastMonth)), now: Self.now,
                        calendar: Self.calendar)
                }
            }
            #expect(menuTitles(in: rendered.host).contains("Date range, Last month"))
        }
    }

    @Test func pickerDaysDescribeThemselves() async throws {
        try await RenderCapture.withAccessibility {
            let draft = DateFilterDraft(
                range: Self.range("2026-10-03", "2026-10-12"), earliest: nil,
                latest: Self.day("2026-11-05"))
            let rendered = try await RenderCapture.render(
                "date-picker-a11y", variant: Self.pickerVariants(height: 380)[0]
            ) {
                PageDateRangePicker(
                    draft: draft, today: Self.day("2026-11-05"), calendar: Self.calendar,
                    onApply: { _ in }, onCancel: {})
            }
            let first = try #require(
                RenderCapture.find(rendered.host, label: "Saturday, 3 October 2026"))
            #expect(first.value(forKey: "isAccessibilitySelected") as? Bool == true)
            #expect(RenderCapture.find(rendered.host, label: "Start date, 3 Oct 2026") != nil)
            #expect(RenderCapture.find(rendered.host, label: "End date, 12 Oct 2026") != nil)
            #expect(RenderCapture.find(rendered.host, label: "Previous month") != nil)
        }
    }

    private func key(_ code: UInt16, _ characters: String, in window: NSWindow) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    private func hostedPicker(
        range: DateFilterRange?, onApply: @escaping (DateFilterRange) -> Void,
        onCancel: @escaping () -> Void
    ) async throws -> OffscreenTestWindow {
        let view = PageDateRangePicker(
            range: range, now: Self.now, calendar: Self.calendar, onApply: onApply,
            onCancel: onCancel
        )
        .environment(\.automaticViewActionsEnabled, false)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 380)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKey()
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(300))
        return window
    }

    @Test func keyboardBuildsARangeAndReturnApplies() async throws {
        var applied: DateFilterRange?
        let window = try await hostedPicker(
            range: nil, onApply: { applied = $0 }, onCancel: {})
        defer {
            window.orderOut(nil)
            window.close()
        }
        try key(36, "\r", in: window)
        try await Task.sleep(for: .milliseconds(80))
        #expect(applied == nil)
        try key(49, " ", in: window)
        try await Task.sleep(for: .milliseconds(80))
        try key(123, String(UnicodeScalar(NSLeftArrowFunctionKey)!), in: window)
        try await Task.sleep(for: .milliseconds(80))
        try key(123, String(UnicodeScalar(NSLeftArrowFunctionKey)!), in: window)
        try await Task.sleep(for: .milliseconds(80))
        try key(49, " ", in: window)
        try await Task.sleep(for: .milliseconds(80))
        try key(36, "\r", in: window)
        try await Task.sleep(for: .milliseconds(80))
        #expect(applied == Self.range("2026-11-03", "2026-11-05"))
    }

    @Test func escapeCancels() async throws {
        var cancelled = false
        let window = try await hostedPicker(
            range: Self.range("2026-10-03", "2026-10-12"), onApply: { _ in },
            onCancel: { cancelled = true })
        defer {
            window.orderOut(nil)
            window.close()
        }
        try key(53, "\u{1b}", in: window)
        try await Task.sleep(for: .milliseconds(80))
        #expect(cancelled)
    }
}
