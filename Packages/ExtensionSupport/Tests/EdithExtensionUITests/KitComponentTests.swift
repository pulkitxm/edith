import AppKit
import EdithExtensionCore
import EdithExtensionTestSupport
import SwiftUI
import Testing
@testable import EdithExtensionUI

private final class SyntheticSettings: ControlSettingsPresenting {
    let load = ContentLoad()
    var error: String?
    var ready: Bool { load.hasContent }
    let active = false
    let running = false
    private(set) var changes = 0
    private(set) var refreshes = 0

    func changed() { changes += 1 }
    func refresh() async { refreshes += 1 }
}

private struct SchemeProbeRow: Identifiable, Equatable { let id: Int }

private struct SchemeSwitchingList: View {
    let scheme: ColorScheme

    var body: some View {
        VirtualList([SchemeProbeRow(id: 1)], rowHeight: { _ in 60 }) {
            EmptyView()
        } row: { _ in
            Text("WWWWWWWW").font(.system(size: 30, weight: .black))
        }
        .frame(width: 400, height: 200)
        .background(Color.black)
        .environment(\.colorScheme, scheme)
    }
}

@MainActor
@Suite(.serialized)
struct KitComponentTests {
    private let previousScale = UIScale.current

    private func withZoom(_ zoom: Double, _ body: () throws -> Void) rethrows {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        UIScale.apply(zoom)
        try body()
    }

    private func fitting<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: view.environment(\.automaticViewActionsEnabled, false)).fittingSize
    }

    private func render<V: View>(
        _ view: V, width: Double = 900, height: Double = 400, scheme: ColorScheme = .light
    ) async throws -> RenderCapture.Rendered {
        try await RenderCapture.render(
            "kit-component",
            variant: .init(name: "probe", width: width, height: height, zoom: 1, scheme: scheme)
        ) { view }
    }

    private func luminance(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Double {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    private func inkRows(_ bitmap: NSBitmapImageRep, columns: Range<Int>, rows: Range<Int>) -> [Int]
    {
        let scale = bitmap.pixelsWide / Int(bitmap.size.width)
        let background = luminance(
            bitmap, x: columns.lowerBound * scale, y: rows.lowerBound * scale)
        return rows.filter { row in
            columns.contains {
                abs(luminance(bitmap, x: $0 * scale, y: row * scale) - background) > 0.2
            }
        }
    }

    private func inkSpan(_ bitmap: NSBitmapImageRep, rows: Range<Int>) -> ClosedRange<Int>? {
        let scale = bitmap.pixelsWide / Int(bitmap.size.width)
        let background = luminance(bitmap, x: 2, y: rows.lowerBound * scale)
        let hits = rows.filter { row in
            stride(from: 0, to: bitmap.pixelsWide, by: 3).contains {
                abs(luminance(bitmap, x: $0, y: row * scale) - background) > 0.04
            }
        }
        guard let first = hits.first, let last = hits.last else { return nil }
        return first...last
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    @Test func metricTilesKeepEqualHeightAcrossIconsAndTrends() {
        let bare = fitting(
            PageMetric(title: "Commits", value: "12", detail: "Synthetic").frame(width: 200))
        let icon = fitting(
            PageMetric(title: "Commits", value: "12", detail: "Synthetic", icon: .heart)
                .frame(width: 200))
        let trend = fitting(
            PageMetric(title: "Commits", value: "12", detail: "Synthetic", trend: "9%")
                .frame(width: 200))
        let skeleton = fitting(PageMetricSkeleton().frame(width: 200))
        #expect(bare.height == icon.height)
        #expect(bare.height == trend.height)
        #expect(abs(bare.height - skeleton.height) <= 1)
    }

    @Test func siblingMetricValuesAlignToThePixel() async throws {
        let rendered = try await render(
            PageMetricGrid(maximumColumns: 4) {
                PageMetric(title: "Commits", value: "888", detail: "Synthetic", icon: .heart)
                PageMetric(title: "Commits", value: "888")
                PageMetric(title: "Commits", value: "888", trend: "4%")
                PageMetric(
                    title: "Commits", value: "888",
                    detail: "Wraps on to a much longer second line here")
            }
            .frame(width: 868), width: 868)
        let tile = (868 - 3 * 12) / 4
        let rows = 40..<70
        let baseline = inkRows(rendered.bitmap, columns: 16..<70, rows: rows)
        #expect(!baseline.isEmpty)
        for index in 1..<4 {
            let start = index * (tile + 12) + 16
            #expect(inkRows(rendered.bitmap, columns: start..<(start + 54), rows: rows) == baseline)
        }
    }

    @Test func metricRowsStayBalancedAndFillTheWidth() {
        let layout = PageMetricLayout(spacing: 12, minimumWidth: 148, maximumColumns: nil)
        #expect(layout.rowCounts(count: 5, width: 1052) == [5])
        #expect(layout.rowCounts(count: 5, width: 640) == [3, 2])
        #expect(layout.rowCounts(count: 4, width: 1052) == [4])
        #expect(layout.rowCounts(count: 4, width: 608) == [2, 2])
        #expect(layout.rowCounts(count: 7, width: 1052) == [4, 3])
        #expect(layout.rowCounts(count: 3, width: 100) == [1, 1, 1])
        #expect(layout.rowCounts(count: 0, width: 900).isEmpty)
        let capped = PageMetricLayout(spacing: 12, minimumWidth: 148, maximumColumns: 2)
        #expect(capped.rowCounts(count: 4, width: 1052) == [2, 2])
        #expect(layout.rowCounts(count: 5, width: .infinity) == [5])
        #expect(capped.rowCounts(count: 5, width: .infinity) == [2, 2, 1])
        #expect(layout.rowCounts(count: 3, width: .nan) == [3])
    }

    @Test func metricGridMeasuresInsideLazyStacksThatProposeAnInfiniteWidth() {
        let host = NSHostingView(
            rootView: ScrollView(.horizontal) {
                LazyHStack {
                    LazyVStack {
                        PageMetricGrid {
                            PageMetric(title: "A", value: "1")
                            PageMetric(title: "B", value: "2")
                        }
                    }
                }
            }
            .frame(width: 600, height: 300))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }

    @Test func metricGridGivesTilesTheHeightOfTheTallestInTheirRow() {
        let grid = fitting(
            PageMetricGrid {
                PageMetric(title: "A", value: "1")
                PageMetric(title: "B", value: "2", detail: "Synthetic detail")
            }
            .frame(width: 500))
        let tallest = fitting(
            PageMetric(title: "B", value: "2", detail: "Synthetic detail").frame(width: 200))
        #expect(abs(grid.height - tallest.height) <= 1)
    }

    @Test func calendarFillMatchesTheAvailableWidthExactly() throws {
        for weeks in [53, 26, 13] {
            let layout = try #require(
                ActivityCalendarLayout.filling(
                    width: 900, weekCount: weeks, minimumSide: 8, maximumSide: 28, gap: 3,
                    labelHeight: 12, pixelScale: 2))
            let last = layout.origin(week: weeks - 1, row: 0).x + layout.cellWidth
            #expect(abs(last - 900) < 0.001)
            #expect(abs(layout.contentWidth(weekCount: weeks) - 900) < 0.001)
            #expect(layout.side <= 28)
            #expect(layout.side <= layout.cellWidth)
            #expect(layout.columnGap >= 3)
        }
        #expect(
            ActivityCalendarLayout.filling(
                width: 200, weekCount: 53, minimumSide: 14, maximumSide: 28, gap: 3,
                labelHeight: 12) == nil)
    }

    @Test func calendarHitTestingFollowsStretchedCells() throws {
        let layout = try #require(
            ActivityCalendarLayout.filling(
                width: 300, weekCount: 5, minimumSide: 14, maximumSide: 28, gap: 3, labelHeight: 12)
        )
        let origin = layout.origin(week: 3, row: 2)
        let inside = layout.hit(
            CGPoint(x: origin.x + layout.cellWidth - 1, y: origin.y + 1), weekCount: 5, rowCount: 7)
        #expect(inside?.week == 3)
        #expect(inside?.row == 2)
        #expect(
            layout.hit(
                CGPoint(x: origin.x + layout.cellWidth + 1, y: origin.y + 1), weekCount: 5,
                rowCount: 7) == nil)
    }

    @Test func calendarFillDrawsToTheTrailingEdgeOfItsContainer() async throws {
        let weeks = DesignSystemGallery.calendarWeeks(13)
        let rendered = try await render(
            ActivityCalendarGrid(
                weeks: weeks.map { week in
                    ActivityCalendarWeek(
                        id: week.id, monthLabel: "",
                        cells: week.cells.map {
                            ActivityCalendarDay(id: $0.id, date: $0.date, value: 1, level: 6)
                        })
                }, dark: false, fillsWidth: true
            ) { _ in EmptyView() }
            .frame(width: 800), width: 800)
        let scale = rendered.bitmap.pixelsWide / 800
        let background = luminance(rendered.bitmap, x: 2, y: 2)
        let y = 60 * scale
        #expect(abs(luminance(rendered.bitmap, x: 796 * scale, y: y) - background) > 0.1)
    }

    @Test func singleClosureHeaderBindsToTrailingActions() {
        let plain = PageHeader("Synthetic", subtitle: "Line") { Button("Action") {} }
        #expect(type(of: plain) == PageHeader<Text, Button<Text>, EmptyView>.self)
        let custom = PageHeader(title: { EdithIconView(.heart, tone: .muted) }) {
            Button("Action") {}
        }
        #expect(type(of: custom) == PageHeader<EdithIconView, Button<Text>, EmptyView>.self)
        let accessory = PageHeader("Synthetic", accessory: { Text("Filters") })
        #expect(type(of: accessory) == PageHeader<Text, EmptyView, Text>.self)
        let both = PageHeader("Synthetic") {
            Button("Action") {}
        } accessory: {
            Text("Filters")
        }
        #expect(type(of: both) == PageHeader<Text, Button<Text>, Text>.self)
    }

    @Test func headerStaysInlineUntilTheActionsTrulyCollide() {
        let actions = { Color.red.frame(width: 300, height: 32) }
        let title = "Synthetic"
        let titleWidth = fitting(
            Text(title).font(PageMetrics.titleFont(false)).lineLimit(1).fixedSize()
        ).width
        let inline = fitting(PageHeader(title).frame(width: 900)).height
        let gutters = 2 * PageMetrics.gutter
        let tight = ceil(titleWidth) + 300 + gutters + 14
        let tightHeight = fitting(PageHeader(title, trailing: actions).frame(width: tight)).height
        #expect(tightHeight <= inline + 1)
        let narrow = ceil(titleWidth) + 300 + gutters + 8
        #expect(
            fitting(PageHeader(title, trailing: actions).frame(width: narrow)).height > inline + 20)
    }

    @Test func headerFallbackLaysActionsOutInARow() {
        let stacked = fitting(
            PageHeader(
                "A title that fills the page",
                trailing: {
                    Color.red.frame(width: 300, height: 32)
                    Color.blue.frame(width: 300, height: 32)
                }
            )
            .frame(width: 500)
        ).height
        let single = fitting(
            PageHeader(
                "A title that fills the page",
                trailing: {
                    Color.red.frame(width: 300, height: 32)
                }
            )
            .frame(width: 500)
        ).height
        #expect(abs(stacked - single) <= 1)
        let section = fitting(
            PageSectionHeader(
                "A title that fills the page",
                trailing: {
                    Color.red.frame(width: 300, height: 32)
                    Color.blue.frame(width: 300, height: 32)
                }
            )
            .frame(width: 300)
        ).height
        let sectionSingle = fitting(
            PageSectionHeader(
                "A title that fills the page",
                trailing: {
                    Color.red.frame(width: 300, height: 32)
                }
            )
            .frame(width: 300)
        ).height
        #expect(abs(section - sectionSingle) <= 1)
    }

    @Test func pageIconFramesStayOnWholePointsAtEveryZoom() {
        defer { UIScale.apply(1) }
        UIScale.apply(1)
        #expect([16, 20, 24, 32, 40, 60, 80].allSatisfy { PageIcon.side($0) == $0 })
        UIScale.apply(1.6)
        #expect(PageIcon.side(32) == 51)
        #expect(PageIcon.side(20) == 32)
        UIScale.apply(1.25)
        #expect(PageIcon.side(32) == 40)
    }

    @Test func flushIconsMeasureTheirInkAndUnknownExtensionsKeepTheirIcon() {
        let dot = PageIcon(icon: .dot, size: 60).leadingInset
        #expect(PageIcon(icon: .brand, size: 60).leadingInset == 6)
        #expect(dot != 6)
        #expect(PageIcon(extensionID: "brand", icon: .dot, size: 60).leadingInset == 6)
        #expect(PageIcon(extensionID: "future", icon: .dot, size: 60).leadingInset == dot)
        #expect(PageIcon(extensionID: nil, icon: .dot, size: 60).leadingInset == dot)
    }

    @Test func emptyStateScrollsOnlyWhenTallerThanItsContainer() async throws {
        let state = PageEmptyState(
            icon: .tray, title: "Synthetic", message: "Synthetic message.",
            steps: DesignSystemGallery.steps, footnote: "Synthetic footnote.")
        let short = try await render(state.frame(width: 600, height: 200), width: 600, height: 200)
        #expect(!scrollViews(in: short.host).isEmpty)
        let tall = try await render(state.frame(width: 900, height: 800), width: 900, height: 800)
        #expect(scrollViews(in: tall.host).isEmpty)
    }

    private func centered(_ bitmap: NSBitmapImageRep, top: Int, height: Int) throws {
        let span = try #require(inkSpan(bitmap, rows: top..<height))
        let middle = (span.lowerBound + span.upperBound) / 2
        #expect(abs(middle - (top + height) / 2) <= 24, "\(span) within \(top)..<\(height)")
    }

    @Test func emptyStateCentersInWorkspacesAndBothScaffolds() async throws {
        let state = PageEmptyState(
            icon: .tray, title: "Synthetic", message: "Synthetic message.")
        let header = { PageHeader("Header") }
        let workspace = try await render(
            PageWorkspace(header: header) { state }, height: 700)
        try centered(workspace.bitmap, top: 80, height: 700)
        let pinned = try await render(
            PageScaffold(pinnedHeader: true, header: header) { state.pageFillViewport() },
            height: 700)
        try centered(pinned.bitmap, top: 80, height: 668)
        let scrolling = try await render(
            PageScaffold(header: header) { state.pageFillViewport() }, height: 700)
        try centered(scrolling.bitmap, top: 80, height: 668)
    }

    @Test func introAlignsToTheTopAndEmbedsWithoutScrolling() async throws {
        let intro = { (embedded: Bool) in
            PageIntro(
                icon: .heart, title: "Synthetic", tagline: "Line", summary: "Summary",
                steps: Array(DesignSystemGallery.steps.prefix(1)),
                start: PageAction("Start") {}, embedded: embedded)
        }
        let page = try await render(intro(false).frame(width: 900, height: 1400), height: 1400)
        let span = try #require(inkSpan(page.bitmap, rows: 0..<1400))
        #expect(span.lowerBound <= 48)
        #expect(!scrollViews(in: page.host).isEmpty)
        let embedded = try await render(intro(true).frame(width: 900), height: 700)
        #expect(scrollViews(in: embedded.host).isEmpty)
    }

    @Test func guidanceButtonLabelsScaleUnderAnInheritedFont() {
        let label = "A long synthetic action label that sets the width"
        func emptyStateWidth(_ zoom: Double) -> CGFloat {
            var result: CGFloat = 0
            withZoom(zoom) {
                result =
                    fitting(
                        PageEmptyState(
                            icon: .tray, title: "A", message: "B",
                            primary: PageAction(label) {}, style: .compact
                        )
                        .font(.system(size: 13))
                        .fixedSize()
                    ).width
            }
            return result
        }
        func introWidth(_ zoom: Double) -> CGFloat {
            var result: CGFloat = 0
            withZoom(zoom) {
                result =
                    fitting(
                        PageIntro(
                            icon: .heart, title: "A", tagline: "B", summary: "C", steps: [],
                            start: PageAction(label) {}, embedded: true
                        )
                        .font(.system(size: 13))
                        .fixedSize()
                    ).width
            }
            return result
        }
        #expect(emptyStateWidth(1.6) / emptyStateWidth(1) > 1.4)
        #expect(introWidth(1.6) / introWidth(1) > 1.4)
    }

    @Test func skeletonBlockSetsARealWidth() {
        withZoom(1.6) {
            let size = fitting(SkeletonBlock(width: 80, height: 10))
            #expect(abs(size.width - 128) < 1)
            let squeezed = fitting(
                HStack(spacing: 0) {
                    SkeletonBlock(width: 80, height: 10)
                    SkeletonBlock(height: 10)
                }
                .frame(width: 300))
            #expect(squeezed.width == 300)
        }
    }

    @Test func errorsUseThePageLoadingTitleUnlessGivenAnErrorTitle() {
        let titled = LoadingContainer(state: .error, title: "Settings unavailable") {
            EmptyView()
        }
        #expect(titled.unavailableTitle == "Settings unavailable")
        let empty = LoadingContainer(
            state: .error, title: "No music found", errorTitle: "Couldn’t load your music"
        ) { EmptyView() }
        #expect(empty.unavailableTitle == "Couldn’t load your music")
        let plain = LoadingContainer(state: .error) { EmptyView() }
        #expect(plain.unavailableTitle == "Couldn’t load content")
        #expect(LoadingContainer(state: .empty) { EmptyView() }.unavailableTitle == "No Content")
        let offline = LoadingContainer(state: .offline, title: "Settings unavailable") {
            EmptyView()
        }
        #expect(offline.unavailableTitle == "You’re offline")
    }

    @Test func pageLoadingKeepsItsEmptyDefaultOutOfErrors() {
        #expect(PageLoading(state: .error) { EmptyView() }.errorHeading == "Couldn’t load content")
        #expect(
            PageLoading(state: .error, title: "Settings unavailable") { EmptyView() }.errorHeading
                == "Settings unavailable")
        #expect(
            PageLoading(state: .error, title: "No music", errorTitle: "Music failed") {
                EmptyView()
            }.errorHeading == "Music failed")
    }

    @Test func placeholderIsFainterThanTypedText() async throws {
        func darkest(_ text: String) async throws -> Double {
            let rendered = try await render(
                EdithTextField(placeholder: "Synthetic placeholder", text: .constant(text))
                    .frame(width: 300), width: 300, height: 60)
            let bitmap = rendered.bitmap
            var value = 1.0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh { value = min(value, luminance(bitmap, x: x, y: y)) }
            }
            return value
        }
        let placeholder = try await darkest("")
        let typed = try await darkest("Synthetic placeholder")
        #expect(placeholder > typed + 0.2, "placeholder \(placeholder) typed \(typed)")
    }

    @Test func textFieldsKeepTheirPlaceholderInsideForms() async throws {
        let rendered = try await render(
            Form {
                EdithTextField(placeholder: "WWWWWWWWWWWW", text: .constant(""))
                EdithSecureField(placeholder: "WWWWWWWWWWWW", text: .constant(""))
            }
            .settingsForm(), width: 600, height: 200)
        let bitmap = rendered.bitmap
        let scale = bitmap.pixelsWide / 600
        let ink = (0..<bitmap.pixelsWide).filter { x in
            (0..<bitmap.pixelsHigh).contains { luminance(bitmap, x: x, y: $0) < 0.72 }
        }
        let first = try #require(ink.first)
        let last = try #require(ink.last)
        #expect(last - first < 200 * scale, "fields must show one placeholder, not a label too")
        #expect(first < 80 * scale, "placeholder must start at the leading edge")
    }

    @Test func numberFieldCanDropGrouping() async throws {
        func inkWidth(_ grouped: Bool) async throws -> Int {
            let rendered = try await render(
                EdithNumberField(value: .constant(12_345_678), width: 200, grouped: grouped)
                    .frame(width: 300), width: 300, height: 60)
            let bitmap = rendered.bitmap
            return (0..<bitmap.pixelsWide).filter { x in
                (8..<bitmap.pixelsHigh - 8).contains { luminance(bitmap, x: x, y: $0) < 0.45 }
            }.count
        }
        let grouped = try await inkWidth(true)
        let plain = try await inkWidth(false)
        #expect(plain < grouped)
    }

    @Test func checkboxFillsWithTheAccentWhenOn() async throws {
        func saturation(_ on: Bool) async throws -> Double {
            let rendered = try await render(
                EdithCheckbox("Synthetic", isOn: .constant(on)).frame(width: 200), width: 200,
                height: 60)
            let bitmap = rendered.bitmap
            var strongest = 0.0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    else { continue }
                    let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                    strongest = max(strongest, channels.max()! - channels.min()!)
                }
            }
            return strongest
        }
        let off = try await saturation(false)
        let on = try await saturation(true)
        #expect(off < 0.1)
        #expect(on > 0.2)
    }

    @Test func iconChipIsSquareAtEveryZoom() {
        for zoom in [1.0, 1.6] {
            withZoom(zoom) {
                let size = fitting(PageIconChip(icon: .heart, label: "Star") {})
                let expected = UIScale.pt(PageMetrics.chipHeight)
                #expect(abs(size.width - expected) < 1)
                #expect(abs(size.height - expected) < 1)
            }
        }
    }

    @Test func compactColumnHelperStaysAdaptive() {
        let columns = PageMetrics.adaptiveColumns(minimum: 120, spacing: 12)
        #expect(columns.count == 1)
        if case .adaptive = columns[0].size {
        } else {
            Issue.record("adaptiveColumns must stay adaptive")
        }
        if case .flexible = PageMetrics.cardColumns(true, minimum: 120)[0].size {
        } else {
            Issue.record("cardColumns keeps its single compact column")
        }
    }

    @Test func tabPickerDropdownLabelScales() {
        func height(_ zoom: Double) -> CGFloat {
            var result: CGFloat = 0
            withZoom(zoom) {
                result =
                    fitting(
                        PageTabPicker(
                            "Section", selection: .constant("Overview"),
                            options: ["Overview", "History"], label: { $0 }
                        )
                        .environment(\.compactLayout, true)
                    ).width
            }
            return result
        }
        #expect(height(1.6) / height(1) > 1.4)
    }

    @Test func statusProgressPercentWidthScales() {
        func width(_ zoom: Double) -> CGFloat {
            var result: CGFloat = 0
            withZoom(zoom) {
                result = fitting(StatusProgressRow(title: "A", percent: 42).fixedSize()).width
            }
            return result
        }
        #expect(width(1.6) / width(1) > 1.4)
    }

    @Test func shelfHidesItsPagerForASingleWidget() {
        let shelf = { (count: Int, editing: Bool) in
            SurfaceShelf(
                layout: SurfaceLayout(tiles: (0..<count).map { _ in SurfaceTile(.clocks) }),
                editing: editing
            ) { _ in EmptyView() }
        }
        #expect(!shelf(1, false).showsFooter)
        #expect(shelf(1, true).showsFooter)
        #expect(shelf(2, false).showsFooter)
        #expect(shelf(0, false).showsFooter)
    }

    @Test func virtualListRowsFollowAColorSchemeChange() async throws {
        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: SchemeSwitchingList(scheme: .light))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        func brightest() async throws -> Double {
            await ScrollFrameHarness.settle(host)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var value = 0.0
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    value = max(value, luminance(bitmap, x: x, y: y))
                }
            }
            return value
        }
        let light = try await brightest()
        #expect(light < 0.5, "dark text on the black probe background")
        host.rootView = SchemeSwitchingList(scheme: .dark)
        let dark = try await brightest()
        #expect(dark > 0.8, "visible rows must pick up the new scheme")
    }

    @Test func disclosureLabelSitsOnThePageEdge() async throws {
        let rendered = try await render(
            DisclosureGroup("WWWW") { Text("Body") }
                .font(.system(size: 20, weight: .black))
                .disclosureGroupStyle(EdithDisclosureGroupStyle())
                .frame(width: 400), width: 400, height: 80)
        let bitmap = rendered.bitmap
        let scale = bitmap.pixelsWide / 400
        let first = (0..<bitmap.pixelsWide).first { x in
            (0..<bitmap.pixelsHigh).contains { luminance(bitmap, x: x, y: $0) < 0.5 }
        }
        #expect((first ?? .max) <= 3 * scale)
    }

    @Test func settingsSubtitleMatchesTheFormSubtitleSize() {
        let caption = fitting(Text("Synthetic").settingsSubtitle())
        let subtitle = fitting(Text("Synthetic").font(.edithText(.body)))
        #expect(caption == subtitle)
    }

    @Test func stepperRowClampsTypedValues() {
        var value = 5
        let row = SettingsStepperRow(
            "Synthetic", value: Binding(get: { value }, set: { value = $0 }), in: 1...10)
        row.clamped.wrappedValue = 99
        #expect(value == 10)
        row.clamped.wrappedValue = -4
        #expect(value == 1)
    }

    @Test func settingsPresentationRetryDefaultsToChangeThenRefresh() async throws {
        let settings = SyntheticSettings()
        settings.retry()
        #expect(settings.changes == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(settings.refreshes == 1)
    }

    @Test func controlSettingsHostShowsTheFormSkeletonWhileLoading() async throws {
        let settings = SyntheticSettings()
        let loading = try await render(
            ControlSettingsHost(presentation: settings) { Text("Body") }, height: 500)
        #expect(RenderCapture.distinctColors(loading.bitmap) > 1)
        settings.load.setContent()
        settings.error = "Synthetic failure"
        let ready = try await render(
            ControlSettingsHost(presentation: settings) {
                Form { SettingsIssueSection() }.settingsForm()
            }, height: 500)
        #expect(inkSpan(ready.bitmap, rows: 0..<500) != nil)
    }

    private func cardEdges(_ bitmap: NSBitmapImageRep, y: Int) throws -> ClosedRange<Int> {
        let scale = bitmap.pixelsWide / Int(bitmap.size.width)
        let background = luminance(bitmap, x: 1, y: y * scale)
        let columns = (0..<bitmap.pixelsWide).filter {
            abs(luminance(bitmap, x: $0, y: y * scale) - background) > 0.004
        }
        return try #require(columns.first) / scale...(try #require(columns.last) / scale)
    }

    @Test func controlSettingsSkeletonSharesTheFormEdges() async throws {
        let settings = SyntheticSettings()
        let loading = try await render(
            ControlSettingsHost(presentation: settings) { Text("Body") }, width: 640, height: 500)
        settings.load.setContent()
        let ready = try await render(
            ControlSettingsHost(presentation: settings) {
                Form { Section { Text("Row") } }.settingsForm()
            }, width: 640, height: 500)
        let skeleton = try cardEdges(loading.bitmap, y: 30)
        let form = try cardEdges(ready.bitmap, y: 30)
        #expect(abs(skeleton.lowerBound - form.lowerBound) <= 1)
        #expect(abs(skeleton.upperBound - form.upperBound) <= 1)
    }

    @Test func analyticsSkeletonReachesTheTrailingEdgeAndCanDropItsFilters() async throws {
        let withControls = fitting(PageSkeleton(layout: .analytics).frame(width: 900)).height
        let without = fitting(
            PageSkeleton(layout: .analytics, showsControls: false).frame(width: 900)
        ).height
        let expected = PageMetrics.chipHeight + PageMetrics.sectionSpacing
        #expect(abs(withControls - without - expected) <= 1)
        let rendered = try await render(
            PageSkeleton(layout: .analytics, showsControls: false).frame(width: 900), width: 900,
            height: 300)
        let scale = rendered.bitmap.pixelsWide / 900
        let trailingTile = luminance(rendered.bitmap, x: 890 * scale, y: 40 * scale)
        #expect(abs(trailingTile - 1) < 0.01, "tile surface must reach the trailing edge")
    }

    @Test func everySkeletonLayoutHasAShape() {
        for layout in PageSkeletonLayout.allCases {
            #expect(fitting(PageSkeleton(layout: layout).frame(width: 800)).height > 60)
        }
        #expect(!PageSkeletonLayout.list.rendersContentDirectly)
        #expect(PageSkeletonLayout.form.rendersContentDirectly)
    }

    @Test func captureRefusesBlankRenders() async {
        await #expect(throws: RenderCaptureError.self) {
            try await RenderCapture.render(
                "blank",
                variant: .init(name: "probe", width: 60, height: 60, zoom: 1, scheme: .light)
            ) { Color.white }
        }
    }

    @Test func captureRestoresTheZoomItApplied() async throws {
        let previous = UIScale.current
        try await RenderCapture.render(
            "zoom", variant: .init(name: "probe", width: 200, height: 80, zoom: 1.6, scheme: .dark)
        ) {
            Text("Synthetic \(UIScale.current)").foregroundStyle(.white)
        }
        #expect(UIScale.current == previous)
        #expect(
            RenderCapture.Variant(name: "z", width: 1100, height: 760, zoom: 1.6, scheme: .light)
                .compact)
        #expect(
            !RenderCapture.Variant(name: "r", width: 1100, height: 760, zoom: 1, scheme: .light)
                .compact)
    }
}
