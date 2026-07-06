import Foundation
import Testing
@testable import Edith

@Suite struct LimitsChartMathTests {
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func emptyPointsProduceNoSamples() {
        #expect(LimitsChartView.samples(from: [], now: now).isEmpty)
    }

    @Test func sessionOnlyPointOlderThanNowGetsCarryForwardTail() {
        let points = [LimitPoint(date: now.addingTimeInterval(-3600), s: 42, w: nil)]
        let samples = LimitsChartView.samples(from: points, now: now)
        let session = samples.filter { $0.series == "Session" }
        let weekly = samples.filter { $0.series == "Weekly" }
        #expect(session.count == 2)
        #expect(weekly.count == 0)
        #expect(session.contains { $0.date == now && $0.value == 42 })
    }

    @Test func pointWithBothSeriesProducesFourSamples() {
        let points = [LimitPoint(date: now.addingTimeInterval(-3600), s: 42, w: 67)]
        let samples = LimitsChartView.samples(from: points, now: now)
        #expect(samples.count == 4)
        #expect(samples.filter { $0.series == "Session" }.count == 2)
        #expect(samples.filter { $0.series == "Weekly" }.count == 2)
    }

    @Test func lastPointExactlyAtNowHasNoTailDuplicate() {
        let points = [LimitPoint(date: now, s: 42, w: 67)]
        let samples = LimitsChartView.samples(from: points, now: now)
        #expect(samples.count == 2)
    }

    @Test func burstOfSessionResetsWithinMinGapCollapsesToOneMarker() {
        let pts = [
            DashLimitPoint(t: now, s: 10, w: nil, sr: now, wr: nil),
            DashLimitPoint(
                t: now.addingTimeInterval(60), s: 10, w: nil,
                sr: now.addingTimeInterval(5 * 3600), wr: nil),
            DashLimitPoint(
                t: now.addingTimeInterval(120), s: 10, w: nil,
                sr: now.addingTimeInterval(5 * 3600 + 30), wr: nil),
            DashLimitPoint(
                t: now.addingTimeInterval(3 * 3600), s: 10, w: nil,
                sr: now.addingTimeInterval(8 * 3600), wr: nil),
        ]
        let marks = DashLimits.markers(pts)
        #expect(marks.count == 2)
        #expect(marks.allSatisfy { $0.session })
    }
}
