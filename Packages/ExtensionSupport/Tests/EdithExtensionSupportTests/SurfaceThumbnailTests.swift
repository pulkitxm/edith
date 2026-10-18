import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import EdithExtensionSupport

@Suite @MainActor
struct SurfaceThumbnailTests {
    @Test(arguments: ["public.png", "public.jpeg"])
    func admittedImagesRoundTripAndDecodeOnlyAtBoundedPreviewSize(_ type: String) throws {
        let data = try fixture(width: 160, height: 80, type: type)
        let thumbnail = SurfaceThumbnail(data: data, accessibilityLabel: "Synthetic artwork")
        let snapshot = SurfaceSnapshot(
            providerID: "music",
            rows: [.init("track", title: "Synthetic track", thumbnail: thumbnail)])
        #expect(try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "music") == snapshot)
        let image = try thumbnail.decodedImage(maximumDimension: 40)
        #expect(image.width == 40 && image.height == 20)
        let original = SurfaceSnapshot(providerID: "music", rows: [.init("track", title: "Track")])
        #expect(!String(decoding: try original.encoded(), as: UTF8.self).contains("thumbnail"))
    }

    @Test(arguments: ["size", "unsupported", "truncated", "dimension", "pixels", "label", "field"])
    func malformedImagesNeverReachImageDecoding(_ mode: String) throws {
        var data = try fixture(width: 160, height: 80)
        var label = "Thumbnail"
        var field: String?
        switch mode {
        case "size": data.append(Data(repeating: 0, count: 131_073))
        case "unsupported": data = try fixture(width: 80, height: 80, type: "com.compuserve.gif")
        case "truncated": data = data.prefix(data.count / 2)
        case "dimension": data = try fixture(width: 1025, height: 1)
        case "pixels": data = try fixture(width: 1024, height: 1024)
        case "label": label = String(repeating: "x", count: 257)
        default: field = "bad\0field"
        }
        let image = SurfaceThumbnail(data: data, accessibilityLabel: label, field: field)
        #expect(throws: ExtensionPeerError.self) { try image.validate() }
        #expect(throws: ExtensionPeerError.self) { _ = try image.decodedImage() }
        let snapshot = SurfaceSnapshot(
            providerID: "music", rows: [.init("track", title: "Track", thumbnail: image)])
        #expect(throws: ExtensionPeerError.self) { _ = try snapshot.encoded() }
    }

    @Test func aggregateImagesAndBase64EncodingStayInsideTheSnapshotBudget() throws {
        let data = try fixture(width: 200, height: 180, noisy: true)
        #expect(data.count > 104_858 && data.count <= 131_072)
        let thumbnail = SurfaceThumbnail(data: data)
        try thumbnail.validate()
        let oversized = SurfaceSnapshot(
            providerID: "clipboard",
            rows: (0..<5).map { .init(String($0), title: "Synthetic image", thumbnail: thumbnail) })
        #expect(throws: ExtensionPeerError.self) { _ = try oversized.encoded() }
        let base64Oversized = SurfaceSnapshot(
            providerID: "clipboard",
            rows: (0..<4).map { .init(String($0), title: "Synthetic image", thumbnail: thumbnail) })
        #expect(throws: ExtensionPeerError.self) { _ = try base64Oversized.encoded() }
        let bounded = SurfaceSnapshot(
            providerID: "clipboard",
            rows: (0..<2).map { .init(String($0), title: "Synthetic image", thumbnail: thumbnail) })
        #expect(try bounded.encoded().count < 524_288)
    }

    @Test func imageFieldsAndPresenterPrivacyAreAppliedBeforePublication() async throws {
        let thumbnail = SurfaceThumbnail(data: try fixture(width: 80, height: 80), field: "artwork")
        let snapshot = SurfaceSnapshot(
            providerID: "music", rows: [.init("track", title: "Track", thumbnail: thumbnail)])
        var tile = SurfaceTile(.music)
        tile.hiddenFields = ["artwork"]
        #expect(SurfaceCommandService.project(snapshot, tile: tile).rows.first?.thumbnail == nil)
        tile.hiddenFields = []
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        var reads = 0
        let data = try await SurfaceCommandService.execute(
            providerID: "music", command: "surface.snapshot",
            payload: request.encoded(providerID: "music"),
            snapshot: { _ in
                reads += 1; return snapshot
            },
            perform: { _ in }, privacyValues: { ["active": "1", "blurMusic": "1"] })
        #expect(reads == 0)
        #expect(try SurfaceSnapshot.decode(data, providerID: "music").rows.isEmpty)
    }

    private func fixture(
        width: Int, height: Int, type: String = "public.png", noisy: Bool = false
    ) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noisy {
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            var state: UInt32 = 1931
            for index in 0..<(width * height * 4) {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                bytes[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: state)
            }
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
