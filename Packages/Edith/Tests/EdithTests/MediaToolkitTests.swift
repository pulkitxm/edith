import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithKit

@Suite struct MediaToolkitTests {
    @Test func imageOptionsClampUnsafeValues() {
        let options = MediaImageOptions(format: .jpeg, quality: 4, maxDimension: -20)

        #expect(options.quality == 1)
        #expect(options.maxDimension == 1)
    }

    @Test func videoPlanFitsDimensionsAndReservesAudio() throws {
        let plan = try #require(
            MediaToolkit.videoPlan(
                targetBytes: 20_000_000, duration: 60,
                sourceSize: CGSize(width: 3840, height: 2160), frameRate: 30,
                hasAudio: true))

        #expect(plan.width <= 1920)
        #expect(plan.height <= 1920)
        #expect(plan.width.isMultiple(of: 2))
        #expect(plan.height.isMultiple(of: 2))
        #expect(plan.audioBitRate == 96_000)
        #expect(plan.videoBitRate > 240_000)
        #expect(abs(Double(plan.width) / Double(plan.height) - 16.0 / 9.0) < 0.01)
    }

    @Test func portraitVideoPlanPreservesOrientationAndAspectRatio() throws {
        let plan = try #require(
            MediaToolkit.videoPlan(
                targetBytes: 12_000_000, duration: 30,
                sourceSize: CGSize(width: 1080, height: 1920), frameRate: 30,
                hasAudio: false))

        #expect(plan.width < plan.height)
        #expect(plan.height <= 1920)
        #expect(abs(Double(plan.width) / Double(plan.height) - 9.0 / 16.0) < 0.01)
    }

    @Test func impossibleVideoTargetHasNoPlan() {
        let plan = MediaToolkit.videoPlan(
            targetBytes: 100_000, duration: 600,
            sourceSize: CGSize(width: 1920, height: 1080), frameRate: 30,
            hasAudio: true)

        #expect(plan == nil)
    }

    @Test func batchConversionResizesAndAvoidsCollisions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let input = root.appendingPathComponent("source.png")
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeImage(input, width: 120, height: 60)

        let first = try MediaToolkit.convertImages(
            [input], to: output,
            options: MediaImageOptions(format: .jpeg, quality: 0.8, maxDimension: 40))
        let second = try MediaToolkit.convertImages(
            [input], to: output,
            options: MediaImageOptions(format: .jpeg, quality: 0.8, maxDimension: 40))
        let firstURL = try #require(first.first?.outputURL)
        let secondURL = try #require(second.first?.outputURL)
        let source = try #require(CGImageSourceCreateWithURL(firstURL as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])

        #expect(firstURL.pathExtension == "jpg")
        #expect(firstURL != secondURL)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 40)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 20)
    }

    @Test func cancellationStopsBeforeWork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: CancellationError.self) {
            try MediaToolkit.convertImages(
                [root.appendingPathComponent("missing.png")], to: root,
                options: MediaImageOptions(format: .png), cancelled: { true })
        }
    }

    @Test func videoCompressionWritesACompleteBoundedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let input = root.appendingPathComponent("source.mov")
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeVideo(input, width: 320, height: 180, frames: 60, frameRate: 30)

        let result = try await MediaToolkit.compressVideo(
            input, to: output,
            options: MediaVideoOptions(targetMegabytes: 1, keepAudio: false))
        let asset = AVURLAsset(url: result.outputURL)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)

        #expect(result.outputBytes > 0)
        #expect(result.outputBytes <= result.targetBytes)
        #expect(result.outputURL.pathExtension == "mp4")
        #expect(duration >= 1.9)
        #expect(tracks.count == 1)
    }

    @Test func cancelledVideoCompressionLeavesNoOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let input = root.appendingPathComponent("source.mov")
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeVideo(input, width: 160, height: 90, frames: 3, frameRate: 30)

        await #expect(throws: CancellationError.self) {
            try await MediaToolkit.compressVideo(
                input, to: output,
                options: MediaVideoOptions(targetMegabytes: 1, keepAudio: false),
                cancelled: { true })
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: output, includingPropertiesForKeys: nil)
        #expect(contents.isEmpty)
    }

    private func writeImage(_ url: URL, width: Int, height: Int) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func writeVideo(
        _ url: URL, width: Int, height: Int, frames: Int, frameRate: Int32
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        try #require(writer.canAdd(input))
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            var pixelBuffer: CVPixelBuffer?
            try #require(
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess)
            let buffer = try #require(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let byteCount = CVPixelBufferGetBytesPerRow(buffer) * height
                memset(base, Int32((frame * 3) % 220 + 20), byteCount)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try #require(
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(value: Int64(frame), timescale: frameRate)))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        try #require(writer.status == .completed)
    }
}
