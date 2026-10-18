import DatabaseCore
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor final class DatabaseSurface {
    private let session: DatabasePageSession
    private let privacyValues: @MainActor () -> [String: String]
    private let sender: any DatabaseBrokerCommandSending
    private var stopped = false

    init(
        session: DatabasePageSession,
        sender: any DatabaseBrokerCommandSending = DatabaseWorkerClient(),
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) {
        self.session = session
        self.sender = sender
        self.privacyValues = privacyValues
    }

    func shutdown() { stopped = true }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "database", command: command, payload: payload,
            snapshot: { try await self.snapshot($0) },
            perform: { try await self.perform($0) }, privacyValues: privacyValues)
    }

    func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        async let connectionResponse = sender.send(
            .connectionList(.init(search: .init(limit: Self.listLimit))))
        async let queryResponse = sender.send(
            .savedQueryList(.init(search: .init(limit: Self.listLimit))))
        async let operationResponse = sender.send(
            .operationList(.init(search: .init(limit: Self.listLimit))))
        let responses = try await (connectionResponse, queryResponse, operationResponse)
        try Task.checkCancellation()
        guard !stopped, responses.0.connectionListResult?.status == .succeeded,
            responses.1.savedQueryListResult?.status == .succeeded,
            responses.2.operationListResult?.status == .succeeded,
            let connections = responses.0.connectionListResult?.payload?.connections,
            let queries = responses.1.savedQueryListResult?.payload?.queries,
            let operations = responses.2.operationListResult?.payload?.operations
        else { throw ExtensionPeerError.rejected(Self.incompleteMessage) }
        return Self.project(
            connections: connections, queries: queries, operations: operations, tile: tile)
    }

    private static let listLimit = 100
    static let incompleteMessage =
        "Database metadata could not be loaded. Open Databases to review the service, then refresh."

    static func project(
        connections: [DatabaseConnectionDefinition], queries: [DatabaseSavedQuery],
        operations: [DatabaseOperationRecordSummary], tile: SurfaceTile
    ) -> SurfaceSnapshot {
        func selected(_ id: String) -> Bool { tile.sourceIDs?.contains(id) ?? true }
        func included(_ kind: String) -> Bool { tile.contentKinds?.contains(kind) ?? true }
        func openAction(_ rowID: String) -> [SurfaceAction] {
            [.init("open/" + rowID, "Open Databases", "arrow.up.right")]
        }
        let chosenConnections = connections.filter { selected($0.id.rawValue.uuidString) }
        let chosenQueries = queries.filter {
            selected($0.connectionID?.rawValue.uuidString ?? "unassigned")
        }
        let chosenOperations = operations.filter { selected($0.connection.id.rawValue.uuidString) }
        let active: Set<DatabaseOperationState> = [.queued, .running, .cancelling]
        let failed: Set<DatabaseOperationState> = [.failed, .partiallySucceeded]
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
                let id = "operation:" + $0.id.rawValue.uuidString
                return SurfaceDataRow(
                    id, sourceID: $0.connection.id.rawValue.uuidString,
                    title: $0.kind.rawValue,
                    detail: String($0.connection.displayName.prefix(256))
                        + " · \($0.recordCount) records",
                    value: $0.state.rawValue,
                    icon: failed.contains($0.state)
                        ? "exclamationmark.circle"
                        : active.contains($0.state)
                            ? "arrow.triangle.2.circlepath" : "checkmark.circle",
                    progress: progress, actions: openAction(id))
            }
        }
        if included("connections") {
            rows += chosenConnections.sorted { $0.isFavorite && !$1.isFavorite }.map {
                let id = "connection:" + $0.id.rawValue.uuidString
                return SurfaceDataRow(
                    id, sourceID: $0.id.rawValue.uuidString,
                    title: String($0.displayName.prefix(256)),
                    detail: $0.productHint.displayName + " · " + $0.environment.label,
                    value: $0.environment.kind.rawValue.capitalized,
                    icon: $0.isFavorite ? "star.fill" : "externaldrive",
                    actions: openAction(id))
            }
        }
        if included("queries") {
            rows += chosenQueries.sorted { $0.isFavorite && !$1.isFavorite }.map {
                let id = "query:" + $0.id.rawValue.uuidString
                return SurfaceDataRow(
                    id, sourceID: $0.connectionID?.rawValue.uuidString ?? "unassigned",
                    title: String($0.name.prefix(256)), detail: $0.language.rawValue,
                    value: $0.isFavorite ? "Favorite" : "Saved query",
                    icon: "text.alignleft", actions: openAction(id))
            }
        }
        var sources = connections.map {
            SurfaceSourceChoice($0.id.rawValue.uuidString, String($0.displayName.prefix(256)))
        }
        if queries.contains(where: { $0.connectionID == nil }) {
            sources.append(.init("unassigned", "Queries without a connection"))
        }
        let limited =
            connections.count >= listLimit || queries.count >= listLimit
            || operations.count >= listLimit
        return SurfaceSnapshot(
            providerID: "database",
            metrics: [
                .init("connections", "Connections", "\(chosenConnections.count)"),
                .init("queries", "Saved queries", "\(chosenQueries.count)"),
                .init(
                    "running", "Active operations",
                    "\(chosenOperations.filter { active.contains($0.state) }.count)"),
                .init(
                    "failed", "Failed operations",
                    "\(chosenOperations.filter { failed.contains($0.state) }.count)"),
            ], rows: Array(rows.prefix(tile.itemLimit)), sources: sources,
            message: limited
                ? "Counts cover up to 100 connections, 100 saved queries, and the 100 most recent operations."
                : rows.isEmpty
                    ? "No saved metadata in this selection. Queries run only in the database workspace."
                    : nil,
            updatedAt: Date())
    }

    private func connections() async throws -> [DatabaseConnectionDefinition] {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let response = try await sender.send(.connectionList(.init()))
        try Task.checkCancellation()
        guard !stopped, case .connectionList(let result) = response, let payload = result.payload
        else {
            throw ExtensionPeerError.unavailable
        }
        return Array(payload.connections.prefix(1_024))
    }

    private func perform(_ action: String) async throws {
        let parts = action.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, parts[0] == "open" else { throw ExtensionPeerError.invalidRequest }
        let target = parts[1].split(separator: ":", maxSplits: 1)
        guard target.count == 2, ["connection", "operation", "query"].contains(target[0]) else {
            throw ExtensionPeerError.invalidRequest
        }
        if target[0] == "connection", let id = UUID(uuidString: String(target[1])),
            try await connections().contains(where: { $0.id.rawValue == id })
        {
            await session.connections.loadConnections()
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            session.connections.selectConnection(.init(rawValue: id))
            session.focusedConnectionID = .init(rawValue: id)
        }
        guard !stopped else { throw ExtensionPeerError.unavailable }
        ExtensionPresentation.showWindow()
    }
}
