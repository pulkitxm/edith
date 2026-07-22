import EdithKit
import Foundation
import Testing

@Suite struct MeterLevelTests {
    private func gain(_ app: Double, _ system: Double) -> Double {
        MeterLevel.gain(appVolume: app, systemVolume: system)
    }

    @Test func silenceFallsToZero() {
        #expect(MeterLevel.level(decibels: -160, gain: 1, previous: 0) == 0)
    }

    @Test func loudPassageFillsTheBars() {
        #expect(MeterLevel.level(decibels: -6, gain: 1, previous: 0) == 1)
        #expect(MeterLevel.level(decibels: 0, gain: 1, previous: 0) == 1)
    }

    @Test func mutingEitherVolumeEmptiesTheBars() {
        #expect(gain(0, 1) == 0)
        #expect(gain(1, 0) == 0)
        #expect(MeterLevel.level(decibels: -6, gain: gain(0.8, 0), previous: 0) == 0)
    }

    @Test func bothVolumesCountTowardsTheSameGain() {
        #expect(gain(1, 1) == 1)
        #expect(gain(0.5, 1) == gain(1, 0.5))
        #expect(gain(0.5, 0.5) < gain(0.5, 1))
    }

    @Test func normalListeningStillFillsMostOfTheBar() {
        let comfortable = MeterLevel.level(decibels: -12, gain: gain(0.7, 0.6), previous: 0)
        #expect(comfortable > 0.55)
        #expect(comfortable < 1)
    }

    @Test func decayHoldsAboveTheNewReading() {
        let decayed = MeterLevel.level(decibels: -160, gain: 1, previous: 1)
        #expect(decayed == 0.8)
        #expect(MeterLevel.level(decibels: -160, gain: 1, previous: decayed) < decayed)
    }

    @Test func aLouderReadingWinsOverTheDecay() {
        #expect(MeterLevel.level(decibels: -6, gain: 1, previous: 0.9) == 1)
    }
}
