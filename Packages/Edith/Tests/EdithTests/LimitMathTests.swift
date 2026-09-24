import Foundation
import Testing
@testable import EdithKit

@Suite struct LimitMathTests {
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func thresholdLevels() {
        let t = UsageThresholds.default
        #expect(UsageLevel.from(pct: 59, thresholds: t) == .green)
        #expect(UsageLevel.from(pct: 60, thresholds: t) == .orange)
        #expect(UsageLevel.from(pct: 85, thresholds: t) == .red)
    }

    @Test func highAbsoluteAlwaysFeelsRed() {
        let r = LimitMath.smartRisk(
            utilization: 98, resetsAt: nil, windowDuration: 0, pacingMargin: 10, now: now)
        #expect(r > 0.85)
        #expect(r >= 0.78)
        #expect(
            LimitMath.smartRisk(
                utilization: 100, resetsAt: nil, windowDuration: 0, pacingMargin: 10, now: now)
                == 1.0)
    }

    @Test func earlyWindowHighRateIsDampened() {
        let resets = now.addingTimeInterval(5 * 3600 - 360)
        let r = LimitMath.smartRisk(
            utilization: 30, resetsAt: resets, windowDuration: 5 * 3600, pacingMargin: 10, now: now)
        #expect(r < 0.5)
    }

    @Test func lateWindowOverpaceEscalates() {
        let resets = now.addingTimeInterval(2.5 * 3600)
        let r = LimitMath.smartRisk(
            utilization: 80, resetsAt: resets, windowDuration: 5 * 3600, pacingMargin: 10, now: now)
        #expect(r >= 0.78)
    }
}
