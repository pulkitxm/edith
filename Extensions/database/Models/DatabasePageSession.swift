import DatabaseCore
import Foundation
import Observation

@MainActor
@Observable
final class DatabasePageSession {
    var focusedConnectionID: DatabaseConnectionID?
    let page: DatabasePageModel
    let connections: DatabaseConnectionWorkspaceModel
    let management: DatabaseConnectionManagementModel
    let tables: DatabaseTableTabsModel
    let objects: DatabaseObjectExplorerModel
    let workspace: DatabaseWorkspaceModel
    @ObservationIgnored private let makeCreation: @MainActor () -> DatabaseConnectionCreationModel

    init(
        sender: any DatabaseBrokerCommandSending = DatabaseWorkerClient(),
        repair: @escaping @Sendable () async throws -> Void = {
            try await DatabaseWorkerClient.restart()
        },
        prepare: @escaping @MainActor @Sendable (DatabaseConnectionSummary) async throws -> Void = {
            try await DatabaseMachineForwardRouter.prepare($0)
        },
        makeColumns: @escaping @MainActor () -> DatabaseColumnsModel = { DatabaseColumnsModel() },
        secretStore: (any DatabaseSecretStore)? = nil
    ) {
        page = DatabasePageModel(
            ensureReady: { _ = try await sender.send(.connectionList(.init())) },
            repairService: repair)
        connections = DatabaseConnectionWorkspaceModel(sender: sender, prepareConnection: prepare)
        management = DatabaseConnectionManagementModel(sender: sender)
        tables = DatabaseTableTabsModel(
            makeData: { DatabaseDataWorkspaceModel(sender: sender) }, makeColumns: makeColumns)
        objects = DatabaseObjectExplorerModel(sender: sender)
        workspace = DatabaseWorkspaceModel(sender: sender)
        makeCreation = { DatabaseConnectionCreationModel(sender: sender, secretStore: secretStore) }
    }

    func connectionCreation() -> DatabaseConnectionCreationModel { makeCreation() }
    func shutdown() {
        objects.cancel()
        tables.data.cancel()
        for tab in tables.tabs { tab.data.cancel() }
        workspace.shutdown()
        page.loading.cancel()
    }
}
