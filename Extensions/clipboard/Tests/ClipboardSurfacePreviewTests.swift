import CoreGraphics
import EdithExtensionSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipboardExtension

@Suite(.serialized) @MainActor struct ClipboardSurfacePreviewTests {
    @Test func previewsHaveBoundedCountBytesAndUnicodeTextAndRespectHiddenFields() async throws {
        let image = try png()
        let transport = ClipboardSurfacePreviewTransport(image: image)
        let surface = ClipboardSurface(
            client: .init(send: { try await transport.send($0, $1) }), privacyValues: { [:] },
            copy: { _ in })
        var tile = SurfaceTile(.ability("clipboard")); tile.itemLimit = 20
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        let data = try await surface.execute(
            "surface.snapshot", payload: request.encoded(providerID: "clipboard"))
        let snapshot = try SurfaceSnapshot.decode(data, providerID: "clipboard")
        let previews = snapshot.rows.compactMap(\.thumbnail)
        #expect(!previews.isEmpty && previews.count < 8)
        #expect(previews.reduce(0, { $0 + $1.data.count }) <= 192 << 10)
        #expect(data.count <= 524_288)
        #expect(
            snapshot.rows.allSatisfy { $0.title.utf8.count <= 768 && !$0.title.utf8.contains(0) })
        #expect(await transport.requests == 8)
        tile.hiddenFields = ["previews", "total", "pinned"]
        let hidden = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot",
                payload: SurfaceSnapshotRequest(target: .home, tile: tile).encoded(
                    providerID: "clipboard")), providerID: "clipboard")
        #expect(hidden.rows.allSatisfy { $0.thumbnail == nil })
        #expect(hidden.metrics.isEmpty)
        #expect(await transport.requests == 8)
        tile.hiddenFields = ["items"]
        let noRows = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot",
                payload: SurfaceSnapshotRequest(target: .home, tile: tile).encoded(
                    providerID: "clipboard")), providerID: "clipboard")
        #expect(noRows.rows.isEmpty)
        #expect(await transport.requests == 8)
    }

    @Test func slowPreviewsCancelAtTheSnapshotDeadlineWithoutBlockingRows() async throws {
        let transport = ClipboardSurfacePreviewTransport(image: try png(), delay: true)
        let surface = ClipboardSurface(
            client: .init(send: { try await transport.send($0, $1) }), privacyValues: { [:] },
            copy: { _ in })
        var tile = SurfaceTile(.ability("clipboard")); tile.itemLimit = 8
        let started = ContinuousClock.now
        let snapshot = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot",
                payload: SurfaceSnapshotRequest(target: .home, tile: tile).encoded(
                    providerID: "clipboard")), providerID: "clipboard")
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(snapshot.rows.count == 8)
        #expect(snapshot.rows.allSatisfy { $0.thumbnail == nil })
        #expect(await transport.requests == 8)
        await ClipboardPreviewCancellation.shared.shutdown()
    }

    private func png() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 128 * 128 * 4)
        var state: UInt32 = 42
        for index in bytes.indices {
            state = 1_664_525 &* state &+ 1_013_904_223
            bytes[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: state >> 24)
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(
            CGImage(
                width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 512,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

private actor ClipboardSurfacePreviewTransport {
    let image: Data
    let delay: Bool
    private(set) var requests = 0
    let entries = (0..<12).map { index in
        ClipboardEntry(
            id: UUID().uuidString, sha256: "mock", types: ["public.png"], ext: "png",
            sourceApp: "Mock Camera", sourceBundleID: "example.mock.camera", size: 64,
            preview: "\u{0}" + String(repeating: "🌈", count: 500))
    }
    init(image: Data, delay: Bool = false) { self.image = image; self.delay = delay }
    func send(_ command: String, _ payload: Data) async throws -> Data {
        switch command {
        case ClipboardServiceOperation.snapshot:
            return try ClipboardMessage.encode(
                ClipboardSnapshot(entries: entries, revision: "mock", total: entries.count))
        case ClipboardServiceOperation.thumbnail:
            requests += 1
            if delay { try await Task.sleep(for: .seconds(10)) }
            return try ClipboardMessage.encode(ClipboardThumbnailSnapshot(data: image))
        case ClipboardServiceOperation.cancelThumbnail: return Data()
        default: throw CocoaError(.featureUnsupported)
        }
    }
}
