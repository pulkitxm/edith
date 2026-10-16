@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import Testing
@testable import StudioExtension

@MainActor @Suite(.serialized) struct VideoFallbackFrameTests {
    private final class PixelLifetime: @unchecked Sendable {
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: 64 * 64 * 4, alignment: 16)
        private let lock = NSLock()
        private var released = false

        init() { bytes.initializeMemory(as: UInt8.self, repeating: 0, count: 64 * 64 * 4) }

        var isReleased: Bool { lock.withLock { released } }

        func release() {
            lock.withLock {
                bytes.deallocate()
                released = true
            }
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private func image(width: Int = 64, height: Int = 64) throws -> CGImage {
        let bytes = Data(repeating: 0, count: width * height * 4)
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        return try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func digest(_ image: CGImage) throws -> SHA256.Digest {
        let data = try #require(image.dataProvider?.data)
        return SHA256.hash(data: data as Data)
    }

    private func movie(_ url: URL, reversed: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64, AVVideoHeightKey: 64,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1],
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
            ])
        input.mediaTimeScale = 30
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        do {
            for frame in 0..<30 {
                let deadline = ContinuousClock.now + .seconds(10)
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try #require(writer.status == .writing && ContinuousClock.now < deadline)
                    try await Task.sleep(for: .milliseconds(5))
                }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(
                    nil, try #require(adaptor.pixelBufferPool), &buffer)
                let pixelBuffer = try #require(buffer)
                let fraction = Double(reversed ? 29 - frame : frame) / 29
                let source = CIImage(
                    color: CIColor(red: fraction, green: 0.2, blue: 1 - fraction)
                ).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
                context.render(
                    source, to: pixelBuffer, bounds: source.extent,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                try #require(
                    adaptor.append(
                        pixelBuffer,
                        withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
            await writer.finishWriting()
            try #require(writer.status == .completed)
        } catch {
            writer.cancelWriting()
            throw error
        }
    }

    @Test func movingFramesRetainExactTimestampPixelsAcross120RepeatedClips() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("moving.mov")
        try await movie(url)
        let asset = AVURLAsset(url: url)
        let original = AVAssetImageGenerator(asset: asset)
        let cache = VideoFallbackFrameCache()
        let scope = cache.begin()
        defer { cache.end(scope) }
        let source = VideoFallbackFrameSource(asset: asset, cache: cache)
        let references = try (0..<30).map { frame in
            try original.copyCGImage(
                at: CMTime(seconds: Double(frame) / 30, preferredTimescale: 600), actualTime: nil)
        }
        let referenceDigests = try references.map { try digest($0) }
        #expect(Set(referenceDigests.map { $0.description }).count > 1)
        let deadline = ContinuousClock.now + .seconds(30)
        for _ in 0..<120 {
            for frame in 0..<30 {
                try Task.checkCancellation()
                try #require(ContinuousClock.now < deadline)
                let seconds = Double(frame) / 30
                let expected = references[frame]
                let actual = try #require(source.frame(at: seconds))
                #expect(try digest(actual) == referenceDigests[frame])
                #expect(actual.width == expected.width && actual.height == expected.height)
                #expect(actual.colorSpace == expected.colorSpace)
            }
        }
        #expect(cache.statistics.requests == 3600 && cache.statistics.hits == 3570)
        #expect(cache.statistics.decodes == 30 && cache.statistics.entries == 30)
        #expect(cache.statistics.bytes == cache.statistics.peakBytes)
        #expect(cache.statistics.bytes <= VideoFallbackFrameCache.maximumBytes)
        cache.end(scope)
        #expect(cache.statistics.bytes == 0 && cache.statistics.entries == 0)
    }

    @Test(arguments: [false, true])
    func changedInputReopensDecoderAndNeverReusesPriorPixels(inPlace: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("moving.mov")
        try await movie(url)
        let cache = VideoFallbackFrameCache()
        let scope = cache.begin()
        defer { cache.end(scope) }
        let source = VideoFallbackFrameSource(asset: AVURLAsset(url: url), cache: cache)
        let before = try digest(#require(source.frame(at: 0)))
        let replacement = root.appendingPathComponent("replacement.mov")
        try await movie(replacement, reversed: true)
        if inPlace {
            let bytes = try Data(contentsOf: replacement)
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: bytes)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } else {
            try #require(rename(replacement.path, url.path) == 0)
        }
        let after = try #require(source.frame(at: 0))
        let fresh = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        let expected = try fresh.copyCGImage(at: .zero, actualTime: nil)
        #expect(try digest(after) == digest(expected))
        #expect(try digest(after) != before)
        #expect(cache.statistics.invalidations == 1 && cache.statistics.hits == 0)
        #expect(cache.statistics.decodes == 2 && cache.statistics.entries == 1)
    }

    @Test func entryAndByteLimitsEvictBeforeRetainingAdditionalImages() throws {
        let cache = VideoFallbackFrameCache()
        let scope = cache.begin()
        defer { cache.end(scope) }
        let source = UUID()
        let small = try image()
        for frame in 0..<65 {
            let time = CMTime(value: Int64(frame), timescale: 600)
            let (_, token) = cache.lookup(source: source, time: time)
            cache.store(small, source: source, time: time, generation: token)
        }
        #expect(cache.statistics.entries == VideoFallbackFrameCache.maximumEntries)
        #expect(cache.lookup(source: source, time: .zero).0 == nil)
        let large = try image(width: 1024, height: 1024)
        for frame in 65..<82 {
            let time = CMTime(value: Int64(frame), timescale: 600)
            let (_, token) = cache.lookup(source: source, time: time)
            cache.store(large, source: source, time: time, generation: token)
            #expect(cache.statistics.bytes <= VideoFallbackFrameCache.maximumBytes)
        }
        #expect(cache.statistics.bytes == VideoFallbackFrameCache.maximumBytes)
        #expect(cache.statistics.entries == 16)
        #expect(cache.statistics.peakBytes == VideoFallbackFrameCache.maximumBytes)
    }

    @Test func lateDecodeCannotPopulateRetiredOrSuccessorExportScope() throws {
        let cache = VideoFallbackFrameCache()
        let first = cache.begin()
        let source = UUID()
        let (_, old) = cache.lookup(source: source, time: .zero)
        cache.end(first)
        let image = try image()
        cache.store(image, source: source, time: .zero, generation: old)
        #expect(cache.statistics.bytes == 0)
        let next = cache.begin()
        defer { cache.end(next) }
        cache.store(image, source: source, time: .zero, generation: old)
        #expect(cache.statistics.bytes == 0 && cache.statistics.entries == 0)
        let (_, fresh) = cache.lookup(source: source, time: .zero)
        cache.store(image, source: source, time: .zero, generation: fresh)
        #expect(cache.statistics.entries == 1)
        cache.end(next)
        #expect(cache.statistics.bytes == 0 && cache.lookup(source: source, time: .zero).0 == nil)
    }

    @Test func invalidationRejectsInFlightSourceGenerationsAndPreservesOtherPixels() throws {
        let cache = VideoFallbackFrameCache()
        let scope = cache.begin()
        defer { cache.end(scope) }
        let first = UUID()
        let other = UUID()
        let image = try image()
        let (_, token) = cache.lookup(source: first, time: .zero)
        cache.store(image, source: first, time: .zero, generation: token)
        cache.store(image, source: other, time: .zero, generation: token)
        cache.invalidate(source: first)
        cache.store(image, source: first, time: .zero, generation: token)
        #expect(cache.statistics.entries == 1)
        #expect(cache.lookup(source: first, time: .zero).0 == nil)
        #expect(cache.lookup(source: other, time: .zero).0 === image)
    }
    @Test func oversizedFramesAndInvalidTimestampsCannotEnterCache() throws {
        let cache = VideoFallbackFrameCache()
        let scope = cache.begin()
        defer { cache.end(scope) }
        let source = UUID()
        let large = try image(width: 4096, height: 4097)
        let (_, token) = cache.lookup(source: source, time: .zero)
        cache.store(large, source: source, time: .zero, generation: token)
        #expect(cache.statistics.bytes == 0 && cache.statistics.entries == 0)
        let small = try image()
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
            #expect(cache.lookup(source: source, time: time).1 == nil)
            cache.store(small, source: source, time: time, generation: token)
        }
        #expect(cache.statistics.bytes == 0 && cache.statistics.entries == 0)
    }

    @Test func retiredEpochCannotReportHitOrDecodeInSuccessorExport() {
        let cache = VideoFallbackFrameCache()
        let first = cache.begin()
        let (_, token) = cache.lookup(source: UUID(), time: .zero)
        cache.end(first)
        let next = cache.begin()
        defer { cache.end(next) }
        #expect(!cache.recordHit(generation: token))
        cache.recordDecode(generation: token)
        #expect(cache.statistics.hits == 0 && cache.statistics.decodes == 0)
    }

    @Test func endingExportReleasesRetainedImmutablePixelStorage() throws {
        let cache = VideoFallbackFrameCache()
        let scope = cache.begin()
        defer { cache.end(scope) }
        let source = UUID()
        let lifetime = PixelLifetime()
        var provider: CGDataProvider? = CGDataProvider(
            dataInfo: Unmanaged.passRetained(lifetime).toOpaque(), data: lifetime.bytes,
            size: 64 * 64 * 4,
            releaseData: { info, _, _ in
                if let info {
                    Unmanaged<PixelLifetime>.fromOpaque(info).takeRetainedValue().release()
                }
            })
        var image: CGImage? = CGImage(
            width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: try #require(provider), decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
        let (_, token) = cache.lookup(source: source, time: .zero)
        cache.store(try #require(image), source: source, time: .zero, generation: token)
        image = nil
        provider = nil
        #expect(!lifetime.isReleased && cache.statistics.bytes == 64 * 64 * 4)
        cache.end(scope)
        #expect(lifetime.isReleased && cache.statistics.bytes == 0)
    }

}
