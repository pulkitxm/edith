import CoreGraphics
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
}
