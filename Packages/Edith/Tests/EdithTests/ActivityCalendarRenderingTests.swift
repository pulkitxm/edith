import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct ActivityCalendarRenderingTests {
    @Test func tokenOnlyCalendarRendersColoredCellsAndTheActualTooltip() async throws {
        let suite = "test.token-calendar.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let json = """
            {"schemaVersion":7,"sources":["sample"],"daily":[
              {"period":"2026-09-29","bySource":{"sample":[
                {"modelName":"sample","inputTokens":100000,"cost":0}]}},
              {"period":"2026-10-06","bySource":{"sample":[
                {"modelName":"sample","inputTokens":25000000,"outputTokens":1700000,
                  "cacheReadTokens":5000000,"cost":0}]}}
            ]}
            """
        let model = DashboardModel(preferences: preferences)
        model.ingest(try JSONDecoder().decode(DashUsage.self, from: Data(json.utf8)))
        let detail = try #require(model.heatDetail["2026-10-06"])
        let host = try auditHost(
            HStack(alignment: .top, spacing: 20) {
                PageCard(title: "Activity", note: "daily activity") {
                    ActivityHeatmap(
                        days: model.homeUsage.calendarDays, scale: model.homeUsage.heatScale,
                        model: model, dark: true)
                }
                HeatCard(detail: detail, model: model, dark: true, blur: false, blurTokens: false)
            }
            .padding(20)
            .environment(\.colorScheme, .dark)
            .environment(\.automaticViewActionsEnabled, false)
            .background(DashSkin.paper(true)), size: CGSize(width: 860, height: 440))
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let point = try #require(model.homeUsage.calendarDays.first { $0.id == "2026-10-06" })
        #expect(model.homeUsage.heatScale.level(for: point) > 0)
        #expect(detail.cost == 0)
        #expect(detail.tokens == 31_700_000)
        if let path = ProcessInfo.processInfo.environment["EDITH_SURFACE_EVIDENCE_DIR"] {
            let root = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("token-only-calendar.png"))
        }
    }

    @Test func weekdayLabelsStayNextToCellsAtWideAndCompactWidths() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for (width, zoom) in [(1800.0, 1.0), (560.0, 1.0), (360.0, 1.6)] {
            UIScale.apply(zoom)
            for scheme in [ColorScheme.light, .dark] {
                let weeks = (0..<28).map { week in
                    ActivityCalendarWeek(
                        id: week, monthLabel: week % 4 == 0 ? "Sep" : "",
                        cells: (0..<7).map { day in
                            ActivityCalendarDay(
                                id: "\(week)-\(day)", date: Date(timeIntervalSince1970: 0),
                                value: 10, level: 4)
                        })
                }
                let host = try auditHost(
                    ActivityCalendarGrid(weeks: weeks, dark: scheme == .dark) { _ in
                        Text("Synthetic activity")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color.black : Color.white),
                    size: CGSize(width: width, height: UIScale.pt(180)))
                let window = TestWindowHost.window(contentRect: host.frame)
                window.contentView = host
                window.orderBack(nil)
                defer { window.orderOut(nil) }
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / width
                var leftmost = bitmap.pixelsWide
                var rightmost = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                            color.redComponent > color.blueComponent + 0.15,
                            color.redComponent > color.greenComponent + 0.1
                        else { continue }
                        leftmost = min(leftmost, x)
                        rightmost = max(rightmost, x)
                    }
                }
                #expect(leftmost < Int(UIScale.pt(32) * scale))
                #expect(rightmost > leftmost + Int(200 * scale))
                if width == 1800 {
                    #expect(rightmost < Int(510 * scale))
                }
                if let path = ProcessInfo.processInfo.environment["EDITH_TEST_EVIDENCE_DIR"] {
                    let root = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(
                        at: root, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(
                            to: root.appendingPathComponent("activity-\(Int(width))-\(scheme).png"))
                    let calendar = CodeStatsPageFixture.calendar
                    let start = CodeStatsPageFixture.date("2026-04-01")
                    let days = (0..<188).map { index in
                        ActivityCalendarDay(
                            id: "sample-\(index)",
                            date: calendar.date(byAdding: .day, value: index, to: start),
                            value: Double(index * 13 % 24))
                    }
                    let populated = ActivityCalendar.weeks(days: days, calendar: calendar)
                    let height = UIScale.pt(240)
                    host.rootView = AnyView(
                        PageCard(title: "Activity") {
                            ActivityCalendarGrid(
                                weeks: populated, dark: scheme == .dark, calendar: calendar
                            ) { _ in
                                Text("Synthetic activity")
                            }
                        }
                        .padding(UIScale.pt(12))
                        .frame(width: width, height: height, alignment: .top)
                        .environment(\.colorScheme, scheme)
                        .background(DashSkin.paper(scheme == .dark)))
                    host.frame.size.height = height
                    window.setContentSize(host.frame.size)
                    try await Task.sleep(for: .milliseconds(100))
                    host.layoutSubtreeIfNeeded()
                    let card = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: card)
                    try #require(card.representation(using: .png, properties: [:]))
                        .write(
                            to: root.appendingPathComponent(
                                "activity-card-\(Int(width))-\(scheme).png"))
                }
            }
        }
    }
}
