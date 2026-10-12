import EdithExtensionSupport
import Foundation
import Testing
@testable import BifrostExtension

@Suite @MainActor struct BifrostSurfaceTests {
    @Test func ownedIndexIsProjectedWithoutLeakingPathsOrHiddenFields() async throws {
        let suite = "bifrost.surface." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite);
            try? FileManager.default.removeItem(at: directory)
        }
        let index = BifrostIndexStore(location: directory.appendingPathComponent("index.json"))
        index.save(
            BifrostIndex(
                generatedAt: Date(),
                applications: [
                    .init(
                        name: "Fixture Notes", path: "/synthetic/Notes.app", bundleID: "test.notes")
                ]))
        let store = BifrostStore(
            store: defaults, indexStore: index, scan: { [] }, open: { _ in false }, copy: { _ in })
        defer { store.shutdown() }
        var queries: [String] = []
        let surface = BifrostSurface(store: store, open: { queries.append($0) }, privacy: { [:] })
        var tile = SurfaceTile(.ability("bifrost"))
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        let data = try await surface.execute(
            "surface.snapshot", payload: request.encoded(providerID: "bifrost"))
        let snapshot = try SurfaceSnapshot.decode(data, providerID: "bifrost")
        #expect(snapshot.rows.first?.title == "Fixture Notes")
        #expect(snapshot.rows.first?.actions.first?.id.hasPrefix("launch/") == true)
        #expect(!String(decoding: data, as: UTF8.self).contains("/synthetic"))
        _ = try await surface.execute(
            "surface.perform",
            payload: SurfaceActionRequest(snapshot: request, actionID: "open").encoded(
                providerID: "bifrost"))
        #expect(queries == [""])
        tile.showActions = false
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: .init(target: .home, tile: tile), actionID: "open"
                ).encoded(providerID: "bifrost"))
        }
        tile = SurfaceTile(.desk); tile.hiddenFields = ["bifrost"]
        let hidden = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot",
                payload: SurfaceSnapshotRequest(target: .home, tile: tile).encoded(
                    providerID: "bifrost")), providerID: "bifrost")
        #expect(hidden.rows.isEmpty && hidden.metrics.isEmpty && hidden.actions.isEmpty)
        tile = SurfaceTile(.ability("bifrost")); tile.sourceIDs = []
        let filtered = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot",
                payload: SurfaceSnapshotRequest(target: .home, tile: tile).encoded(
                    providerID: "bifrost")), providerID: "bifrost")
        #expect(filtered.rows.isEmpty)
        let masked = BifrostSurface(
            store: store, open: { _ in Issue.record("Hidden launcher opened") },
            privacy: { ["active": "1"] })
        let privateResult = try SurfaceSnapshot.decode(
            try await masked.execute(
                "surface.snapshot", payload: request.encoded(providerID: "bifrost")),
            providerID: "bifrost")
        #expect(
            privateResult.rows.isEmpty && privateResult.actions.isEmpty
                && privateResult.metrics.isEmpty)
        await #expect(throws: ExtensionPeerError.self) {
            try await masked.execute("bifrost.open", payload: Data())
        }
    }
}
