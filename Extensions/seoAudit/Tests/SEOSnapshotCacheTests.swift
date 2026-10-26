import AppKit
import Foundation
import ImageIO
import Testing
@testable import SEOAuditExtension

@Suite(.serialized) struct SEOSnapshotCacheTests {
    @Test func decodesOwnedSnapshotsAndRejectsOutsideAndLinkedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root);
            try? FileManager.default.removeItem(at: outside)
        }
        let image = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 48, bitsPerPixel: 32))
        let data = try #require(image.representation(using: .png, properties: [:]))
        let file = root.appendingPathComponent("snapshot.png")
        try SEOAuditOwnedIO.write(data, to: file, root: root)
        try data.write(to: outside)
        let cache = SEOSnapshotCache(root: root)
        #expect(await cache.image(for: file) != nil)
        #expect(await cache.image(for: outside) == nil)
        let linked = root.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        #expect(await cache.image(for: linked) == nil)
        cache.shutdown()
        #expect(await cache.image(for: file) == nil)
    }

    @Test func closingEitherRemoteOwnerLeavesTheOtherSnapshotReaderUsable() async throws {
        let cache = SEOSnapshotCache()
        let first = UUID(), second = UUID()
        let calls = SnapshotReaderCalls()
        let url = try #require(URL(string: "https://synthetic.invalid/snapshot.png"))
        cache.configureRemote(owner: first) { _ in
            await calls.record("first"); return nil
        }
        cache.configureRemote(owner: second) { _ in
            await calls.record("second"); return nil
        }
        _ = await cache.image(for: url)
        cache.releaseRemote(second)
        _ = await cache.image(for: url)
        cache.configureRemote(owner: second) { _ in
            await calls.record("second"); return nil
        }
        cache.releaseRemote(first)
        _ = await cache.image(for: url)
        cache.releaseRemote(second)
        _ = await cache.image(for: url)
        #expect(await calls.values == ["second", "first", "second"])
        cache.shutdown()
    }

    @Test func corruptImagesAndOversizedBodiesNeverDecode() {
        #expect(SEOSnapshotCache.decode(Data([1, 2, 3, 4])) == nil)
        #expect(SEOSnapshotCache.decode(Data(count: 25 * 1_024 * 1_024 + 1)) == nil)
    }

    @Test func cancelledCallerCannotPublishCachedImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = SEOSnapshotCache(root: root)
        let task = Task { await cache.image(for: root.appendingPathComponent("missing.png")) }
        task.cancel()
        #expect(await task.value == nil)
        cache.shutdown()
    }
}

private actor SnapshotReaderCalls {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
