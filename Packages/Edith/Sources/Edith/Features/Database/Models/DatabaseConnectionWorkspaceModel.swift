import AppKit
import EdithDatabase
import Foundation
import Observation

struct DatabaseConnectionSummary: Identifiable, Equatable, Sendable {
    let id: DatabaseConnectionID
    let name: String
    let product: DatabaseProduct
    let environmentKind: DatabaseEnvironmentKind
    let environmentLabel: String
    let environmentProtection: DatabaseEnvironmentProtection
    let readOnlyPolicy: DatabaseReadOnlyPolicy
    let productionPolicy: DatabaseProductionPolicy
    let groupIdentity: String?
    let group: String?
    let tags: [String]
    let color: String?
    let isFavorite: Bool
    let lastUsedAt: Date?
    let defaultDatabase: String?
    let defaultSchema: String?
    let logicalDatabase: String?
    let networkEndpoints: [DatabaseNetworkEndpoint]

    init(definition: DatabaseConnectionDefinition) {
        id = definition.id
        name = DatabaseConnectionDisplayText.rendered(
            definition.displayName,
            fallback: "Untitled connection")
        product = definition.productHint
        environmentKind = definition.environment.kind
        environmentLabel = DatabaseConnectionDisplayText.rendered(
            definition.environment.label,
            fallback: definition.environment.kind.title)
        environmentProtection = definition.environment.protection
        readOnlyPolicy = definition.readOnlyPolicy
        productionPolicy = definition.productionPolicy
        groupIdentity = definition.group
        group = DatabaseConnectionDisplayText.optional(definition.group)
        tags = definition.tags.prefix(8).map {
            DatabaseConnectionDisplayText.rendered($0, fallback: "Tag", limit: 96)
        }
        color = DatabaseConnectionDisplayText.optional(definition.color)
        isFavorite = definition.isFavorite
        lastUsedAt = definition.lastUsedAt
        defaultDatabase = DatabaseConnectionDisplayText.optional(definition.namespaces.database)
        defaultSchema = DatabaseConnectionDisplayText.optional(definition.namespaces.schema)
        logicalDatabase = DatabaseConnectionDisplayText.optional(
            definition.namespaces.logicalDatabase)
        switch definition.location {
        case .network(let endpoints):
            networkEndpoints = endpoints
        case .sqlite, .memory:
            networkEndpoints = []
        }
    }

    var environmentSummary: String {
        "\(environmentKind.title), \(environmentLabel), \(environmentProtection.title)"
    }

    var readOnlySummary: String {
        readOnlyPolicy.title
    }

    var productionSummary: String {
        productionPolicy.title
    }
}

struct DatabaseConnectionGroupOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let label: String
}

enum DatabaseConnectionDataQuality: Equatable, Sendable {
    case complete
    case partial
    case stale

    var title: String {
        switch self {
        case .complete: "Current"
        case .partial: "Partial"
        case .stale: "Stale"
        }
    }
}

enum DatabaseConnectionListState: Equatable, Sendable {
    case idle
    case loading([DatabaseConnectionSummary])
    case empty
    case filteredEmpty(String)
    case loaded([DatabaseConnectionSummary])
    case partial([DatabaseConnectionSummary])
    case stale([DatabaseConnectionSummary])
    case failed([DatabaseConnectionSummary], String)

    var connections: [DatabaseConnectionSummary] {
        switch self {
        case .idle, .empty, .filteredEmpty:
            []
        case .loading(let connections), .loaded(let connections), .partial(let connections),
            .stale(let connections), .failed(let connections, _):
            connections
        }
    }
}

struct DatabaseConnectedSessionSummary: Equatable, Sendable {
    let connectionID: DatabaseConnectionID
    let connectionName: String
    let environmentKind: DatabaseEnvironmentKind
    let environmentLabel: String
    let environmentProtection: DatabaseEnvironmentProtection
    let product: DatabaseProduct
    let version: String?
    let distribution: String?
    let topology: DatabaseTopologyKind
    let connectedAt: Date

    init(result: DatabaseConnectResult) {
        connectionID = result.connection.id
        connectionName = DatabaseConnectionDisplayText.rendered(
            result.connection.displayName,
            fallback: "Untitled connection")
        environmentKind = result.connection.environment.kind
        environmentLabel = DatabaseConnectionDisplayText.rendered(
            result.connection.environment.label,
            fallback: result.connection.environment.kind.title)
        environmentProtection = result.connection.environment.protection
        product = result.productIdentity.product
        version = DatabaseConnectionDisplayText.optional(result.productIdentity.version?.string)
        distribution = DatabaseConnectionDisplayText.optional(result.productIdentity.distribution)
        topology = result.productIdentity.topology.kind
        connectedAt = result.connectedAt
    }
}

enum DatabaseConnectionSessionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(DatabaseConnectedSessionSummary, DatabaseConnectionDataQuality)
    case disconnecting(DatabaseConnectedSessionSummary?)
    case failed(String, DatabaseConnectedSessionSummary?)
    case outcomeUnknown(String, DatabaseConnectedSessionSummary?)

    var connectedSession: DatabaseConnectedSessionSummary? {
        switch self {
        case .connected(let session, _):
            session
        case .disconnecting(let session), .failed(_, let session), .outcomeUnknown(_, let session):
            session
        case .disconnected, .connecting:
            nil
        }
    }
}

struct DatabaseCapabilitySummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let availability: DatabaseCapabilityAvailability
    let unavailableReason: String?

    var availabilityTitle: String {
        switch availability {
        case .available: "Available"
        case .degraded: "Degraded"
        case .unavailable: "Unavailable"
        case .planned: "Planned"
        }
    }
}

enum DatabaseCapabilitySourceSummary: Equatable, Sendable {
    case connection
    case cached
    case discovered

    var title: String {
        switch self {
        case .connection: "Connection"
        case .cached: "Cached"
        case .discovered: "Discovered"
        }
    }
}

struct DatabaseCapabilitySnapshot: Equatable, Sendable {
    let product: DatabaseProduct
    let version: String?
    let topology: DatabaseTopologyKind
    let capabilities: [DatabaseCapabilitySummary]
    let safetyLimitations: [String]
    let source: DatabaseCapabilitySourceSummary
    let discoveredAt: Date
    let expiresAt: Date?

    init(report: DatabaseCapabilityReport, source: DatabaseCapabilitySourceSummary) {
        product = report.productIdentity.product
        version = DatabaseConnectionDisplayText.optional(report.productIdentity.version?.string)
        topology = report.productIdentity.topology.kind
        capabilities = report.capabilities.prefix(64).enumerated().map { index, status in
            let name = DatabaseConnectionDisplayText.rendered(
                status.id.rawValue,
                fallback: "Capability")
            return DatabaseCapabilitySummary(
                id: "\(index):\(name)",
                name: name,
                availability: status.availability,
                unavailableReason: DatabaseConnectionDisplayText.optional(status.reason?.message))
        }
        safetyLimitations = report.safetyLimitations.prefix(12).map {
            DatabaseConnectionDisplayText.rendered($0, fallback: "Safety limitation")
        }
        self.source = source
        discoveredAt = report.discoveredAt
        expiresAt = report.expiresAt
    }

    var availableCount: Int {
        capabilities.count { $0.availability == .available }
    }

    var degradedCount: Int {
        capabilities.count { $0.availability == .degraded }
    }

    var unavailableCount: Int {
        capabilities.count {
            $0.availability == .unavailable || $0.availability == .planned
        }
    }
}

enum DatabaseCapabilityState: Equatable, Sendable {
    case unavailable
    case refreshing(DatabaseCapabilitySnapshot?, DatabaseConnectionDataQuality?)
    case loaded(DatabaseCapabilitySnapshot, DatabaseConnectionDataQuality)
    case failed(
        String,
        DatabaseCapabilitySnapshot?,
        DatabaseConnectionDataQuality?)

    var snapshot: DatabaseCapabilitySnapshot? {
        switch self {
        case .unavailable:
            nil
        case .loaded(let snapshot, _):
            snapshot
        case .refreshing(let snapshot, _), .failed(_, let snapshot, _):
            snapshot
        }
    }
}

@MainActor
@Observable
final class DatabaseConnectionWorkspaceModel {
    var searchText = ""
    var favoritesOnly = false
    var selectedGroup: String?
    private(set) var listState = DatabaseConnectionListState.idle
    private(set) var selectedConnectionID: DatabaseConnectionID?

    private let sender: any DatabaseBrokerCommandSending
    private let currentDate: @Sendable () -> Date
    private let announcement: @MainActor (String) -> Void
    private let prepareConnection:
        @MainActor @Sendable (DatabaseConnectionSummary) async throws -> Void
    private var summariesByID: [DatabaseConnectionID: DatabaseConnectionSummary] = [:]
    private var sessionStates: [DatabaseConnectionID: DatabaseConnectionSessionState] = [:]
    private var capabilityStates: [DatabaseConnectionID: DatabaseCapabilityState] = [:]
    private var sessionGenerations: [DatabaseConnectionID: UUID] = [:]
    private var capabilityGenerations: [DatabaseConnectionID: UUID] = [:]
    private var listGeneration = UUID()

    init(
        sender: any DatabaseBrokerCommandSending = DatabaseBrokerCommandClient(),
        currentDate: @escaping @Sendable () -> Date = { Date() },
        prepareConnection:
            @escaping @MainActor @Sendable (DatabaseConnectionSummary) async throws -> Void =
            { summary in try await DatabaseMachineForwardRouter.prepare(summary) },
        announcement: @escaping @MainActor (String) -> Void =
            DatabaseConnectionWorkspaceModel.announce
    ) {
        self.sender = sender
        self.currentDate = currentDate
        self.prepareConnection = prepareConnection
        self.announcement = announcement
    }

    var visibleConnections: [DatabaseConnectionSummary] {
        listState.connections
    }

    var availableGroups: [DatabaseConnectionGroupOption] {
        let groups = summariesByID.values.reduce(
            into: [String: DatabaseConnectionGroupOption]()
        ) { result, summary in
            guard let identity = summary.groupIdentity, let label = summary.group else { return }
            result[identity] = DatabaseConnectionGroupOption(id: identity, label: label)
        }
        return groups.values.sorted {
            let labelOrder = $0.label.localizedStandardCompare($1.label)
            if labelOrder == .orderedSame {
                return $0.id < $1.id
            }
            return labelOrder == .orderedAscending
        }
    }

    var selectedConnection: DatabaseConnectionSummary? {
        guard let selectedConnectionID else { return nil }
        return summariesByID[selectedConnectionID]
    }

    var selectedSessionState: DatabaseConnectionSessionState {
        guard let selectedConnectionID else { return .disconnected }
        return sessionState(for: selectedConnectionID)
    }

    var selectedCapabilityState: DatabaseCapabilityState {
        guard let selectedConnectionID else { return .unavailable }
        return capabilityState(for: selectedConnectionID)
    }

    func sessionState(for connectionID: DatabaseConnectionID) -> DatabaseConnectionSessionState {
        sessionStates[connectionID] ?? .disconnected
    }

    func capabilityState(for connectionID: DatabaseConnectionID) -> DatabaseCapabilityState {
        capabilityStates[connectionID] ?? .unavailable
    }

    func selectConnection(_ connectionID: DatabaseConnectionID) {
        guard summariesByID[connectionID] != nil else { return }
        selectedConnectionID = connectionID
        announcement("Selected \(summariesByID[connectionID]?.name ?? "database connection").")
    }

    func clearFilters() {
        searchText = ""
        favoritesOnly = false
        selectedGroup = nil
    }

    func selectSavedConnection(_ connection: DatabaseConnectionDefinition) {
        listGeneration = UUID()
        let summary = DatabaseConnectionSummary(definition: connection)
        summariesByID[connection.id] = summary
        selectedConnectionID = connection.id
        announcement("Selected \(summary.name).")
    }

    func applyManagedConnection(
        _ connection: DatabaseConnectionDefinition,
        disconnectsSession: Bool
    ) {
        listGeneration = UUID()
        let summary = DatabaseConnectionSummary(definition: connection)
        summariesByID[connection.id] = summary
        if disconnectsSession {
            invalidateManagedConnectionSession(connection.id)
        }
        replaceVisibleConnection(summary)
        announcement("Updated \(summary.name).")
    }

    func invalidateManagedConnectionSession(_ connectionID: DatabaseConnectionID) {
        sessionGenerations[connectionID] = UUID()
        capabilityGenerations[connectionID] = UUID()
        sessionStates[connectionID] = .disconnected
        capabilityStates[connectionID] = .unavailable
    }

    func applyDuplicatedConnection(_ connection: DatabaseConnectionDefinition) {
        listGeneration = UUID()
        let summary = DatabaseConnectionSummary(definition: connection)
        summariesByID[connection.id] = summary
        let current = listState.connections
        guard !current.contains(where: { $0.id == connection.id }) else { return }
        setVisibleConnections(current + [summary])
        announcement("Created \(summary.name).")
    }

    @discardableResult
    func removeManagedConnection(_ connectionID: DatabaseConnectionID) -> DatabaseConnectionID? {
        listGeneration = UUID()
        let current = listState.connections
        let removedIndex = current.firstIndex { $0.id == connectionID }
        let remaining = current.filter { $0.id != connectionID }
        summariesByID[connectionID] = nil
        sessionGenerations[connectionID] = UUID()
        capabilityGenerations[connectionID] = UUID()
        sessionStates[connectionID] = nil
        capabilityStates[connectionID] = nil
        if selectedConnectionID == connectionID {
            selectedConnectionID = remaining.first?.id
        }
        setVisibleConnections(remaining)
        announcement("Removed database connection.")
        guard let removedIndex, !remaining.isEmpty else { return remaining.first?.id }
        return remaining[min(removedIndex, remaining.count - 1)].id
    }

    func loadConnections() async {
        let generation = UUID()
        listGeneration = generation
        let priorState = listState
        let previous = listState.connections
        let search = normalizedSearch
        listState = .loading(previous)
        announcement("Loading saved database connections.")

        do {
            let response = try await sender.send(
                .connectionList(
                    DatabaseConnectionListRequest(
                        search: DatabaseConnectionSearch(
                            text: search,
                            group: selectedGroup,
                            favoritesOnly: favoritesOnly,
                            order: .recentlyUsed,
                            limit: 100))))
            try Task.checkCancellation()
            guard listGeneration == generation else { return }
            finishConnectionList(response)
        } catch is CancellationError {
            guard listGeneration == generation else { return }
            listState = priorState
        } catch {
            guard listGeneration == generation else { return }
            let message = Self.message(for: error, action: .list)
            listState = .failed(previous, message)
            announcement(message)
        }
    }

    func connectSelected() async {
        guard let connectionID = selectedConnectionID else { return }
        let priorState = sessionState(for: connectionID)
        guard !priorState.isBusy else { return }
        if case .connected = priorState { return }

        let generation = UUID()
        sessionGenerations[connectionID] = generation
        sessionStates[connectionID] = .connecting
        announcement("Connecting to \(connectionName(for: connectionID)).")

        do {
            guard let summary = summariesByID[connectionID] else { return }
            try await prepareConnection(summary)
            try Task.checkCancellation()
            let response = try await sender.send(
                .connect(DatabaseConnectRequest(connectionID: connectionID)))
            try Task.checkCancellation()
            guard sessionGenerations[connectionID] == generation else { return }
            finishConnect(response, connectionID: connectionID)
        } catch is CancellationError {
            guard sessionGenerations[connectionID] == generation else { return }
            sessionStates[connectionID] = priorState
        } catch {
            guard sessionGenerations[connectionID] == generation else { return }
            let message = Self.message(for: error, action: .connect)
            if error as? DatabaseBrokerCommandClientError == .outcomeUnknown {
                sessionStates[connectionID] = .outcomeUnknown(
                    message,
                    priorState.connectedSession)
            } else {
                sessionStates[connectionID] = .failed(message, priorState.connectedSession)
            }
            announcement(message)
        }
    }

    func disconnectSelected() async {
        guard let connectionID = selectedConnectionID else { return }
        let priorState = sessionState(for: connectionID)
        guard !priorState.isBusy else { return }
        guard priorState.canDisconnect else { return }

        let generation = UUID()
        sessionGenerations[connectionID] = generation
        sessionStates[connectionID] = .disconnecting(priorState.connectedSession)
        announcement("Disconnecting \(connectionName(for: connectionID)).")

        do {
            let response = try await sender.send(
                .disconnect(DatabaseDisconnectRequest(connectionID: connectionID)))
            try Task.checkCancellation()
            guard sessionGenerations[connectionID] == generation else { return }
            finishDisconnect(response, connectionID: connectionID, priorState: priorState)
        } catch is CancellationError {
            guard sessionGenerations[connectionID] == generation else { return }
            sessionStates[connectionID] = priorState
        } catch {
            guard sessionGenerations[connectionID] == generation else { return }
            let message = Self.message(for: error, action: .disconnect)
            if error as? DatabaseBrokerCommandClientError == .outcomeUnknown {
                sessionStates[connectionID] = .outcomeUnknown(
                    message,
                    priorState.connectedSession)
            } else {
                sessionStates[connectionID] = .failed(message, priorState.connectedSession)
            }
            announcement(message)
        }
    }

    func refreshSelectedCapabilities() async {
        guard let connectionID = selectedConnectionID else { return }
        guard sessionState(for: connectionID).connectedSession != nil else { return }
        let priorState = capabilityState(for: connectionID)
        let generation = UUID()
        capabilityGenerations[connectionID] = generation
        capabilityStates[connectionID] = .refreshing(priorState.snapshot, priorState.quality)
        announcement("Refreshing database capabilities.")

        do {
            let response = try await sender.send(
                .capabilities(
                    DatabaseCapabilitiesRequest(
                        connectionID: connectionID,
                        resolution: .refresh)))
            try Task.checkCancellation()
            guard capabilityGenerations[connectionID] == generation else { return }
            finishCapabilities(response, connectionID: connectionID)
        } catch is CancellationError {
            guard capabilityGenerations[connectionID] == generation else { return }
            capabilityStates[connectionID] = priorState
        } catch {
            guard capabilityGenerations[connectionID] == generation else { return }
            let message = Self.message(for: error, action: .capabilities)
            capabilityStates[connectionID] = .failed(
                message,
                priorState.snapshot,
                priorState.quality)
            announcement(message)
        }
    }

    private var normalizedSearch: String? {
        let value = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : DatabaseConnectionDisplayText.rendered(value, fallback: "")
    }

    private func finishConnectionList(_ response: DatabaseBrokerCommandResponse) {
        guard case .connectionList(let result) = response else {
            let message = "The database service returned an unexpected connection list response."
            listState = .failed(listState.connections, message)
            announcement(message)
            return
        }
        guard result.status != .failed, let payload = result.payload else {
            let message = Self.message(for: result.error, action: .list)
            listState = .failed(listState.connections, message)
            announcement(message)
            return
        }

        let connections = payload.connections.map(DatabaseConnectionSummary.init(definition:))
        for connection in connections {
            summariesByID[connection.id] = connection
        }
        reconcileSelection(connections)

        switch Self.quality(for: result) {
        case .partial:
            listState = .partial(connections)
            announcement("Saved database connections loaded with partial results.")
        case .stale:
            listState = .stale(connections)
            announcement("Saved database connections loaded from stale information.")
        case .complete:
            if connections.isEmpty, let filterDescription {
                listState = .filteredEmpty(filterDescription)
                announcement("No saved database connections matched the search.")
            } else if connections.isEmpty {
                listState = .empty
                announcement("No saved database connections are available.")
            } else {
                listState = .loaded(connections)
                announcement("\(connections.count) saved database connections loaded.")
            }
        }
    }

    private func finishConnect(
        _ response: DatabaseBrokerCommandResponse,
        connectionID: DatabaseConnectionID
    ) {
        guard case .connect(let result) = response else {
            failSession(
                connectionID,
                message: "The database service returned an unexpected connection response.")
            return
        }
        guard result.status != .failed, let payload = result.payload else {
            failSession(connectionID, message: Self.message(for: result.error, action: .connect))
            return
        }
        guard payload.connection.id == connectionID else {
            failSession(
                connectionID, message: "The database service returned a different connection.")
            return
        }
        guard payload.productIdentity.product == payload.capabilities.productIdentity.product else {
            failSession(
                connectionID,
                message: "The database service returned inconsistent database capabilities.")
            return
        }

        let session = DatabaseConnectedSessionSummary(result: payload)
        let snapshot = DatabaseCapabilitySnapshot(
            report: payload.capabilities,
            source: .connection)
        let quality = Self.quality(
            for: result,
            expiresAt: snapshot.expiresAt,
            currentDate: currentDate())
        sessionStates[connectionID] = .connected(session, quality)
        capabilityStates[connectionID] = .loaded(snapshot, quality)
        announcement("Connected to \(session.connectionName).")
    }

    private func finishDisconnect(
        _ response: DatabaseBrokerCommandResponse,
        connectionID: DatabaseConnectionID,
        priorState: DatabaseConnectionSessionState
    ) {
        guard case .disconnect(let result) = response else {
            failSession(
                connectionID,
                message: "The database service returned an unexpected disconnect response.",
                previous: priorState.connectedSession)
            return
        }
        guard result.status != .failed, let payload = result.payload else {
            failSession(
                connectionID,
                message: Self.message(for: result.error, action: .disconnect),
                previous: priorState.connectedSession)
            return
        }
        guard payload.connection.id == connectionID, payload.disconnected else {
            failSession(
                connectionID,
                message: "The database service did not confirm the database disconnection.",
                previous: priorState.connectedSession)
            return
        }

        sessionStates[connectionID] = .disconnected
        capabilityStates[connectionID] = .unavailable
        announcement("Disconnected \(connectionName(for: connectionID)).")
    }

    private func finishCapabilities(
        _ response: DatabaseBrokerCommandResponse,
        connectionID: DatabaseConnectionID
    ) {
        let previous = capabilityState(for: connectionID)
        guard case .capabilities(let result) = response else {
            failCapabilities(
                connectionID,
                message: "The database service returned an unexpected capability response.",
                previous: previous)
            return
        }
        guard result.status != .failed, let payload = result.payload else {
            failCapabilities(
                connectionID,
                message: Self.message(for: result.error, action: .capabilities),
                previous: previous)
            return
        }
        if let product = sessionState(for: connectionID).connectedSession?.product,
            product != payload.report.productIdentity.product
        {
            failCapabilities(
                connectionID,
                message:
                    "The database service returned capabilities for a different database product.",
                previous: previous)
            return
        }

        let source: DatabaseCapabilitySourceSummary =
            payload.source == .cached ? .cached : .discovered
        let snapshot = DatabaseCapabilitySnapshot(report: payload.report, source: source)
        let quality = Self.quality(
            for: result,
            expiresAt: snapshot.expiresAt,
            currentDate: currentDate())
        capabilityStates[connectionID] = .loaded(snapshot, quality)
        announcement("Database capabilities refreshed with \(quality.title.lowercased()) data.")
    }

    private func failSession(
        _ connectionID: DatabaseConnectionID,
        message: String,
        previous: DatabaseConnectedSessionSummary? = nil
    ) {
        sessionStates[connectionID] = .failed(message, previous)
        announcement(message)
    }

    private func failCapabilities(
        _ connectionID: DatabaseConnectionID,
        message: String,
        previous: DatabaseCapabilityState
    ) {
        capabilityStates[connectionID] = .failed(
            message,
            previous.snapshot,
            previous.quality)
        announcement(message)
    }

    private func reconcileSelection(_ connections: [DatabaseConnectionSummary]) {
        if let selectedConnectionID,
            connections.contains(where: { $0.id == selectedConnectionID })
        {
            return
        }
        if let first = connections.first {
            selectedConnectionID = first.id
        } else if !hasActiveFilters {
            selectedConnectionID = nil
        }
    }

    private var hasActiveFilters: Bool {
        normalizedSearch != nil || favoritesOnly || selectedGroup != nil
    }

    private var filterDescription: String? {
        let values = [
            normalizedSearch,
            favoritesOnly ? "favorites" : nil,
            DatabaseConnectionDisplayText.optional(selectedGroup).map { "group \($0)" },
        ].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private func replaceVisibleConnection(_ connection: DatabaseConnectionSummary) {
        let current = listState.connections
        let updated = current.map { $0.id == connection.id ? connection : $0 }
        if updated == current, !current.contains(where: { $0.id == connection.id }) {
            setVisibleConnections(current + [connection])
        } else {
            setVisibleConnections(updated)
        }
    }

    private func setVisibleConnections(_ connections: [DatabaseConnectionSummary]) {
        switch listState {
        case .idle, .empty, .filteredEmpty, .loaded:
            listState = connections.isEmpty ? .empty : .loaded(connections)
        case .loading:
            listState = .loading(connections)
        case .partial:
            listState = .partial(connections)
        case .stale:
            listState = .stale(connections)
        case .failed(_, let message):
            listState = .failed(connections, message)
        }
    }

    private func connectionName(for connectionID: DatabaseConnectionID) -> String {
        summariesByID[connectionID]?.name ?? "database connection"
    }

    private static func quality<Payload>(
        for result: DatabaseCommandResult<Payload>,
        expiresAt: Date? = nil,
        currentDate: Date = Date()
    ) -> DatabaseConnectionDataQuality {
        if result.metadata.completeness.state == .stale
            || expiresAt.map({ $0 <= currentDate }) == true
        {
            return .stale
        }
        if result.status == .partiallySucceeded
            || !result.metadata.partialFailures.isEmpty
            || result.metadata.completeness.state != .complete
        {
            return .partial
        }
        return .complete
    }

    private static func message(
        for error: Error,
        action: DatabaseConnectionAction
    ) -> String {
        if let routingError = error as? DatabaseMachineForwardRoutingError {
            return routingError.errorDescription ?? action.genericFailure
        }
        guard let clientError = error as? DatabaseBrokerCommandClientError else {
            return action.genericFailure
        }
        switch clientError {
        case .invalidRequest:
            return "The database service rejected the database \(action.requestName)."
        case .timedOut:
            return "The database \(action.requestName) timed out."
        case .unavailable:
            return "The local database service is unavailable."
        case .unsafePeer:
            return "The local database service could not be verified."
        case .outcomeUnknown:
            return "The database \(action.requestName) outcome is unknown."
        }
    }

    private static func message(
        for error: DatabaseErrorEnvelope?,
        action: DatabaseConnectionAction
    ) -> String {
        guard let error else { return action.genericFailure }
        switch error.category {
        case .invalidRequest:
            return "The database service rejected the database \(action.requestName)."
        case .connectionFailed, .network, .server:
            return action.genericFailure
        case .authenticationFailed:
            return "Database authentication failed."
        case .tlsFailed:
            return "Secure database connection setup failed."
        case .tunnelFailed:
            return "The database tunnel could not be established."
        case .permissionDenied:
            return "The database account does not have permission for this request."
        case .unsupported:
            return "The database does not support this request."
        case .readOnlyViolation:
            return "The connection is read-only."
        case .timeout:
            return "The database \(action.requestName) timed out."
        case .cancelled:
            return "The database \(action.requestName) was cancelled."
        case .partialFailure:
            return "The database returned a partial result."
        case .resourceLimit:
            return "The database request exceeded a configured resource limit."
        case .confirmationRequired, .confirmationInvalid, .conflict, .decoding,
            .internalFailure:
            return action.genericFailure
        }
    }

    private static func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }
}

private enum DatabaseConnectionAction {
    case list
    case connect
    case disconnect
    case capabilities

    var requestName: String {
        switch self {
        case .list: "connection list request"
        case .connect: "connection request"
        case .disconnect: "disconnect request"
        case .capabilities: "capability request"
        }
    }

    var genericFailure: String {
        switch self {
        case .list: "Saved database connections could not be loaded."
        case .connect: "The database connection could not be completed."
        case .disconnect: "The database could not be disconnected."
        case .capabilities: "Database capabilities could not be refreshed."
        }
    }
}

private extension DatabaseConnectionSessionState {
    var isBusy: Bool {
        switch self {
        case .connecting, .disconnecting:
            true
        case .disconnected, .connected, .failed, .outcomeUnknown:
            false
        }
    }

    var canDisconnect: Bool {
        switch self {
        case .connected, .outcomeUnknown:
            true
        case .failed(_, let previous):
            previous != nil
        case .disconnected, .connecting, .disconnecting:
            false
        }
    }
}

private extension DatabaseCapabilityState {
    var quality: DatabaseConnectionDataQuality? {
        switch self {
        case .unavailable:
            nil
        case .loaded(_, let quality):
            quality
        case .refreshing(_, let quality), .failed(_, _, let quality):
            quality
        }
    }
}

extension DatabaseEnvironmentKind {
    var title: String {
        switch self {
        case .local: "Local"
        case .development: "Development"
        case .testing: "Testing"
        case .staging: "Staging"
        case .production: "Production"
        case .other: "Other"
        }
    }
}

extension DatabaseEnvironmentProtection {
    var title: String {
        switch self {
        case .standard: "Standard protection"
        case .confirmationRequired: "Confirmation required"
        case .readOnly: "Read-only environment"
        }
    }
}

extension DatabaseReadOnlyPolicy {
    var title: String {
        switch self {
        case .disabled: "Read and write"
        case .preferred: "Read-only preferred"
        case .required: "Read-only required"
        }
    }
}

extension DatabaseProductionPolicy {
    var title: String {
        switch self {
        case .standard: "Standard mutation policy"
        case .requireMutationPreview: "Mutation preview required"
        case .prohibitMutations: "Mutations prohibited"
        }
    }
}

extension DatabaseTopologyKind {
    var title: String {
        switch self {
        case .unknown: "Unknown"
        case .embedded: "Embedded"
        case .standalone: "Standalone"
        case .primaryReplica: "Primary and replica"
        case .sentinel: "Sentinel"
        case .cluster: "Cluster"
        case .replicaSet: "Replica set"
        case .shardedCluster: "Sharded cluster"
        case .distributed: "Distributed"
        }
    }
}

private enum DatabaseConnectionDisplayText {
    static func optional(_ value: String?, limit: Int = 160) -> String? {
        guard let value else { return nil }
        let rendered = rendered(value, fallback: "", limit: limit)
        return rendered.isEmpty ? nil : rendered
    }

    static func rendered(_ value: String, fallback: String, limit: Int = 160) -> String {
        var output = ""
        output.reserveCapacity(min(value.count, limit))
        for scalar in value.unicodeScalars {
            if shouldEscape(scalar) {
                output += String(format: "\\u{%04X}", scalar.value)
            } else {
                output.unicodeScalars.append(scalar)
            }
            if output.count >= limit {
                break
            }
        }
        let bounded = output.count > limit ? String(output.prefix(limit - 1)) + "…" : output
        let trimmed = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func shouldEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            true
        default:
            false
        }
    }
}
