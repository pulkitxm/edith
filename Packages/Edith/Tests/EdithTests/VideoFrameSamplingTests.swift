import AVFoundation
import Testing

@testable import Edith

@Suite(.serialized) struct VideoFrameSamplingTests {
    static let cases = ["vfr", "jitter", "thirty", "thirtyLate", "thirtyPhase", "oneTwenty"]

    @Test(arguments: cases)
    func decodedFramesFollowRoundedPostSeekTimestamps(_ name: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sampling-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let times = Self.timestamps(name)
        try await Self.fixture(url, times: times)
        let seek = Self.seek(name)
        let source = CMTimeRange(
            start: CMTime(value: seek, timescale: 90000), duration: CMTime(value: 1, timescale: 1))
        let output = CMTimeRange(start: .zero, duration: source.duration)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let range = try await VideoFrameSampling.nearest.visualRange(
            track: track, source: source, output: output,
            frameDuration: CMTime(value: 1, timescale: 60))
        #expect(range.duration == source.duration)
        let retained = times.indices.filter { times[$0] >= seek }
        let initial = (times[try #require(retained.first)] - seek + 750) / 1500
        let expected = (0..<60).map { frame in
            retained.last { (times[$0] - seek + 750) / 1500 <= initial + Int64(frame) }! % 256
        }
        let nearest = try await Self.render(track: track, range: range)
        #expect(nearest == expected)
        let held = try await VideoFrameSampling.hold.visualRange(
            track: track, source: source, output: output,
            frameDuration: CMTime(value: 1, timescale: 60))
        #expect(held == source)
        if name == "vfr" || name == "thirtyLate" || name == "thirtyPhase" {
            #expect(try await Self.render(track: track, range: held) != expected)
        }
    }

    @Test func rejectsInsufficientMediaSpeedAndUnalignedOutput() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sampling-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Self.fixture(url, times: Self.timestamps("oneTwenty"))
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let source = CMTimeRange(
            start: CMTime(value: 4, timescale: 1), duration: CMTime(value: 1, timescale: 1))
        for output in [
            CMTimeRange(start: .zero, duration: source.duration),
            CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1)),
            CMTimeRange(start: CMTime(value: 1, timescale: 120), duration: source.duration),
        ] {
            await #expect(throws: VideoFrameSampling.Failure.self) {
                try await VideoFrameSampling.nearest.visualRange(
                    track: track, source: source, output: output,
                    frameDuration: CMTime(value: 1, timescale: 60))
            }
        }
    }

    static func seek(_ name: String) -> Int64 {
        switch name {
        case "thirty", "thirtyLate": 135000
        case "thirtyPhase": 162000
        case "oneTwenty": 36000
        case "vfrSix": 540000
        default: 180000
        }
    }

    static func timestamps(_ name: String, seconds: Int = 5) -> [Int64] {
        let count = seconds * (name == "oneTwenty" ? 120 : name.hasPrefix("thirty") ? 30 : 60)
        return (0..<count).map { index in
            let n = Int64(index)
            guard n > 0 else { return 0 }
            switch name {
            case "vfr", "vfrSix": return n * 1501 - 84
            case "jitter": return n * 1500 + (n % 7 == 0 ? -500 : 600)
            case "thirty": return n * 3000
            case "thirtyLate": return n * 2999 + 40
            case "thirtyPhase": return n * 3000 + 2181
            default: return n * 750
            }
        }
    }

    static func fixture(_ url: URL, times: [Int64], seconds: Int = 5) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
                AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
            ])
        input.mediaTimeScale = 90000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (index, time) in times.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            var storage: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &storage)
            let buffer = try #require(storage)
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(
                to: UInt8.self)
            for y in 0..<32 {
                for x in 0..<32 {
                    let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                    let value: UInt8 = index & (1 << (x / 4)) == 0 ? 24 : 220
                    for channel in 0..<3 { bytes[offset + channel] = value }
                    bytes[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(
                adaptor.append(buffer, withPresentationTime: CMTime(value: time, timescale: 90000)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(seconds), timescale: 1))
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    static func render(track: AVAssetTrack, range: CMTimeRange) async throws -> [Int] {
        let composition = AVMutableComposition()
        let video = try #require(
            composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        video.naturalTimeScale = range.start.timescale
        try video.insertTimeRange(range, of: track, at: .zero)
        let filter = AVMutableVideoComposition(asset: composition) { request in
            request.finish(with: request.sourceImage, context: nil)
        }
        filter.renderSize = CGSize(width: 32, height: 32)
        filter.frameDuration = CMTime(value: 1, timescale: 60)
        filter.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        return try read(composition, videoComposition: filter)
    }

    static func read(_ composition: AVAsset, videoComposition: AVVideoComposition? = nil) throws
        -> [Int]
    {
        let reader = try AVAssetReader(asset: composition)
        let settings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output: AVAssetReaderOutput
        if let videoComposition {
            let composed = AVAssetReaderVideoCompositionOutput(
                videoTracks: composition.tracks(withMediaType: .video), videoSettings: settings)
            composed.videoComposition = videoComposition
            output = composed
        } else {
            output = AVAssetReaderTrackOutput(
                track: try #require(composition.tracks(withMediaType: .video).first),
                outputSettings: settings)
        }
        reader.add(output)
        #expect(reader.startReading())
        var ids: [Int] = []
        while let sample = output.copyNextSampleBuffer() {
            let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let bytes = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(
                to: UInt8.self)
            let id = (0..<8).reduce(0) { value, bit in
                value
                    | (bytes[16 * CVPixelBufferGetBytesPerRow(buffer) + (bit * 4 + 2) * 4] > 128
                        ? 1 << bit : 0)
            }
            ids.append(id)
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        #expect(reader.status == .completed)
        return ids
    }
}
