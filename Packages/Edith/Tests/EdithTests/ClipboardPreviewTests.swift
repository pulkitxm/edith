import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithAgent
@testable import EdithKit

@Suite struct ClipboardPreviewTests {
    @Test func daemonPreparesFileAndHTMLTextAndReturnsBoundedImageDataOverXPC() async throws {
        let fixture = try ClipboardPreviewFixture()
        defer { fixture.cleanup() }
        let runtime = AgentRuntime(build: "clipboard-previews", store: nil)
        let service = ClipboardService(
            archive: fixture.archive, defaults: fixture.defaults, changed: {})
        await service.register(on: runtime)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = AgentClipboardClient(client: listener.client())
        let file = fixture.root.appendingPathComponent("notes.txt")
        try Data("Prepared in the daemon".utf8).write(to: file)
        let capture = fixture.capture(
            Data(file.absoluteString.utf8), ext: "url", preview: "notes.txt")
        _ = try await client.capture(capture)
        #expect(try await client.entries().first?.preview == "notes.txt · Prepared in the daemon")
        let html = fixture.capture(
            Data(
                "<html><head><title>Hidden</title></head><body><script>discard()</script><p>Hello &amp; welcome</p></body></html>"
                    .utf8),
            ext: "html", preview: "HTML")
        _ = try await client.capture(html)
        #expect(
            try await client.entries().first(where: { $0.id == html.id })?.preview
                == "Hello & welcome")
        let pixels = try Self.png(width: 1600, height: 800)
        let picture = fixture.capture(pixels, ext: "png", preview: "PNG image")
        _ = try await client.capture(picture)
        let thumbnail = try #require(try await client.thumbnail(id: picture.id).data)
        #expect(thumbnail.count <= ClipboardThumbnailSnapshot.maximumBytes)
        let size = try Self.dimensions(thumbnail)
        #expect(size.width == 160)
        #expect(size.height == 80)
        let imageFile = fixture.root.appendingPathComponent("picture.png")
        try pixels.write(to: imageFile)
        let reference = fixture.capture(Data(imageFile.absoluteString.utf8), ext: "url")
        _ = try await client.capture(reference)
        let fileThumbnail = try #require(try await client.thumbnail(id: reference.id).data)
        let fileSize = try Self.dimensions(fileThumbnail)
        #expect(fileSize.width > 0 && fileSize.width <= 80)
        #expect(fileSize.height > 0 && fileSize.height <= 80)
        await runtime.shutdown()
    }

    @Test func recentSnapshotIgnoresPinAndCopyOrderAndDetectsExternalAtomicChanges() throws {
        let fixture = try ClipboardPreviewFixture()
        defer { fixture.cleanup() }
        let first = fixture.capture(Data("first".utf8), at: Date(timeIntervalSince1970: 100))
        let second = fixture.capture(Data("second".utf8), at: Date(timeIntervalSince1970: 200))
        try fixture.store(first)
        try fixture.store(second)
        _ = try fixture.archive.mutate(.init(.pin, ids: [first.id]))
        #expect(try fixture.archive.snapshot(.init(limit: 1)).entries.first?.id == first.id)
        let recent = try fixture.archive.snapshot(.init(limit: 1, recentlyCreated: true))
        #expect(recent.entries.first?.id == second.id)
        let replacement = ClipboardArchive(root: fixture.archive.root)
        _ = try replacement.mutate(.init(.delete, ids: [second.id]))
        #expect(try fixture.archive.snapshot(.init()).total == 1)
        #expect(throws: AgentError.self) {
            try fixture.archive.snapshot(.init(revision: recent.revision))
        }
    }

    @Test func cachedFileThumbnailsInvalidateWhenTheReferencedFileChanges() async throws {
        let fixture = try ClipboardPreviewFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("changing.txt")
        try Data("first".utf8).write(to: file)
        let capture = fixture.capture(Data(file.absoluteString.utf8), ext: "url")
        try fixture.store(capture)
        let counter = ClipboardPreviewCounter()
        let previews = ClipboardThumbnailService(archive: fixture.archive) { _ in
            Data([UInt8(await counter.next())])
        }
        let first = try await previews.read(.init(entryID: capture.id))
        #expect(first.data == Data([1]))
        #expect(try await previews.read(.init(entryID: capture.id)).data == first.data)
        #expect(await counter.count == 1)
        try Data("second value".utf8).write(to: file, options: .atomic)
        #expect(try await previews.read(.init(entryID: capture.id)).data == Data([2]))
        #expect(await counter.count == 2)
        await previews.stop()
    }

    @Test func cancellationCrossesXPCAndReleasesTheRenderer() async throws {
        let fixture = try ClipboardPreviewFixture()
        defer { fixture.cleanup() }
        let capture = fixture.capture(Data("fixture".utf8), ext: "png")
        try fixture.store(capture)
        let counter = ClipboardPreviewCounter()
        let previews = ClipboardThumbnailService(archive: fixture.archive) { _ in
            _ = await counter.next()
            try await Task.sleep(for: .seconds(30))
            return Data()
        }
        let runtime = AgentRuntime(build: "clipboard-cancellation", store: nil)
        await runtime.register(operation: AgentClipboardOperation.thumbnail) { payload in
            try await AgentPayload.encode(
                previews.read(AgentPayload.decode(ClipboardThumbnailRequest.self, from: payload)))
        }
        await runtime.register(operation: AgentClipboardOperation.cancelThumbnail) { payload in
            await previews.cancel(try AgentPayload.decode(UUID.self, from: payload))
            return Data()
        }
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = AgentClipboardClient(client: listener.client())
        let operation = Task { try await client.thumbnail(id: capture.id) }
        try await wait { await counter.count == 1 }
        operation.cancel()
        await #expect(throws: Error.self) { try await operation.value }
        try await wait { await previews.activity.active == 0 }
        #expect(await previews.activity.pending == 0)
        #expect(await previews.activity.cachedBytes == 0)
        await previews.stop()
        await runtime.shutdown()
    }

    @Test func queueLimitsTimeoutsAndEarlyCancellationKeepPreviewWorkBounded() async throws {
        let fixture = try ClipboardPreviewFixture()
        defer { fixture.cleanup() }
        let capture = fixture.capture(Data("fixture".utf8), ext: "png")
        try fixture.store(capture)
        let previews = ClipboardThumbnailService(
            archive: fixture.archive, concurrency: 1, capacity: 1, timeout: 0.1
        ) { _ in
            try await Task.sleep(for: .seconds(30))
            return nil
        }
        let early = ClipboardThumbnailRequest(entryID: capture.id)
        await previews.cancel(early.id)
        await #expect(throws: CancellationError.self) { try await previews.read(early) }
        let operation = Task { try await previews.read(.init(entryID: capture.id)) }
        try await wait { await previews.activity.pending == 1 }
        await #expect(throws: AgentError.self) {
            try await previews.read(.init(entryID: capture.id))
        }
        await #expect(throws: AgentError.self) { try await operation.value }
        try await wait { await previews.activity.active == 0 }
        await previews.stop()
        await #expect(throws: AgentError.self) {
            try await previews.read(.init(entryID: capture.id))
        }
    }

    @Test func oversizedRendererResultsAreRejectedAndNotCached() async throws {
        let fixture = try ClipboardPreviewFixture()
        defer { fixture.cleanup() }
        let capture = fixture.capture(Data("fixture".utf8), ext: "png")
        try fixture.store(capture)
        let previews = ClipboardThumbnailService(archive: fixture.archive) { _ in
            Data(repeating: 0, count: ClipboardThumbnailSnapshot.maximumBytes + 1)
        }
        await #expect(throws: AgentError.self) {
            try await previews.read(.init(entryID: capture.id))
        }
        #expect(await previews.activity.cachedBytes == 0)
        await previews.stop()
    }

    @Test @MainActor func pasteboardExtractionSkipsFileIOAndPreservesPlatformText() throws {
        let fixture = try ClipboardPreviewFixture()
        defer { fixture.cleanup() }
        let pipe = fixture.root.appendingPathComponent("named.txt")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([pipe as NSURL])
        let capture = try #require(
            ClipboardPayloadExtractor.extract(
                from: pasteboard, options: .init(saveFiles: true, saveImages: true, saveText: true))
        )
        #expect(capture.preview == "named.txt")
        let prepared = try ClipboardPreviewPreparation.prepare(
            .init(
                payload: capture, sourceApp: nil, sourceBundleID: nil))
        #expect(prepared.preview == "named.txt")
        pasteboard.clearContents()
        pasteboard.setData(Data("{\\rtf1\\ansi Prepared rich text}".utf8), forType: .rtf)
        let rich = try #require(
            ClipboardPayloadExtractor.extract(
                from: pasteboard, options: .init(saveFiles: true, saveImages: true, saveText: true))
        )
        #expect(rich.preview == "Prepared rich text")
        let decoded = try ClipboardPreviewPreparation.prepare(
            .init(
                payload: .init(
                    data: rich.data, types: rich.types, ext: rich.ext, preview: "Rich text"),
                sourceApp: nil, sourceBundleID: nil))
        #expect(decoded.preview == "Prepared rich text")
    }

    @Test(arguments: [(800, 600), (100, 20), (3400, 40), (34, 400)])
    func imagePreviewsFitTheirBoundsWithoutUpscaling(size: (Int, Int)) throws {
        let input = try Self.png(width: size.0, height: size.1)
        let output = try #require(ClipboardThumbnailRenderer.image(input))
        let dimensions = try Self.dimensions(output)
        #expect(dimensions.width <= 680)
        #expect(dimensions.height <= 80)
        #expect(dimensions.width <= size.0)
        #expect(dimensions.height <= size.1)
        let ratio = min(1, min(680 / Double(size.0), 80 / Double(size.1)))
        #expect(abs(Double(dimensions.width) - Double(size.0) * ratio) <= 1)
        #expect(abs(Double(dimensions.height) - Double(size.1) * ratio) <= 1)
    }

    private func wait(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The clipboard preview condition did not complete.")
    }

    @Test func rotatedImageUsesItsDisplayedDimensionsToFitThePreview() throws {
        let input = try Self.png(width: 800, height: 160, orientation: 6)
        let output = try #require(ClipboardThumbnailRenderer.image(input))
        let dimensions = try Self.dimensions(output)
        #expect(dimensions.width == 16)
        #expect(dimensions.height == 80)
    }

    private static func png(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let result = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                result, (orientation == 1 ? UTType.png : UTType.tiff).identifier as CFString, 1, nil
            ))
        CGImageDestinationAddImage(
            destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return result as Data
    }

    private static func dimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let values = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            try #require(values[kCGImagePropertyPixelWidth] as? Int),
            try #require(values[kCGImagePropertyPixelHeight] as? Int)
        )
    }
}

private actor ClipboardPreviewCounter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

private struct ClipboardPreviewFixture {
    let root: URL
    let archive: ClipboardArchive
    let defaults: UserDefaults
    let suite = "clipboard-preview-" + UUID().uuidString

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        archive = ClipboardArchive(root: root.appendingPathComponent("archive"))
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func capture(_ data: Data, ext: String = "txt", preview: String = "fixture", at: Date = Date())
        -> ClipboardCapture
    {
        ClipboardCapture(
            payload: .init(data: data, types: ["public.data"], ext: ext, preview: preview),
            sourceApp: nil, sourceBundleID: nil, capturedAt: at)
    }

    func store(_ capture: ClipboardCapture) throws {
        _ = try archive.capture(
            capture, maxItems: 200, maxBytes: ClipboardArchive.maximumBlobBytes, maxAge: nil)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
