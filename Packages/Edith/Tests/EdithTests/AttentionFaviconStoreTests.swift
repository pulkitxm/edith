import AppKit
import Foundation
import Testing

@testable import Edith

@MainActor
@Suite struct AttentionFaviconStoreTests {
    @Test func persistedFaviconsLoadFromAFreshStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-favicon-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://meet.google.com/favicon.ico")!
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))

        let writer = AttentionFaviconStore(directory: directory)
        try await writer.store(data, for: url)
        let reader = AttentionFaviconStore(directory: directory)

        #expect(await reader.cachedData(for: url) == data)
        #expect(
            await reader.cachedData(for: URL(string: "https://example.com/favicon.ico")!) == nil)
    }

    @Test func invalidImageDataIsNotPersisted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-favicon-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://example.com/favicon.ico")!
        let store = AttentionFaviconStore(directory: directory)

        try await store.store(Data("not an image".utf8), for: url)

        #expect(await store.cachedData(for: url) == nil)
        #expect(FileManager.default.fileExists(atPath: directory.path) == false)
    }
}
