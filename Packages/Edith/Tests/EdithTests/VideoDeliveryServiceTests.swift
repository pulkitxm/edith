import AVFoundation
import Foundation
import Testing
@testable import Edith

@Suite struct VideoDeliveryServiceTests {
    static func project(in directory: URL) async throws -> URL {
        let source = try await VideoEditorServiceTests.movie(in: directory)
        let audio = directory.appendingPathComponent("tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for channel in 0..<2 {
            let samples = try #require(buffer.floatChannelData?[channel])
            for index in 0..<48000 {
                samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 48000)) * 0.1
            }
        }
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: buffer)
        }
        let url = directory.appendingPathComponent("demo.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Synthetic delivery")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .addMedia(path: source.path, name: "intro"),
                .addAudio(path: audio.path, start: 0, offset: 0),
            ]), to: url, overwrite: true)
        return url
    }

    @Test func serviceReturnsNativeReportsAndKeepsResultContract() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await Self.project(in: directory)
        let output = directory.appendingPathComponent("master.mov")
        var settings = VideoDeliverySettings.master()
        settings.colorSpace = .displayP3
        let result = try await VideoEditorService.render(project, to: output, settings: settings)
        #expect(result.written && result.path == output.path)
        let report = try #require(result.videoReport)
        #expect(report.videoCodec == "apch")
        #expect(report.bitsPerComponent == 10)
        #expect(report.colorPrimaries == AVVideoColorPrimaries_P3_D65)
        #expect(report.transferFunction == kCVImageBufferTransferFunction_sRGB as String)
        #expect(report.audioCodec == "lpcm")
        #expect(report.frameCount == 60)
        #expect(report.bytes == (try Data(contentsOf: output)).count)
        #expect(result.audioReport == nil)
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(json["written"] as? Bool == true)
        #expect(json["videoReport"] is [String: Any])
    }

    @Test func rationalFrameSelectionUsesExactCompositionClock() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await Self.project(in: directory)
        let source = try await VideoRenderPipeline.make(project: VideoProject.open(project))
        for cadence in [CMTime(value: 1001, timescale: 60000), CMTime(value: 1, timescale: 120)] {
            let video = source.videoComposition.mutableCopy() as! AVMutableVideoComposition
            video.frameDuration = cadence
            let pipeline = VideoRenderPipeline(
                composition: source.composition, videoComposition: video, audioMix: source.audioMix,
                segments: source.segments, canvas: source.canvas)
            let exact = try VideoEditorService.frameSelection(in: pipeline, frameIndex: 3)
            #expect(exact.time == CMTimeMultiply(cadence, multiplier: 3))
            #expect(exact.frame == 3)
            let fromSeconds = try VideoEditorService.frameSelection(
                in: pipeline, seconds: exact.time.seconds + cadence.seconds / 2)
            #expect(fromSeconds.frame == 3 && fromSeconds.time == exact.time)
            let count = Int64(ceil(pipeline.composition.duration.seconds / cadence.seconds))
            #expect(throws: VideoEditorService.Failure.self) {
                try VideoEditorService.frameSelection(in: pipeline, frameIndex: count)
            }
            #expect(throws: VideoEditorService.Failure.self) {
                try VideoEditorService.frameSelection(in: pipeline, frameIndex: -1)
            }
        }
    }

    @Test(arguments: VideoAudioDeliverySettings.Container.allCases)
    func audioServiceReturnsMeasuredMix(_ container: VideoAudioDeliverySettings.Container)
        async throws
    {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await Self.project(in: directory)
        var settings = VideoAudioDeliverySettings()
        settings.container = container
        let output = directory.appendingPathComponent("mix.\(container.rawValue)")
        let result = try await VideoEditorService.renderAudio(
            project, to: output, settings: settings)
        #expect(result.written && result.path == output.path)
        let report = try #require(result.audioReport)
        #expect(report.frames == 48000)
        #expect(report.sampleRate == 48000)
        #expect(report.channels == 2)
        #expect(report.codec == (container == .m4a ? "aac " : "lpcm"))
        #expect(report.sha256.count == 64)
        #expect(result.videoReport == nil)
    }

    @Test func serviceCancellationAndValidationPreserveDestinationAndSources() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await Self.project(in: directory)
        let output = directory.appendingPathComponent("delivery.mp4")
        let sentinel = Data("previous delivery".utf8)
        try sentinel.write(to: output)
        let worker = Task {
            try await VideoEditorService.render(project, to: output, overwrite: true) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(try Data(contentsOf: output) == sentinel)
        var invalid = VideoDeliverySettings()
        invalid.audioCodec = .pcm
        await #expect(throws: VideoEditorService.Failure.self) {
            try await VideoEditorService.render(
                project, to: output, overwrite: true, settings: invalid)
        }
        let audio = directory.appendingPathComponent("tone.wav")
        let original = try Data(contentsOf: audio)
        await #expect(throws: VideoEditorService.Failure.self) {
            try await VideoEditorService.renderAudio(project, to: audio, overwrite: true)
        }
        #expect(try Data(contentsOf: audio) == original)
        #expect(try Data(contentsOf: output) == sentinel)
        #expect(
            try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
                $0.hasPrefix(".edith-") || $0.contains(".partial.")
            })
    }
}
