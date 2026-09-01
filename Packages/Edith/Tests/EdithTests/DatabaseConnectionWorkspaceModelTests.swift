import Foundation
import Testing

@testable import Edith
@testable import EdithDatabase

@MainActor
@Suite struct DatabaseConnectionWorkspaceModelTests {
    @Test func completeListProjectsOnlySafeDisplayFieldsAndSearch() async throws {
        let connection = try Self.connection(
            id: 1,
            name: "Primary\norders\u{202E}",
            tags: (0..<12).map { "tag-\($0)" })
        let sender = DatabaseConnectionScriptedSender()
        await sender.succeed(Self.listResponse([connection]), at: 0)
        let model = Self.model(sender)
        model.searchText = "orders"

        await model.loadConnections()

        guard case .loaded(let connections) = model.listState else {
            Issue.record("Expected a complete connection list.")
            return
        }
        let summary = try #require(connections.first)
        #expect(summary.name == "Primary\\u{000A}orders\\u{202E}")
        #expect(summary.product == .postgresql)
        #expect(summary.environmentKind == .production)
        #expect(summary.environmentLabel == "customer-a")
        #expect(summary.environmentProtection == .confirmationRequired)
        #expect(summary.readOnlyPolicy == .required)
        #expect(summary.productionPolicy == .requireMutationPreview)
        #expect(summary.group == "payments")
        #expect(summary.tags.count == 8)
        #expect(summary.isFavorite)
        #expect(model.selectedConnectionID == connection.id)

        let requests = await sender.recordedRequests()
        let request = try #require(requests.first?.connectionListRequest)
        #expect(request.search.text == "orders")
        #expect(request.search.order == .recentlyUsed)
        #expect(request.search.limit == 100)
        #expect(request.search.offset == 0)
    }

    @Test func completeEmptyListDistinguishesInitialAndFilteredResults() async {
        let sender = DatabaseConnectionScriptedSender()
        await sender.succeed(Self.listResponse([]), at: 0)
        await sender.succeed(Self.listResponse([]), at: 1)
        let model = Self.model(sender)

        await model.loadConnections()
        #expect(model.listState == .empty)

        model.searchText = "missing"
        await model.loadConnections()
        #expect(model.listState == .filteredEmpty("missing"))
    }

    @Test func connectionListLabelsPartialAndStaleBrokerResults() async throws {
        let connection = try Self.connection(id: 2, name: "Analytics")
        let sender = DatabaseConnectionScriptedSender()
        await sender.succeed(
            Self.listResponse(
                [connection],
                status: .partiallySucceeded,
                completeness: .partial),
            at: 0)
        await sender.succeed(
            Self.listResponse([connection], completeness: .stale),
            at: 1)
        let model = Self.model(sender)

        await model.loadConnections()
        guard case .partial(let partial) = model.listState else {
            Issue.record("Expected a partial connection list.")
            return
        }
        #expect(partial.map(\.id) == [connection.id])

        await model.loadConnections()
        guard case .stale(let stale) = model.listState else {
            Issue.record("Expected a stale connection list.")
            return
        }
        #expect(stale.map(\.id) == [connection.id])
    }

    @Test func staleConnectionListResponseCannotReplaceNewSearch() async throws {
        let oldConnection = try Self.connection(id: 3, name: "Old result")
        let newConnection = try Self.connection(id: 4, name: "New result")
        let sender = DatabaseConnectionScriptedSender()
        let model = Self.model(sender)
        model.searchText = "old"

        let first = Task { @MainActor in await model.loadConnections() }
        await sender.waitUntilRequested(1)
        model.searchText = "new"
        let second = Task { @MainActor in await model.loadConnections() }
        await sender.waitUntilRequested(2)

        await sender.succeed(Self.listResponse([newConnection]), at: 1)
        await second.value
        await sender.succeed(Self.listResponse([oldConnection]), at: 0)
        await first.value

        guard case .loaded(let connections) = model.listState else {
            Issue.record("Expected the newest connection list.")
            return
        }
        #expect(connections.map(\.id) == [newConnection.id])
        #expect(model.selectedConnectionID == newConnection.id)
        let requests = await sender.recordedRequests()
        #expect(requests[0].connectionListRequest?.search.text == "old")
        #expect(requests[1].connectionListRequest?.search.text == "new")
    }

    @Test func savedConnectionSelectionSurvivesAnOverlappingSearchReload() async throws {
        let existing = try Self.connection(id: 31, name: "Existing")
        let saved = try Self.connection(id: 32, name: "Newly saved")
        let sender = DatabaseConnectionScriptedSender()
        await sender.succeed(Self.listResponse([existing]), at: 0)
        let model = Self.model(sender)
        await model.loadConnections()
        model.searchText = "old"

        let oldReload = Task { @MainActor in await model.loadConnections() }
        await sender.waitUntilRequested(2)
        model.selectSavedConnection(saved)

        #expect(model.selectedConnectionID == saved.id)
        #expect(model.selectedConnection?.name == "Newly saved")

        await sender.succeed(Self.listResponse([existing]), at: 1)
        await oldReload.value

        #expect(model.selectedConnectionID == saved.id)
        #expect(model.selectedConnection?.name == "Newly saved")

        model.searchText = ""
        let currentReload = Task { @MainActor in await model.loadConnections() }
        await sender.waitUntilRequested(3)
        await sender.succeed(Self.listResponse([existing, saved]), at: 2)
        await currentReload.value

        #expect(model.selectedConnectionID == saved.id)
        #expect(model.visibleConnections.map(\.id) == [existing.id, saved.id])
    }

    @Test func loadingAndFailureKeepPreviouslyLoadedConnectionsVisible() async throws {
        let connection = try Self.connection(id: 10, name: "Retained")
        let sender = DatabaseConnectionScriptedSender()
        await sender.succeed(Self.listResponse([connection]), at: 0)
        let model = Self.model(sender)

        await model.loadConnections()
        let reload = Task { @MainActor in await model.loadConnections() }
        await sender.waitUntilRequested(2)

        guard case .loading(let loading) = model.listState else {
            Issue.record("Expected a loading connection list.")
            return
        }
        #expect(loading.map(\.id) == [connection.id])

        await sender.fail(.unavailable, at: 1)
        await reload.value

        guard case .failed(let retained, let message) = model.listState else {
            Issue.record("Expected a failed connection list with retained data.")
            return
        }
        #expect(retained.map(\.id) == [connection.id])
        #expect(message == "The local database service is unavailable.")
    }

    @Test func selectionNeverAutoConnectsAndSessionFailuresStayIsolated() async throws {
        let primary = try Self.connection(id: 5, name: "Primary")
        let reporting = try Self.connection(id: 6, name: "Reporting", product: .redis)
        let primaryReport = Self.capabilityReport(product: .postgresql, version: "17.4")
        let sender = DatabaseConnectionScriptedSender()
        await sender.succeed(Self.listResponse([primary, reporting]), at: 0)
        await sender.succeed(Self.connectResponse(primary, report: primaryReport), at: 1)
        await sender.fail(.unavailable, at: 2)
        let model = Self.model(sender)

        await model.loadConnections()
        model.selectConnection(primary.id)
        #expect((await sender.recordedRequests()).count == 1)

        await model.connectSelected()
        guard case .connected(let session, let quality) = model.sessionState(for: primary.id)
        else {
            Issue.record("Expected the primary connection to be connected.")
            return
        }
        #expect(session.connectionID == primary.id)
        #expect(session.product == .postgresql)
        #expect(session.version == "17.4")
        #expect(quality == .complete)
        guard
            case .loaded(let snapshot, let capabilityQuality) =
                model.capabilityState(for: primary.id)
        else {
            Issue.record("Expected capabilities from the connection response.")
            return
        }
        #expect(snapshot.capabilities.count == 2)
        #expect(
            snapshot.capabilities.last?.unavailableReason
                == "DELETE permission is unavailable.")
        #expect(capabilityQuality == .complete)

        model.selectConnection(reporting.id)
        #expect((await sender.recordedRequests()).count == 2)
        await model.connectSelected()
        guard case .failed(let message, nil) = model.sessionState(for: reporting.id) else {
            Issue.record("Expected the reporting connection to fail independently.")
            return
        }
        #expect(message == "The local database service is unavailable.")
        #expect(model.sessionState(for: primary.id).connectedSession?.connectionID == primary.id)

        let requests = await sender.recordedRequests()
        #expect(requests[1].connectRequest?.connectionID == primary.id)
        #expect(requests[2].connectRequest?.connectionID == reporting.id)
    }

    @Test func explicitDisconnectClearsOnlyTheSelectedSessionAndCapabilities() async throws {
        let connection = try Self.connection(id: 7, name: "Orders")
        let report = Self.capabilityReport(product: .postgresql, version: "17.4")
        let sender = DatabaseConnectionScriptedSender()
        await sender.succeed(Self.listResponse([connection]), at: 0)
        let model = Self.model(sender)

        await model.loadConnections()
        let connect = Task { @MainActor in await model.connectSelected() }
        await sender.waitUntilRequested(2)
        #expect(model.sessionState(for: connection.id) == .connecting)
        await sender.succeed(Self.connectResponse(connection, report: report), at: 1)
        await connect.value

        let disconnect = Task { @MainActor in await model.disconnectSelected() }
        await sender.waitUntilRequested(3)
        guard case .disconnecting(let previous) = model.sessionState(for: connection.id) else {
            Issue.record("Expected a disconnecting session.")
            return
        }
        #expect(previous?.connectionID == connection.id)
        await sender.succeed(Self.disconnectResponse(connection), at: 2)
        await disconnect.value

        #expect(model.sessionState(for: connection.id) == .disconnected)
        #expect(model.capabilityState(for: connection.id) == .unavailable)
        let requests = await sender.recordedRequests()
        #expect(requests[2].disconnectRequest?.connectionID == connection.id)
    }

    @Test func explicitCapabilityRefreshRejectsLateResultsAndLabelsQuality() async throws {
        let connection = try Self.connection(id: 8, name: "Warehouse")
        let connectedReport = Self.capabilityReport(product: .postgresql, version: "17.4")
        let oldReport = Self.capabilityReport(product: .postgresql, version: "16.9")
        let staleReport = Self.capabilityReport(product: .postgresql, version: "17.5")
        let partialReport = Self.capabilityReport(product: .postgresql, version: "17.6")
        let sender = DatabaseConnectionScriptedSender()
        await sender.succeed(Self.listResponse([connection]), at: 0)
        await sender.succeed(Self.connectResponse(connection, report: connectedReport), at: 1)
        let model = Self.model(sender)

        await model.loadConnections()
        await model.connectSelected()
        #expect((await sender.recordedRequests()).count == 2)

        let first = Task { @MainActor in await model.refreshSelectedCapabilities() }
        await sender.waitUntilRequested(3)
        guard
            case .refreshing(let retained, let retainedQuality) =
                model.selectedCapabilityState
        else {
            Issue.record("Expected capabilities to be refreshing.")
            return
        }
        #expect(retained?.version == "17.4")
        #expect(retainedQuality == .complete)
        let second = Task { @MainActor in await model.refreshSelectedCapabilities() }
        await sender.waitUntilRequested(4)
        await sender.succeed(
            Self.capabilitiesResponse(staleReport, completeness: .stale),
            at: 3)
        await second.value
        await sender.succeed(Self.capabilitiesResponse(oldReport), at: 2)
        await first.value

        guard case .loaded(let staleSnapshot, let staleQuality) = model.selectedCapabilityState
        else {
            Issue.record("Expected refreshed stale capabilities.")
            return
        }
        #expect(staleSnapshot.version == "17.5")
        #expect(staleQuality == .stale)

        await sender.succeed(
            Self.capabilitiesResponse(
                partialReport,
                status: .partiallySucceeded,
                completeness: .partial),
            at: 4)
        await model.refreshSelectedCapabilities()
        guard case .loaded(let partialSnapshot, let partialQuality) = model.selectedCapabilityState
        else {
            Issue.record("Expected refreshed partial capabilities.")
            return
        }
        #expect(partialSnapshot.version == "17.6")
        #expect(partialQuality == .partial)

        let requests = await sender.recordedRequests()
        #expect(requests[2].capabilitiesRequest?.resolution == .refresh)
        #expect(requests[3].capabilitiesRequest?.resolution == .refresh)
        #expect(requests[4].capabilitiesRequest?.resolution == .refresh)
    }

    @Test func unknownConnectOutcomeCanBeResolvedByExplicitDisconnect() async throws {
        let connection = try Self.connection(id: 9, name: "Uncertain")
        let sender = DatabaseConnectionScriptedSender()
        await sender.succeed(Self.listResponse([connection]), at: 0)
        await sender.fail(.outcomeUnknown, at: 1)
        await sender.succeed(Self.disconnectResponse(connection), at: 2)
        let model = Self.model(sender)

        await model.loadConnections()
        await model.connectSelected()
        guard case .outcomeUnknown(let message, nil) = model.selectedSessionState else {
            Issue.record("Expected an unknown connection outcome.")
            return
        }
        #expect(message == "The database connection request outcome is unknown.")

        await model.disconnectSelected()
        #expect(model.selectedSessionState == .disconnected)
    }

    @Test func connectionPreparationFailurePreventsBrokerConnect() async throws {
        let connection = try Self.connection(id: 11, name: "Forwarded")
        let sender = DatabaseConnectionScriptedSender()
        await sender.succeed(Self.listResponse([connection]), at: 0)
        let model = DatabaseConnectionWorkspaceModel(
            sender: sender,
            currentDate: { Date(timeIntervalSince1970: 8_000) },
            prepareConnection: { _ in
                throw DatabaseMachineForwardRoutingError.machineUnavailable(
                    "database PostgreSQL")
            },
            announcement: { _ in })

        await model.loadConnections()
        await model.connectSelected()

        guard case .failed(let message, nil) = model.selectedSessionState else {
            Issue.record("Expected connection preparation to fail.")
            return
        }
        #expect(message == "The machine for database PostgreSQL is unavailable.")
        #expect((await sender.recordedRequests()).count == 1)
    }

    private static let now = Date(timeIntervalSince1970: 8_000)
    private static let completeMetadata = DatabaseResultMetadata(
        completeness: DatabaseResultCompleteness(state: .complete))

    private static func model(
        _ sender: DatabaseConnectionScriptedSender
    ) -> DatabaseConnectionWorkspaceModel {
        DatabaseConnectionWorkspaceModel(
            sender: sender,
            currentDate: { Date(timeIntervalSince1970: 8_000) },
            prepareConnection: { _ in },
            announcement: { _ in })
    }

    private static func listResponse(
        _ connections: [DatabaseConnectionDefinition],
        status: DatabaseCommandResultStatus = .succeeded,
        completeness: DatabaseCompletenessState = .complete
    ) -> DatabaseBrokerCommandResponse {
        let payload = DatabaseConnectionListResult(connections: connections)
        let metadata = DatabaseResultMetadata(
            completeness: DatabaseResultCompleteness(state: completeness))
        let result: DatabaseCommandResult<DatabaseConnectionListResult> =
            status == .partiallySucceeded
            ? .partial(payload, metadata: metadata)
            : .success(payload, metadata: metadata)
        return .connectionList(result)
    }

    private static func connectResponse(
        _ connection: DatabaseConnectionDefinition,
        report: DatabaseCapabilityReport
    ) -> DatabaseBrokerCommandResponse {
        .connect(
            .success(
                DatabaseConnectResult(
                    connection: connection.identity,
                    productIdentity: report.productIdentity,
                    capabilities: report,
                    connectedAt: now),
                metadata: completeMetadata))
    }

    private static func disconnectResponse(
        _ connection: DatabaseConnectionDefinition
    ) -> DatabaseBrokerCommandResponse {
        .disconnect(
            .success(
                DatabaseDisconnectResult(
                    connection: connection.identity,
                    disconnected: true,
                    disconnectedAt: now),
                metadata: completeMetadata))
    }

    private static func capabilitiesResponse(
        _ report: DatabaseCapabilityReport,
        status: DatabaseCommandResultStatus = .succeeded,
        completeness: DatabaseCompletenessState = .complete
    ) -> DatabaseBrokerCommandResponse {
        let payload = DatabaseCapabilitiesResult(report: report, source: .discovered)
        let metadata = DatabaseResultMetadata(
            completeness: DatabaseResultCompleteness(state: completeness))
        let result: DatabaseCommandResult<DatabaseCapabilitiesResult> =
            status == .partiallySucceeded
            ? .partial(payload, metadata: metadata)
            : .success(payload, metadata: metadata)
        return .capabilities(result)
    }

    private static func connection(
        id: UInt8,
        name: String,
        product: DatabaseProduct = .postgresql,
        tags: [String] = ["critical", "orders"]
    ) throws -> DatabaseConnectionDefinition {
        let secret = DatabaseSecretReference(
            identifier: uuid(id + 100),
            purpose: .password)
        return DatabaseConnectionDefinition(
            id: DatabaseConnectionID(rawValue: uuid(id)),
            displayName: name,
            productHint: product,
            location: .network([
                DatabaseNetworkEndpoint(host: "db.internal", port: try DatabasePort(5_432))
            ]),
            username: "sensitive-user",
            namespaces: DatabaseNamespaceDefaults(schema: "public", database: "orders"),
            deploymentMode: .standalone,
            authentication: DatabaseAuthentication(
                kind: .usernameAndPassword,
                secretReferences: [secret],
                source: "TOP_SECRET_DATABASE_SOURCE"),
            tls: DatabaseTLSConfiguration(mode: .required, verification: .full),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
                poolSize: try DatabasePoolSize(4)),
            readOnlyPolicy: .required,
            productionPolicy: .requireMutationPreview,
            environment: DatabaseEnvironmentMetadata(
                kind: .production,
                label: "customer-a",
                protection: .confirmationRequired),
            group: "payments",
            tags: tags,
            isFavorite: true,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            lastUsedAt: Date(timeIntervalSince1970: 3_000))
    }

    private static func capabilityReport(
        product: DatabaseProduct,
        version: String
    ) -> DatabaseCapabilityReport {
        DatabaseCapabilityReport(
            productIdentity: DatabaseProductIdentity(
                product: product,
                version: DatabaseVersion(string: version),
                topology: DatabaseTopology(kind: .standalone)),
            capabilities: [
                DatabaseCapabilityStatus(
                    id: .browse,
                    requirement: .sharedRequired,
                    availability: .available),
                DatabaseCapabilityStatus(
                    id: .delete,
                    requirement: .sharedRequired,
                    availability: .unavailable,
                    reason: DatabaseCapabilityUnavailableReason(
                        category: .permission,
                        message: "DELETE permission is unavailable.")),
            ],
            pagingModes: [.keyset],
            cancellationModes: [.protocolCancellation],
            safetyLimitations: ["DDL is disabled."],
            discoveredAt: now,
            expiresAt: now.addingTimeInterval(300))
    }

    private static func uuid(_ value: UInt8) -> UUID {
        UUID(
            uuid: (
                0x71, 0x20, 0x9A, 0xB4, 0x61, 0x99, 0x4D, 0x1B,
                0x90, 0x02, 0x43, 0x08, 0x77, 0x00, 0x00, value
            ))
    }
}

private actor DatabaseConnectionScriptedSender: DatabaseBrokerCommandSending {
    private enum Outcome: Sendable {
        case response(DatabaseBrokerCommandResponse)
        case failure(DatabaseBrokerCommandClientError)
    }

    private var requests: [DatabaseBrokerCommandRequest] = []
    private var outcomes: [Int: Outcome] = [:]
    private var outcomeWaiters: [Int: CheckedContinuation<Outcome, Never>] = [:]
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        let index = requests.count
        requests.append(request)
        resumeRequestWaiters()
        let outcome: Outcome
        if let preparedOutcome = outcomes.removeValue(forKey: index) {
            outcome = preparedOutcome
        } else {
            outcome = await withCheckedContinuation { outcomeWaiters[index] = $0 }
        }
        switch outcome {
        case .response(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func succeed(_ response: DatabaseBrokerCommandResponse, at index: Int) {
        resolve(.response(response), at: index)
    }

    func fail(_ error: DatabaseBrokerCommandClientError, at index: Int) {
        resolve(.failure(error), at: index)
    }

    func waitUntilRequested(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func recordedRequests() -> [DatabaseBrokerCommandRequest] {
        requests
    }

    private func resolve(_ outcome: Outcome, at index: Int) {
        if let waiter = outcomeWaiters.removeValue(forKey: index) {
            waiter.resume(returning: outcome)
        } else {
            outcomes[index] = outcome
        }
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { requests.count >= $0.0 }
        requestWaiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private extension DatabaseBrokerCommandRequest {
    var connectionListRequest: DatabaseConnectionListRequest? {
        guard case .connectionList(let request) = self else { return nil }
        return request
    }

    var connectRequest: DatabaseConnectRequest? {
        guard case .connect(let request) = self else { return nil }
        return request
    }

    var disconnectRequest: DatabaseDisconnectRequest? {
        guard case .disconnect(let request) = self else { return nil }
        return request
    }

    var capabilitiesRequest: DatabaseCapabilitiesRequest? {
        guard case .capabilities(let request) = self else { return nil }
        return request
    }
}
