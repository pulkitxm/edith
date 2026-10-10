import AppKit
import EdithExtensionSupport
import Foundation
import Testing
@testable import VirtualCameraExtension

@MainActor @Suite(.serialized) struct CameraSurfaceTests {
    private func engine(
        sources: @escaping () -> [VirtualCameraSource] = {
            [.init(id: "synthetic-camera", name: "Synthetic camera", kind: .external)]
        }
    ) -> VirtualCameraEngine {
        VirtualCameraEngine(
            state: VirtualCameraState(),
            environment: .init(
                authorization: { .denied }, obsRunning: { false }, frontmostApplication: { nil },
                sources: sources),
            previewBus: .init(
                file: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString), unlinkOnClose: true))
    }

    @Test func homeAndNotchExposeLiveScenesSourcesAndBoundedZoom() async throws {
        let engine = engine()
        defer { engine.shutdown() }
        let surface = CameraSurface(engine: engine, privacyValues: { [:] })
        for target in [SurfaceTarget.home, .notch] {
            let request = SurfaceSnapshotRequest(
                target: target, tile: .init(.ability("virtualCamera")))
            let result = try SurfaceSnapshot.decode(
                await surface.execute(
                    "surface.snapshot", payload: request.encoded(providerID: "virtualCamera")),
                providerID: "virtualCamera")
            #expect(result.rows.contains { $0.title == "Synthetic camera" })
            #expect(!result.rows.contains { $0.id.contains("synthetic-camera") })
            let zoom = try #require(result.sliders?.first)
            _ = try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(snapshot: request, actionID: zoom.id, value: 0.5)
                    .encoded(providerID: "virtualCamera"))
            #expect(engine.snapshot().state.composition.framing.zoom == 4.5)
            let source = try #require(result.rows.first?.actions.first)
            _ = try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(snapshot: request, actionID: source.id).encoded(
                    providerID: "virtualCamera"))
            #expect(engine.snapshot().state.sourceID == "synthetic-camera")
        }
    }

    @Test func changedSourcesFilteredActionsAndPresenterMaskCannotMutateCamera() async throws {
        var sources: [VirtualCameraSource] = [
            .init(id: "camera-a", name: "Synthetic A", kind: .external),
            .init(id: "camera-b", name: "Synthetic B", kind: .external),
        ]
        let engine = engine(sources: { sources })
        defer { engine.shutdown() }
        var privacy: [String: String] = [:]
        let surface = CameraSurface(engine: engine, privacyValues: { privacy })
        let all = surface.snapshot(.init(.ability("virtualCamera")))
        let row = try #require(all.rows.first)
        let action = try #require(row.actions.first)
        var tile = SurfaceTile(.ability("virtualCamera"))
        tile.sourceIDs = [row.sourceID]
        tile.itemLimit = 1
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let selected = try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "virtualCamera")),
            providerID: "virtualCamera")
        #expect(selected.rows.count == 1)
        sources.removeFirst()
        await #expect(throws: (any Error).self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(snapshot: request, actionID: action.id).encoded(
                    providerID: "virtualCamera"))
        }
        privacy = ["active": "1", "blurCamera": "1"]
        let masked = try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "virtualCamera")),
            providerID: "virtualCamera")
        #expect(masked.rows.isEmpty)
        #expect(masked.sources.isEmpty)
        #expect(masked.sliders == nil)
        await #expect(throws: (any Error).self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(snapshot: request, actionID: "resume").encoded(
                    providerID: "virtualCamera"))
        }
    }

    @Test func largeSourceCatalogRemainsBoundedAndRetainsSelectedScene() async throws {
        let sources = (0..<100).map {
            VirtualCameraSource(
                id: "synthetic-\($0)", name: String(repeating: "🟢", count: 300), kind: .external)
        }
        let scenes = (0..<100).map {
            VirtualCameraScene(name: "Synthetic scene \($0)", composition: .init())
        }
        let engine = VirtualCameraEngine(
            state: .init(scenes: scenes),
            environment: .init(
                authorization: { .denied }, obsRunning: { false }, frontmostApplication: { nil },
                sources: { sources }))
        defer { engine.shutdown() }
        let surface = CameraSurface(engine: engine, privacyValues: { [:] })
        var tile = SurfaceTile(.ability("virtualCamera"))
        tile.sourceIDs = [CameraSurface.identity("scene:" + scenes[99].id.uuidString)]
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        let snapshot = try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "virtualCamera")),
            providerID: "virtualCamera")
        #expect(snapshot.sources.count == 100)
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows.first?.title == "Synthetic scene 99")
        #expect(snapshot.sources.allSatisfy { $0.title.utf8.count <= 1024 })
        #expect(snapshot.metrics.allSatisfy { $0.value.utf8.count <= 256 })
    }

    @Test func awaitedShutdownClearsWorkAndRejectsLateCommands() async throws {
        let engine = engine()
        let surface = CameraSurface(engine: engine, privacyValues: { [:] })
        engine.start()
        await engine.finishShutdown()
        #expect(engine.isStopped)
        #expect(!engine.streaming)
        #expect(engine.snapshot().audioStatus?.running == false)
        #expect(throws: (any Error).self) { try engine.perform(.zoom(2)) }
        await #expect(throws: (any Error).self) {
            try await surface.execute(
                "surface.snapshot",
                payload: SurfaceSnapshotRequest(
                    target: .notch, tile: .init(.ability("virtualCamera"))
                ).encoded(providerID: "virtualCamera"))
        }
    }
}
