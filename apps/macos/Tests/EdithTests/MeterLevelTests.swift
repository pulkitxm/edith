import EdithKit
import Foundation
import Testing

@Suite struct MeterLevelTests {
    @Test func silenceFallsToZero() {
        #expect(MeterLevel.level(decibels: -160, volume: 1, previous: 0) == 0)
    }

    @Test func loudPassageFillsTheBars() {
        #expect(MeterLevel.level(decibels: -6, volume: 1, previous: 0) == 1)
        #expect(MeterLevel.level(decibels: 0, volume: 1, previous: 0) == 1)
    }

    @Test func volumeScalesTheLevel() {
        let full = MeterLevel.level(decibels: -16, volume: 1, previous: 0)
        let half = MeterLevel.level(decibels: -16, volume: 0.5, previous: 0)
        #expect(half < full)
        #expect(abs(half - full / 2) < 0.0001)
    }

    @Test func decayHoldsAboveTheNewReading() {
        let decayed = MeterLevel.level(decibels: -160, volume: 1, previous: 1)
        #expect(decayed == 0.8)
        #expect(MeterLevel.level(decibels: -160, volume: 1, previous: decayed) < decayed)
    }

    @Test func aLouderReadingWinsOverTheDecay() {
        #expect(MeterLevel.level(decibels: -6, volume: 1, previous: 0.9) == 1)
    }
}
