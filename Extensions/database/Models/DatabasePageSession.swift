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
    @ObservationIgnored private var creations: [UUID: DatabaseConnectionCreationModel] = [:]
    @ObservationIgnored private var closed = false
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

    func connectionCreation() -> DatabaseConnectionCreationModel {
        creations = creations.filter { !$0.value.isDrained }
        let creation = makeCreation()
        guard !closed, creations.count < 256 else {
            creation.cancelPendingCommands()
            return creation
        }
        creations[creation.id] = creation
        return creation
    }
    func cancelPendingCommands() {
        closed = true
        for creation in creations.values { creation.cancelPendingCommands() }
        objects.cancelPendingCommands()
        tables.cancelPendingCommands()
        workspace.cancelPendingCommands()
        connections.cancelPendingCommands()
        management.cancelPendingCommands()
        page.cancelPendingCommands()
    }

    func cancelAndWait() async {
        cancelPendingCommands()
        for creation in creations.values { await creation.cancelAndWait() }
        creations.removeAll()
        await objects.cancelAndWait()
        await tables.cancelAndWait()
        await workspace.cancelAndWait()
        await connections.cancelAndWait()
        await management.cancelAndWait()
        await page.cancelAndWait()
    }

    func shutdown() {
        cancelPendingCommands()
        objects.cancel()
        tables.data.cancel()
        for tab in tables.tabs { tab.data.cancel() }
        workspace.shutdown()
        page.loading.cancel()
    }
}

@MainActor
final class DatabaseTaskOwner {
    private struct Entry {
        let task: Task<Void, Never>
        let cancel: @Sendable () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private(set) var closed = false

    func launch(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !closed, entries.count < 256 else { return nil }
        let id = UUID()
        let task = Task {
            defer { entries[id] = nil }
            await work()
        }
        entries[id] = Entry(task: task, cancel: { task.cancel() })
        return task
    }

    func perform<Value: Sendable>(
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        guard !closed, entries.count < 256 else { throw CancellationError() }
        let id = UUID()
        let task = Task { try await work() }
        let joined = Task {
            _ = await task.result
            entries[id] = nil
        }
        entries[id] = Entry(task: joined, cancel: { task.cancel() })
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    var activeCount: Int { entries.count }

    func wait() async {
        let active = Array(entries.values)
        for entry in active { await entry.task.value }
    }

    func cancel() {
        closed = true
        for entry in entries.values { entry.cancel() }
    }

    func drain() async {
        cancel()
        while let entry = entries.values.first { await entry.task.value }
    }
}
