import AVFoundation
import Foundation
import Testing

@testable import EdithStudio

@Suite(.enabled(if: MediaFixtures.available)) struct AudioMasteringTests {
    @Test func exactTrimVerifiedLoudnessAndImmutableSource() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let source = space.url("source.wav")
        try await MediaFixtures.tone(at: source, seconds: 8)
        let original = try StudioAudioMastering.sha256(source)
        let output = space.url("master.wav")
        let report = try await StudioAudioMastering.master(
            source, to: output,
            request: .init(durationSeconds: 6))
        #expect(report.verified)
        #expect(report.recipe.sampleFrames == 288_000)
        #expect(abs(try #require(report.after.integratedLUFS) + 16) <= 0.3)
        #expect(try #require(report.after.truePeakDBTP) <= -1.4)
        #expect(try StudioAudioMastering.sha256(source) == original)
        let audio = try AVAudioFile(forReading: output)
        #expect(audio.length == 288_000)
        let tail = try #require(
            AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 480))
        audio.framePosition = audio.length - 480
        try audio.read(into: tail)
        #expect(abs(try #require(tail.floatChannelData)[0][479]) < 0.001)
        await #expect(throws: StudioAudioMastering.Failure.self) {
            try await StudioAudioMastering.master(
                source, to: output, request: .init(durationSeconds: 6))
        }
        #expect(try StudioAudioMastering.sha256(output) == report.artifactSHA256)
        let repeated = try await StudioAudioMastering.master(
            source, to: space.url("second.wav"),
            request: .init(durationSeconds: 6))
        #expect(repeated.artifactSHA256 == report.artifactSHA256)
    }

    @Test func silentAndShortSourcesDoNotPublish() async throws {
        let space = try Workspace()
        defer { withExtendedLifetime(space) {} }
        let source = space.url("silence.wav")
        let executable = try #require(StudioEnvironment.detect().ffmpeg)
        let result = try await StudioProcess.run(
            executable,
            [
                "-f", "lavfi", "-i",
                "anullsrc=r=48000:cl=stereo", "-t", "2", source.path,
            ])
        #expect(result.status == 0)
        let measurement = try await StudioAudioMastering.measure(source)
        #expect(
            measurement.silent && measurement.integratedLUFS == nil
                && measurement.truePeakDBTP == nil)
        let output = space.url("master.wav")
        await #expect(throws: StudioAudioMastering.Failure.self) {
            try await StudioAudioMastering.master(
                source, to: output, request: .init(durationSeconds: 2))
        }
        let tone = space.url("tone.wav")
        try await MediaFixtures.tone(at: tone, seconds: 2)
        await #expect(throws: StudioAudioMastering.Failure.self) {
            try await StudioAudioMastering.master(
                tone, to: output, request: .init(durationSeconds: 4))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: space.url(".").path).allSatisfy {
                !$0.hasPrefix(".")
            })
    }

    @Test func missingBackendIsExplicit() async throws {
        let health = await StudioAudioMastering.health(environment: .init())
        #expect(!health.available)
        #expect(health.reason != nil)
    }
}
