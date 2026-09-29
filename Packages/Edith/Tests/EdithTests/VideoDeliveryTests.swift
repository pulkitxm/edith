import AVFoundation
import CoreImage
import CryptoKit
import Testing
@testable import Edith

@Suite struct VideoDeliveryTests {
    @Test(arguments: VideoDeliverySettings.Codec.allCases)
    func nativeExportsReportTheirActualFramesCodecsAndAudio(_ codec: VideoDeliverySettings.Codec)
        async throws
    {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = try await fixture(in: directory)
        var settings =
            codec.isMaster ? VideoDeliverySettings.master(codec) : VideoDeliverySettings()
        settings.codec = codec
        let url = directory.appendingPathComponent("delivery.\(codec.fileExtension)")
        let report = try await pipeline.export(to: url, settings: settings)
        #expect(report.width == 128)
        #expect(report.height == 128)
        #expect(report.frameCount == 30)
        #expect(report.frameRateNumerator == 60)
        #expect(report.frameRateDenominator == 1)
        #expect(abs(report.duration - 0.5) < 0.025)
        #expect(
            report.videoCodec
                == [
                    "h264": "avc1", "hevc": "hvc1", "hevc10": "hvc1",
                    "proRes422": "apcn", "proRes422HQ": "apch", "proRes4444": "ap4h",
                ][codec.rawValue])
        #expect(report.audioCodec == (codec.isMaster ? "lpcm" : "aac "))
        #expect(report.audioSampleRate == 48_000)
        #expect(report.audioChannels == 2)
        #expect(report.colorPrimaries == "ITU_R_709_2")
        if codec == .proRes422 || codec == .proRes422HQ || codec == .hevc10 {
            #expect(report.bitsPerComponent == 10)
        }
        let data = try Data(contentsOf: url)
        #expect(report.bytes == data.count)
        #expect(
            report.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        let frame = try generator.copyCGImage(at: CMTime(value: 1, timescale: 4), actualTime: nil)
        #expect(frame.width == 128 && frame.height == 128)
    }

    @Test(arguments: [CMTime(value: 1, timescale: 120), CMTime(value: 1001, timescale: 60_000)])
    func preservesHighAndFractionalFrameRates(_ frameDuration: CMTime) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await fixture(in: directory)
        let video = source.videoComposition.mutableCopy() as! AVMutableVideoComposition
        video.frameDuration = frameDuration
        let pipeline = VideoRenderPipeline(
            composition: source.composition, videoComposition: video, audioMix: source.audioMix,
            segments: source.segments, canvas: source.canvas)
        let report = try await pipeline.export(
            to: directory.appendingPathComponent("fractional.mp4"))
        #expect(report.frameCount == Int(ceil(0.5 / frameDuration.seconds)))
        #expect(report.frameRateNumerator == Int64(frameDuration.timescale))
        #expect(report.frameRateDenominator == frameDuration.value)
    }

    @Test func failedOrCancelledExportsPreserveExistingDestination() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = try await fixture(in: directory)
        let output = directory.appendingPathComponent("existing.mp4")
        let original = Data("existing deliverable".utf8)
        try original.write(to: output)
        await #expect(throws: VideoDeliveryError.self) { try await pipeline.export(to: output) }
        #expect(try Data(contentsOf: output) == original)
        await #expect(throws: CancellationError.self) {
            try await pipeline.export(to: output, overwrite: true) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        #expect(try Data(contentsOf: output) == original)
        _ = try await pipeline.export(to: output, overwrite: true)
        #expect(try Data(contentsOf: output) != original)
        let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!children.contains { $0.contains(".partial.") })
    }

    @Test func rejectsIncompatibleEncodingBeforeWriting() throws {
        var settings = VideoDeliverySettings()
        settings.audioCodec = .pcm
        #expect(throws: VideoDeliveryError.self) { try settings.validate() }
        settings = .master()
        settings.requireHardware = true
        #expect(throws: VideoDeliveryError.self) { try settings.validate() }
        settings = .init()
        settings.audioSampleRate = 96_000
        #expect(throws: VideoDeliveryError.self) { try settings.validate() }
        settings = .init()
        settings.bitRate = -1
        #expect(throws: VideoDeliveryError.self) { try settings.validate() }
    }

    @Test func rejectsReplacingOriginalMediaThroughAnAlias() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = try await fixture(in: directory)
        let source = directory.appendingPathComponent("source.mov")
        let original = try Data(contentsOf: source)
        let alias = directory.appendingPathComponent("alias.mov")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        await #expect(throws: VideoDeliveryError.self) {
            try await pipeline.export(to: alias, settings: .master(), overwrite: true)
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func verifiesQuantizedCompositionRatherThanUnroundedProjectSeconds() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await fixture(in: directory)
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 128, height: 128)
        project.addAsset(
            directory.appendingPathComponent("source.mov"), duration: 0.500005, width: 128,
            height: 128)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        #expect(pipeline.composition.duration == CMTime(value: 1, timescale: 2))
        let report = try await pipeline.export(
            to: directory.appendingPathComponent("quantized.mp4"))
        #expect(report.frameCount == 30)
    }

    @Test func encodesMonoAACAndRejectsUnsupportedBitrate() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = try await fixture(in: directory)
        var settings = VideoDeliverySettings()
        settings.audioChannels = 1
        #expect(throws: VideoDeliveryError.self) { try settings.validate() }
        settings.audioBitRate = 192_000
        let report = try await pipeline.export(
            to: directory.appendingPathComponent("mono.mp4"), settings: settings)
        #expect(report.audioChannels == 1)
        #expect(report.audioSampleRate == 48_000)
    }

    @Test(arguments: VideoAudioDeliverySettings.Container.allCases)
    func exportsAudioMixWithSilentTailAndVerifiedSampleCount(
        _ container: VideoAudioDeliverySettings.Container
    ) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = try await fixture(in: directory, audioFrames: 12_000)
        var settings = VideoAudioDeliverySettings()
        settings.container = container
        let output = directory.appendingPathComponent("mix.\(container.rawValue)")
        let report = try await pipeline.exportAudio(to: output, settings: settings)
        #expect(report.frames == 24_000)
        #expect(report.duration == 0.5)
        #expect(report.channels == 2)
        #expect(report.codec == (container == .m4a ? "aac " : "lpcm"))
        if container != .m4a { #expect(report.bitsPerSample == 24) }
        let file = try AVAudioFile(forReading: output)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24_000))
        try file.read(into: buffer)
        try #require(buffer.frameLength == 24_000)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect((1_000..<10_000).contains { abs(samples[$0]) > 0.03 })
        #expect((18_000..<24_000).allSatisfy { abs(samples[$0]) < 0.001 })
    }

    @Test func audioExportPreservesLeadingSilenceAndCancelledDestination() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = try await fixture(in: directory, audioFrames: 12_000, audioStartMs: 125)
        let output = directory.appendingPathComponent("offset.wav")
        _ = try await pipeline.exportAudio(to: output)
        let original = try Data(contentsOf: output)
        let file = try AVAudioFile(forReading: output)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24_000))
        try file.read(into: buffer)
        try #require(buffer.frameLength == 24_000)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect((0..<5_000).allSatisfy { abs(samples[$0]) < 0.001 })
        #expect((7_000..<16_000).contains { abs(samples[$0]) > 0.03 })
        let task = Task {
            try await pipeline.exportAudio(to: output, overwrite: true) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: output) == original)
        let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!children.contains { $0.contains(".partial.") })
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-delivery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(in directory: URL, audioFrames: Int = 24_000, audioStartMs: Double = 0)
        async throws
        -> VideoRenderPipeline
    {
        let imageURL = directory.appendingPathComponent("synthetic.png")
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        try CIContext().writePNGRepresentation(
            of: image, to: imageURL, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let source = directory.appendingPathComponent("source.mov")
        try await VideoSyntheticMovie.write(image, to: source, duration: 0.5)
        let audio = directory.appendingPathComponent("tone.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFrames)))
        buffer.frameLength = AVAudioFrameCount(audioFrames)
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<audioFrames {
            samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.1
        }
        try file.write(from: buffer)
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 128, height: 128)
        project.addAsset(source, duration: 0.5, width: 128, height: 128)
        project.addAudio(audio, duration: Double(audioFrames) / 48_000, at: audioStartMs)
        return try await VideoRenderPipeline.make(project: project)
    }
}
