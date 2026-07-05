import Foundation
import Testing
@testable import Edith

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
        #expect(LimitMath.level(forRisk: r) == .red)
        #expect(
            LimitMath.smartRisk(
                utilization: 100, resetsAt: nil, windowDuration: 0, pacingMargin: 10, now: now)
                == 1.0)
    }

    @Test func earlyWindowHighRateIsDampened() {
        let resets = now.addingTimeInterval(5 * 3600 - 360)
        let r = LimitMath.smartRisk(
            utilization: 30, resetsAt: resets, windowDuration: 5 * 3600, pacingMargin: 10, now: now)
        #expect(LimitMath.level(forRisk: r) == .green)
    }

    @Test func lateWindowOverpaceEscalates() {
        let resets = now.addingTimeInterval(2.5 * 3600)
        let r = LimitMath.smartRisk(
            utilization: 80, resetsAt: resets, windowDuration: 5 * 3600, pacingMargin: 10, now: now)
        #expect(LimitMath.level(forRisk: r) == .red)
    }

    @Test func hysteresisHoldsZoneNearBoundary() {
        #expect(LimitMath.zone(forRisk: 0.76, previous: nil) == .warning)
        #expect(LimitMath.zone(forRisk: 0.76, previous: .hot) == .hot)
        #expect(LimitMath.zone(forRisk: 0.72, previous: .hot) == .warning)
        #expect(LimitMath.zone(forRisk: 0.28, previous: .onTrack) == .onTrack)
    }

    @Test func pacingDeltaAndZones() {
        let resets = now.addingTimeInterval(2.5 * 3600)
        let d = LimitMath.pacingDelta(
            utilization: 75, resetsAt: resets, windowDuration: 5 * 3600, now: now)
        #expect(abs(d - 25) < 0.01)
        #expect(LimitMath.pacingZone(delta: -15, margin: 10) == .chill)
        #expect(LimitMath.pacingZone(delta: 5, margin: 10) == .onTrack)
        #expect(LimitMath.pacingZone(delta: 15, margin: 10) == .warning)
        #expect(LimitMath.pacingZone(delta: 25, margin: 10) == .hot)
    }
}
