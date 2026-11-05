import AppKit
import Foundation
import Testing

@testable import AttentionNative

@Suite @MainActor struct AttentionIconStoreTests {
    @Test func concurrentRowsShareOneFetchPerIcon() async {
        let store = AttentionIconStore()
        let descriptor = AttentionEventIconDescriptor.application(bundleID: "test.sample.app1")
        var fetches = 0
        let png = AttentionSyntheticHistory.largeIconPNG
        let fetch: @MainActor () async -> Data? = {
            fetches += 1
            try? await Task.sleep(for: .milliseconds(20))
            return png
        }
        async let first = store.load(descriptor, fetch: fetch)
        async let second = store.load(descriptor, fetch: fetch)
        async let third = store.load(descriptor, fetch: fetch)
        let images = await [first, second, third]
        #expect(fetches == 1)
        #expect(images.allSatisfy { $0 != nil })
        #expect(store.cached(descriptor) != nil)
        #expect(!store.needsLoad(descriptor))
        _ = await store.load(descriptor, fetch: fetch)
        #expect(fetches == 1)
    }

    @Test func missingIconsAreNotRequestedAgain() async {
        let store = AttentionIconStore()
        let descriptor = AttentionEventIconDescriptor.website(
            URL(string: "https://site1.example.com/favicon.ico"))
        var fetches = 0
        let fetch: @MainActor () async -> Data? = {
            fetches += 1
            return nil
        }
        #expect(await store.load(descriptor, fetch: fetch) == nil)
        #expect(await store.load(descriptor, fetch: fetch) == nil)
        #expect(fetches == 1)
        #expect(!store.needsLoad(descriptor))
    }

    @Test func largeIconsAreDecodedAsSmallThumbnails() throws {
        let image = try #require(
            AttentionIconStore.thumbnail(
                AttentionSyntheticHistory.largeIconPNG, pixels: AttentionIconStore.pixelSize))
        let pixels = try #require(image.representations.first)
        #expect(pixels.pixelsWide <= AttentionIconStore.pixelSize)
        #expect(pixels.pixelsHigh <= AttentionIconStore.pixelSize)
    }

    @Test func symbolsNeverLoad() async {
        let store = AttentionIconStore()
        let descriptor = AttentionEventIconDescriptor.icon(.globe)
        #expect(!store.needsLoad(descriptor))
        #expect(await store.load(descriptor, fetch: { Data() }) == nil)
    }
}
