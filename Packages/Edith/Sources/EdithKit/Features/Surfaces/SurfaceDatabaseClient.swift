import EdithDatabase
import Foundation

public enum SurfaceDatabaseError: LocalizedError {
    case incompleteResponse
    public var errorDescription: String? {
        "Database metadata could not be loaded. Open Databases to review the service, then refresh."
    }
}

public struct SurfaceDatabaseClient: Sendable {
    private let client: any DatabaseBrokerCommandSending
    private let packReady: @Sendable () -> Bool
    public init(
        client: any DatabaseBrokerCommandSending = DatabaseBrokerCommandClient(),
        packReady: @escaping @Sendable () -> Bool = {
            DatabasePackStore.inspect(expectedVersion: DatabasePackVersion.current()).state
                == .current
        }
    ) {
        self.client = client
        self.packReady = packReady
    }
    public func snapshot(_ tile: SurfaceTile) async throws -> SurfaceExtensionSnapshot {
        guard packReady() else {
            return .init(
                actions: [.init("Open Databases", "arrow.up.right", .navigate("database"))],
                message:
                    "Open Databases to set up or update its local service. This widget uses saved metadata and does not run queries."
            )
        }
        async let connections = client.send(.connectionList(.init(search: .init(limit: 100))))
        async let queries = client.send(.savedQueryList(.init(search: .init(limit: 100))))
        async let operations = client.send(.operationList(.init(search: .init(limit: 100))))
        let responses = try await (connections, queries, operations)
        guard responses.0.connectionListResult?.status == .succeeded,
            responses.1.savedQueryListResult?.status == .succeeded,
            responses.2.operationListResult?.status == .succeeded,
            let connections = responses.0.connectionListResult?.payload?.connections,
            let queries = responses.1.savedQueryListResult?.payload?.queries,
            let operations = responses.2.operationListResult?.payload?.operations
        else { throw SurfaceDatabaseError.incompleteResponse }
        return Self.project(
            connections: connections, queries: queries, operations: operations, tile: tile)
    }
    static func project(
        connections: [DatabaseConnectionDefinition], queries: [DatabaseSavedQuery],
        operations: [DatabaseOperationRecordSummary], tile: SurfaceTile
    ) -> SurfaceExtensionSnapshot {
        func selected(_ id: String) -> Bool { tile.sourceIDs?.contains(id) ?? true }
        func included(_ kind: String) -> Bool { tile.contentKinds?.contains(kind) ?? true }
        let chosenConnections = connections.filter { selected($0.id.rawValue.uuidString) }
        let chosenQueries = queries.filter {
            selected($0.connectionID?.rawValue.uuidString ?? "unassigned")
        }
        let chosenOperations = operations.filter { selected($0.connection.id.rawValue.uuidString) }
        let active: Set<DatabaseOperationState> = [.queued, .running, .cancelling]
        let failed: Set<DatabaseOperationState> = [.failed, .partiallySucceeded]
        let review = SurfaceRowAction("Open Databases", "arrow.up.right", .navigate("database"))
        var rows: [SurfaceDataRow] = []
        if included("operations") {
            rows += chosenOperations.sorted {
                let left = active.contains($0.state) || failed.contains($0.state) ? 1 : 0
                let right = active.contains($1.state) || failed.contains($1.state) ? 1 : 0
                return left == right
                    ? ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) : left > right
            }.map {
                let progress = $0.progress.flatMap { value -> Double? in
                    guard value.kind == .determinate, let completed = value.completed,
                        let total = value.total, total > 0
                    else { return nil }
                    return Double(completed) / Double(total)
                }
                return .init(
                    "operation:" + $0.id.rawValue.uuidString,
                    source: $0.connection.id.rawValue.uuidString,
                    title: $0.kind.rawValue,
                    detail: $0.connection.displayName + " · \($0.recordCount) records",
                    value: $0.state.rawValue,
                    icon: failed.contains($0.state)
                        ? "exclamationmark.circle"
                        : active.contains($0.state)
                            ? "arrow.triangle.2.circlepath" : "checkmark.circle",
                    progress: progress, actions: [review])
            }
        }
        if included("connections") {
            rows += chosenConnections.sorted { $0.isFavorite && !$1.isFavorite }.map {
                .init(
                    "connection:" + $0.id.rawValue.uuidString, source: $0.id.rawValue.uuidString,
                    title: $0.displayName,
                    detail: $0.productHint.displayName + " · " + $0.environment.label,
                    value: $0.environment.kind.rawValue.capitalized,
                    icon: $0.isFavorite ? "star.fill" : "externaldrive", actions: [review])
            }
        }
        if included("queries") {
            rows += chosenQueries.sorted { $0.isFavorite && !$1.isFavorite }.map {
                .init(
                    "query:" + $0.id.rawValue.uuidString,
                    source: $0.connectionID?.rawValue.uuidString ?? "unassigned",
                    title: $0.name, detail: $0.language.rawValue,
                    value: $0.isFavorite ? "Favorite" : "Saved query",
                    icon: "text.alignleft", actions: [review])
            }
        }
        var sources = connections.map {
            SurfaceSourceChoice($0.id.rawValue.uuidString, $0.displayName)
        }
        if queries.contains(where: { $0.connectionID == nil }) {
            sources.append(.init("unassigned", "Queries without a connection"))
        }
        let limited = connections.count >= 100 || queries.count >= 100 || operations.count >= 100
        return .init(
            metrics: [
                .init("connections", "Connections", "\(chosenConnections.count)"),
                .init("queries", "Saved queries", "\(chosenQueries.count)"),
                .init(
                    "running", "Active operations",
                    "\(chosenOperations.filter { active.contains($0.state) }.count)"),
                .init(
                    "failed", "Failed operations",
                    "\(chosenOperations.filter { failed.contains($0.state) }.count)"),
            ], rows: rows,
            message: limited
                ? "Counts cover up to 100 connections, 100 saved queries, and the 100 most recent operations."
                : rows.isEmpty
                    ? "No saved metadata in this selection. Queries run only in the database workspace."
                    : nil,
            updatedAt: Date(), sources: sources)
    }
}
