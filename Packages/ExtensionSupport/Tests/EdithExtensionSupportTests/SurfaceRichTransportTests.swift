import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import EdithExtensionSupport

@Suite @MainActor
struct SurfaceRichTransportTests {
    @Test func socketRoundTripsRichCardsAndCurrentControlsAcrossCancellationAndRestart()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: UUID().uuidString, owner: "music", directory: directory)
        let thumbnail = try syntheticImage()
        var volume = 0.4
        var privacy: [String: String] = [:]
        var calls = 0
        var reads = 0
        var slow = false
        let started = AsyncStream<Void>.makeStream()
        let server = ExtensionPeerServer(endpoint: endpoint) { _, command, payload in
            calls += 1
            return try await SurfaceCommandService.execute(
                providerID: "music", command: command, payload: payload,
                snapshot: { _ in
                    reads += 1
                    if slow {
                        started.continuation.yield(())
                        try await Task.sleep(for: .seconds(30))
                    }
                    return SurfaceSnapshot(
                        providerID: "music",
                        rows: [.init("track", title: "Synthetic track", thumbnail: thumbnail)],
                        sliders: [
                            .init(
                                "volume", "Volume", "speaker.wave.2", value: volume, field: "volume"
                            )
                        ],
                        charts: [
                            .init(
                                "activity", "Synthetic activity",
                                series: [
                                    .init(
                                        "series", "Activity",
                                        points: (0..<30).map {
                                            .init(String($0), x: Double($0), y: Double($0 % 5))
                                        })
                                ])
                        ])
                }, perform: { _ in Issue.record("Slider unexpectedly invoked a button") },
                adjust: { id, value in
                    #expect(id == "volume"); volume = value
                }, privacyValues: { privacy })
        }
        try server.start()
        defer { server.shutdown() }
        var versions = ["music": "1"]
        let client = SurfaceSnapshotClient(activeVersions: { versions }) { _, command, payload in
            try await endpoint.invoke(command, payload: payload, timeout: 5)
        }
        defer { client.shutdown() }
        var tile = SurfaceTile(.music)
        let first = try await client.snapshot(providerID: "music", target: .home, tile: tile)
        #expect(first.rows.first?.thumbnail == thumbnail)
        #expect(first.charts?.first?.series.first?.points.count == 30)
        let changed = try await client.perform(
            providerID: "music", target: .home, tile: tile, snapshot: first, actionID: "volume",
            value: 0.9)
        #expect(volume == 0.9 && changed.sliders?.first?.value == 0.9)
        tile.hiddenFields = ["volume", "artwork", "chart"]
        let before = calls
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await client.perform(
                providerID: "music", target: .home, tile: tile, snapshot: changed,
                actionID: "volume", value: 0.1)
        }
        #expect(calls == before)
        tile.hiddenFields = []
        let forged = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: tile), actionID: "arbitrary:outside", value: 0.5)
        await #expect(throws: (any Error).self) {
            _ = try await endpoint.invoke(
                "surface.perform", payload: forged.encoded(providerID: "music"))
        }
        #expect(volume == 0.9)
        privacy = ["active": "1", "blurMusic": "1"]
        let beforePrivacy = reads
        let hidden = try await client.snapshot(providerID: "music", target: .home, tile: tile)
        #expect(hidden.rows.isEmpty && hidden.charts == nil && hidden.sliders == nil)
        #expect(reads == beforePrivacy)
        privacy = [:]; slow = true
        let pending = Task {
            try await client.snapshot(providerID: "music", target: .home, tile: tile)
        }
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        versions = [:]; client.retain(activeVersions: versions)
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(client.pendingCount == 0)
        server.shutdown()
        slow = false; volume = 0.2; versions = ["music": "2"]
        client.retain(activeVersions: versions)
        try server.start()
        let restored = try await client.snapshot(providerID: "music", target: .home, tile: tile)
        #expect(restored.sliders?.first?.value == 0.2)
        #expect(restored.rows.first?.thumbnail == thumbnail)
        #expect(client.pendingCount == 0)
    }

    private func syntheticImage() throws -> SurfaceThumbnail {
        let context = try #require(
            CGContext(
                data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 320,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return SurfaceThumbnail(
            data: data as Data, accessibilityLabel: "Synthetic artwork", field: "artwork")
    }
}
