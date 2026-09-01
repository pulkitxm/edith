import Foundation
import Testing

@testable import EdithDatabase

private struct DatabaseExecutorTestFixture {
    let directory: URL
    let path: String
    let store: SQLiteDatabaseMetadataStore
    let secretStore: InMemoryDatabaseSecretStore
    let runtimeOwner: DatabaseRuntimeOwnerToken
    let executor: DatabaseExecutor
    let adapter: DatabaseExecutorRecordingAdapter
    let session: DatabaseExecutorRecordingSession
    let connection: DatabaseConnectionDefinition
    let report: DatabaseCapabilityReport
}

private enum DatabaseExecutorFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let runtimeOwner = DatabaseRuntimeOwnerToken(
        rawValue: UUID(uuidString: "803FD7C3-E5CB-4680-A24C-009D689BDA89")!)

    static func uuid(_ index: UInt8) -> UUID {
        UUID(
            uuid: (
                0xA2, 0x7D, 0x19, 0xB4, 0x56, 0x3E, 0x4C, 0x81,
                0x9F, 0x20, 0x71, 0x43, 0x11, 0x00, 0x00, index
            ))
    }

    static func connectionID(_ index: UInt8 = 1) -> DatabaseConnectionID {
        DatabaseConnectionID(rawValue: uuid(index))
    }

    static func sessionID(_ index: UInt8 = 1) -> DatabaseAdapterSessionID {
        DatabaseAdapterSessionID(rawValue: uuid(index &+ 40))
    }

    static func operation(
        _ index: UInt8,
        deadline: Date? = nil
    ) -> DatabaseOperationContext {
        DatabaseOperationContext(
            operationID: DatabaseOperationID(rawValue: uuid(index &+ 80)),
            deadline: deadline)
    }

    static func connection(
        id: DatabaseConnectionID = connectionID(),
        name: String = "Orders",
        product: DatabaseProduct = .postgresql,
        secretReference: DatabaseSecretReference? = nil,
        connectionTimeoutMilliseconds: UInt64 = 5_000,
        operationTimeoutMilliseconds: UInt64 = 30_000
    ) throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            id: id,
            displayName: name,
            productHint: product,
            location: .network([
                DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: try DatabasePort(5_432))
            ]),
            username: "edith",
            namespaces: DatabaseNamespaceDefaults(schema: "public", database: "edith_lab"),
            deploymentMode: .standalone,
            authentication: secretReference.map {
                DatabaseAuthentication(kind: .password, secretReferences: [$0])
            } ?? DatabaseAuthentication(kind: .none),
            tls: DatabaseTLSConfiguration(mode: .disabled, verification: .none),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(
                    milliseconds: connectionTimeoutMilliseconds),
                operationTimeout: try DatabaseTimeout(
                    milliseconds: operationTimeoutMilliseconds),
                poolSize: try DatabasePoolSize(4)),
            environment: DatabaseEnvironmentMetadata(
                kind: .development,
                label: "development",
                protection: .standard),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: now.addingTimeInterval(-10))
    }

    static func identity(
        product: DatabaseProduct = .postgresql,
        marker: String = "primary"
    ) -> DatabaseProductIdentity {
        DatabaseProductIdentity(
            product: product,
            version: DatabaseVersion(string: "1.0.0", major: 1, minor: 0, patch: 0),
            topology: DatabaseTopology(kind: .standalone, name: marker),
            serverIdentifier: marker)
    }

    static func report(
        identity: DatabaseProductIdentity,
        discoveredAt: Date = now.addingTimeInterval(-10),
        includesQuery: Bool = false,
        includesMutation: Bool = false
    ) -> DatabaseCapabilityReport {
        var capabilities = [
            DatabaseCapabilityStatus(
                id: .connectionTest,
                requirement: .sharedRequired,
                availability: .available),
            DatabaseCapabilityStatus(
                id: .browse,
                requirement: .sharedRequired,
                availability: .available),
        ]
        if includesQuery {
            capabilities.append(
                DatabaseCapabilityStatus(
                    id: .query,
                    requirement: .sharedRequired,
                    availability: .available))
        }
        if includesMutation {
            capabilities.append(contentsOf: [
                DatabaseCapabilityStatus(
                    id: .administration,
                    requirement: .sharedRequired,
                    availability: .available),
                DatabaseCapabilityStatus(
                    id: .mutationStatus,
                    requirement: .sharedRequired,
                    availability: .available),
                DatabaseCapabilityStatus(
                    id: .mutationCancellation,
                    requirement: .sharedRequired,
                    availability: .available),
            ])
        }
        return DatabaseCapabilityReport(
            productIdentity: identity,
            capabilities: capabilities,
            mutationModes: includesMutation ? [.boundedBatch] : [],
            discoveredAt: discoveredAt,
            expiresAt: now.addingTimeInterval(600))
    }

    static func target(_ connectionID: DatabaseConnectionID) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: .table, path: ["public", "orders"]))
    }

    static func page() throws -> DatabaseAdapterPage {
        try DatabaseAdapterPage(
            records: [],
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(state: .complete),
                count: DatabaseCountMetadata(value: 0, accuracy: .exact)))
    }

    static func mutationRequest(
        connection: DatabaseConnectionDefinition,
        command: String = "maintenance"
    ) -> DatabaseDestructiveRequest {
        DatabaseDestructiveRequest(
            target: target(connection.id),
            payload: .administrative(
                product: connection.productHint,
                command: command,
                parameters: [],
                body: nil))
    }

    static func mutationPlan(
        connection: DatabaseConnectionDefinition,
        request: DatabaseDestructiveRequest? = nil,
        impactDescription: String = "No records"
    ) -> DatabaseDestructivePlan {
        let request = request ?? mutationRequest(connection: connection)
        return DatabaseDestructivePlan(
            request: request,
            action: .maintenance,
            scope: .entireObject,
            impact: DatabaseMutationImpact(
                count: DatabaseCountMetadata(value: 0, accuracy: .exact),
                description: impactDescription),
            transactionBehavior: .productDependent,
            rollbackAvailability: .unavailable,
            executionMode: .synchronous)
    }

    static func session(
        id: DatabaseAdapterSessionID = sessionID(),
        connection: DatabaseConnectionDefinition,
        report: DatabaseCapabilityReport,
        gates: DatabaseExecutorTestSessionGates = DatabaseExecutorTestSessionGates()
    ) throws -> DatabaseExecutorRecordingSession {
        let page = try page()
        return DatabaseExecutorRecordingSession(
            id: id,
            connection: connection,
            productIdentity: report.productIdentity,
            capabilities: report,
            page: page,
            queryPage: page,
            mutationPlan: mutationPlan(connection: connection),
            mutationResult: try DatabaseAdapterMutationResult(
                disposition: .completed,
                effect: .applied,
                affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .exact)),
            gates: gates)
    }

    static func make(
        connection: DatabaseConnectionDefinition? = nil,
        report: DatabaseCapabilityReport? = nil,
        secretValues: [DatabaseSecretReference: Data] = [:],
        saveConnection: Bool = true,
        adapterGates: DatabaseExecutorTestAdapterGates = DatabaseExecutorTestAdapterGates(),
        sessionGates: DatabaseExecutorTestSessionGates = DatabaseExecutorTestSessionGates()
    ) async throws -> DatabaseExecutorTestFixture {
        let connection = try connection ?? self.connection()
        let report = report ?? self.report(identity: identity(product: connection.productHint))
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        let store = try SQLiteDatabaseMetadataStore(path: path)
        if saveConnection {
            try await store.seedConnection(connection)
        }
        let runtimeOwner = try await DatabaseRuntimeOwnerFactory.claimReadyOwner(
            from: store,
            claimedAt: now.addingTimeInterval(-1)
        ).owner.token
        let secretStore = try InMemoryDatabaseSecretStore(initialValues: secretValues)
        let session = try self.session(
            connection: connection,
            report: report,
            gates: sessionGates)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: DatabaseAdapterID(rawValue: "recording-\(connection.productHint.rawValue)"),
            products: [connection.productHint],
            session: session,
            gates: adapterGates)
        let executor = try DatabaseExecutor(
            metadataStore: store,
            secretStore: secretStore,
            runtimeOwner: runtimeOwner,
            adapters: [adapter],
            currentDate: { now })
        return DatabaseExecutorTestFixture(
            directory: directory,
            path: path,
            store: store,
            secretStore: secretStore,
            runtimeOwner: runtimeOwner,
            executor: executor,
            adapter: adapter,
            session: session,
            connection: connection,
            report: report)
    }

    static func discoveryCount(_ snapshot: DatabaseExecutorTestSessionSnapshot) -> Int {
        snapshot.invocations.reduce(into: 0) { count, invocation in
            if case .discoverCapabilities = invocation {
                count += 1
            }
        }
    }

    static func mutationNormalizationCount(
        _ snapshot: DatabaseExecutorTestSessionSnapshot
    ) -> Int {
        snapshot.invocations.reduce(into: 0) { count, invocation in
            if case .normalizeMutation = invocation {
                count += 1
            }
        }
    }

    static func mutationExecutionCount(
        _ snapshot: DatabaseExecutorTestSessionSnapshot
    ) -> Int {
        snapshot.invocations.reduce(into: 0) { count, invocation in
            if case .executeMutation = invocation {
                count += 1
            }
        }
    }
}

private struct DatabaseExecutorUnexpectedStoreError: Error, CustomStringConvertible, Sendable {
    let description = "private-unexpected-store-marker"
}

private struct DatabaseExecutorUnexpectedMetadataStore: DatabaseMetadataStore {
    private func failure() -> DatabaseExecutorUnexpectedStoreError {
        DatabaseExecutorUnexpectedStoreError()
    }

    func saveConnection(
        _ definition: DatabaseConnectionDefinition,
        replacing expected: DatabaseConnectionDefinition?,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseOwnedMetadataWriteResult {
        throw failure()
    }

    func connection(id: DatabaseConnectionID) throws -> DatabaseConnectionDefinition? {
        throw failure()
    }

    func connections(matching search: DatabaseConnectionSearch) throws
        -> [DatabaseConnectionDefinition]
    {
        throw failure()
    }

    func deleteConnection(
        id: DatabaseConnectionID,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseOwnedMetadataDeleteResult {
        throw failure()
    }

    func saveQuery(
        _ query: DatabaseSavedQuery,
        replacing expected: DatabaseSavedQuery?,
        validatedAgainst connection: DatabaseConnectionDefinition?,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseOwnedMetadataWriteResult {
        throw failure()
    }

    func savedQuery(id: DatabaseSavedQueryID) throws -> DatabaseSavedQuery? {
        throw failure()
    }

    func savedQueries(matching search: DatabaseSavedQuerySearch) throws
        -> [DatabaseSavedQuery]
    {
        throw failure()
    }

    func deleteSavedQuery(
        id: DatabaseSavedQueryID,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseOwnedMetadataDeleteResult {
        throw failure()
    }

    func runtimeOwner() throws -> DatabaseRuntimeOwnerRecord? {
        throw failure()
    }

    func claimRuntimeOwner(
        claimedAt: Date,
        recoveryLimit: Int
    ) throws -> DatabaseRuntimeOwnerClaimResult {
        throw failure()
    }

    func recoverRuntimeOwner(
        _ owner: DatabaseRuntimeOwnerToken,
        limit: Int
    ) throws -> DatabaseRuntimeRecoveryResult {
        throw failure()
    }

    func releaseRuntimeOwner(
        _ token: DatabaseRuntimeOwnerToken,
        releasedAt: Date
    ) throws -> Bool {
        throw failure()
    }

    func reserveOperation(
        _ summary: DatabaseOperationRecordSummary,
        for connection: DatabaseConnectionDefinition,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseOwnedOperationReservationResult {
        throw failure()
    }

    func reserveEphemeralOperation(
        _ summary: DatabaseOperationRecordSummary,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseOwnedOperationReservationResult {
        throw failure()
    }

    func transitionOperation(
        _ summary: DatabaseOperationRecordSummary,
        from expectedStates: Set<DatabaseOperationState>,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> Bool {
        throw failure()
    }

    func operation(id: DatabaseOperationID) throws -> DatabaseOperationRecordSummary? {
        throw failure()
    }

    func operations(matching search: DatabaseOperationHistorySearch) throws
        -> [DatabaseOperationRecordSummary]
    {
        throw failure()
    }

    func recordMutationOutcome(
        _ outcome: DatabaseMutationApplyResult,
        operationID: DatabaseOperationID,
        owner: DatabaseRuntimeOwnerToken
    ) throws {
        throw failure()
    }

    func transitionMutationOutcome(
        _ outcome: DatabaseMutationApplyResult,
        operationID: DatabaseOperationID,
        from expectedStates: Set<DatabaseMutationOutcomeState>,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseMutationOutcomeTransitionResult {
        throw failure()
    }

    func mutationOutcome(
        operationID: DatabaseOperationID
    ) throws -> DatabaseMutationApplyResult? {
        throw failure()
    }

    func pruneOperations(
        finishedBefore date: Date,
        limit: Int,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseMetadataCleanupResult {
        throw failure()
    }

    func registerConfirmation(
        _ receipt: DatabaseConfirmationReceipt,
        owner: DatabaseRuntimeOwnerToken
    ) throws {
        throw failure()
    }

    func consumeConfirmation(
        identifier: UUID,
        effectDigest: String,
        connection: DatabaseConnectionDefinition,
        consumedAt: Date,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> Bool {
        throw failure()
    }

    func removeExpiredConfirmations(
        before date: Date,
        limit: Int,
        owner: DatabaseRuntimeOwnerToken
    ) throws -> DatabaseMetadataCleanupResult {
        throw failure()
    }
}

private actor DatabaseExecutorGatedMetadataStore: DatabaseMetadataStore {
    private let base: any DatabaseMetadataStore
    private let reservationGate: DatabaseExecutorTestGate?
    private let blockedTransitionStates: Set<DatabaseOperationState>
    private let rejectedTransitionStates: Set<DatabaseOperationState>
    private let transitionGate: DatabaseExecutorTestGate?

    init(
        base: any DatabaseMetadataStore,
        reservationGate: DatabaseExecutorTestGate? = nil,
        blockedTransitionStates: Set<DatabaseOperationState> = [],
        rejectedTransitionStates: Set<DatabaseOperationState> = [],
        transitionGate: DatabaseExecutorTestGate? = nil
    ) {
        self.base = base
        self.reservationGate = reservationGate
        self.blockedTransitionStates = blockedTransitionStates
        self.rejectedTransitionStates = rejectedTransitionStates
        self.transitionGate = transitionGate
    }

    func saveConnection(
        _ definition: DatabaseConnectionDefinition,
        replacing expected: DatabaseConnectionDefinition?,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedMetadataWriteResult {
        try await base.saveConnection(definition, replacing: expected, owner: owner)
    }

    func connection(id: DatabaseConnectionID) async throws -> DatabaseConnectionDefinition? {
        try await base.connection(id: id)
    }

    func connections(matching search: DatabaseConnectionSearch) async throws
        -> [DatabaseConnectionDefinition]
    {
        try await base.connections(matching: search)
    }

    func deleteConnection(
        id: DatabaseConnectionID,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedMetadataDeleteResult {
        try await base.deleteConnection(id: id, owner: owner)
    }

    func saveQuery(
        _ query: DatabaseSavedQuery,
        replacing expected: DatabaseSavedQuery?,
        validatedAgainst connection: DatabaseConnectionDefinition?,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedMetadataWriteResult {
        try await base.saveQuery(
            query,
            replacing: expected,
            validatedAgainst: connection,
            owner: owner)
    }

    func savedQuery(id: DatabaseSavedQueryID) async throws -> DatabaseSavedQuery? {
        try await base.savedQuery(id: id)
    }

    func savedQueries(matching search: DatabaseSavedQuerySearch) async throws
        -> [DatabaseSavedQuery]
    {
        try await base.savedQueries(matching: search)
    }

    func deleteSavedQuery(
        id: DatabaseSavedQueryID,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedMetadataDeleteResult {
        try await base.deleteSavedQuery(id: id, owner: owner)
    }

    func runtimeOwner() async throws -> DatabaseRuntimeOwnerRecord? {
        try await base.runtimeOwner()
    }

    func claimRuntimeOwner(
        claimedAt: Date,
        recoveryLimit: Int
    ) async throws -> DatabaseRuntimeOwnerClaimResult {
        try await base.claimRuntimeOwner(
            claimedAt: claimedAt,
            recoveryLimit: recoveryLimit)
    }

    func recoverRuntimeOwner(
        _ owner: DatabaseRuntimeOwnerToken,
        limit: Int
    ) async throws -> DatabaseRuntimeRecoveryResult {
        try await base.recoverRuntimeOwner(owner, limit: limit)
    }

    func releaseRuntimeOwner(
        _ token: DatabaseRuntimeOwnerToken,
        releasedAt: Date
    ) async throws -> Bool {
        try await base.releaseRuntimeOwner(token, releasedAt: releasedAt)
    }

    func reserveOperation(
        _ summary: DatabaseOperationRecordSummary,
        for connection: DatabaseConnectionDefinition,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedOperationReservationResult {
        if let reservationGate {
            await reservationGate.enter()
        }
        return try await base.reserveOperation(summary, for: connection, owner: owner)
    }

    func reserveEphemeralOperation(
        _ summary: DatabaseOperationRecordSummary,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseOwnedOperationReservationResult {
        if let reservationGate {
            await reservationGate.enter()
        }
        return try await base.reserveEphemeralOperation(summary, owner: owner)
    }

    func transitionOperation(
        _ summary: DatabaseOperationRecordSummary,
        from expectedStates: Set<DatabaseOperationState>,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> Bool {
        if blockedTransitionStates.contains(summary.state), let transitionGate {
            await transitionGate.enter()
        }
        if rejectedTransitionStates.contains(summary.state) {
            return false
        }
        return try await base.transitionOperation(summary, from: expectedStates, owner: owner)
    }

    func operation(id: DatabaseOperationID) async throws -> DatabaseOperationRecordSummary? {
        try await base.operation(id: id)
    }

    func operations(matching search: DatabaseOperationHistorySearch) async throws
        -> [DatabaseOperationRecordSummary]
    {
        try await base.operations(matching: search)
    }

    func recordMutationOutcome(
        _ outcome: DatabaseMutationApplyResult,
        operationID: DatabaseOperationID,
        owner: DatabaseRuntimeOwnerToken
    ) async throws {
        try await base.recordMutationOutcome(
            outcome,
            operationID: operationID,
            owner: owner)
    }

    func transitionMutationOutcome(
        _ outcome: DatabaseMutationApplyResult,
        operationID: DatabaseOperationID,
        from expectedStates: Set<DatabaseMutationOutcomeState>,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseMutationOutcomeTransitionResult {
        try await base.transitionMutationOutcome(
            outcome,
            operationID: operationID,
            from: expectedStates,
            owner: owner)
    }

    func mutationOutcome(
        operationID: DatabaseOperationID
    ) async throws -> DatabaseMutationApplyResult? {
        try await base.mutationOutcome(operationID: operationID)
    }

    func pruneOperations(
        finishedBefore date: Date,
        limit: Int,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseMetadataCleanupResult {
        try await base.pruneOperations(
            finishedBefore: date,
            limit: limit,
            owner: owner)
    }

    func registerConfirmation(
        _ receipt: DatabaseConfirmationReceipt,
        owner: DatabaseRuntimeOwnerToken
    ) async throws {
        try await base.registerConfirmation(receipt, owner: owner)
    }

    func consumeConfirmation(
        identifier: UUID,
        effectDigest: String,
        connection: DatabaseConnectionDefinition,
        consumedAt: Date,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> Bool {
        try await base.consumeConfirmation(
            identifier: identifier,
            effectDigest: effectDigest,
            connection: connection,
            consumedAt: consumedAt,
            owner: owner)
    }

    func removeExpiredConfirmations(
        before date: Date,
        limit: Int,
        owner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseMetadataCleanupResult {
        try await base.removeExpiredConfirmations(
            before: date,
            limit: limit,
            owner: owner)
    }
}

private actor DatabaseExecutorBlockingSecretStore: DatabaseSecretStore {
    private let values: [DatabaseSecretReference: Data]
    private let readGate: DatabaseExecutorTestGate

    init(
        values: [DatabaseSecretReference: Data],
        readGate: DatabaseExecutorTestGate
    ) {
        self.values = values
        self.readGate = readGate
    }

    func store(_ secret: Data, for reference: DatabaseSecretReference) throws {
        throw DatabaseSecretStoreError.invalidStoredData(reference)
    }

    func storeIfAbsent(
        _ secret: Data,
        for reference: DatabaseSecretReference
    ) throws -> Data {
        throw DatabaseSecretStoreError.invalidStoredData(reference)
    }

    func read(_ reference: DatabaseSecretReference) async throws -> Data {
        await readGate.enter()
        guard let value = values[reference] else {
            throw DatabaseSecretStoreError.notFound(reference)
        }
        return value
    }

    func delete(_ reference: DatabaseSecretReference) throws {
        throw DatabaseSecretStoreError.notFound(reference)
    }

    func contains(_ reference: DatabaseSecretReference) -> Bool {
        values[reference] != nil
    }
}

@Suite struct DatabaseExecutorTests {
    @Test func mutationPreviewNormalizesWithoutExecuting() async throws {
        let report = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(),
            includesMutation: true)
        let fixture = try await DatabaseExecutorFixtures.make(report: report)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let mutation = DatabaseExecutorFixtures.mutationRequest(
            connection: fixture.connection)
        let operation = DatabaseExecutorFixtures.operation(66)

        let result = await fixture.executor.previewMutation(
            DatabaseMutationPreviewRequest(
                mutation: mutation,
                operation: operation))

        #expect(result.status == .succeeded)
        #expect(result.payload?.preview.effect.target == mutation.target)
        #expect(result.metadata.operation?.id == operation.operationID)
        #expect(result.metadata.operation?.kind == .databaseMutationPreview)
        let snapshot = await fixture.session.snapshot()
        #expect(DatabaseExecutorFixtures.mutationNormalizationCount(snapshot) == 1)
        #expect(DatabaseExecutorFixtures.mutationExecutionCount(snapshot) == 0)
    }

    @Test func mutationPreviewRejectsAPlanForADifferentRequest() async throws {
        let report = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(),
            includesMutation: true)
        let fixture = try await DatabaseExecutorFixtures.make(report: report)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let mutation = DatabaseExecutorFixtures.mutationRequest(
            connection: fixture.connection)
        let different = DatabaseExecutorFixtures.mutationRequest(
            connection: fixture.connection,
            command: "different maintenance")
        await fixture.session.setMutationPlan(
            DatabaseExecutorFixtures.mutationPlan(
                connection: fixture.connection,
                request: different))

        let result = await fixture.executor.previewMutation(
            DatabaseMutationPreviewRequest(
                mutation: mutation,
                operation: DatabaseExecutorFixtures.operation(67)))

        #expect(result.status == .failed)
        #expect(result.error?.category == .internalFailure)
        let snapshot = await fixture.session.snapshot()
        #expect(DatabaseExecutorFixtures.mutationNormalizationCount(snapshot) == 1)
        #expect(DatabaseExecutorFixtures.mutationExecutionCount(snapshot) == 0)
    }

    @Test func mutationApplyRejectsChangedPlansAndConsumesSuccessfulTokensOnce() async throws {
        let report = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(),
            includesMutation: true)
        let fixture = try await DatabaseExecutorFixtures.make(report: report)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let mutation = DatabaseExecutorFixtures.mutationRequest(
            connection: fixture.connection)
        let preview = await fixture.executor.previewMutation(
            DatabaseMutationPreviewRequest(
                mutation: mutation,
                operation: DatabaseExecutorFixtures.operation(68)))
        let issued = try #require(preview.payload?.preview)
        await fixture.session.setMutationPlan(
            DatabaseExecutorFixtures.mutationPlan(
                connection: fixture.connection,
                request: mutation,
                impactDescription: "Changed impact"))

        let mismatch = await fixture.executor.applyMutation(
            DatabaseMutationApplyRequest(
                mutation: mutation,
                token: issued.token,
                confirmationText: issued.requiredConfirmation.text,
                operation: DatabaseExecutorFixtures.operation(69)))

        #expect(mismatch.status == .failed)
        #expect(mismatch.error?.category == .confirmationInvalid)
        #expect(
            DatabaseExecutorFixtures.mutationExecutionCount(
                await fixture.session.snapshot()) == 0)

        await fixture.session.setMutationPlan(
            DatabaseExecutorFixtures.mutationPlan(
                connection: fixture.connection,
                request: mutation))
        let wrongConfirmation = await fixture.executor.applyMutation(
            DatabaseMutationApplyRequest(
                mutation: mutation,
                token: issued.token,
                confirmationText: issued.requiredConfirmation.text + "x",
                operation: DatabaseExecutorFixtures.operation(70)))

        #expect(wrongConfirmation.status == .failed)
        #expect(wrongConfirmation.error?.category == .confirmationInvalid)
        #expect(
            DatabaseExecutorFixtures.mutationExecutionCount(
                await fixture.session.snapshot()) == 0)

        let applied = await fixture.executor.applyMutation(
            DatabaseMutationApplyRequest(
                mutation: mutation,
                token: issued.token,
                confirmationText: issued.requiredConfirmation.text,
                operation: DatabaseExecutorFixtures.operation(71)))
        let recovered = await fixture.executor.mutationOutcome(
            DatabaseMutationOutcomeGetRequest(
                operationID: DatabaseExecutorFixtures.operation(71).operationID))
        let replayed = await fixture.executor.applyMutation(
            DatabaseMutationApplyRequest(
                mutation: mutation,
                token: issued.token,
                confirmationText: issued.requiredConfirmation.text,
                operation: DatabaseExecutorFixtures.operation(79)))

        #expect(applied.status == .succeeded)
        #expect(applied.payload?.disposition == .completed)
        #expect(applied.payload?.effect == .applied)
        #expect(applied.metadata.operation?.kind == .databaseMutationApply)
        #expect(applied.metadata.operation?.retryClassification == .requiresNewPreview)
        #expect(recovered.status == .succeeded)
        #expect(recovered.payload?.outcome == applied.payload)
        #expect(recovered.payload?.operation?.id == applied.metadata.operation?.id)
        #expect(replayed.status == .failed)
        #expect(replayed.error?.category == .confirmationInvalid)
        #expect(
            DatabaseExecutorFixtures.mutationExecutionCount(
                await fixture.session.snapshot()) == 1)
    }

    @Test func cancelledMutationApplyDoesNotExecuteOrConsumeItsToken() async throws {
        let normalizationGate = DatabaseExecutorTestGate()
        let report = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(),
            includesMutation: true)
        let fixture = try await DatabaseExecutorFixtures.make(
            report: report,
            sessionGates: DatabaseExecutorTestSessionGates(
                normalizeMutation: normalizationGate))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let mutation = DatabaseExecutorFixtures.mutationRequest(
            connection: fixture.connection)
        let preview = await fixture.executor.previewMutation(
            DatabaseMutationPreviewRequest(
                mutation: mutation,
                operation: DatabaseExecutorFixtures.operation(72)))
        let issued = try #require(preview.payload?.preview)
        await normalizationGate.block()
        let applyOperation = DatabaseExecutorFixtures.operation(73)
        let applyTask = Task {
            await fixture.executor.applyMutation(
                DatabaseMutationApplyRequest(
                    mutation: mutation,
                    token: issued.token,
                    confirmationText: issued.requiredConfirmation.text,
                    operation: applyOperation))
        }
        await normalizationGate.waitForEntries(2)

        let cancellation = await fixture.executor.cancel(
            DatabaseOperationCancelRequest(operationID: applyOperation.operationID))
        await normalizationGate.releaseAll()
        let cancelled = await applyTask.value

        #expect(cancellation.payload?.disposition == .accepted)
        #expect(cancelled.status == .failed)
        #expect(cancelled.error?.category == .cancelled)
        #expect(
            DatabaseExecutorFixtures.mutationExecutionCount(
                await fixture.session.snapshot()) == 0)

        let retried = await fixture.executor.applyMutation(
            DatabaseMutationApplyRequest(
                mutation: mutation,
                token: issued.token,
                confirmationText: issued.requiredConfirmation.text,
                operation: DatabaseExecutorFixtures.operation(74)))

        #expect(retried.status == .succeeded)
        let snapshot = await fixture.session.snapshot()
        #expect(DatabaseExecutorFixtures.mutationExecutionCount(snapshot) == 1)
        #expect(snapshot.cancelledOperationIDs.contains(applyOperation.operationID))
    }

    @Test func mutationApplyPersistsUnknownBeforeCallingTheAdapter() async throws {
        let executeGate = DatabaseExecutorTestGate()
        let report = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(),
            includesMutation: true)
        let fixture = try await DatabaseExecutorFixtures.make(
            report: report,
            sessionGates: DatabaseExecutorTestSessionGates(
                executeMutation: executeGate))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let mutation = DatabaseExecutorFixtures.mutationRequest(
            connection: fixture.connection)
        let preview = await fixture.executor.previewMutation(
            DatabaseMutationPreviewRequest(
                mutation: mutation,
                operation: DatabaseExecutorFixtures.operation(94)))
        let issued = try #require(preview.payload?.preview)
        await executeGate.block()
        let applyOperation = DatabaseExecutorFixtures.operation(95)
        let task = Task {
            await fixture.executor.applyMutation(
                DatabaseMutationApplyRequest(
                    mutation: mutation,
                    token: issued.token,
                    confirmationText: issued.requiredConfirmation.text,
                    operation: applyOperation))
        }
        await executeGate.waitForEntries()

        let reopened = try SQLiteDatabaseMetadataStore(path: fixture.path)
        let unresolved = try #require(
            try await reopened.mutationOutcome(operationID: applyOperation.operationID))

        #expect(unresolved.effect == .unknown)
        #expect(unresolved.acceptedMutation == nil)
        #expect(unresolved.error == nil)

        task.cancel()
        await executeGate.releaseAll()
        let result = await task.value
        let persisted = try await reopened.mutationOutcome(
            operationID: applyOperation.operationID)

        #expect(result.status == .succeeded)
        #expect(result.payload?.effect == .unknown)
        #expect(result.payload?.error?.category == .cancelled)
        #expect(persisted == result.payload)
    }

    @Test func adapterThrowAfterMutationBoundaryReturnsDurableUnknown() async throws {
        let report = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(),
            includesMutation: true)
        let fixture = try await DatabaseExecutorFixtures.make(report: report)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let unsafeMessage = "private adapter effect marker"
        await fixture.session.enqueueMutationResult(
            .failure(
                .reported(
                    DatabaseErrorEnvelope(
                        category: .server,
                        message: unsafeMessage))))
        let mutation = DatabaseExecutorFixtures.mutationRequest(
            connection: fixture.connection)
        let preview = await fixture.executor.previewMutation(
            DatabaseMutationPreviewRequest(
                mutation: mutation,
                operation: DatabaseExecutorFixtures.operation(96)))
        let issued = try #require(preview.payload?.preview)
        let applyOperation = DatabaseExecutorFixtures.operation(97)

        let result = await fixture.executor.applyMutation(
            DatabaseMutationApplyRequest(
                mutation: mutation,
                token: issued.token,
                confirmationText: issued.requiredConfirmation.text,
                operation: applyOperation))
        let persisted = try await fixture.store.mutationOutcome(
            operationID: applyOperation.operationID)

        #expect(result.status == .succeeded)
        #expect(result.payload?.disposition == .completed)
        #expect(result.payload?.effect == .unknown)
        #expect(result.payload?.error?.category == .server)
        #expect(result.payload?.error?.message.contains(unsafeMessage) == false)
        #expect(persisted == result.payload)
        #expect(
            DatabaseExecutorFixtures.mutationExecutionCount(
                await fixture.session.snapshot()) == 1)
    }

    @Test func brokerDispatcherRoutesMutationPreviewAndApplyThroughTheExecutor() async throws {
        let report = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(),
            includesMutation: true)
        let fixture = try await DatabaseExecutorFixtures.make(report: report)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let dispatcher = try DatabaseBrokerCommandDispatcher(
            handler: DatabaseBrokerExecutorHandler(executor: fixture.executor))
        let mutation = DatabaseExecutorFixtures.mutationRequest(
            connection: fixture.connection)
        let serverOperationIdentifier = "server-task-42"
        await fixture.session.setMutationResult(
            try DatabaseAdapterMutationResult(
                disposition: .accepted,
                effect: .unknown,
                affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .unknown),
                serverOperationIdentifier: serverOperationIdentifier))
        let previewOperation = DatabaseExecutorFixtures.operation(75)
        let previewRequestID = DatabaseExecutorFixtures.uuid(76)
        let previewEnvelope = DatabaseBrokerCommandRequest.mutationPreview(
            DatabaseMutationPreviewRequest(
                mutation: mutation,
                operation: previewOperation)
        ).envelope(requestID: previewRequestID, sequence: 10)

        let previewResponse = try await dispatcher.dispatch(
            previewEnvelope,
            responseSequence: 11)
        let previewResult = try #require(previewResponse.payload.mutationPreviewResult)
        let issued = try #require(previewResult.payload?.preview)

        #expect(previewResponse.requestID == previewRequestID)
        #expect(previewResponse.operationID == previewOperation.operationID)
        #expect(previewResult.status == .succeeded)

        let applyOperation = DatabaseExecutorFixtures.operation(77)
        let applyRequestID = DatabaseExecutorFixtures.uuid(78)
        let applyEnvelope = DatabaseBrokerCommandRequest.mutationApply(
            DatabaseMutationApplyRequest(
                mutation: mutation,
                token: issued.token,
                confirmationText: issued.requiredConfirmation.text,
                operation: applyOperation)
        ).envelope(requestID: applyRequestID, sequence: 12)
        let applyResponse = try await dispatcher.dispatch(
            applyEnvelope,
            responseSequence: 13)
        let applyResult = try #require(applyResponse.payload.mutationApplyResult)

        #expect(applyResponse.requestID == applyRequestID)
        #expect(applyResponse.operationID == applyOperation.operationID)
        #expect(applyResult.status == .succeeded)
        #expect(applyResult.payload?.disposition == .accepted)
        let acceptedMutation = try #require(applyResult.payload?.acceptedMutation)
        #expect(acceptedMutation.operationID == applyOperation.operationID)
        #expect(acceptedMutation.serverOperationIdentifier == serverOperationIdentifier)
        #expect(
            DatabaseExecutorFixtures.mutationExecutionCount(
                await fixture.session.snapshot()) == 1)

        let terminalOutcome = try DatabaseAdapterMutationResult(
            disposition: .completed,
            effect: .applied,
            affectedRecords: DatabaseCountMetadata(value: 12, accuracy: .exact),
            serverOperationIdentifier: serverOperationIdentifier)
        let terminalStatus = try DatabaseAdapterMutationStatus(
            serverOperationIdentifier: serverOperationIdentifier,
            state: .completed,
            outcome: terminalOutcome)
        await fixture.session.enqueueMutationStatus(.success(terminalStatus))
        await fixture.session.enqueueMutationCancellation(
            .success(
                try DatabaseAdapterMutationCancellationResult(
                    serverOperationIdentifier: serverOperationIdentifier,
                    disposition: .alreadyFinished,
                    status: terminalStatus)))

        let statusOperation = DatabaseExecutorFixtures.operation(83)
        let statusEnvelope = DatabaseBrokerCommandRequest.mutationStatus(
            DatabaseMutationStatusRequest(
                connectionID: fixture.connection.id,
                acceptedMutation: acceptedMutation,
                operation: statusOperation)
        ).envelope(requestID: DatabaseExecutorFixtures.uuid(84), sequence: 14)
        let statusResponse = try await dispatcher.dispatch(
            statusEnvelope,
            responseSequence: 15)
        let statusResult = try #require(statusResponse.payload.mutationStatusResult)

        #expect(statusResponse.operationID == statusOperation.operationID)
        #expect(statusResult.status == .succeeded)
        #expect(statusResult.payload?.state == .completed)
        #expect(statusResult.payload?.acceptedMutation == acceptedMutation)
        #expect(statusResult.payload?.outcome?.affectedRecords.value == 12)

        let cancelOperation = DatabaseExecutorFixtures.operation(85)
        let cancelEnvelope = DatabaseBrokerCommandRequest.mutationCancel(
            DatabaseMutationCancelRequest(
                connectionID: fixture.connection.id,
                acceptedMutation: acceptedMutation,
                operation: cancelOperation)
        ).envelope(requestID: DatabaseExecutorFixtures.uuid(86), sequence: 16)
        let cancelResponse = try await dispatcher.dispatch(
            cancelEnvelope,
            responseSequence: 17)
        let cancelResult = try #require(cancelResponse.payload.mutationCancelResult)

        #expect(cancelResponse.operationID == cancelOperation.operationID)
        #expect(cancelResult.status == .succeeded)
        #expect(cancelResult.payload?.disposition == .alreadyFinished)
        #expect(cancelResult.payload?.acceptedMutation == acceptedMutation)
        #expect(cancelResult.payload?.status?.state == .completed)

        let outcomeEnvelope = DatabaseBrokerCommandRequest.mutationOutcomeGet(
            DatabaseMutationOutcomeGetRequest(operationID: applyOperation.operationID)
        ).envelope(requestID: DatabaseExecutorFixtures.uuid(87), sequence: 18)
        let outcomeResponse = try await dispatcher.dispatch(
            outcomeEnvelope,
            responseSequence: 19)
        let outcomeResult = try #require(outcomeResponse.payload.mutationOutcomeGetResult)

        #expect(outcomeResponse.operationID == applyOperation.operationID)
        #expect(outcomeResult.status == .succeeded)
        #expect(outcomeResult.payload?.operation?.id == applyOperation.operationID)
        #expect(outcomeResult.payload?.outcome == statusResult.payload?.outcome)
    }

    @Test func terminalFailedAndCancelledStatusesUpdateOriginalApplyOutcomes() async throws {
        let report = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(),
            includesMutation: true)
        let failedFixture = try await DatabaseExecutorFixtures.make(report: report)
        defer { try? FileManager.default.removeItem(at: failedFixture.directory) }
        let failedMutation = DatabaseExecutorFixtures.mutationRequest(
            connection: failedFixture.connection)
        await failedFixture.session.setMutationResult(
            try DatabaseAdapterMutationResult(
                disposition: .accepted,
                effect: .unknown,
                affectedRecords: DatabaseCountMetadata(accuracy: .unknown),
                serverOperationIdentifier: "failed-server-task"))
        let failedPreview = await failedFixture.executor.previewMutation(
            DatabaseMutationPreviewRequest(
                mutation: failedMutation,
                operation: DatabaseExecutorFixtures.operation(98)))
        let failedIssued = try #require(failedPreview.payload?.preview)
        let failedApply = await failedFixture.executor.applyMutation(
            DatabaseMutationApplyRequest(
                mutation: failedMutation,
                token: failedIssued.token,
                confirmationText: failedIssued.requiredConfirmation.text,
                operation: DatabaseExecutorFixtures.operation(99)))
        let failedAccepted = try #require(failedApply.payload?.acceptedMutation)
        let partialError = DatabaseErrorEnvelope(
            category: .partialFailure,
            message: "A bounded mutation item failed.",
            partialResult: DatabaseResultCompleteness(state: .partial))
        let partialOutcome = try DatabaseAdapterMutationResult(
            disposition: .completed,
            effect: .partiallyApplied,
            affectedRecords: DatabaseCountMetadata(value: 4, accuracy: .lowerBound),
            serverOperationIdentifier: failedAccepted.serverOperationIdentifier,
            partialFailures: [
                DatabasePartialFailure(itemIndex: 4, error: partialError)
            ],
            error: partialError)
        await failedFixture.session.enqueueMutationStatus(
            .success(
                try DatabaseAdapterMutationStatus(
                    serverOperationIdentifier: failedAccepted.serverOperationIdentifier,
                    state: .failed,
                    outcome: partialOutcome,
                    error: partialError)))

        let failedStatus = await failedFixture.executor.mutationStatus(
            DatabaseMutationStatusRequest(
                connectionID: failedFixture.connection.id,
                acceptedMutation: failedAccepted,
                operation: DatabaseExecutorFixtures.operation(100)))
        let failedPersisted = try await failedFixture.store.mutationOutcome(
            operationID: failedAccepted.operationID)

        #expect(failedStatus.status == .succeeded)
        #expect(failedStatus.payload?.state == .failed)
        #expect(failedStatus.payload?.outcome?.effect == .partiallyApplied)
        #expect(failedStatus.payload?.outcome?.partialFailures.count == 1)
        #expect(failedPersisted == failedStatus.payload?.outcome)

        let cancelledFixture = try await DatabaseExecutorFixtures.make(report: report)
        defer { try? FileManager.default.removeItem(at: cancelledFixture.directory) }
        let cancelledMutation = DatabaseExecutorFixtures.mutationRequest(
            connection: cancelledFixture.connection)
        await cancelledFixture.session.setMutationResult(
            try DatabaseAdapterMutationResult(
                disposition: .accepted,
                effect: .unknown,
                affectedRecords: DatabaseCountMetadata(accuracy: .unknown),
                serverOperationIdentifier: "cancelled-server-task"))
        let cancelledPreview = await cancelledFixture.executor.previewMutation(
            DatabaseMutationPreviewRequest(
                mutation: cancelledMutation,
                operation: DatabaseExecutorFixtures.operation(101)))
        let cancelledIssued = try #require(cancelledPreview.payload?.preview)
        let cancelledApply = await cancelledFixture.executor.applyMutation(
            DatabaseMutationApplyRequest(
                mutation: cancelledMutation,
                token: cancelledIssued.token,
                confirmationText: cancelledIssued.requiredConfirmation.text,
                operation: DatabaseExecutorFixtures.operation(102)))
        let cancelledAccepted = try #require(cancelledApply.payload?.acceptedMutation)
        let notApplied = try DatabaseAdapterMutationResult(
            disposition: .completed,
            effect: .notApplied,
            affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .exact),
            serverOperationIdentifier: cancelledAccepted.serverOperationIdentifier)
        let cancelledStatus = try DatabaseAdapterMutationStatus(
            serverOperationIdentifier: cancelledAccepted.serverOperationIdentifier,
            state: .cancelled,
            outcome: notApplied)
        await cancelledFixture.session.enqueueMutationCancellation(
            .success(
                try DatabaseAdapterMutationCancellationResult(
                    serverOperationIdentifier: cancelledAccepted.serverOperationIdentifier,
                    disposition: .alreadyFinished,
                    status: cancelledStatus)))

        let cancellation = await cancelledFixture.executor.cancelMutation(
            DatabaseMutationCancelRequest(
                connectionID: cancelledFixture.connection.id,
                acceptedMutation: cancelledAccepted,
                operation: DatabaseExecutorFixtures.operation(103)))
        let cancelledPersisted = try await cancelledFixture.store.mutationOutcome(
            operationID: cancelledAccepted.operationID)

        #expect(cancellation.status == .succeeded)
        #expect(cancellation.payload?.status?.state == .cancelled)
        #expect(cancellation.payload?.status?.outcome?.effect == .notApplied)
        #expect(cancelledPersisted == cancellation.payload?.status?.outcome)
    }

    @Test func mutationReconciliationRequiresCapabilitiesAndExactServerIdentifiers() async throws {
        let unsupported = try await DatabaseExecutorFixtures.make()
        defer { try? FileManager.default.removeItem(at: unsupported.directory) }
        let unsupportedResult = await unsupported.executor.mutationStatus(
            DatabaseMutationStatusRequest(
                connectionID: unsupported.connection.id,
                acceptedMutation: DatabaseAcceptedMutation(
                    operationID: DatabaseExecutorFixtures.operation(91).operationID,
                    serverOperationIdentifier: "server-task-42"),
                operation: DatabaseExecutorFixtures.operation(88)))

        #expect(unsupportedResult.status == .failed)
        #expect(unsupportedResult.error?.category == .unsupported)
        #expect(
            await unsupported.session.snapshot().invocations.contains {
                if case .mutationStatus = $0 { return true }
                return false
            } == false)

        let report = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(),
            includesMutation: true)
        let fixture = try await DatabaseExecutorFixtures.make(report: report)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let mutation = DatabaseExecutorFixtures.mutationRequest(
            connection: fixture.connection)
        await fixture.session.setMutationResult(
            try DatabaseAdapterMutationResult(
                disposition: .accepted,
                effect: .unknown,
                affectedRecords: DatabaseCountMetadata(accuracy: .unknown),
                serverOperationIdentifier: "server-task-42"))
        let preview = await fixture.executor.previewMutation(
            DatabaseMutationPreviewRequest(
                mutation: mutation,
                operation: DatabaseExecutorFixtures.operation(92)))
        let issued = try #require(preview.payload?.preview)
        let apply = await fixture.executor.applyMutation(
            DatabaseMutationApplyRequest(
                mutation: mutation,
                token: issued.token,
                confirmationText: issued.requiredConfirmation.text,
                operation: DatabaseExecutorFixtures.operation(93)))
        let acceptedMutation = try #require(apply.payload?.acceptedMutation)
        let wrongOperation = await fixture.executor.mutationStatus(
            DatabaseMutationStatusRequest(
                connectionID: fixture.connection.id,
                acceptedMutation: DatabaseAcceptedMutation(
                    operationID: DatabaseExecutorFixtures.operation(104).operationID,
                    serverOperationIdentifier: acceptedMutation.serverOperationIdentifier),
                operation: DatabaseExecutorFixtures.operation(105)))
        let wrongServer = await fixture.executor.mutationStatus(
            DatabaseMutationStatusRequest(
                connectionID: fixture.connection.id,
                acceptedMutation: DatabaseAcceptedMutation(
                    operationID: acceptedMutation.operationID,
                    serverOperationIdentifier: "different-client-server-task"),
                operation: DatabaseExecutorFixtures.operation(106)))

        #expect(wrongOperation.status == .failed)
        #expect(wrongOperation.error?.category == .conflict)
        #expect(wrongServer.status == .failed)
        #expect(wrongServer.error?.category == .conflict)
        await fixture.session.enqueueMutationStatus(
            .success(
                try DatabaseAdapterMutationStatus(
                    serverOperationIdentifier: "different-server-task",
                    state: .running)))
        await fixture.session.enqueueMutationCancellation(
            .success(
                try DatabaseAdapterMutationCancellationResult(
                    serverOperationIdentifier: "different-server-task",
                    disposition: .accepted)))

        let status = await fixture.executor.mutationStatus(
            DatabaseMutationStatusRequest(
                connectionID: fixture.connection.id,
                acceptedMutation: acceptedMutation,
                operation: DatabaseExecutorFixtures.operation(89)))
        let cancellation = await fixture.executor.cancelMutation(
            DatabaseMutationCancelRequest(
                connectionID: fixture.connection.id,
                acceptedMutation: acceptedMutation,
                operation: DatabaseExecutorFixtures.operation(90)))

        #expect(status.status == .failed)
        #expect(status.error?.category == .internalFailure)
        #expect(cancellation.status == .failed)
        #expect(cancellation.error?.category == .internalFailure)
    }

    @Test func mutationBrokerPayloadsRedactResolvedSecrets() async throws {
        let secret = "mutation-result-secret"
        let reference = DatabaseSecretReference(
            identifier: DatabaseExecutorFixtures.uuid(80),
            purpose: .password)
        let connection = try DatabaseExecutorFixtures.connection(
            name: "Orders \(secret)",
            secretReference: reference)
        let report = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(),
            includesMutation: true)
        let fixture = try await DatabaseExecutorFixtures.make(
            connection: connection,
            report: report,
            secretValues: [reference: Data(secret.utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let returnedPage = try DatabaseAdapterPage(
            records: [
                DatabaseRecord(
                    identity: DatabaseRecordIdentity(
                        kind: .primaryKey,
                        components: [
                            DatabaseIdentityComponent(
                                name: "id-\(secret)",
                                value: .string(secret))
                        ]),
                    fields: [
                        DatabaseObjectField(
                            name: "value-\(secret)",
                            value: .string(secret))
                    ],
                    metadata: [DatabaseStringAttribute(name: "meta", value: secret)])
            ],
            fields: [
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("value-\(secret)"),
                    displayName: "Value \(secret)",
                    typeName: "text-\(secret)",
                    isNullable: false,
                    isSortable: false,
                    isFilterable: false)
            ],
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(state: .complete),
                count: DatabaseCountMetadata(value: 1, accuracy: .exact),
                warnings: [
                    DatabaseWarning(
                        code: "server.\(secret)",
                        message: "Server reported \(secret)",
                        severity: .caution)
                ]))
        await fixture.session.setMutationResult(
            try DatabaseAdapterMutationResult(
                disposition: .completed,
                effect: .partiallyApplied,
                affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .exact),
                returnedPage: returnedPage,
                serverOperationIdentifier: "job-\(secret)",
                partialFailures: [
                    DatabasePartialFailure(
                        itemIdentifier: "item-\(secret)",
                        error: DatabaseErrorEnvelope(
                            category: .partialFailure,
                            message: "Partial failure \(secret)"))
                ],
                error: DatabaseErrorEnvelope(
                    category: .partialFailure,
                    message: "Mutation result \(secret)")))
        let mutation = DatabaseExecutorFixtures.mutationRequest(connection: connection)
        let preview = await fixture.executor.previewMutation(
            DatabaseMutationPreviewRequest(
                mutation: mutation,
                operation: DatabaseExecutorFixtures.operation(81)))
        let issued = try #require(preview.payload?.preview)
        let applyOperation = DatabaseExecutorFixtures.operation(82)

        let applied = await fixture.executor.applyMutation(
            DatabaseMutationApplyRequest(
                mutation: mutation,
                token: issued.token,
                confirmationText: issued.requiredConfirmation.text,
                operation: applyOperation))
        let recovered = await fixture.executor.mutationOutcome(
            DatabaseMutationOutcomeGetRequest(operationID: applyOperation.operationID))
        let encodedPreview = String(
            decoding: try JSONEncoder().encode(preview),
            as: UTF8.self)
        let encodedApply = String(
            decoding: try JSONEncoder().encode(applied),
            as: UTF8.self)
        let encodedRecovery = String(
            decoding: try JSONEncoder().encode(recovered),
            as: UTF8.self)

        #expect(preview.status == .succeeded)
        #expect(applied.status == .succeeded)
        #expect(recovered.status == .succeeded)
        #expect(recovered.payload?.outcome == applied.payload)
        #expect(applied.payload?.effect == .partiallyApplied)
        #expect(applied.payload?.partialFailures.count == 1)
        #expect(applied.payload?.error?.category == .partialFailure)
        #expect(!encodedPreview.contains(secret))
        #expect(!encodedApply.contains(secret))
        #expect(!encodedRecovery.contains(secret))
        #expect(encodedPreview.contains(DatabaseSecretRedactor.defaultReplacement))
        #expect(encodedApply.contains(DatabaseSecretRedactor.defaultReplacement))
        #expect(encodedRecovery.contains(DatabaseSecretRedactor.defaultReplacement))
    }

    @Test func connectAndDisconnectReturnTypedResultsAndPersistTerminalHistory() async throws {
        let fixture = try await DatabaseExecutorFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connectOperation = DatabaseExecutorFixtures.operation(1)
        let connect = await fixture.executor.connect(
            DatabaseConnectRequest(
                connectionID: fixture.connection.id,
                operation: connectOperation))

        #expect(connect.status == .succeeded)
        #expect(connect.error == nil)
        let connected = try #require(connect.payload)
        #expect(connected.connection == fixture.connection.identity)
        #expect(connected.productIdentity == fixture.report.productIdentity)
        #expect(connected.capabilities == fixture.report)
        #expect(connected.connectedAt == DatabaseExecutorFixtures.now)
        let connectSummary = try #require(connect.metadata.operation)
        #expect(connectSummary.id == connectOperation.operationID)
        #expect(connectSummary.kind == .databaseConnect)
        #expect(connectSummary.state == .succeeded)
        #expect(connectSummary.finishedAt == DatabaseExecutorFixtures.now)
        #expect(
            try await fixture.store.operation(id: connectOperation.operationID) == connectSummary)

        let disconnectOperation = DatabaseExecutorFixtures.operation(2)
        let disconnect = await fixture.executor.disconnect(
            DatabaseDisconnectRequest(
                connectionID: fixture.connection.id,
                operation: disconnectOperation))

        #expect(disconnect.status == .succeeded)
        let disconnected = try #require(disconnect.payload)
        #expect(disconnected.connection == fixture.connection.identity)
        #expect(disconnected.disconnected)
        #expect(disconnected.disconnectedAt == DatabaseExecutorFixtures.now)
        let disconnectSummary = try #require(disconnect.metadata.operation)
        #expect(disconnectSummary.kind == .databaseDisconnect)
        #expect(disconnectSummary.state == .succeeded)
        #expect(
            try await fixture.store.operation(id: disconnectOperation.operationID)
                == disconnectSummary)
        let sessionSnapshot = await fixture.session.snapshot()
        #expect(sessionSnapshot.state == .disconnected)
        #expect(sessionSnapshot.disconnectCount == 1)
    }

    @Test func duplicateOperationIdentifierIsAtomicallyRejectedAcrossExecutors() async throws {
        let connectGate = DatabaseExecutorTestGate(open: false)
        let fixture = try await DatabaseExecutorFixtures.make(
            adapterGates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let secondStore = try SQLiteDatabaseMetadataStore(path: fixture.path)
        let secondExecutor = try DatabaseExecutor(
            metadataStore: secondStore,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.runtimeOwner,
            adapters: [fixture.adapter],
            currentDate: { DatabaseExecutorFixtures.now })
        let operation = DatabaseExecutorFixtures.operation(3)
        let request = DatabaseConnectRequest(
            connectionID: fixture.connection.id,
            operation: operation)

        let firstTask = Task { await fixture.executor.connect(request) }
        await connectGate.waitForEntries()
        let duplicate = await secondExecutor.connect(request)

        #expect(duplicate.status == .failed)
        #expect(duplicate.error?.category == .conflict)
        #expect(duplicate.payload == nil)
        #expect(duplicate.metadata.operation == nil)
        #expect(await fixture.adapter.recordedInvocations().count == 1)

        await connectGate.releaseAll()
        let first = await firstTask.value
        #expect(first.status == .succeeded)
        let persisted = try #require(
            try await fixture.store.operation(id: operation.operationID))
        #expect(persisted.state == .succeeded)
        #expect(persisted.kind == .databaseConnect)
    }

    @Test func capabilitiesUseCacheUnlessRefreshIsExplicit() async throws {
        let fixture = try await DatabaseExecutorFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connectOperation = DatabaseExecutorFixtures.operation(4)
        let connected = await fixture.executor.connect(
            DatabaseConnectRequest(
                connectionID: fixture.connection.id,
                operation: connectOperation))
        #expect(connected.status == .succeeded)

        let cachedOperation = DatabaseExecutorFixtures.operation(5)
        let cached = await fixture.executor.capabilities(
            DatabaseCapabilitiesRequest(
                connectionID: fixture.connection.id,
                operation: cachedOperation))
        #expect(cached.status == .succeeded)
        #expect(cached.payload?.source == .cached)
        #expect(cached.payload?.report == fixture.report)
        #expect(DatabaseExecutorFixtures.discoveryCount(await fixture.session.snapshot()) == 1)

        let refreshedReport = DatabaseExecutorFixtures.report(
            identity: fixture.report.productIdentity,
            discoveredAt: DatabaseExecutorFixtures.now,
            includesQuery: true)
        await fixture.session.setCapabilities(refreshedReport)
        let refreshOperation = DatabaseExecutorFixtures.operation(6)
        let refreshed = await fixture.executor.capabilities(
            DatabaseCapabilitiesRequest(
                connectionID: fixture.connection.id,
                resolution: .refresh,
                operation: refreshOperation))

        #expect(refreshed.status == .succeeded)
        #expect(refreshed.payload?.source == .discovered)
        #expect(refreshed.payload?.report == refreshedReport)
        #expect(DatabaseExecutorFixtures.discoveryCount(await fixture.session.snapshot()) == 2)
        #expect(
            try await fixture.store.operation(id: cachedOperation.operationID)?.state
                == .succeeded)
        #expect(
            try await fixture.store.operation(id: refreshOperation.operationID)?.state
                == .succeeded)
    }

    @Test func browseAndQueryProtectAdapterContinuations() async throws {
        let report = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(),
            includesQuery: true)
        let fixture = try await DatabaseExecutorFixtures.make(report: report)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let target = DatabaseExecutorFixtures.target(fixture.connection.id)
        let adapterContinuation = try DatabaseAdapterContinuation(
            mode: .keyset,
            payload: Data("adapter-position".utf8),
            expiresAt: DatabaseExecutorFixtures.now.addingTimeInterval(300))
        let continuedPage = try DatabaseAdapterPage(
            records: [],
            nextContinuation: adapterContinuation,
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(state: .complete),
                count: DatabaseCountMetadata(value: 0, accuracy: .exact)))
        await fixture.session.setPage(continuedPage)
        let firstBrowse = await fixture.executor.browse(
            DatabaseBrowseRequest(
                target: target,
                operation: DatabaseExecutorFixtures.operation(61)))

        #expect(firstBrowse.status == .succeeded)
        let browseToken = try #require(firstBrowse.payload?.page.nextContinuation)
        #expect(!browseToken.rawValue.contains("adapter-position"))
        await fixture.session.setPage(try DatabaseExecutorFixtures.page())
        let secondBrowse = await fixture.executor.browse(
            DatabaseBrowseRequest(
                target: target,
                page: DatabasePageRequest(continuation: browseToken),
                operation: DatabaseExecutorFixtures.operation(62)))
        #expect(secondBrowse.status == .succeeded)

        await fixture.session.setQueryPage(continuedPage)
        let firstQuery = await fixture.executor.query(
            DatabaseQueryRequest(
                target: target,
                language: .sql,
                command: "SELECT * FROM orders",
                operation: DatabaseExecutorFixtures.operation(63)))
        #expect(firstQuery.status == .succeeded)
        let queryToken = try #require(firstQuery.payload?.page.nextContinuation)
        #expect(queryToken != browseToken)
        await fixture.session.setQueryPage(try DatabaseExecutorFixtures.page())
        let secondQuery = await fixture.executor.query(
            DatabaseQueryRequest(
                target: target,
                language: .sql,
                command: "SELECT * FROM orders",
                page: DatabasePageRequest(continuation: queryToken),
                operation: DatabaseExecutorFixtures.operation(64)))
        #expect(secondQuery.status == .succeeded)

        let invalidContinuation = await fixture.executor.browse(
            DatabaseBrowseRequest(
                target: target,
                page: DatabasePageRequest(
                    continuation: DatabaseContinuationToken(
                        rawValue: browseToken.rawValue + "x")),
                operation: DatabaseExecutorFixtures.operation(65)))
        #expect(invalidContinuation.status == .failed)
        #expect(invalidContinuation.error?.category == .invalidRequest)
        #expect(invalidContinuation.error?.target == target)

        let invocations = await fixture.session.snapshot().invocations
        let browseContinuations: [DatabaseAdapterContinuation] = invocations.compactMap {
            invocation in
            guard case .readPage(let request, _) = invocation else { return nil }
            return request.continuation
        }
        let queryContinuations: [DatabaseAdapterContinuation] = invocations.compactMap {
            invocation in
            guard case .query(let request, _) = invocation else { return nil }
            return request.source.continuation
        }
        #expect(browseContinuations.count == 1)
        #expect(browseContinuations.first?.payload == adapterContinuation.payload)
        #expect(queryContinuations.count == 1)
        #expect(queryContinuations.first?.payload == adapterContinuation.payload)
    }

    @Test func connectionTestsAreEphemeralAcrossSuccessAndFailure() async throws {
        let fixture = try await DatabaseExecutorFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstTestOperation = DatabaseExecutorFixtures.operation(7)
        let firstTest = await fixture.executor.testConnection(
            DatabaseConnectionTestRequest(
                connection: fixture.connection,
                operation: firstTestOperation))

        #expect(firstTest.status == .succeeded)
        #expect(firstTest.payload?.connection == fixture.connection.identity)
        #expect(firstTest.payload?.productIdentity == fixture.report.productIdentity)
        #expect(firstTest.payload?.capabilities == fixture.report)
        #expect(await fixture.session.snapshot().disconnectCount == 1)
        #expect(
            try await fixture.store.operation(id: firstTestOperation.operationID)?.state
                == .succeeded)

        let sharedSession = try DatabaseExecutorFixtures.session(
            id: DatabaseExecutorFixtures.sessionID(2),
            connection: fixture.connection,
            report: fixture.report)
        await fixture.adapter.setSession(sharedSession)
        let connect = await fixture.executor.connect(
            DatabaseConnectRequest(
                connectionID: fixture.connection.id,
                operation: DatabaseExecutorFixtures.operation(8)))
        #expect(connect.status == .succeeded)

        let failingSession = try DatabaseExecutorFixtures.session(
            id: DatabaseExecutorFixtures.sessionID(3),
            connection: fixture.connection,
            report: fixture.report)
        await failingSession.enqueueCapabilities(
            .failure(
                .reported(
                    DatabaseErrorEnvelope(
                        category: .server,
                        message: "Capability discovery failed."))))
        await fixture.adapter.setSession(failingSession)
        let failedTestOperation = DatabaseExecutorFixtures.operation(9)
        let failedTest = await fixture.executor.testConnection(
            DatabaseConnectionTestRequest(
                connection: fixture.connection,
                operation: failedTestOperation))

        #expect(failedTest.status == .failed)
        #expect(failedTest.error?.category == .server)
        #expect(await failingSession.snapshot().disconnectCount == 1)
        #expect(
            try await fixture.store.operation(id: failedTestOperation.operationID)?.state
                == .failed)

        let cached = await fixture.executor.capabilities(
            DatabaseCapabilitiesRequest(
                connectionID: fixture.connection.id,
                operation: DatabaseExecutorFixtures.operation(10)))
        #expect(cached.status == .succeeded)
        #expect(cached.payload?.source == .cached)
        #expect(await sharedSession.snapshot().disconnectCount == 0)
        #expect(await fixture.adapter.recordedInvocations().count == 3)
    }

    @Test func taskCancellationPersistsACancelledTerminalState() async throws {
        let connectGate = DatabaseExecutorTestGate(open: false)
        let fixture = try await DatabaseExecutorFixtures.make(
            adapterGates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let operation = DatabaseExecutorFixtures.operation(11)
        let task = Task {
            await fixture.executor.connect(
                DatabaseConnectRequest(
                    connectionID: fixture.connection.id,
                    operation: operation))
        }
        await connectGate.waitForEntries()

        task.cancel()
        await connectGate.releaseAll()
        let result = await task.value

        #expect(result.status == .failed)
        #expect(result.error?.category == .cancelled)
        #expect(result.metadata.operation?.state == .cancelled)
        let persisted = try #require(
            try await fixture.store.operation(id: operation.operationID))
        #expect(persisted.state == .cancelled)
        #expect(persisted.error?.category == .cancelled)
    }

    @Test func runtimeDeadlinePersistsATimeoutTerminalState() async throws {
        let connectGate = DatabaseExecutorTestGate(open: false)
        let fixture = try await DatabaseExecutorFixtures.make(
            adapterGates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let operation = DatabaseExecutorFixtures.operation(
            12,
            deadline: DatabaseExecutorFixtures.now.addingTimeInterval(0.01))
        let task = Task {
            await fixture.executor.connect(
                DatabaseConnectRequest(
                    connectionID: fixture.connection.id,
                    operation: operation))
        }
        await connectGate.waitForEntries()
        try await Task.sleep(nanoseconds: 100_000_000)
        await connectGate.releaseAll()
        let result = await task.value

        #expect(result.status == .failed)
        #expect(result.error?.category == .timeout)
        #expect(result.metadata.operation?.state == .failed)
        let persisted = try #require(
            try await fixture.store.operation(id: operation.operationID))
        #expect(persisted.state == .failed)
        #expect(persisted.error?.category == .timeout)
    }

    @Test func missingConnectionEvictsTheCachedSession() async throws {
        let fixture = try await DatabaseExecutorFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let connected = await fixture.executor.connect(
            DatabaseConnectRequest(
                connectionID: fixture.connection.id,
                operation: DatabaseExecutorFixtures.operation(13)))
        #expect(connected.status == .succeeded)
        #expect(try await fixture.store.removeSeededConnection(id: fixture.connection.id))

        let missingOperation = DatabaseExecutorFixtures.operation(14)
        let missing = await fixture.executor.capabilities(
            DatabaseCapabilitiesRequest(
                connectionID: fixture.connection.id,
                operation: missingOperation))

        #expect(missing.status == .failed)
        #expect(missing.error?.category == .invalidRequest)
        #expect(missing.payload == nil)
        #expect(missing.metadata.operation == nil)
        #expect(try await fixture.store.operation(id: missingOperation.operationID) == nil)
        let snapshot = await fixture.session.snapshot()
        #expect(snapshot.state == .disconnected)
        #expect(snapshot.disconnectCount == 1)
    }

    @Test func adapterFailuresAreRedactedBeforeResultsAndHistory() async throws {
        let secret = "known-database-secret"
        let reference = DatabaseSecretReference(
            identifier: DatabaseExecutorFixtures.uuid(20),
            purpose: .password)
        let connection = try DatabaseExecutorFixtures.connection(
            name: "Orders \(secret)",
            secretReference: reference)
        let fixture = try await DatabaseExecutorFixtures.make(
            connection: connection,
            secretValues: [reference: Data(secret.utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let target = DatabaseTargetIdentifier(
            connectionID: connection.id,
            object: DatabaseObjectIdentifier(kind: .table, path: [secret]),
            record: DatabaseRecordIdentity(
                kind: .primaryKey,
                components: [
                    DatabaseIdentityComponent(name: "id", value: .string(secret))
                ]))
        await fixture.adapter.enqueueFailure(
            .reported(
                DatabaseErrorEnvelope(
                    category: .network,
                    message: "Network failure \(secret)",
                    productCode: "code-\(secret)",
                    target: target,
                    retry: DatabaseRetryGuidance(
                        action: .reconnect,
                        message: "Reconnect with \(secret)"),
                    details: [
                        DatabaseErrorDetail(name: "credential", value: secret)
                    ])))
        let operation = DatabaseExecutorFixtures.operation(15)
        let result = await fixture.executor.connect(
            DatabaseConnectRequest(
                connectionID: connection.id,
                operation: operation))

        #expect(result.status == .failed)
        #expect(result.error?.category == .network)
        let resultText = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!resultText.contains(secret))
        #expect(resultText.contains(DatabaseSecretRedactor.defaultReplacement))
        let persisted = try #require(
            try await fixture.store.operation(id: operation.operationID))
        let historyText = String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self)
        #expect(!historyText.contains(secret))
        #expect(historyText.contains(DatabaseSecretRedactor.defaultReplacement))
        #expect(persisted.error?.category == .network)
    }

    @Test func failureInOneSessionDoesNotDisturbAnotherConnection() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDatabaseMetadataStore(path: path)
        let postgres = try DatabaseExecutorFixtures.connection(
            id: DatabaseExecutorFixtures.connectionID(2),
            name: "PostgreSQL",
            product: .postgresql)
        let redis = try DatabaseExecutorFixtures.connection(
            id: DatabaseExecutorFixtures.connectionID(3),
            name: "Redis",
            product: .redis)
        try await store.seedConnection(postgres)
        try await store.seedConnection(redis)
        let runtimeOwner = try await store.claimRuntimeOwner(
            claimedAt: DatabaseExecutorFixtures.now.addingTimeInterval(-1)
        ).owner.token
        let postgresReport = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(product: .postgresql))
        let redisReport = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(product: .redis))
        let postgresSession = try DatabaseExecutorFixtures.session(
            id: DatabaseExecutorFixtures.sessionID(4),
            connection: postgres,
            report: postgresReport)
        let redisSession = try DatabaseExecutorFixtures.session(
            id: DatabaseExecutorFixtures.sessionID(5),
            connection: redis,
            report: redisReport)
        let postgresAdapter = DatabaseExecutorRecordingAdapter(
            id: "postgres-recording",
            products: [.postgresql],
            session: postgresSession)
        let redisAdapter = DatabaseExecutorRecordingAdapter(
            id: "redis-recording",
            products: [.redis],
            session: redisSession)
        let secretStore = try InMemoryDatabaseSecretStore()
        let executor = try DatabaseExecutor(
            metadataStore: store,
            secretStore: secretStore,
            runtimeOwner: runtimeOwner,
            adapters: [postgresAdapter, redisAdapter],
            currentDate: { DatabaseExecutorFixtures.now })

        #expect(
            await executor.connect(
                DatabaseConnectRequest(
                    connectionID: postgres.id,
                    operation: DatabaseExecutorFixtures.operation(16))
            )
            .status == .succeeded)
        #expect(
            await executor.connect(
                DatabaseConnectRequest(
                    connectionID: redis.id,
                    operation: DatabaseExecutorFixtures.operation(17))
            )
            .status == .succeeded)

        await postgresSession.setState(.failed)
        await postgresAdapter.enqueueFailure(
            .reported(
                DatabaseErrorEnvelope(
                    category: .network,
                    message: "PostgreSQL disconnected.")))
        let postgresFailureOperation = DatabaseExecutorFixtures.operation(18)
        let postgresFailure = await executor.capabilities(
            DatabaseCapabilitiesRequest(
                connectionID: postgres.id,
                operation: postgresFailureOperation))
        let redisOperation = DatabaseExecutorFixtures.operation(19)
        let redisResult = await executor.capabilities(
            DatabaseCapabilitiesRequest(
                connectionID: redis.id,
                operation: redisOperation))

        #expect(postgresFailure.status == .failed)
        #expect(postgresFailure.error?.category == .network)
        #expect(redisResult.status == .succeeded)
        #expect(redisResult.payload?.source == .cached)
        #expect(await postgresSession.snapshot().disconnectCount == 1)
        #expect(await redisSession.snapshot().disconnectCount == 0)
        #expect(await redisAdapter.recordedInvocations().count == 1)
        #expect(
            try await store.operation(id: postgresFailureOperation.operationID)?.state == .failed)
        #expect(try await store.operation(id: redisOperation.operationID)?.state == .succeeded)
    }

    @Test func unexpectedMetadataErrorsRemainOpaque() async throws {
        let connection = try DatabaseExecutorFixtures.connection()
        let report = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity())
        let session = try DatabaseExecutorFixtures.session(
            connection: connection,
            report: report)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "unexpected-store",
            products: [.postgresql],
            session: session)
        let executor = try DatabaseExecutor(
            metadataStore: DatabaseExecutorUnexpectedMetadataStore(),
            secretStore: InMemoryDatabaseSecretStore(),
            runtimeOwner: DatabaseExecutorFixtures.runtimeOwner,
            adapters: [adapter],
            currentDate: { DatabaseExecutorFixtures.now })
        let result = await executor.connect(
            DatabaseConnectRequest(
                connectionID: connection.id,
                operation: DatabaseExecutorFixtures.operation(20)))

        #expect(result.status == .failed)
        #expect(result.error?.category == .internalFailure)
        #expect(result.error?.message == "The database operation failed unexpectedly.")
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!encoded.contains("private-unexpected-store-marker"))
        #expect(await adapter.recordedInvocations().isEmpty)
    }

    @Test func connectionTestUsesOwnedHistoryBeforeTheDefinitionIsSaved() async throws {
        let fixture = try await DatabaseExecutorFixtures.make(saveConnection: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(try await fixture.store.connection(id: fixture.connection.id) == nil)
        let operation = DatabaseExecutorFixtures.operation(21)
        let request = DatabaseConnectionTestRequest(
            connection: fixture.connection,
            operation: operation)

        let first = await fixture.executor.testConnection(request)
        let duplicate = await fixture.executor.testConnection(request)

        #expect(first.status == .succeeded)
        #expect(first.payload?.connection == fixture.connection.identity)
        #expect(first.metadata.operation?.state == .succeeded)
        #expect(duplicate.status == .failed)
        #expect(duplicate.error?.category == .conflict)
        #expect(await fixture.adapter.recordedInvocations().count == 1)
        #expect(await fixture.session.snapshot().disconnectCount == 1)
        #expect(
            try await fixture.store.operation(id: operation.operationID)
                == first.metadata.operation)
    }

    @Test func configuredAndCallerDeadlinesArePersistedAsTheEffectiveDeadline() async throws {
        let connection = try DatabaseExecutorFixtures.connection(
            connectionTimeoutMilliseconds: 500,
            operationTimeoutMilliseconds: 900)
        let fixture = try await DatabaseExecutorFixtures.make(connection: connection)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let configuredConnect = await fixture.executor.connect(
            DatabaseConnectRequest(
                connectionID: connection.id,
                operation: DatabaseExecutorFixtures.operation(22)))
        #expect(
            configuredConnect.metadata.operation?.deadline
                == DatabaseExecutorFixtures.now.addingTimeInterval(0.5))

        let configuredCapabilities = await fixture.executor.capabilities(
            DatabaseCapabilitiesRequest(
                connectionID: connection.id,
                operation: DatabaseExecutorFixtures.operation(23)))
        #expect(
            configuredCapabilities.metadata.operation?.deadline
                == DatabaseExecutorFixtures.now.addingTimeInterval(0.9))

        let callerDeadline = DatabaseExecutorFixtures.now.addingTimeInterval(0.1)
        let callerEarlier = await fixture.executor.connect(
            DatabaseConnectRequest(
                connectionID: connection.id,
                operation: DatabaseExecutorFixtures.operation(
                    24,
                    deadline: callerDeadline)))
        #expect(callerEarlier.status == .succeeded)
        #expect(callerEarlier.metadata.operation?.deadline == callerDeadline)
    }

    @Test func configuredConnectionTimeoutCancelsAndCleansTheActiveRegistry() async throws {
        let connectGate = DatabaseExecutorTestGate(open: false)
        let connection = try DatabaseExecutorFixtures.connection(
            connectionTimeoutMilliseconds: 100)
        let fixture = try await DatabaseExecutorFixtures.make(
            connection: connection,
            adapterGates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.adapter.setHonorsContextCancellation(false)
        let operation = DatabaseExecutorFixtures.operation(25)
        let task = Task {
            await fixture.executor.connect(
                DatabaseConnectRequest(
                    connectionID: connection.id,
                    operation: operation))
        }
        await connectGate.waitForEntries()

        let result = await task.value

        #expect(result.status == .failed)
        #expect(result.error?.category == .timeout)
        #expect(
            result.metadata.operation?.deadline
                == DatabaseExecutorFixtures.now.addingTimeInterval(0.1))
        #expect(await fixture.executor.activeOperationCount() == 0)
        #expect(
            try await fixture.store.operation(id: operation.operationID)?.state
                == .failed)
        await connectGate.releaseAll()
    }

    @Test func inactiveRuntimeOwnerRejectsWorkBeforeHistoryOrAdapterAccess() async throws {
        let fixture = try await DatabaseExecutorFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(
            try await fixture.store.releaseRuntimeOwner(
                fixture.runtimeOwner,
                releasedAt: DatabaseExecutorFixtures.now))
        let operation = DatabaseExecutorFixtures.operation(26)

        let result = await fixture.executor.connect(
            DatabaseConnectRequest(
                connectionID: fixture.connection.id,
                operation: operation))

        #expect(result.status == .failed)
        #expect(result.error?.category == .conflict)
        #expect(result.metadata.operation == nil)
        #expect(try await fixture.store.operation(id: operation.operationID) == nil)
        #expect(await fixture.adapter.recordedInvocations().isEmpty)
        #expect(await fixture.executor.activeOperationCount() == 0)
    }

    @Test func capabilityRefreshCancellationUsesItsCooperativeSharedContext() async throws {
        let fixture = try await DatabaseExecutorFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(
            await fixture.executor.connect(
                DatabaseConnectRequest(
                    connectionID: fixture.connection.id,
                    operation: DatabaseExecutorFixtures.operation(27))
            ).status == .succeeded)
        await fixture.session.gates.discoverCapabilities.block()
        await fixture.session.gates.cancel.block()
        let operation = DatabaseExecutorFixtures.operation(28)
        let task = Task {
            await fixture.executor.capabilities(
                DatabaseCapabilitiesRequest(
                    connectionID: fixture.connection.id,
                    resolution: .refresh,
                    operation: operation))
        }
        await fixture.session.gates.discoverCapabilities.waitForEntries(2)

        let cancellation = await fixture.executor.cancel(
            DatabaseOperationCancelRequest(operationID: operation.operationID))
        let result = await task.value
        let repeated = await fixture.executor.cancel(
            DatabaseOperationCancelRequest(operationID: operation.operationID))

        #expect(cancellation.status == .succeeded)
        #expect(cancellation.payload?.disposition == .accepted)
        #expect(cancellation.payload?.cancellationSupport == .cooperative)
        #expect(result.status == .failed)
        #expect(result.error?.category == .cancelled)
        #expect(repeated.payload?.disposition == .alreadyFinished)
        #expect(await fixture.session.snapshot().cancelledOperationIDs.isEmpty)
        #expect(await fixture.session.gates.cancel.blockedCount() == 0)
        #expect(await fixture.executor.activeOperationCount() == 0)
        await fixture.session.gates.discoverCapabilities.releaseAll()
    }

    @Test func disconnectCancelsOnlyOtherOperationsForItsConnection() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDatabaseMetadataStore(path: path)
        let firstConnection = try DatabaseExecutorFixtures.connection(
            id: DatabaseExecutorFixtures.connectionID(4),
            name: "First")
        let secondConnection = try DatabaseExecutorFixtures.connection(
            id: DatabaseExecutorFixtures.connectionID(5),
            name: "Second",
            product: .redis)
        try await store.seedConnection(firstConnection)
        try await store.seedConnection(secondConnection)
        let runtimeOwner = try await store.claimRuntimeOwner(
            claimedAt: DatabaseExecutorFixtures.now.addingTimeInterval(-1)
        ).owner.token
        let firstReport = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(
                product: .postgresql,
                marker: "first"))
        let secondReport = DatabaseExecutorFixtures.report(
            identity: DatabaseExecutorFixtures.identity(
                product: .redis,
                marker: "second"))
        let firstSession = try DatabaseExecutorFixtures.session(
            id: DatabaseExecutorFixtures.sessionID(6),
            connection: firstConnection,
            report: firstReport)
        let secondSession = try DatabaseExecutorFixtures.session(
            id: DatabaseExecutorFixtures.sessionID(7),
            connection: secondConnection,
            report: secondReport)
        let firstAdapter = DatabaseExecutorRecordingAdapter(
            id: "first-isolation",
            products: [.postgresql],
            session: firstSession)
        let secondAdapter = DatabaseExecutorRecordingAdapter(
            id: "second-isolation",
            products: [.redis],
            session: secondSession)
        let executor = try DatabaseExecutor(
            metadataStore: store,
            secretStore: InMemoryDatabaseSecretStore(),
            runtimeOwner: runtimeOwner,
            adapters: [firstAdapter, secondAdapter],
            currentDate: { DatabaseExecutorFixtures.now })
        #expect(
            await executor.connect(
                DatabaseConnectRequest(
                    connectionID: firstConnection.id,
                    operation: DatabaseExecutorFixtures.operation(29))
            ).status == .succeeded)
        #expect(
            await executor.connect(
                DatabaseConnectRequest(
                    connectionID: secondConnection.id,
                    operation: DatabaseExecutorFixtures.operation(30))
            ).status == .succeeded)
        await firstSession.gates.discoverCapabilities.block()
        await secondSession.gates.discoverCapabilities.block()
        let firstOperation = DatabaseExecutorFixtures.operation(31)
        let secondOperation = DatabaseExecutorFixtures.operation(32)
        let firstTask = Task {
            await executor.capabilities(
                DatabaseCapabilitiesRequest(
                    connectionID: firstConnection.id,
                    resolution: .refresh,
                    operation: firstOperation))
        }
        let secondTask = Task {
            await executor.capabilities(
                DatabaseCapabilitiesRequest(
                    connectionID: secondConnection.id,
                    resolution: .refresh,
                    operation: secondOperation))
        }
        await firstSession.gates.discoverCapabilities.waitForEntries(2)
        await secondSession.gates.discoverCapabilities.waitForEntries(2)

        let disconnected = await executor.disconnect(
            DatabaseDisconnectRequest(
                connectionID: firstConnection.id,
                operation: DatabaseExecutorFixtures.operation(33)))
        let firstResult = await firstTask.value

        #expect(disconnected.status == .succeeded)
        #expect(firstResult.error?.category == .connectionFailed)
        #expect(await executor.activeOperationCount() == 1)
        #expect(await firstSession.snapshot().cancelledOperationIDs.isEmpty)
        #expect(await secondSession.snapshot().cancelledOperationIDs.isEmpty)

        await secondSession.gates.discoverCapabilities.releaseAll()
        let secondResult = await secondTask.value
        #expect(secondResult.status == .succeeded)
        #expect(await executor.activeOperationCount() == 0)
        await firstSession.gates.discoverCapabilities.releaseAll()
    }

    @Test func completedActionSurvivesTerminalHistoryFailureWithFixedWarning() async throws {
        let connectGate = DatabaseExecutorTestGate(open: false)
        let fixture = try await DatabaseExecutorFixtures.make(
            adapterGates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let operation = DatabaseExecutorFixtures.operation(34)
        let task = Task {
            await fixture.executor.connect(
                DatabaseConnectRequest(
                    connectionID: fixture.connection.id,
                    operation: operation))
        }
        await connectGate.waitForEntries()
        #expect(
            try await fixture.store.releaseRuntimeOwner(
                fixture.runtimeOwner,
                releasedAt: DatabaseExecutorFixtures.now))
        await connectGate.releaseAll()

        let result = await task.value

        #expect(result.status == .succeeded)
        #expect(result.payload != nil)
        #expect(result.metadata.warnings == [DatabaseExecutor.historyFinalizationWarning])
        #expect(result.metadata.operation?.state == .succeeded)
        #expect(
            result.metadata.operation?.warnings
                == [DatabaseExecutor.historyFinalizationWarning])
        #expect(
            try await fixture.store.operation(id: operation.operationID)?.state
                == .running)
        #expect(await fixture.executor.activeOperationCount() == 0)
    }

    @Test func typedHistoryCommandsReturnPersistedOperations() async throws {
        let fixture = try await DatabaseExecutorFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let operation = DatabaseExecutorFixtures.operation(35)
        let connected = await fixture.executor.connect(
            DatabaseConnectRequest(
                connectionID: fixture.connection.id,
                operation: operation))
        let expected = try #require(connected.metadata.operation)

        let get = await fixture.executor.operation(
            DatabaseOperationGetRequest(operationID: operation.operationID))
        let list = await fixture.executor.operations(
            DatabaseOperationListRequest(
                search: DatabaseOperationHistorySearch(
                    connectionID: fixture.connection.id,
                    states: [.succeeded],
                    kinds: [.databaseConnect],
                    limit: 10)))

        #expect(get.status == .succeeded)
        #expect(get.payload?.operation == expected)
        #expect(list.status == .succeeded)
        #expect(list.payload?.operations == [expected])
    }

    @Test func activeHistoryAndPayloadsNeverExposeResolvedSecretText() async throws {
        let secret = "active-history-secret"
        let reference = DatabaseSecretReference(
            identifier: DatabaseExecutorFixtures.uuid(37),
            purpose: .password)
        let connection = try DatabaseExecutorFixtures.connection(
            name: "Orders \(secret)",
            secretReference: reference)
        let connectGate = DatabaseExecutorTestGate(open: false)
        let fixture = try await DatabaseExecutorFixtures.make(
            connection: connection,
            secretValues: [reference: Data(secret.utf8)],
            adapterGates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let operation = DatabaseExecutorFixtures.operation(36)
        let task = Task {
            await fixture.executor.connect(
                DatabaseConnectRequest(
                    connectionID: connection.id,
                    operation: operation))
        }
        await connectGate.waitForEntries()

        let active = try #require(
            try await fixture.store.operation(id: operation.operationID))
        let activeText = String(
            decoding: try JSONEncoder().encode(active),
            as: UTF8.self)
        #expect(active.state == .running)
        #expect(!activeText.contains(secret))
        #expect(activeText.contains(DatabaseSecretRedactor.defaultReplacement))

        await connectGate.releaseAll()
        let result = await task.value
        let resultText = String(
            decoding: try JSONEncoder().encode(result),
            as: UTF8.self)
        #expect(result.status == .succeeded)
        #expect(!resultText.contains(secret))
        #expect(resultText.contains(DatabaseSecretRedactor.defaultReplacement))
    }

    @Test func acceptedCancellationWinsTheTerminalRaceWithoutWaitingForServerCancel() async throws {
        let successGate = DatabaseExecutorTestGate(open: false)
        let fixture = try await DatabaseExecutorFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gatedStore = DatabaseExecutorGatedMetadataStore(
            base: fixture.store,
            blockedTransitionStates: [.succeeded],
            transitionGate: successGate)
        let executor = try DatabaseExecutor(
            metadataStore: gatedStore,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.runtimeOwner,
            adapters: [fixture.adapter],
            currentDate: { DatabaseExecutorFixtures.now },
            managementDrainTimeoutNanoseconds: 10_000_000)
        await fixture.session.gates.cancel.block()
        let operation = DatabaseExecutorFixtures.operation(38)
        let task = Task {
            await executor.connect(
                DatabaseConnectRequest(
                    connectionID: fixture.connection.id,
                    operation: operation))
        }
        await successGate.waitForEntries()

        let cancellation = await executor.cancel(
            DatabaseOperationCancelRequest(operationID: operation.operationID))

        #expect(cancellation.payload?.disposition == .accepted)
        #expect(cancellation.payload?.cancellationSupport == .cooperative)
        await fixture.session.gates.cancel.waitForEntries()
        #expect(await fixture.session.gates.cancel.blockedCount() == 1)
        #expect(await executor.backgroundTaskCount() == 1)
        await successGate.releaseAll()
        let result = await task.value
        #expect(result.status == .failed)
        #expect(result.error?.category == .cancelled)
        #expect(result.metadata.operation?.state == .cancelled)
        #expect(
            try await fixture.store.operation(id: operation.operationID)?.state
                == .cancelled)
        #expect(await executor.activeOperationCount() == 0)

        await executor.disconnectAll()
        await fixture.session.gates.disconnect.waitForEntries()
        #expect(await executor.backgroundTaskCount() == 1)
        #expect(await executor.retainedServerCancellationCount() == 1)
        let invocations = await fixture.session.snapshot().invocations
        let cancellationIndex = try #require(
            invocations.firstIndex(of: .cancel(operation.operationID)))
        let disconnectionIndex = try #require(invocations.firstIndex(of: .disconnect))
        #expect(cancellationIndex < disconnectionIndex)
        await fixture.session.gates.cancel.releaseAll()
        for _ in 0..<100 where await executor.retainedServerCancellationCount() != 0 {
            await Task.yield()
        }
        #expect(await executor.backgroundTaskCount() == 0)
        #expect(await executor.retainedServerCancellationCount() == 0)
    }

    @Test func retainedServerCancellationCapRejectsNewServerOperationsUntilCleanup() async throws {
        let successGate = DatabaseExecutorTestGate(open: false)
        let fixture = try await DatabaseExecutorFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gatedStore = DatabaseExecutorGatedMetadataStore(
            base: fixture.store,
            blockedTransitionStates: [.succeeded],
            transitionGate: successGate)
        let executor = try DatabaseExecutor(
            metadataStore: gatedStore,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.runtimeOwner,
            adapters: [fixture.adapter],
            currentDate: { DatabaseExecutorFixtures.now },
            maximumRetainedServerCancellations: 1)
        await fixture.session.gates.cancel.block()
        let firstOperation = DatabaseExecutorFixtures.operation(43)
        let firstTask = Task {
            await executor.connect(
                DatabaseConnectRequest(
                    connectionID: fixture.connection.id,
                    operation: firstOperation))
        }
        await successGate.waitForEntries()
        let cancellation = await executor.cancel(
            DatabaseOperationCancelRequest(operationID: firstOperation.operationID))
        await fixture.session.gates.cancel.waitForEntries()
        await successGate.releaseAll()

        #expect(cancellation.payload?.disposition == .accepted)
        #expect(await firstTask.value.error?.category == .cancelled)
        #expect(await executor.retainedServerCancellationCount() == 1)
        let rejected = await executor.connect(
            DatabaseConnectRequest(
                connectionID: fixture.connection.id,
                operation: DatabaseExecutorFixtures.operation(44)))
        #expect(rejected.error?.category == .resourceLimit)
        #expect(await executor.retainedServerCancellationCount() == 1)

        await fixture.session.gates.cancel.releaseAll()
        for _ in 0..<100 where await executor.retainedServerCancellationCount() != 0 {
            await Task.yield()
        }
        #expect(await executor.retainedServerCancellationCount() == 0)
        let admitted = await executor.connect(
            DatabaseConnectRequest(
                connectionID: fixture.connection.id,
                operation: DatabaseExecutorFixtures.operation(45)))
        #expect(admitted.status == .succeeded)
    }

    @Test func shutdownSchedulesFreshServerCancellationBeforeDisconnect() async throws {
        let successGate = DatabaseExecutorTestGate(open: false)
        let fixture = try await DatabaseExecutorFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = DatabaseExecutorGatedMetadataStore(
            base: fixture.store,
            blockedTransitionStates: [.succeeded],
            transitionGate: successGate)
        let executor = try DatabaseExecutor(
            metadataStore: store,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.runtimeOwner,
            adapters: [fixture.adapter],
            currentDate: { DatabaseExecutorFixtures.now },
            managementDrainTimeoutNanoseconds: 1)
        await fixture.session.gates.cancel.block()
        let operation = DatabaseExecutorFixtures.operation(46)
        let task = Task {
            await executor.connect(
                DatabaseConnectRequest(
                    connectionID: fixture.connection.id,
                    operation: operation))
        }
        await successGate.waitForEntries()
        await executor.disconnectAll()
        await fixture.session.gates.disconnect.waitForEntries()
        let invocations = await fixture.session.snapshot().invocations
        let cancellationIndex = try #require(
            invocations.firstIndex(of: .cancel(operation.operationID)))
        let disconnectionIndex = try #require(invocations.firstIndex(of: .disconnect))
        #expect(cancellationIndex < disconnectionIndex)
        await fixture.session.gates.cancel.releaseAll()
        await successGate.releaseAll()
        _ = await task.value
    }

    @Test func acceptedCancellationReplacesAConcurrentFailureTerminal() async throws {
        let failureGate = DatabaseExecutorTestGate(open: false)
        let fixture = try await DatabaseExecutorFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.adapter.enqueueFailure(
            .reported(
                DatabaseErrorEnvelope(
                    category: .network,
                    message: "Connection failed.")))
        let gatedStore = DatabaseExecutorGatedMetadataStore(
            base: fixture.store,
            blockedTransitionStates: [.failed],
            transitionGate: failureGate)
        let executor = try DatabaseExecutor(
            metadataStore: gatedStore,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.runtimeOwner,
            adapters: [fixture.adapter],
            currentDate: { DatabaseExecutorFixtures.now })
        let operation = DatabaseExecutorFixtures.operation(42)
        let task = Task {
            await executor.connect(
                DatabaseConnectRequest(
                    connectionID: fixture.connection.id,
                    operation: operation))
        }
        await failureGate.waitForEntries()

        let cancellation = await executor.cancel(
            DatabaseOperationCancelRequest(operationID: operation.operationID))
        await failureGate.releaseAll()
        let result = await task.value

        #expect(cancellation.payload?.disposition == .accepted)
        #expect(result.error?.category == .cancelled)
        #expect(result.metadata.operation?.state == .cancelled)
        #expect(result.metadata.warnings.isEmpty)
        #expect(
            try await fixture.store.operation(id: operation.operationID)?.state
                == .cancelled)
    }

    @Test func locallyAcceptedCancellationSurvivesACancellingHistoryFailure() async throws {
        let connectGate = DatabaseExecutorTestGate(open: false)
        let fixture = try await DatabaseExecutorFixtures.make(
            adapterGates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gatedStore = DatabaseExecutorGatedMetadataStore(
            base: fixture.store,
            rejectedTransitionStates: [.cancelling])
        let executor = try DatabaseExecutor(
            metadataStore: gatedStore,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.runtimeOwner,
            adapters: [fixture.adapter],
            currentDate: { DatabaseExecutorFixtures.now })
        let operation = DatabaseExecutorFixtures.operation(43)
        let task = Task {
            await executor.connect(
                DatabaseConnectRequest(
                    connectionID: fixture.connection.id,
                    operation: operation))
        }
        await connectGate.waitForEntries()

        let cancellation = await executor.cancel(
            DatabaseOperationCancelRequest(operationID: operation.operationID))
        let result = await task.value

        #expect(cancellation.payload?.disposition == .accepted)
        #expect(cancellation.metadata.warnings == [DatabaseExecutor.historyFinalizationWarning])
        #expect(result.error?.category == .cancelled)
        #expect(result.metadata.operation?.state == .cancelled)
        #expect(
            try await fixture.store.operation(id: operation.operationID)?.state
                == .cancelled)
        await connectGate.releaseAll()
    }

    @Test func cancellationBeforeReservationCannotTouchAnotherExecutorsHistory() async throws {
        let firstConnectGate = DatabaseExecutorTestGate(open: false)
        let fixture = try await DatabaseExecutorFixtures.make(
            adapterGates: DatabaseExecutorTestAdapterGates(connect: firstConnectGate))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let operation = DatabaseExecutorFixtures.operation(39)
        let request = DatabaseConnectRequest(
            connectionID: fixture.connection.id,
            operation: operation)
        let firstTask = Task { await fixture.executor.connect(request) }
        await firstConnectGate.waitForEntries()
        let reservationGate = DatabaseExecutorTestGate(open: false)
        let secondStore = DatabaseExecutorGatedMetadataStore(
            base: fixture.store,
            reservationGate: reservationGate)
        let secondExecutor = try DatabaseExecutor(
            metadataStore: secondStore,
            secretStore: fixture.secretStore,
            runtimeOwner: fixture.runtimeOwner,
            adapters: [fixture.adapter],
            currentDate: { DatabaseExecutorFixtures.now })
        let duplicateTask = Task { await secondExecutor.connect(request) }
        await reservationGate.waitForEntries()

        let cancellation = await secondExecutor.cancel(
            DatabaseOperationCancelRequest(operationID: operation.operationID))

        #expect(cancellation.payload?.disposition == .notActive)
        #expect(
            try await fixture.store.operation(id: operation.operationID)?.state
                == .running)
        #expect(await fixture.session.snapshot().cancelledOperationIDs.isEmpty)
        await reservationGate.releaseAll()
        let duplicate = await duplicateTask.value
        #expect(duplicate.error?.category == .conflict)
        await firstConnectGate.releaseAll()
        let first = await firstTask.value
        #expect(first.status == .succeeded)
        #expect(
            try await fixture.store.operation(id: operation.operationID)?.state
                == .succeeded)
    }

    @Test func blockedSecretRedactorCannotOutliveCancellationControl() async throws {
        let secret = "blocked-redactor-secret"
        let reference = DatabaseSecretReference(
            identifier: DatabaseExecutorFixtures.uuid(40),
            purpose: .password)
        let connection = try DatabaseExecutorFixtures.connection(
            name: "Orders \(secret)",
            secretReference: reference,
            connectionTimeoutMilliseconds: 100)
        let fixture = try await DatabaseExecutorFixtures.make(connection: connection)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let readGate = DatabaseExecutorTestGate(open: false)
        let secretStore = DatabaseExecutorBlockingSecretStore(
            values: [reference: Data(secret.utf8)],
            readGate: readGate)
        let executor = try DatabaseExecutor(
            metadataStore: fixture.store,
            secretStore: secretStore,
            runtimeOwner: fixture.runtimeOwner,
            adapters: [fixture.adapter],
            currentDate: { DatabaseExecutorFixtures.now })
        let operation = DatabaseExecutorFixtures.operation(41)
        let task = Task {
            await executor.connect(
                DatabaseConnectRequest(
                    connectionID: connection.id,
                    operation: operation))
        }
        await readGate.waitForEntries()

        let result = await task.value

        #expect(result.error?.category == .timeout)
        #expect(result.metadata.operation?.state == .failed)
        #expect(await executor.activeOperationCount() == 0)
        #expect(await executor.backgroundTaskCount() == 1)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!encoded.contains(secret))
        await readGate.releaseAll()
        for _ in 0..<100 where await executor.backgroundTaskCount() != 0 {
            await Task.yield()
        }
        #expect(await executor.backgroundTaskCount() == 0)
    }
}
