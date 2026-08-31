import EdithDatabase
import Foundation
import Observation

enum DatabaseObjectExplorerState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum DatabaseExplorerGroupState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

struct DatabaseExplorerObject: Identifiable, Equatable, Sendable {
    let identifier: DatabaseObjectIdentifier
    let title: String
    let estimatedRows: Int64?
    let columnCount: Int64?

    var id: DatabaseObjectIdentifier { identifier }
}

struct DatabaseExplorerGroup: Identifiable, Equatable, Sendable {
    let identifier: DatabaseObjectIdentifier
    let title: String
    let isAvailable: Bool
    var objects: [DatabaseExplorerObject]
    var state: DatabaseExplorerGroupState
    var nextContinuation: DatabaseContinuationToken?

    var id: DatabaseObjectIdentifier { identifier }
}

@MainActor
@Observable
final class DatabaseObjectExplorerModel {
    var searchText = ""
    private(set) var state = DatabaseObjectExplorerState.idle
    private(set) var groups: [DatabaseExplorerGroup] = []
    private(set) var selectedObject: DatabaseObjectIdentifier?

    private let sender: any DatabaseBrokerCommandSending
    private var activeTask: Task<Void, Never>?
    private var generation = UUID()
    private var activeConnectionID: DatabaseConnectionID?

    init(sender: any DatabaseBrokerCommandSending = DatabaseBrokerCommandClient()) {
        self.sender = sender
    }

    var filteredGroups: [DatabaseExplorerGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        var results: [DatabaseExplorerGroup] = []
        for group in groups {
            var matchingObjects: [DatabaseExplorerObject] = []
            for object in group.objects {
                if object.title.localizedCaseInsensitiveContains(query)
                    || object.identifier.kind.rawValue.localizedCaseInsensitiveContains(query)
                {
                    matchingObjects.append(object)
                }
            }
            guard group.title.localizedCaseInsensitiveContains(query) || !matchingObjects.isEmpty
            else { continue }
            var result = group
            if !group.title.localizedCaseInsensitiveContains(query) {
                result.objects = matchingObjects
            }
            results.append(result)
        }
        return results
    }

    func prepare(for connection: DatabaseConnectionSummary?) {
        guard activeConnectionID != connection?.id else { return }
        cancel()
        activeConnectionID = connection?.id
        groups = []
        selectedObject = nil
        searchText = ""
        state = .idle
    }

    func load(_ connection: DatabaseConnectionSummary) {
        prepare(for: connection)
        switch connection.product {
        case .redis, .valkey:
            let database = connection.logicalDatabase ?? "0"
            let object = DatabaseObjectIdentifier(kind: .keyspace, path: [database])
            groups = [
                DatabaseExplorerGroup(
                    identifier: DatabaseObjectIdentifier(kind: .server, path: []),
                    title: "Keyspaces",
                    isAvailable: true,
                    objects: [
                        DatabaseExplorerObject(
                            identifier: object,
                            title: "Database \(database)",
                            estimatedRows: nil,
                            columnCount: nil)
                    ],
                    state: .loaded,
                    nextContinuation: nil)
            ]
            selectedObject = object
            state = .loaded
        case .postgresql:
            loadPostgreSQL(connection)
        case .sqlite:
            let group = DatabaseExplorerGroup(
                identifier: DatabaseObjectIdentifier(kind: .schema, path: ["main"]),
                title: "main",
                isAvailable: true,
                objects: [],
                state: .idle,
                nextContinuation: nil)
            groups = [group]
            state = .loaded
            loadGroup(group.identifier, connection: connection)
        default:
            state = .failed(
                "Automatic object discovery is not available for \(connection.product.displayName) yet."
            )
        }
    }

    func loadGroup(
        _ identifier: DatabaseObjectIdentifier,
        connection: DatabaseConnectionSummary,
        appending: Bool = false
    ) {
        guard let index = groups.firstIndex(where: { $0.identifier == identifier }),
            groups[index].isAvailable,
            groups[index].state != .loading
        else { return }
        let continuation = appending ? groups[index].nextContinuation : nil
        if appending, continuation == nil { return }
        activeTask?.cancel()
        for groupIndex in groups.indices where groups[groupIndex].state == .loading {
            groups[groupIndex].state = .idle
        }
        groups[index].state = .loading
        let requestGeneration = generation
        let sender = sender
        let task = Task { [weak self] in
            do {
                let response = try await sender.send(
                    .browse(
                        Self.discoveryRequest(
                            connectionID: connection.id,
                            object: identifier,
                            continuation: continuation)))
                try Task.checkCancellation()
                let page = try Self.page(from: response)
                self?.finishGroup(
                    identifier,
                    page: page,
                    connectionID: connection.id,
                    generation: requestGeneration,
                    appending: appending)
            } catch is CancellationError {
            } catch {
                self?.failGroup(identifier, error: error, generation: requestGeneration)
            }
        }
        activeTask = task
    }

    func select(_ object: DatabaseObjectIdentifier?) {
        selectedObject = object
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        generation = UUID()
        if state == .loading {
            state = groups.isEmpty ? .idle : .loaded
        }
    }

    private func loadPostgreSQL(_ connection: DatabaseConnectionSummary) {
        activeTask?.cancel()
        let requestGeneration = UUID()
        generation = requestGeneration
        state = .loading
        let sender = sender
        let task = Task { [weak self] in
            do {
                let response = try await sender.send(
                    .browse(
                        Self.discoveryRequest(
                            connectionID: connection.id,
                            object: DatabaseObjectIdentifier(
                                kind: .database,
                                path: [connection.defaultDatabase ?? connection.name]))))
                try Task.checkCancellation()
                let page = try Self.page(from: response)
                let groups = try Self.postgreSQLGroups(from: page.records)
                self?.finishPostgreSQLGroups(
                    groups,
                    connection: connection,
                    generation: requestGeneration)
            } catch is CancellationError {
            } catch {
                self?.fail(error, generation: requestGeneration)
            }
        }
        activeTask = task
    }

    private func finishPostgreSQLGroups(
        _ discoveredGroups: [DatabaseExplorerGroup],
        connection: DatabaseConnectionSummary,
        generation: UUID
    ) {
        guard self.generation == generation, activeConnectionID == connection.id else { return }
        groups = discoveredGroups
        state = .loaded
        activeTask = nil
        let preferredSchema = connection.defaultSchema ?? "public"
        guard
            let group = groups.first(where: {
                $0.identifier.path == [preferredSchema] && $0.isAvailable
            }) ?? groups.first(where: \.isAvailable)
        else { return }
        loadGroup(group.identifier, connection: connection)
    }

    private func finishGroup(
        _ identifier: DatabaseObjectIdentifier,
        page: EdithDatabase.DatabasePage<DatabaseRecord>,
        connectionID: DatabaseConnectionID,
        generation: UUID,
        appending: Bool
    ) {
        guard self.generation == generation, activeConnectionID == connectionID,
            let index = groups.firstIndex(where: { $0.identifier == identifier })
        else { return }
        let objects = Self.objects(from: page.records, parent: identifier)
        if appending {
            groups[index].objects.append(contentsOf: objects)
        } else {
            groups[index].objects = objects
        }
        groups[index].nextContinuation = page.nextContinuation
        groups[index].state = .loaded
        activeTask = nil
        if selectedObject == nil {
            selectedObject = groups[index].objects.first?.identifier
        }
    }

    private func fail(_ error: Error, generation: UUID) {
        guard self.generation == generation else { return }
        activeTask = nil
        state = .failed(Self.message(for: error))
    }

    private func failGroup(
        _ identifier: DatabaseObjectIdentifier,
        error: Error,
        generation: UUID
    ) {
        guard self.generation == generation,
            let index = groups.firstIndex(where: { $0.identifier == identifier })
        else { return }
        activeTask = nil
        groups[index].state = .failed(Self.message(for: error))
    }

    private static func discoveryRequest(
        connectionID: DatabaseConnectionID,
        object: DatabaseObjectIdentifier,
        continuation: DatabaseContinuationToken? = nil
    ) -> DatabaseBrowseRequest {
        DatabaseBrowseRequest(
            target: DatabaseTargetIdentifier(connectionID: connectionID, object: object),
            page: DatabasePageRequest(
                pageSize: discoveryPageSize,
                continuation: continuation))
    }

    private static let discoveryPageSize: DatabasePageSize = {
        do {
            return try DatabasePageSize(100)
        } catch {
            preconditionFailure("The database discovery page size is invalid.")
        }
    }()

    private static func page(
        from response: DatabaseBrokerCommandResponse
    ) throws -> EdithDatabase.DatabasePage<DatabaseRecord> {
        guard case .browse(let result) = response else {
            throw DatabaseObjectExplorerError.invalidResponse
        }
        if result.status == .failed {
            throw result.error ?? DatabaseObjectExplorerError.invalidResponse
        }
        guard let page = result.payload?.page else {
            throw DatabaseObjectExplorerError.invalidResponse
        }
        return page
    }

    private static func postgreSQLGroups(
        from records: [DatabaseRecord]
    ) throws -> [DatabaseExplorerGroup] {
        try records.map { record in
            let name = try string("name", in: record)
            return DatabaseExplorerGroup(
                identifier: DatabaseObjectIdentifier(kind: .schema, path: [name]),
                title: name,
                isAvailable: boolean("canUse", in: record) ?? true,
                objects: [],
                state: .idle,
                nextContinuation: nil)
        }
    }

    private static func objects(
        from records: [DatabaseRecord],
        parent: DatabaseObjectIdentifier
    ) -> [DatabaseExplorerObject] {
        records.compactMap { record in
            guard let name = try? string("name", in: record) else { return nil }
            let kind =
                stringIfPresent("kind", in: record).flatMap(DatabaseObjectKind.init(rawValue:))
                ?? .table
            return DatabaseExplorerObject(
                identifier: DatabaseObjectIdentifier(kind: kind, path: parent.path + [name]),
                title: name,
                estimatedRows: integer("estimatedRows", in: record),
                columnCount: integer("columnCount", in: record))
        }
    }

    private static func string(_ name: String, in record: DatabaseRecord) throws -> String {
        guard case .string(let value)? = record.fields.first(where: { $0.name == name })?.value
        else { throw DatabaseObjectExplorerError.invalidRecord }
        return value
    }

    private static func stringIfPresent(_ name: String, in record: DatabaseRecord) -> String? {
        guard case .string(let value)? = record.fields.first(where: { $0.name == name })?.value
        else { return nil }
        return value
    }

    private static func boolean(_ name: String, in record: DatabaseRecord) -> Bool? {
        guard case .boolean(let value)? = record.fields.first(where: { $0.name == name })?.value
        else { return nil }
        return value
    }

    private static func integer(_ name: String, in record: DatabaseRecord) -> Int64? {
        guard
            case .signedInteger(let value)? = record.fields.first(where: { $0.name == name })?.value
        else { return nil }
        return value
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let error as DatabaseErrorEnvelope:
            error.message
        case DatabaseObjectExplorerError.invalidResponse:
            "The database returned an unexpected discovery response."
        case DatabaseObjectExplorerError.invalidRecord:
            "The database returned invalid object metadata."
        default:
            "Could not load database objects: \(error.localizedDescription)"
        }
    }
}

private enum DatabaseObjectExplorerError: Error {
    case invalidResponse
    case invalidRecord
}
