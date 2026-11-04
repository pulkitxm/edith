import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import QuartzCore
import SwiftUI
import Testing

@testable import UsageExtension

@Suite(.serialized) @MainActor struct UsageChartAppearanceTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil

    @Test(.enabled(if: enabled)) func chartCardsFirstAppearanceWithAYearOfSyntheticUsage()
        async throws
    {
        for (name, millis) in try await Self.appearances(days: 365, repeats: 3) {
            print("usage-chart \(name): first=\(Self.format(millis))")
        }
    }

    @Test func chartCardsAppearWithinBounds() async throws {
        for (name, millis) in try await Self.appearances(days: 365, repeats: 2) {
            print("usage-chart regression \(name): \(Self.format(millis))")
            #expect(millis[1] < 22, "\(name) repeat appearance")
        }
    }

    static func format(_ millis: [Double]) -> String {
        millis.map { String(format: "%.1fms", $0) }.joined(separator: " ")
    }

    static func appearances(days: Int, repeats: Int) async throws -> [(String, [Double])] {
        let suite = "usage-chart-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences)
        defer { model.shutdown() }
        model.ingest(
            try JSONDecoder().decode(
                DashUsage.self,
                from: UsageSyntheticYear.document(days: days, projects: 120, sessions: 1_000)))
        model.range = .all
        await model.awaitPendingComputation()
        let data = model.chartData
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .gray]
        let cases: [(String, () -> AnyView)] = [
            (
                "heatmap",
                {
                    AnyView(
                        ActivityHeatmap(
                            days: model.calendarDays, scale: data.heatScale, model: model,
                            dark: true))
                }
            ),
            (
                "daily",
                {
                    AnyView(
                        ComboChart(
                            points: data.daily, barColor: .blue, lineColor: .orange, dark: true,
                            scroll: true))
                }
            ),
            (
                "tokenMix",
                {
                    AnyView(
                        StackedChart(
                            bars: data.tokenMix, costLine: data.stackedCost,
                            domain: ["input", "output", "cache write", "cache read"],
                            range: Array(palette.prefix(4)), dark: true))
                }
            ),
            (
                "modelTime",
                {
                    let domain = chartSeriesDomain(data.modelTime)
                    return AnyView(
                        StackedChart(
                            bars: data.modelTime, costLine: data.stackedCost, domain: domain,
                            range: domain.indices.map { palette[$0 % palette.count] }, dark: true))
                }
            ),
            (
                "source",
                {
                    let domain = chartSeriesDomain(data.source)
                    return AnyView(
                        StackedChart(
                            bars: data.source, costLine: data.stackedCost, domain: domain,
                            range: domain.indices.map { palette[$0 % palette.count] }, dark: true))
                }
            ),
            (
                "project",
                {
                    AnyView(
                        ComboChart(
                            points: data.project, barColor: .blue, lineColor: .orange, dark: true,
                            height: 280))
                }
            ),
            (
                "hourly",
                {
                    AnyView(
                        ComboChart(
                            points: data.hourly, barColor: .blue, lineColor: .orange, dark: true))
                }
            ),
        ]
        var results: [(String, [Double])] = []
        for (name, make) in cases {
            var millis: [Double] = []
            for _ in 0..<repeats {
                millis.append(await Self.appearance(make()))
            }
            results.append((name, millis))
        }
        return results
    }

    static func appearance(_ chart: AnyView) async -> Double {
        let (window, host) = UsageScrollHarness.host(
            AnyView(Color.clear), size: CGSize(width: 1_000, height: 400))
        await UsageScrollHarness.settle(host, for: .milliseconds(100))
        let start = CACurrentMediaTime()
        host.rootView = AnyView(
            chart.frame(width: 1_000, height: 400).environment(\.colorScheme, .dark))
        host.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
        CATransaction.flush()
        let elapsed = (CACurrentMediaTime() - start) * 1000
        window.orderOut(nil)
        window.contentView = nil
        return elapsed
    }
}

@Suite struct ActivityCalendarLayoutTests {
    private let layout = ActivityCalendarLayout(side: 14, gap: 3, labelHeight: 12)

    @Test func pointerInsideACellResolvesItsWeekAndRow() {
        let corner = layout.origin(week: 4, row: 2)
        let hit = layout.hit(
            CGPoint(x: corner.x + 7, y: corner.y + 7), weekCount: 53, rowCount: 7)
        #expect(hit?.week == 4)
        #expect(hit?.row == 2)
    }

    @Test func pointerInGapsLabelsAndOutsideTheGridResolvesNothing() {
        let corner = layout.origin(week: 4, row: 2)
        #expect(
            layout.hit(CGPoint(x: corner.x + 15, y: corner.y + 5), weekCount: 53, rowCount: 7)
                == nil)
        #expect(
            layout.hit(CGPoint(x: corner.x + 5, y: corner.y + 15), weekCount: 53, rowCount: 7)
                == nil)
        #expect(layout.hit(CGPoint(x: 5, y: 6), weekCount: 53, rowCount: 7) == nil)
        #expect(layout.hit(CGPoint(x: -1, y: 40), weekCount: 53, rowCount: 7) == nil)
        let last = layout.origin(week: 52, row: 6)
        #expect(layout.hit(CGPoint(x: last.x + 20, y: last.y), weekCount: 53, rowCount: 7) == nil)
        #expect(layout.hit(CGPoint(x: last.x, y: last.y + 40), weekCount: 53, rowCount: 7) == nil)
    }
}
