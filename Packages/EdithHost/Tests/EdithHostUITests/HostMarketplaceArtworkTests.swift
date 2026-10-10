import AppKit
import CryptoKit
import Foundation
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostMarketplaceArtworkTests {
    private let golden: [String: String] = [
        "claude-accent": "49cb3b5739bf8d901106d6fe9e284bfb546557890523aa49fe96a255358facf3",
        "edith-accent": "e2a95265b9d815322b381983b42126a02870f5267e8de233d3f0b75026edff9c",
        "edith-blue": "3cf0620698eb2cc188bcc270d3db5e072852bad9f9ed0e3f37ec8689ed151690",
        "edith-green": "fb438fea9a833c7d5ddb7574f52fe5828d5d61a373634afebf06a3dc25b32586",
        "edith-indigo": "031d8d3243fdf950bde1aec4260148483a542b9cd3b42e44d88c669366e5c6ea",
        "edith-orange": "0c0f4a868e8962b23fe426369f14f0e89652c224699f90950912d6cb1b5a0689",
        "edith-pink": "036111783bc4955d0db2623a271e67e2143e5e55bb533ecefb42d18c858629e4",
        "edith-purple": "fe6b984fbe1173bfb903141da13ef047ef05c6e54c058927357e7f11e78a3939",
        "edith-red": "33aee9540c5b7e9ba47cbe5036844360231d4feb25d32036b0ab961fa0b3fcc9",
        "edith-teal": "272c1cd61fd439cf351ce7b45d575defbce2c4219f1e948fb371b8e7f6419f25",
        "finder-accent": "3eb2e231e7b5233d30e9ac8fb74a60659cdcf20067de17e90d045378b246aeee",
        "spotify-accent": "69f898243ca32f7510b53c9be401657ff277902e387c4a6d29dd6d36485ccd66",
    ]

    private func archive() throws -> Data {
        let products = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
        let url = products.appendingPathComponent(HostMarketplaceArtwork.resourceBundleName)
            .appendingPathComponent("MarketplaceArtwork.lzma")
        return try Data(contentsOf: url)
    }

    @Test func allOriginalPixelsAndImageMetadataAreIdentical() throws {
        #expect(HostMarketplaceArtwork.image("unknown") == nil)
        #expect(HostMarketplaceArtwork.image("edith-accent") != nil)
        let pixels = try #require(HostMarketplaceArtwork.decode(archive()))
        #expect(pixels.count == 1_843_200)
        #expect(Set(HostMarketplaceArtwork.keys) == Set(golden.keys))
        for key in HostMarketplaceArtwork.keys {
            let image = try #require(HostMarketplaceArtwork.image(key, pixels: pixels))
            let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bytes = try #require(cg.dataProvider?.data as Data?)
            #expect(
                SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == golden[key])
            #expect(cg.width == 252 && cg.height == 150 && cg.bytesPerRow == 1024)
            #expect(cg.bitsPerComponent == 8 && cg.bitsPerPixel == 32)
            #expect(cg.alphaInfo == .premultipliedFirst)
            #expect(cg.bitmapInfo.contains(.byteOrder32Little))
            #expect(cg.colorSpace?.name == CGColorSpace.sRGB)
            #expect(cg.shouldInterpolate && cg.renderingIntent == .defaultIntent)
            #expect(image.size == NSSize(width: 84, height: 50))
        }
    }

    @Test func malformedArchivesFailWithoutDecode() throws {
        let valid = try archive()
        #expect(HostMarketplaceArtwork.decode(Data()) == nil)
        #expect(HostMarketplaceArtwork.decode(valid.dropLast()) == nil)
        #expect(HostMarketplaceArtwork.decode(valid + Data([0])) == nil)
        var wrong = valid
        wrong[wrong.startIndex] ^= 1
        #expect(HostMarketplaceArtwork.decode(wrong) == nil)
        #expect(HostMarketplaceArtwork.image("unknown", pixels: Data()) == nil)
    }

    @Test func cacheLoadsOnlyOnThemeChangesAndKeepsOnlySelectedSwatches() throws {
        let pixels = try #require(HostMarketplaceArtwork.decode(archive()))
        let cache = HostMarketplaceArtworkCache()
        var loads = 0
        let load = {
            loads += 1; return Optional(pixels)
        }
        let first = cache.swatches(theme: "accent", load: load)
        let same = cache.swatches(theme: "accent", load: load)
        #expect(loads == 1 && first.count == 4)
        #expect(zip(first, same).allSatisfy { $0 === $1 })
        let changed = cache.swatches(theme: "blue", load: load)
        #expect(loads == 2 && changed.count == 4)
        #expect(first[0] !== changed[0])
    }

    @Test func installedHostAndContainedWorkerResolveOutsideWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Synthetic.app")
        let archiveURL = try #require(HostMarketplaceArtwork.resourceURL(bundleURL: app))
        try FileManager.default.createDirectory(
            at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive().write(to: archiveURL)
        #expect(HostMarketplaceArtwork.loadPixels(at: archiveURL)?.count == 1_843_200)
        let appex = app.appendingPathComponent("Contents/Extensions/Synthetic.appex")
        let workerURL = try #require(HostMarketplaceArtwork.resourceURL(bundleURL: appex))
        #expect(workerURL != archiveURL)
        #expect(HostMarketplaceArtwork.loadPixels(at: workerURL) == nil)
        try FileManager.default.createDirectory(
            at: workerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive().write(to: workerURL)
        #expect(HostMarketplaceArtwork.loadPixels(at: workerURL)?.count == 1_843_200)
        #expect(
            HostMarketplaceArtwork.resourceURL(
                bundleURL: root.appendingPathComponent("foreign.appex")) == nil)
        try Data([0]).write(to: archiveURL)
        #expect(HostMarketplaceArtwork.loadPixels(at: workerURL)?.count == 1_843_200)
        #expect(HostMarketplaceArtwork.loadPixels(at: archiveURL) == nil)
        try FileManager.default.removeItem(at: archiveURL)
        #expect(HostMarketplaceArtwork.loadPixels(at: archiveURL) == nil)
        let foreign = root.appendingPathComponent("foreign.lzma")
        try archive().write(to: foreign)
        try FileManager.default.createSymbolicLink(at: archiveURL, withDestinationURL: foreign)
        #expect(HostMarketplaceArtwork.loadPixels(at: archiveURL) == nil)
    }

    private final class Marker: NSObject {}
}
