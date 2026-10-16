@testable import MachinesExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite @MainActor struct MachineSurfaceTests {
    @Test func filteringPrivacyAndOpaqueActionsUseCurrentRegistryItems() async throws {
        let first = UUID(), second = UUID()
        var items = [
            MachineSurfaceItem(
                id: first, name: "Synthetic alpha", detail: "alpha.invalid", connected: true),
            MachineSurfaceItem(
                id: second, name: "Synthetic beta", detail: "beta.invalid", connected: false),
        ]
        var opened: [UUID] = []
        var privacy: [String: String] = [:]
        var stopped = false
        let surface = MachineSurface(
            items: { items }, open: { opened.append($0) },
            stopped: { stopped }, privacy: { privacy })
        var tile = SurfaceTile(.machines)
        tile.sourceIDs = [first.uuidString]
        tile.itemLimit = 1
        tile.hiddenFields = ["metadata"]
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let snapshot = try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "machines")),
            providerID: "machines")
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows.first?.id == first.uuidString)
        #expect(snapshot.rows.first?.detail == "")
        #expect(snapshot.metrics.first(where: { $0.id == "total" })?.value == "1")
        let action = try #require(snapshot.rows.first?.actions.first?.id)
        #expect(UUID(uuidString: action) != nil)
        #expect(action != first.uuidString)
        _ = try await surface.execute(
            "surface.perform",
            payload: SurfaceActionRequest(
                snapshot: request, actionID: action
            ).encoded(providerID: "machines"))
        #expect(opened == [first])
        privacy = ["active": "1", "blurFleet": "1"]
        let hidden = try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.snapshot",
                payload: request.encoded(providerID: "machines")), providerID: "machines")
        #expect(hidden.rows.isEmpty); #expect(hidden.sources.isEmpty);
        #expect(hidden.metrics.isEmpty)
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: request, actionID: action
                ).encoded(providerID: "machines"))
        }
        privacy = [:]
        items.removeFirst()
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: request, actionID: action
                ).encoded(providerID: "machines"))
        }
        #expect(opened == [first])
        stopped = true
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "machines"))
        }
    }

    @Test func cancelledSnapshotPublishesNothingAndPerformsNoAction() async throws {
        var performed = false
        let surface = MachineSurface(
            items: { [] }, open: { _ in performed = true }, stopped: { false })
        let request = SurfaceSnapshotRequest(target: .notch, tile: SurfaceTile(.machines))
        let task = Task {
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "machines"))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!performed)
    }
}
