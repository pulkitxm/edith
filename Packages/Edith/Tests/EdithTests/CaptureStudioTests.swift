import AppKit
import Foundation
import Testing

@testable import EdithKit

@Suite struct CaptureStudioTests {
    @Test func filenameTemplatesResolveTokensAndUnsafeCharacters() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = CaptureFilenameTemplate.resolve(
            "Shot/{mode}:{date} {time}", mode: .window, now: date)

        #expect(name.hasPrefix("Shot-window-"))
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
    }

    @Test func recentLibraryIsBoundedAndRemovable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try png(width: 10, height: 8)
        for index in 0..<(CaptureLibraryStore.maximumCount + 3) {
            _ = try CaptureLibraryStore.add(
                data, mode: .area,
                recognition: CaptureRecognition(text: "\(index)", codes: []),
                to: directory, capturedAt: Date(timeIntervalSince1970: Double(index)))
        }

        let items = CaptureLibraryStore.load(from: directory)
        #expect(items.count == CaptureLibraryStore.maximumCount)
        #expect(items.first?.recognition.text == "14")
        let removed = try #require(items.first)
        try CaptureLibraryStore.remove(removed, from: directory)
        #expect(CaptureLibraryStore.load(from: directory).count == 11)
        #expect(!FileManager.default.fileExists(
            atPath: CaptureLibraryStore.imageURL(for: removed, in: directory).path))
    }

    @Test func rendererCropsAnnotatesAndFrames() throws {
        let source = try image(width: 100, height: 80)
        let annotation = CaptureAnnotation(
            tool: .redact,
            points: [CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 35)])
        let document = CaptureEditDocument(
            cropRect: CGRect(x: 10, y: 10, width: 60, height: 40),
            annotations: [annotation], backdrop: .light)
        let rendered = try CaptureRenderer.render(baseImage: source, document: document)

        #expect(rendered.width > 60)
        #expect(rendered.height > 40)
        #expect(try CaptureRenderer.pngData(baseImage: source, document: document).isEmpty == false)
    }

    private func png(width: Int, height: Int) throws -> Data {
        let representation = NSBitmapImageRep(cgImage: try image(width: width, height: height))
        return try #require(representation.representation(using: .png, properties: [:]))
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
