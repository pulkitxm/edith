import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite @MainActor
struct SurfaceChartTests {
    @Test func chartsRoundTripWithBoundedDomainsAndLabels() throws {
        let chart = SurfaceChart(
            "daily", "Daily cost",
            series: [
                .init(
                    "cost", "Cost",
                    points: [
                        .init(
                            "first", x: 1_700_000_000, y: 3, label: "Synthetic day", value: "$3.00"),
                        .init("second", x: 1_700_086_400, y: 5, label: "Next day", value: "$5.00"),
                    ])
            ], xAxis: .date, xTitle: "Day", yTitle: "Cost")
        let snapshot = SurfaceSnapshot(providerID: "usage", charts: [chart])
        #expect(try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "usage") == snapshot)
        #expect(chart.yDomain == 0...5)
        #expect(chart.axisValues.count == 2)
        let original = SurfaceSnapshot(providerID: "usage")
        #expect(!String(decoding: try original.encoded(), as: UTF8.self).contains("charts"))
    }

    @Test(arguments: [
        "charts", "series", "points", "duplicateChart", "duplicateSeries", "duplicatePoint", "x",
        "y", "label", "field",
    ])
    func malformedChartsNeverReachTheRenderer(_ mode: String) throws {
        var point = SurfaceChartPoint("one", x: 1, y: 2)
        var charts: [SurfaceChart]
        switch mode {
        case "x": point = .init("one", x: .infinity, y: 2)
        case "y": point = .init("one", x: 1, y: .nan)
        case "label": point = .init("one", x: 1, y: 2, label: String(repeating: "x", count: 257))
        default: break
        }
        let series = SurfaceChartSeries("series", "Series", points: [point])
        let chart = SurfaceChart("chart", "Chart", series: [series])
        switch mode {
        case "charts":
            charts = (0..<9).map {
                .init(String($0), "Chart", series: [.init(String($0), "Series", points: [point])])
            }
        case "series":
            charts = [
                .init(
                    "chart", "Chart",
                    series: (0..<9).map { .init(String($0), "Series", points: [point]) })
            ]
        case "points":
            charts = [
                .init(
                    "chart", "Chart",
                    series: [
                        .init(
                            "series", "Series",
                            points: (0..<1025).map { .init(String($0), x: Double($0), y: 1) })
                    ])
            ]
        case "duplicateChart": charts = [chart, chart]
        case "duplicateSeries": charts = [.init("chart", "Chart", series: [series, series])]
        case "duplicatePoint":
            charts = [
                .init(
                    "chart", "Chart", series: [.init("series", "Series", points: [point, point])])
            ]
        case "field": charts = [.init("chart", "Chart", series: [series], field: "bad\0field")]
        default: charts = [chart]
        }
        let snapshot = SurfaceSnapshot(providerID: "usage", charts: charts)
        #expect(throws: (any Error).self) { _ = try snapshot.encoded() }
    }

    @Test func aggregateSeriesAndPointsAreLimitedAcrossEveryChart() {
        let charts = (0..<2).map { index in
            SurfaceChart(
                String(index), "Chart",
                series: [
                    .init(
                        String(index), "Series",
                        points: (0..<600).map { .init(String($0), x: Double($0), y: 1) })
                ])
        }
        #expect(throws: ExtensionPeerError.self) {
            _ = try SurfaceSnapshot(providerID: "usage", charts: charts).encoded()
        }
        let tooManySeries = (0..<3).map { index in
            SurfaceChart(
                String(index), "Chart",
                series: (0..<3).map {
                    .init("\(index):\($0)", "Series", points: [.init("point", x: 1, y: 1)])
                })
        }
        #expect(throws: ExtensionPeerError.self) {
            _ = try SurfaceSnapshot(providerID: "usage", charts: tooManySeries).encoded()
        }
    }

    @Test func extremeFiniteValuesNeverProduceInfiniteScalesOrExcessiveAxisMarks() throws {
        for style in [SurfaceChartStyle.bar, .line, .area] {
            let chart = SurfaceChart(
                "chart", "Chart",
                series: [
                    .init(
                        "series", "Series",
                        points: [
                            .init(
                                "negative", x: -Double.greatestFiniteMagnitude,
                                y: -Double.greatestFiniteMagnitude),
                            .init(
                                "positive", x: Double.greatestFiniteMagnitude,
                                y: Double.greatestFiniteMagnitude),
                        ])
                ], style: style)
            try chart.validate()
            #expect(chart.xDomain.lowerBound == -1e15 && chart.xDomain.upperBound == 1e15)
            #expect(chart.yDomain.lowerBound == -1e15 && chart.yDomain.upperBound == 1e15)
            #expect(chart.axisValues.count <= 5)
        }
        let manyDates = SurfaceChart(
            "dates", "Dates",
            series: [
                .init(
                    "series", "Series",
                    points: (0..<1024).map {
                        .init(String($0), x: Double($0) * 1e15, y: 1)
                    })
            ], xAxis: .date)
        #expect(manyDates.axisValues.count <= 5)
        #expect(
            manyDates.axisValues.allSatisfy { (-62_135_596_800...253_402_300_799).contains($0) })
        let one = SurfaceChart(
            "one", "One", series: [.init("series", "Series", points: [.init("point", x: 0, y: 0)])])
        #expect(one.xDomain.lowerBound < one.xDomain.upperBound)
        #expect(one.yDomain.lowerBound < one.yDomain.upperBound)
    }

    @Test func chartsRespectDetailsFieldsSourceSelectionAndPresenterPrivacy() async throws {
        let charts = [
            SurfaceChart(
                "daily", "Daily cost",
                series: [
                    .init(
                        "first", "First", points: [.init("point", x: 1, y: 2)], sourceID: "selected"
                    ),
                    .init(
                        "second", "Second", points: [.init("point", x: 1, y: 8)], sourceID: "hidden"
                    ),
                ])
        ]
        let snapshot = SurfaceSnapshot(providerID: "usage", charts: charts)
        var tile = SurfaceTile(.usage)
        tile.sourceIDs = ["selected"]
        #expect(
            SurfaceCommandService.project(snapshot, tile: tile).charts?.first?.series.count == 1)
        tile.hiddenFields = ["chart"]
        #expect(SurfaceCommandService.project(snapshot, tile: tile).charts == nil)
        tile.hiddenFields = []; tile.showDetails = false
        #expect(SurfaceCommandService.project(snapshot, tile: tile).charts == nil)
        tile.showDetails = true
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        var reads = 0
        let data = try await SurfaceCommandService.execute(
            providerID: "usage", command: "surface.snapshot",
            payload: request.encoded(providerID: "usage"),
            snapshot: { _ in
                reads += 1; return snapshot
            },
            perform: { _ in }, privacyValues: { ["active": "1", "blurUsage": "1"] })
        #expect(reads == 0)
        #expect(try SurfaceSnapshot.decode(data, providerID: "usage").charts == nil)
    }
}
