import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import StudioExtension

@Suite struct VideoDeliveryRangeTests {
    static func fixture(
        in directory: URL, cadence: CMTime = CMTime(value: 1001, timescale: 60000),
        audioStartMs: Double = 0
    ) async throws -> VideoRenderPipeline {
        let source = try await VideoEditorServiceTests.movie(in: directory)
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(
            width: 64, height: 64, frameRateNumerator: Int(cadence.timescale),
            frameRateDenominator: Int(cadence.value))
        project.addAsset(source, duration: 1, width: 64, height: 64)
        let duplicate = project.duplicate(clipID: project.clips[0].id)
        let second = try #require(duplicate)
        project.setTransition(before: second, kind: "fade", duration: 0.6)
        project.addText("demo", startMs: 1050, endMs: 1300)
        let caption = try #require(project.annotations.first?.id)
        project.setAnnotationStyle(caption, key: "fontSize", value: 12)
        let audio = directory.appendingPathComponent("music.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        buffer.frameLength = 96000
        for channel in 0..<2 {
            let samples = try #require(buffer.floatChannelData?[channel])
            for index in 0..<96000 {
                samples[index] = Float(sin(Double(index) * 2 * .pi * 997 / 48000)) * 0.1
            }
        }
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: buffer)
        }
        project.addAudio(audio, duration: 2, at: audioStartMs)
        return try await VideoRenderPipeline.make(project: project)
    }

    @Test func middleRangeKeepsTransitionCaptionAndMusicPhaseOnOriginalTimeline() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = try await Self.fixture(in: directory)
        let cadence = pipeline.videoComposition.frameDuration
        let originalDuration = pipeline.composition.duration
        let fullURL = directory.appendingPathComponent("full.mov")
        let partURL = directory.appendingPathComponent("part.mov")
        let full = try await pipeline.export(to: fullURL, settings: .master())
        let part = try await pipeline.export(
            to: partURL, settings: .master(), range: .init(startFrame: 45, endFrame: 81))
        #expect(full.frameCount == 120 && full.range == nil)
        #expect(part.frameCount == 36)
        #expect(part.frameRateNumerator == 60000 && part.frameRateDenominator == 1001)
        #expect(abs(part.duration - 36 * cadence.seconds) < 0.0001)
        #expect(part.range?.startFrame == 45 && part.range?.endFrame == 81)
        #expect(part.range?.frameRateNumerator == 60000 && part.range?.frameRateDenominator == 1001)
        #expect(pipeline.composition.duration == originalDuration)
        let first = AVAssetImageGenerator(asset: AVURLAsset(url: fullURL))
        let second = AVAssetImageGenerator(asset: AVURLAsset(url: partURL))
        for generator in [first, second] {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        for frame in [0, 10, 20, 25, 35] {
            let expected = try await first.image(
                at: CMTimeMultiply(cadence, multiplier: Int32(frame + 45)))
            let actual = try await second.image(
                at: CMTimeMultiply(cadence, multiplier: Int32(frame)))
            let a = Self.pixels(expected.image)
            let b = Self.pixels(actual.image)
            let difference = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            #expect(Double(difference) / Double(a.count) < 2)
        }
        let timestamps = try await Self.timestamps(partURL)
        #expect(timestamps.count == 36)
        #expect(timestamps.first == .zero)
        #expect(timestamps.last == CMTimeMultiply(cadence, multiplier: 35))
        let audio = try await Self.audioSamples(partURL)
        #expect(audio.firstTime == .zero)
        try #require(audio.samples.count >= 4800)
        for index in stride(from: 0, to: 2400, by: 17) {
            let expected = Float(sin(Double(36036 + index) * 2 * .pi * 997 / 48000)) * 0.1
            #expect(abs(audio.samples[index * 2] - expected) < 0.0001)
        }
    }

    @Test(arguments: VideoAudioDeliverySettings.Container.allCases)
    func rangeAudioPreservesLeadingSilenceAndSampleClock(
        _ container: VideoAudioDeliverySettings.Container
    )
        async throws
    {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = try await Self.fixture(in: directory, audioStartMs: 1000)
        var settings = VideoAudioDeliverySettings()
        settings.container = container
        let output = directory.appendingPathComponent("range.\(container.rawValue)")
        let report = try await pipeline.exportAudio(
            to: output, settings: settings, range: .init(startFrame: 45, endFrame: 81))
        #expect(report.frames == 28829)
        #expect(report.range?.startFrame == 45 && report.range?.endFrame == 81)
        let file = try AVAudioFile(forReading: output)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 28829))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect((0..<11000).allSatisfy { abs(samples[$0]) < 0.001 })
        let tolerance: Float = container == .m4a ? 0.012 : 0.0001
        for index in stride(from: 14000, to: 28000, by: 101) {
            let expected = Float(sin(Double(index - 11964) * 2 * .pi * 997 / 48000)) * 0.1
            #expect(abs(samples[index] - expected) < tolerance)
        }
    }

    @Test(arguments: [46, 48])
    func audioRangeRoundsFractionalSampleOrigins(_ startFrame: Int) async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = try await Self.fixture(in: directory)
        let output = directory.appendingPathComponent("fractional.wav")
        let report = try await pipeline.exportAudio(
            to: output,
            range: .init(startFrame: Int64(startFrame), endFrame: Int64(startFrame + 36)))
        #expect(report.frames == 28829)
        let file = try AVAudioFile(forReading: output)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4000))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let origin = Int((Double(startFrame) * 1001 / 60000 * 48000).rounded())
        for index in stride(from: 0, to: 4000, by: 17) {
            let expected = Float(sin(Double(origin + index) * 2 * .pi * 997 / 48000)) * 0.1
            #expect(abs(samples[index] - expected) < 0.0001)
        }
    }

    @Test func rangeValidationCancellationAndFinalPartialFrame() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = try await Self.fixture(in: directory)
        let output = directory.appendingPathComponent("range.mp4")
        let original = Data("previous delivery".utf8)
        try original.write(to: output)
        for range in [
            VideoDeliveryFrameRange(startFrame: -1, endFrame: 1),
            .init(startFrame: 0, endFrame: 121), .init(startFrame: 4, endFrame: 4),
            .init(startFrame: 6, endFrame: 3), .init(startFrame: 0, endFrame: Int64.max),
        ] {
            await #expect(throws: VideoDeliveryError.self) {
                try await pipeline.export(to: output, overwrite: true, range: range)
            }
            #expect(try Data(contentsOf: output) == original)
        }
        await #expect(throws: CancellationError.self) {
            try await pipeline.export(
                to: output, overwrite: true, range: .init(startFrame: 45, endFrame: 81)
            ) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        #expect(try Data(contentsOf: output) == original)
        let last = try await pipeline.export(
            to: output, overwrite: true, range: .init(startFrame: 119, endFrame: 120))
        #expect(last.frameCount == 1)
        #expect(abs(last.duration - (2 - 119 * 1001.0 / 60000)) < 0.0001)
        #expect(try await Self.timestamps(output) == [.zero])
        #expect(
            try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
                $0.contains(".partial.")
            })
    }

    @Test func partialLastFrameKeepsTheOriginalCompositionDurationAtIntegerCadence() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.fixture(in: directory, cadence: CMTime(value: 1, timescale: 60))
        let composition = source.composition.mutableCopy() as! AVMutableComposition
        composition.removeTimeRange(
            CMTimeRange(
                start: CMTime(value: 199, timescale: 100),
                duration: CMTime(value: 1, timescale: 100)))
        let pipeline = VideoRenderPipeline(
            composition: composition, videoComposition: source.videoComposition,
            audioMix: source.audioMix, segments: source.segments, canvas: source.canvas)
        let fullURL = directory.appendingPathComponent("full.mp4")
        let full = try await pipeline.export(to: fullURL)
        let lastURL = directory.appendingPathComponent("last.mp4")
        let last = try await pipeline.export(
            to: lastURL,
            range: .init(startFrame: 119, endFrame: 120))
        #expect(full.frameCount == 120)
        #expect(abs(full.duration - 1.99) < 0.00001)
        #expect(last.frameCount == 1)
        #expect(abs(last.duration - (1.99 - 119.0 / 60)) < 0.00001)
        for url in [fullURL, lastURL] {
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let timescale = try await track.load(.naturalTimeScale)
            let end = composition.duration
            #expect(CMTimeConvertScale(end, timescale: timescale, method: .default) == end)
        }
        #expect(try await Self.timestamps(lastURL) == [.zero])
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        CIContext().render(
            CIImage(cgImage: image), toBitmap: &pixels, rowBytes: image.width * 4,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return pixels
    }

    static func timestamps(_ url: URL) async throws -> [CMTime] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try #require(reader.startReading())
        var timestamps: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 {
                timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample))
            }
        }
        #expect(reader.status == .completed)
        return timestamps.sorted { $0 < $1 }
    }

    static func audioSamples(_ url: URL) async throws -> (firstTime: CMTime?, samples: [Float]) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            ])
        reader.add(output)
        try #require(reader.startReading())
        var firstTime: CMTime?
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            if firstTime == nil { firstTime = CMSampleBufferGetPresentationTimeStamp(sample) }
            let data = try #require(CMSampleBufferGetDataBuffer(sample))
            var buffer = [Float](repeating: 0, count: CMSampleBufferGetNumSamples(sample) * 2)
            try #require(
                CMBlockBufferCopyDataBytes(
                    data, atOffset: 0, dataLength: buffer.count * 4, destination: &buffer) == noErr)
            samples += buffer
        }
        #expect(reader.status == .completed)
        return (firstTime, samples)
    }
}
