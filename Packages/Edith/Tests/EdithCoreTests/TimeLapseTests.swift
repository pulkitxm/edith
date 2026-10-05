import Foundation
import Testing

@testable import EdithCore

@Suite struct TimeLapseTests {
    @Test func fiveHoursIsTwoMinutesOfPlayback() {
        let settings = TimeLapseSettings()
        #expect(settings.speed == 150)
        #expect(settings.estimatedBytes(hours: 5) == 180_000_000)
    }

    @Test func audioCostUsesWallTime() {
        var settings = TimeLapseSettings()
        settings.systemAudio = true
        settings.microphoneID = "synthetic-microphone"
        #expect(settings.estimatedBytes(hours: 5) == 756_000_000)
        settings.interval = 60
        #expect(settings.audioBitRate == 256_000)
    }

    @Test func invalidAndNonFiniteIntervalsAreRejected() {
        for interval in [0.0, -1, .nan, .infinity, 3] {
            var settings = TimeLapseSettings()
            settings.interval = interval
            #expect(throws: TimeLapseError.self) { try settings.validate() }
        }
    }

    @Test func dimensionsPreserveAspectWithoutUpscaling() {
        let settings = TimeLapseSettings()
        #expect(settings.dimensions(width: 7680, height: 4320).width == 3840)
        #expect(settings.dimensions(width: 7680, height: 4320).height == 2160)
        #expect(settings.dimensions(width: 101, height: 51).width == 100)
        #expect(settings.dimensions(width: .infinity, height: 0).width == 2)
    }

    @Test func clockSkipsMissedIntervalsAfterSleepAndBackpressure() {
        var clock = TimeLapseClock(interval: 5)
        #expect(clock.isDue(at: 10))
        clock.accepted(at: 10)
        #expect(!clock.isDue(at: 14))
        #expect(clock.isDue(at: 15))
        #expect(clock.frames == 1)
        clock.accepted(at: 3600)
        #expect(clock.frames == 2)
        #expect(!clock.isDue(at: 3601))
        #expect(!clock.isDue(at: .nan))
        #expect(clock.playbackSeconds == 2.0 / 30)
    }

    @Test func sessionRoundTripsAndRejectsUnsafePaths() throws {
        var session = TimeLapseSession(settings: TimeLapseSettings(), width: 1920, height: 1080)
        session.segments = [
            .init(
                file: "video-0000.mov", kind: "video", frames: 300,
                startedAt: Date(), duration: 10)
        ]
        try session.validate()
        #expect(session.playbackSeconds == 10)
        let decoded = try JSONDecoder().decode(
            TimeLapseSession.self,
            from: JSONEncoder().encode(session))
        #expect(decoded.id == session.id)
        for file in ["../private.mov", "/private.mov", "x/y.mov", ".hidden", "x\\y.mov", ""] {
            session.segments = [
                .init(
                    file: file, kind: "video", frames: 1,
                    startedAt: Date(), duration: 1.0 / 30)
            ]
            #expect(throws: TimeLapseError.self) { try session.validate() }
        }
    }

    @Test func duplicateSegmentsAndInvalidDurationsAreRejected() {
        var session = TimeLapseSession(settings: TimeLapseSettings(), width: 1920, height: 1080)
        let segment = TimeLapseSession.Segment(
            file: "video.mov", kind: "video", frames: 300,
            startedAt: Date(), duration: 10)
        session.segments = [segment, segment]
        #expect(throws: TimeLapseError.self) { try session.validate() }
        session.segments = [
            .init(
                file: "video.mov", kind: "video", frames: 0,
                startedAt: Date(), duration: .nan)
        ]
        #expect(throws: TimeLapseError.self) { try session.validate() }
    }
}
