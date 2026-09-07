import AppKit
import SwiftUI
import CoreGraphics
import EdithKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Edith

@MainActor
@Suite struct MediaToolkitPageModelTests {
    @Test func imageSelectionDeduplicatesAndUsesTheSourceFolder() {
        let model = MediaToolkitPageModel()
        let first = URL(fileURLWithPath: "/tmp/media/a.png")
        let second = URL(fileURLWithPath: "/tmp/media/b.jpg")

        model.add([first, first, second])

        #expect(model.mode == .images)
        #expect(model.imageURLs == [first, second])
        #expect(model.resolvedOutputDirectory == first.deletingLastPathComponent())
        #expect(model.canProcess)
    }

    @Test func videoSelectionReplacesTheCurrentVideo() {
        let model = MediaToolkitPageModel()
        let first = URL(fileURLWithPath: "/tmp/first.mov")
        let second = URL(fileURLWithPath: "/tmp/second.mp4")

        model.add([first])
        model.add([second])

        #expect(model.mode == .video)
        #expect(model.videoURL == second)
        #expect(model.canProcess)
    }

    @Test func unsupportedSelectionReportsAUsefulError() {
        let model = MediaToolkitPageModel()

        model.add([URL(fileURLWithPath: "/tmp/archive.zip")])

        #expect(!model.canProcess)
        #expect(model.errorMessage == "Choose an image or video that macOS can read.")
    }

    @Test func modelProcessesAnImageAndPublishesTheResult() async throws {
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("media-demo-" + UUID().uuidString, isDirectory: true)
        let input = root.appendingPathComponent("source.png")
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeImage(input)
        let model = MediaToolkitPageModel(
            executor: MediaToolkitExecutor(
                images: { try MediaToolkit.convertImages($0, to: $1, options: $2, progress: $3) },
                video: {
                    try await MediaToolkit.compressVideo($0, to: $1, options: $2, progress: $3)
                }))
        model.add([input])
        model.outputDirectory = output

        model.process(
            imageOptions: MediaImageOptions(format: .jpeg, maxDimension: 1600),
            videoOptions: MediaVideoOptions())
        while model.isProcessing {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try #require(model.imageResults.first)
        let resultURL = try #require(result.outputURL)
        #expect(resultURL.pathExtension == "jpg")
        #expect(FileManager.default.fileExists(atPath: resultURL.path))
        #expect(model.progress == 1)
        #expect(model.status == "Converted 1 of 1")
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            let hosting = NSHostingView(rootView: MediaToolkitPage(model: model))
            hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 1100)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("media-toolkit.png"))
        }
    }

    private func writeImage(_ url: URL) throws {
        let context = try #require(
            CGContext(
                data: nil, width: 80, height: 40, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }
}
