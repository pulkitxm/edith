import DatabaseCore
import EdithExtensionSupport
import Foundation
import Testing
@testable import DatabaseExtension

@MainActor @Suite struct DatabaseSurfaceTests {
    @Test func sourceSelectionAndStaleActionsAreEnforced() async throws {
        let first = try DatabaseConnectionDraft(
            displayName: "Synthetic first", product: .sqlite, path: ":memory:"
        ).definition()
        let second = try DatabaseConnectionDraft(
            displayName: "Synthetic second", product: .sqlite, path: ":memory:"
        ).definition()
        let sender = DatabaseSurfaceSender([first, second])
        let surface = DatabaseSurface(session: DatabasePageSession(), sender: sender)
        var tile = SurfaceTile(.databases)
        tile.sourceIDs = [first.id.rawValue.uuidString]
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        let result = try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "database")),
            providerID: "database")
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.title == first.displayName)
        #expect(result.sources.count == 2)
        let action = try #require(result.rows.first?.actions.first)
        await sender.replace([second])
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(snapshot: request, actionID: action.id).encoded(
                    providerID: "database"))
        }
        surface.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "database"))
        }
    }

    @Test func presenterPrivacyAvoidsOpeningMetadataAndRejectsActions() async throws {
        let sender = DatabaseSurfaceSender([])
        let surface = DatabaseSurface(
            session: DatabasePageSession(), sender: sender,
            privacyValues: { ["active": "1", "blurDatabase": "1"] })
        let request = SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.databases))
        let result = try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "database")),
            providerID: "database")
        #expect(result.rows.isEmpty)
        #expect(result.sources.isEmpty)
        #expect(await sender.calls == 0)
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: request, actionID: "open/" + UUID().uuidString
                ).encoded(providerID: "database"))
        }
        #expect(await sender.calls == 0)
    }
}

private actor DatabaseSurfaceSender: DatabaseBrokerCommandSending {
    private var connections: [DatabaseConnectionDefinition]
    private(set) var calls = 0
    init(_ connections: [DatabaseConnectionDefinition]) { self.connections = connections }
    func replace(_ connections: [DatabaseConnectionDefinition]) { self.connections = connections }
    func send(_ request: DatabaseBrokerCommandRequest) async throws -> DatabaseBrokerCommandResponse
    {
        calls += 1
        guard case .connectionList = request else {
            throw DatabaseBrokerCommandClientError.invalidRequest
        }
        return .connectionList(
            .success(
                .init(connections: connections),
                metadata: .init(completeness: .init(state: .complete))))
    }
}
