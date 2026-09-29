import AVFoundation
import Foundation
import Testing
@testable import Edith

@Suite struct VideoBeatAnalysisTests {
    @Test func clicksRemainSampleAccurateAcrossChunkBoundaries() throws {
        let clicks = [79, 160, 4095, 8192, 11999, 15999]
        let samples = signal(count: 16000, clicks: clicks)
        var settings = VideoBeatAnalysis.Settings()
        settings.minimumSpacingSeconds = 0
        settings.refractorySeconds = 0
        var whole = try VideoBeatAnalysis.Stream(sampleRate: 8000, channels: 1, settings: settings)
        try whole.append(samples)
        var chunked = try VideoBeatAnalysis.Stream(
            sampleRate: 8000, channels: 1, settings: settings)
        for offset in stride(from: 0, to: samples.count, by: 79) {
            try chunked.append(Array(samples[offset..<min(offset + 79, samples.count)]))
        }
        #expect(chunked.finish() == whole.finish())
        #expect(chunked.finish().transients.map(\.sample) == clicks.map(Int64.init))
        #expect(chunked.finish().waveform.reduce(0) { $0 + $1.sampleCount } == 16000)
    }

    @Test func silenceHasNoTransientsOrTempo() throws {
        var stream = try VideoBeatAnalysis.Stream(sampleRate: 8000, channels: 2)
        try stream.append([Float](repeating: 0, count: 80000))
        let result = stream.finish()
        #expect(result.transients.isEmpty)
        #expect(result.tempoEstimate == nil)
        #expect(result.waveform.allSatisfy { $0.peak == 0 && $0.rms == 0 })
        #expect(result.duration == 5)
    }

    @Test func oppositePhaseStereoDoesNotCancelEnergy() throws {
        let mono = signal(count: 8000, clicks: [2000, 6000])
        let stereo = mono.flatMap { [$0, -$0] }
        var left = try VideoBeatAnalysis.Stream(sampleRate: 8000, channels: 1)
        var pair = try VideoBeatAnalysis.Stream(sampleRate: 8000, channels: 2)
        try left.append(mono)
        try pair.append(stereo)
        #expect(left.finish() == pair.finish())
        #expect(pair.finish().transients.count == 2)
    }

    @Test func waveformAndEventsStayBoundedForLongStreams() throws {
        var settings = VideoBeatAnalysis.Settings()
        settings.maximumWaveformBins = 32
        settings.maximumTransients = 5
        var stream = try VideoBeatAnalysis.Stream(sampleRate: 1000, channels: 1, settings: settings)
        let chunk = signal(count: 1000, clicks: [250, 750])
        for _ in 0..<3600 { try stream.append(chunk) }
        let result = stream.finish()
        #expect(result.duration == 3600)
        #expect(result.waveform.count <= 32)
        #expect(result.transients.count == 5)
        #expect(result.transientsTruncated)
        #expect(result.tempoEstimate == nil)
        #expect(result.waveform.reduce(0) { $0 + $1.sampleCount } == 3_600_000)
        for (left, right) in zip(result.waveform, result.waveform.dropFirst()) {
            #expect(left.startSample + left.sampleCount == right.startSample)
        }
        let energy = result.waveform.reduce(0) { $0 + $1.meanSquare * Double($1.sampleCount) }
        #expect(abs(energy - 7200 * Double(Float(0.8)) * Double(Float(0.8))) < 0.001)
    }

    @Test func sensitivityAndRefractoryAreIndependentControls() throws {
        var high = VideoBeatAnalysis.Settings()
        high.sensitivity = 1
        var low = high
        low.sensitivity = 0
        let bed = [Float](repeating: 0.1, count: 1000) + [Float](repeating: 0.16, count: 10)
        var sensitive = try VideoBeatAnalysis.Stream(sampleRate: 1000, channels: 1, settings: high)
        var conservative = try VideoBeatAnalysis.Stream(
            sampleRate: 1000, channels: 1, settings: low)
        try sensitive.append(bed)
        try conservative.append(bed)
        #expect(sensitive.finish().transients.count == 2)
        #expect(conservative.finish().transients.count == 1)
        high.refractorySeconds = 0.1
        high.minimumSpacingSeconds = 0.3
        var spaced = try VideoBeatAnalysis.Stream(sampleRate: 1000, channels: 1, settings: high)
        try spaced.append(signal(count: 1000, clicks: [100, 150, 250, 450, 750]))
        #expect(spaced.finish().transients.map(\.sample) == [100, 450, 750])
        high.refractorySeconds = 0.5
        high.minimumSpacingSeconds = 0
        var refractory = try VideoBeatAnalysis.Stream(sampleRate: 1000, channels: 1, settings: high)
        try refractory.append(signal(count: 1000, clicks: [100, 150, 250, 450, 750]))
        #expect(refractory.finish().transients.map(\.sample) == [100, 750])
    }

    @Test func tempoIsOnlyAnEstimateFromConsistentIntervals() throws {
        var regular = try VideoBeatAnalysis.Stream(sampleRate: 1000, channels: 1)
        try regular.append(signal(count: 4000, clicks: Array(stride(from: 250, to: 4000, by: 500))))
        let estimate = try #require(regular.finish().tempoEstimate)
        #expect(estimate.beatsPerMinute == 120)
        #expect(estimate.intervalAgreement == 1)
        var irregular = try VideoBeatAnalysis.Stream(sampleRate: 1000, channels: 1)
        try irregular.append(signal(count: 5000, clicks: [100, 400, 1100, 1500, 2400, 2800, 4100]))
        #expect(irregular.finish().transients.count == 7)
        #expect(irregular.finish().tempoEstimate == nil)
    }

    @Test func sourceTransientsMapToOutputFramesExplicitly() throws {
        var stream = try VideoBeatAnalysis.Stream(sampleRate: 1000, channels: 1)
        try stream.append(signal(count: 4000, clicks: [500, 1500, 2500, 3500]))
        let rate = try VideoMarkerFrameRate(numerator: 30000, denominator: 1001)
        let markers = try stream.finish().markers(
            frameRate: rate, sourceRange: 1..<3, outputStart: 10, playbackRate: 2)
        #expect(markers.map(\.frame) == [307, 322])
        #expect(markers.allSatisfy { $0.kind == .transient && $0.frameRate == rate })
        #expect(throws: VideoBeatAnalysis.AnalysisError.self) {
            try stream.finish().markers(playbackRate: 0)
        }
    }

    @Test func discontinuousTimestampsPreserveGapsAndIgnoreOverlappingFrames() throws {
        var stream = try VideoBeatAnalysis.Stream(sampleRate: 1000, channels: 1)
        try stream.append(signal(count: 100, clicks: [50]), startingAtFrame: 1000)
        try stream.append(signal(count: 100, clicks: [0]), startingAtFrame: 1050)
        try stream.append(signal(count: 100, clicks: [50]), startingAtFrame: 2000)
        let result = stream.finish()
        #expect(result.transients.map(\.sample) == [1050, 2050])
        #expect(result.sampleCount == 2100)
        #expect(result.waveform.first?.peak == 0)
    }

    @Test func malformedPCMAndSettingsAreRejected() throws {
        var stream = try VideoBeatAnalysis.Stream(sampleRate: 8000, channels: 2)
        #expect(throws: VideoBeatAnalysis.AnalysisError.self) { try stream.append([1]) }
        #expect(throws: VideoBeatAnalysis.AnalysisError.self) { try stream.append([.nan, 0]) }
        #expect(throws: VideoBeatAnalysis.AnalysisError.self) {
            try stream.append([0, 0], startingAtFrame: Int64.max)
        }
        #expect(stream.finish().sampleCount == 0)
        var settings = VideoBeatAnalysis.Settings()
        settings.sensitivity = .nan
        #expect(throws: VideoBeatAnalysis.AnalysisError.self) {
            try VideoBeatAnalysis.Stream(sampleRate: 8000, channels: 1, settings: settings)
        }
    }

    @Test(arguments: [false, true])
    func nativeDecoderFindsSyntheticClicksInStereoAudio(compressed: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "transient-fixture-\(UUID().uuidString).\(compressed ? "m4a" : "caf")")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(url, compressed: compressed)
        let result = try await VideoBeatAnalysis.analyze(url)
        #expect(abs(result.duration - 4) < 0.1)
        #expect(result.transients.count == 7)
        for (transient, expected) in zip(result.transients, stride(from: 0.25, to: 3.75, by: 0.5)) {
            #expect(abs(Double(transient.sample) / result.sampleRate - expected) < 0.025)
        }
        #expect(result.waveform.contains { $0.peak > 0.3 })
        #expect(result.waveform.contains { $0.peak < 0.001 })
        let estimate = try #require(result.tempoEstimate)
        #expect(abs(estimate.beatsPerMinute - 120) < 2)
    }

    @Test func nativeAnalysisHonorsCancellation() async throws {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await VideoBeatAnalysis.analyze(
                URL(fileURLWithPath: "/synthetic/missing.caf"))
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        }
    }

    @Test func nativeDecodedSilenceHasNoMarkers() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "silence-fixture-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(url, compressed: false, silent: true)
        let result = try await VideoBeatAnalysis.analyze(url)
        #expect(result.duration == 4)
        #expect(result.transients.isEmpty)
        #expect(result.tempoEstimate == nil)
        #expect(try result.markers().isEmpty)
        #expect(result.waveform.allSatisfy { $0.peak == 0 && $0.rms == 0 })
    }

    private func signal(count: Int, clicks: [Int]) -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        for click in clicks { samples[click] = 0.8 }
        return samples
    }

    private func writeFixture(_ url: URL, compressed: Bool, silent: Bool = false) throws {
        let rate = 48000.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let settings: [String: Any] =
            compressed
            ? [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000,
            ]
            : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000))
        buffer.frameLength = 192000
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<192000 {
            let inClick = frame >= 12000 && frame < 168000 && (frame - 12000) % 24000 < 240
            let value: Float = inClick && !silent ? Float(sin(Double(frame) * 0.35)) * 0.8 : 0
            channels[0][frame] = value
            channels[1][frame] = -value
        }
        try file.write(from: buffer)
    }
}
