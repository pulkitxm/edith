import Foundation
import Testing

@testable import EdithDatabase

private final class DatabaseSessionPoolTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private enum DatabaseSessionPoolFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let firstID = DatabaseConnectionID(
        rawValue: UUID(uuidString: "F362FC61-6799-4A19-865A-BD81F80D48FB")!)
    static let secondID = DatabaseConnectionID(
        rawValue: UUID(uuidString: "18407A75-85C1-44A7-BDC9-42820BFD304A")!)
    static let thirdID = DatabaseConnectionID(
        rawValue: UUID(uuidString: "6C072F6A-A0E4-4CE6-A612-7BEAA3C6EA43")!)
    static let fourthID = DatabaseConnectionID(
        rawValue: UUID(uuidString: "14E4D508-AF03-45A0-90BA-28772EB46A8A")!)
    static let passwordReference = DatabaseSecretReference(
        identifier: UUID(uuidString: "28B89E07-BDB1-46F0-984B-A4C12C9E9D77")!,
        purpose: .password)
    static let privateKeyReference = DatabaseSecretReference(
        identifier: UUID(uuidString: "F9DA8FB4-E4E4-4C9B-86EA-92187CBC3C14")!,
        purpose: .clientPrivateKey)

    static func operationID(_ suffix: UInt8) -> DatabaseOperationID {
        DatabaseOperationID(
            rawValue: UUID(
                uuid: (
                    0x4A, 0xAE, 0xCC, 0x5E, 0x2C, 0x60, 0x43, 0x54,
                    0xA7, 0xEA, 0x33, 0x42, 0x45, 0x00, 0x00, suffix
                )))
    }

    static func connection(
        id: DatabaseConnectionID = firstID,
        name: String = "Primary",
        updatedAt: Date = now,
        includesSecrets: Bool = false,
        authenticationSecretReferences: [DatabaseSecretReference]? = nil
    ) throws -> DatabaseConnectionDefinition {
        let secretReferences =
            authenticationSecretReferences
            ?? (includesSecrets ? [passwordReference] : [])
        return DatabaseConnectionDefinition(
            id: id,
            displayName: name,
            productHint: .postgresql,
            location: .network([
                DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: try DatabasePort(5_432))
            ]),
            username: "edith",
            namespaces: DatabaseNamespaceDefaults(schema: "public", database: "edith"),
            deploymentMode: .standalone,
            authentication: DatabaseAuthentication(
                kind: secretReferences.isEmpty ? .none : .usernameAndPassword,
                secretReferences: secretReferences),
            tls: DatabaseTLSConfiguration(
                mode: includesSecrets ? .required : .disabled,
                verification: includesSecrets ? .full : .none,
                clientPrivateKey: includesSecrets ? privateKeyReference : nil),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
                poolSize: try DatabasePoolSize(4)),
            environment: DatabaseEnvironmentMetadata(
                kind: .testing,
                label: "testing",
                protection: .standard),
            createdAt: now.addingTimeInterval(-100),
            updatedAt: updatedAt)
    }

    static func identity(
        product: DatabaseProduct = .postgresql,
        server: String = "primary"
    ) -> DatabaseProductIdentity {
        DatabaseProductIdentity(
            product: product,
            version: DatabaseVersion(string: "17.4", major: 17, minor: 4),
            topology: DatabaseTopology(kind: .standalone),
            serverIdentifier: server)
    }

    static func report(
        identity: DatabaseProductIdentity = identity(),
        marker: String = "initial",
        discoveredAt: Date = now,
        expiresAt: Date? = nil,
        capabilities: [DatabaseCapabilityStatus]? = nil
    ) -> DatabaseCapabilityReport {
        DatabaseCapabilityReport(
            productIdentity: identity,
            capabilities: capabilities ?? [
                DatabaseCapabilityStatus(
                    id: .browse,
                    requirement: .sharedRequired,
                    availability: .available,
                    attributes: [
                        DatabaseStringAttribute(name: "marker", value: marker)
                    ])
            ],
            safetyLimitations: [marker],
            discoveredAt: discoveredAt,
            expiresAt: expiresAt)
    }

    static func session(
        connection: DatabaseConnectionDefinition,
        identity: DatabaseProductIdentity = identity(),
        report: DatabaseCapabilityReport? = nil,
        state: DatabaseAdapterSessionState = .connected,
        honorsContextCancellation: Bool = true,
        gates: DatabaseExecutorTestSessionGates = DatabaseExecutorTestSessionGates()
    ) throws -> DatabaseExecutorRecordingSession {
        let capabilityReport = report ?? self.report(identity: identity)
        let metadata = DatabasePageMetadata(
            completeness: DatabaseResultCompleteness(state: .complete),
            count: DatabaseCountMetadata(value: 0, accuracy: .exact))
        let page = try DatabaseAdapterPage(records: [], metadata: metadata)
        let target = DatabaseTargetIdentifier(
            connectionID: connection.id,
            object: DatabaseObjectIdentifier(kind: .table, path: ["public", "items"]))
        let request = DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .postgresql,
                statement: "DELETE FROM items",
                parameters: []))
        let plan = DatabaseDestructivePlan(
            request: request,
            action: .deleteMany,
            scope: .entireObject,
            impact: DatabaseMutationImpact(
                count: DatabaseCountMetadata(value: 0, accuracy: .exact),
                description: "No records"),
            transactionBehavior: .transactional,
            rollbackAvailability: .available,
            executionMode: .synchronous)
        let mutationResult = try DatabaseAdapterMutationResult(
            disposition: .completed,
            affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .exact))
        return DatabaseExecutorRecordingSession(
            id: DatabaseAdapterSessionID(),
            connection: connection,
            productIdentity: identity,
            capabilities: capabilityReport,
            page: page,
            queryPage: page,
            mutationPlan: plan,
            mutationResult: mutationResult,
            state: state,
            honorsContextCancellation: honorsContextCancellation,
            gates: gates)
    }

    static func pool(
        adapter: DatabaseExecutorRecordingAdapter,
        store: any DatabaseSecretStore,
        clock: DatabaseSessionPoolTestClock
    ) throws -> DatabaseSessionPool {
        DatabaseSessionPool(
            registry: try DatabaseAdapterRegistry(adapters: [adapter]),
            secretStore: store,
            currentDate: { clock.now() })
    }

    static func context(
        operation: DatabaseOperationContext = DatabaseOperationContext(),
        cancellation: DatabaseAdapterCancellationSignal = DatabaseAdapterCancellationSignal()
    ) -> DatabaseAdapterOperationContext {
        DatabaseAdapterOperationContext(
            operation: operation,
            cancellation: cancellation)
    }

    static func discoveryCount(_ session: DatabaseExecutorRecordingSession) async -> Int {
        let snapshot = await session.snapshot()
        return snapshot.invocations.reduce(into: 0) { count, invocation in
            if case .discoverCapabilities = invocation {
                count += 1
            }
        }
    }

    static func waitForDiagnostics(
        _ pool: DatabaseSessionPool,
        matching predicate: (DatabaseSessionPoolDiagnostics) -> Bool
    ) async -> DatabaseSessionPoolDiagnostics {
        var diagnostics = await pool.diagnostics()
        for _ in 0..<1_000 {
            if predicate(diagnostics) {
                return diagnostics
            }
            await Task.yield()
            diagnostics = await pool.diagnostics()
        }
        return diagnostics
    }

    static func waitForIdle(
        _ pool: DatabaseSessionPool
    ) async -> DatabaseSessionPoolDiagnostics {
        await waitForDiagnostics(pool) {
            $0
                == DatabaseSessionPoolDiagnostics(
                    connectWaiters: 0,
                    refreshWaiters: 0,
                    completionObservers: 0,
                    sharedCancellationObservers: 0,
                    activeTasks: 0,
                    cleanupTasks: 0)
        }
    }
}

@Suite struct DatabaseSessionPoolTests {
    @Test func sameDefinitionSingleFlightsConnectDiscoveryAndSecretResolution() async throws {
        let connection = try DatabaseSessionPoolFixtures.connection(includesSecrets: true)
        let session = try DatabaseSessionPoolFixtures.session(connection: connection)
        let connectGate = DatabaseExecutorTestGate(open: false)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: session,
            gates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        let password = Data("password".utf8)
        let privateKey = Data("private-key".utf8)
        let store = try InMemoryDatabaseSecretStore(initialValues: [
            DatabaseSessionPoolFixtures.passwordReference: password,
            DatabaseSessionPoolFixtures.privateKeyReference: privateKey,
        ])
        let clock = DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now)
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: store,
            clock: clock)
        let firstOperation = DatabaseOperationContext(
            operationID: DatabaseSessionPoolFixtures.operationID(1),
            deadline: DatabaseSessionPoolFixtures.now.addingTimeInterval(100))
        let secondOperation = DatabaseOperationContext(
            operationID: DatabaseSessionPoolFixtures.operationID(2),
            deadline: DatabaseSessionPoolFixtures.now.addingTimeInterval(200))

        let first = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context(operation: firstOperation))
        }
        await connectGate.waitForEntries()
        let second = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context(operation: secondOperation))
        }
        await connectGate.releaseAll()

        let firstLease = try await first.value
        let secondLease = try await second.value
        let invocations = await adapter.recordedInvocations()

        #expect(firstLease.generation == secondLease.generation)
        #expect(firstLease.session.id == secondLease.session.id)
        #expect(invocations.count == 1)
        #expect(invocations[0].definition == connection)
        #expect(invocations[0].operation.operationID != firstOperation.operationID)
        #expect(invocations[0].operation.operationID != secondOperation.operationID)
        #expect(invocations[0].operation.deadline == nil)
        #expect(
            invocations[0].secrets == [
                DatabaseSessionPoolFixtures.passwordReference: password,
                DatabaseSessionPoolFixtures.privateKeyReference: privateKey,
            ])
        #expect(await DatabaseSessionPoolFixtures.discoveryCount(session) == 1)
        let discoveryOperations = await session.snapshot().invocations.compactMap {
            if case let .discoverCapabilities(operation) = $0 {
                return operation
            }
            return nil
        }
        #expect(discoveryOperations == [invocations[0].operation])
        #expect(
            await DatabaseSessionPoolFixtures.waitForIdle(pool)
                == DatabaseSessionPoolDiagnostics(
                    connectWaiters: 0,
                    refreshWaiters: 0,
                    completionObservers: 0,
                    sharedCancellationObservers: 0,
                    activeTasks: 0,
                    cleanupTasks: 0))
    }

    @Test func continuationSigningKeyCannotBeResolvedIntoAnAdapterSession() async throws {
        let reference = DatabaseContinuationAuthority.signingKeyReference
        let connection = try DatabaseSessionPoolFixtures.connection(
            authenticationSecretReferences: [reference])
        let session = try DatabaseSessionPoolFixtures.session(connection: connection)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: session)
        let store = try InMemoryDatabaseSecretStore(initialValues: [
            reference: Data(repeating: 7, count: 32)
        ])
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: store,
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))
        let failure = DatabaseAdapterFailure.reported(
            DatabaseErrorEnvelope(
                category: .invalidRequest,
                message: "The connection contains an invalid secret reference."))

        await #expect(throws: failure) {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context())
        }
        #expect(await adapter.recordedInvocations().isEmpty)
    }

    @Test func differentConnectionsEstablishIndependently() async throws {
        let firstConnection = try DatabaseSessionPoolFixtures.connection()
        let secondConnection = try DatabaseSessionPoolFixtures.connection(
            id: DatabaseSessionPoolFixtures.secondID,
            name: "Secondary")
        let firstDiscovery = DatabaseExecutorTestGate(open: false)
        let firstSession = try DatabaseSessionPoolFixtures.session(
            connection: firstConnection,
            gates: DatabaseExecutorTestSessionGates(
                discoverCapabilities: firstDiscovery))
        let secondSession = try DatabaseSessionPoolFixtures.session(
            connection: secondConnection,
            identity: DatabaseSessionPoolFixtures.identity(server: "secondary"),
            report: DatabaseSessionPoolFixtures.report(
                identity: DatabaseSessionPoolFixtures.identity(server: "secondary"),
                marker: "secondary"))
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: firstSession)
        let store = try InMemoryDatabaseSecretStore()
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: store,
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))

        let first = Task {
            try await pool.lease(
                for: firstConnection,
                context: DatabaseSessionPoolFixtures.context())
        }
        await firstDiscovery.waitForEntries()
        await adapter.setSession(secondSession)

        let secondLease = try await pool.lease(
            for: secondConnection,
            context: DatabaseSessionPoolFixtures.context())
        #expect(secondLease.definition == secondConnection)
        #expect(secondLease.session.id == secondSession.id)

        await firstDiscovery.releaseAll()
        let firstLease = try await first.value
        #expect(firstLease.definition == firstConnection)
        #expect(firstLease.generation != secondLease.generation)
        #expect(await adapter.recordedInvocations().count == 2)
    }

    @Test func exactDefinitionRevisionReplacesSessionWithEqualUpdatedAt() async throws {
        let timestamp = DatabaseSessionPoolFixtures.now.addingTimeInterval(-10)
        let original = try DatabaseSessionPoolFixtures.connection(
            name: "Original",
            updatedAt: timestamp)
        let revised = try DatabaseSessionPoolFixtures.connection(
            name: "Revised",
            updatedAt: timestamp)
        let originalSession = try DatabaseSessionPoolFixtures.session(connection: original)
        let revisedSession = try DatabaseSessionPoolFixtures.session(
            connection: revised,
            identity: DatabaseSessionPoolFixtures.identity(server: "revised"),
            report: DatabaseSessionPoolFixtures.report(
                identity: DatabaseSessionPoolFixtures.identity(server: "revised"),
                marker: "revised"))
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: originalSession)
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))

        let originalLease = try await pool.lease(
            for: original,
            context: DatabaseSessionPoolFixtures.context())
        await adapter.setSession(revisedSession)
        let revisedLease = try await pool.lease(
            for: revised,
            context: DatabaseSessionPoolFixtures.context())

        #expect(original.updatedAt == revised.updatedAt)
        #expect(original != revised)
        #expect(originalLease.generation != revisedLease.generation)
        #expect(revisedLease.definition == revised)
        #expect(await adapter.recordedInvocations().count == 2)
        #expect(await originalSession.snapshot().disconnectCount == 1)
    }

    @Test func failedConnectIsEvictedAndRetried() async throws {
        let connection = try DatabaseSessionPoolFixtures.connection()
        let session = try DatabaseSessionPoolFixtures.session(connection: connection)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: session)
        let failure = DatabaseAdapterFailure.reported(
            DatabaseErrorEnvelope(category: .connectionFailed, message: "unavailable"))
        await adapter.enqueueFailure(failure)
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))

        await #expect(throws: failure) {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context())
        }
        let lease = try await pool.lease(
            for: connection,
            context: DatabaseSessionPoolFixtures.context())

        #expect(lease.session.id == session.id)
        #expect(await adapter.recordedInvocations().count == 2)
    }

    @Test(arguments: [true, false])
    func cancelledWaiterDoesNotCancelSharedAttempt(cancelFirstCaller: Bool) async throws {
        let connection = try DatabaseSessionPoolFixtures.connection()
        let session = try DatabaseSessionPoolFixtures.session(connection: connection)
        let connectGate = DatabaseExecutorTestGate(open: false)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: session,
            gates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))
        let firstSignal = DatabaseAdapterCancellationSignal()
        let secondSignal = DatabaseAdapterCancellationSignal()
        let cancelledSignal = cancelFirstCaller ? firstSignal : secondSignal
        let actualSurvivingSignal = cancelFirstCaller ? secondSignal : firstSignal

        let first = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context(
                    cancellation: firstSignal))
        }
        await connectGate.waitForEntries()
        let second = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context(
                    cancellation: secondSignal))
        }
        _ = await DatabaseSessionPoolFixtures.waitForDiagnostics(pool) {
            $0.connectWaiters == 2
        }
        await cancelledSignal.cancel(.deadlineExceeded)

        if cancelFirstCaller {
            await #expect(throws: DatabaseAdapterFailure.cancelled) {
                try await first.value
            }
        } else {
            await #expect(throws: DatabaseAdapterFailure.cancelled) {
                try await second.value
            }
        }
        #expect(await connectGate.blockedCount() == 1)
        await connectGate.releaseAll()

        let lease: DatabaseSessionLease
        if cancelFirstCaller {
            lease = try await second.value
        } else {
            lease = try await first.value
        }
        #expect(lease.session.id == session.id)
        #expect(await adapter.recordedInvocations().count == 1)
        #expect(await session.snapshot().disconnectCount == 0)
        #expect(await actualSurvivingSignal.reason() == nil)
        #expect(await firstSignal.registeredEventStreamCount() == 0)
        #expect(await secondSignal.registeredEventStreamCount() == 0)
        #expect(
            await DatabaseSessionPoolFixtures.waitForIdle(pool)
                == DatabaseSessionPoolDiagnostics(
                    connectWaiters: 0,
                    refreshWaiters: 0,
                    completionObservers: 0,
                    sharedCancellationObservers: 0,
                    activeTasks: 0,
                    cleanupTasks: 0))
    }

    @Test func firstCallerDeadlineDoesNotBecomeSharedAttemptDeadline() async throws {
        let connection = try DatabaseSessionPoolFixtures.connection()
        let session = try DatabaseSessionPoolFixtures.session(connection: connection)
        let connectGate = DatabaseExecutorTestGate(open: false)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: session,
            gates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))
        let firstSignal = DatabaseAdapterCancellationSignal()
        let firstOperation = DatabaseOperationContext(
            operationID: DatabaseSessionPoolFixtures.operationID(3),
            deadline: DatabaseSessionPoolFixtures.now.addingTimeInterval(0.05))

        let first = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context(
                    operation: firstOperation,
                    cancellation: firstSignal))
        }
        await connectGate.waitForEntries()
        let survivor = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context())
        }
        _ = await DatabaseSessionPoolFixtures.waitForDiagnostics(pool) {
            $0.connectWaiters == 2
        }

        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            try await first.value
        }
        #expect(await firstSignal.reason() == .deadlineExceeded)
        #expect(await connectGate.blockedCount() == 1)
        await connectGate.releaseAll()

        let lease = try await survivor.value
        let invocations = await adapter.recordedInvocations()
        let invocation = try #require(invocations.first)
        #expect(lease.session.id == session.id)
        #expect(invocation.operation.operationID != firstOperation.operationID)
        #expect(invocation.operation.deadline == nil)
        #expect(await session.snapshot().disconnectCount == 0)
        #expect(await firstSignal.registeredEventStreamCount() == 0)
        #expect(
            await DatabaseSessionPoolFixtures.waitForIdle(pool)
                == DatabaseSessionPoolDiagnostics(
                    connectWaiters: 0,
                    refreshWaiters: 0,
                    completionObservers: 0,
                    sharedCancellationObservers: 0,
                    activeTasks: 0,
                    cleanupTasks: 0))
    }

    @Test func cancellingEveryWaiterRetiresAndDisconnectsLateSharedSession() async throws {
        let connection = try DatabaseSessionPoolFixtures.connection()
        let session = try DatabaseSessionPoolFixtures.session(
            connection: connection,
            honorsContextCancellation: false)
        let connectGate = DatabaseExecutorTestGate(open: false)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: session,
            honorsContextCancellation: false,
            gates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))
        let firstSignal = DatabaseAdapterCancellationSignal()
        let secondSignal = DatabaseAdapterCancellationSignal()

        let first = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context(
                    cancellation: firstSignal))
        }
        await connectGate.waitForEntries()
        let second = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context(
                    cancellation: secondSignal))
        }
        _ = await DatabaseSessionPoolFixtures.waitForDiagnostics(pool) {
            $0.connectWaiters == 2
        }
        await firstSignal.cancel(.userRequested)
        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            try await first.value
        }
        let oneRemaining = await pool.diagnostics()
        #expect(oneRemaining.connectWaiters == 1)
        #expect(oneRemaining.cleanupTasks == 0)

        await secondSignal.cancel(.deadlineExceeded)
        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            try await second.value
        }
        let retired = await DatabaseSessionPoolFixtures.waitForDiagnostics(pool) {
            $0.connectWaiters == 0 && $0.activeTasks == 0 && $0.cleanupTasks == 1
        }
        #expect(retired.cleanupTasks == 1)
        #expect(await pool.disconnect(connectionID: connection.id) == false)

        await connectGate.releaseAll()
        #expect(
            await DatabaseSessionPoolFixtures.waitForIdle(pool)
                == DatabaseSessionPoolDiagnostics(
                    connectWaiters: 0,
                    refreshWaiters: 0,
                    completionObservers: 0,
                    sharedCancellationObservers: 0,
                    activeTasks: 0,
                    cleanupTasks: 0))
        #expect(await session.snapshot().disconnectCount == 1)
        #expect(await firstSignal.registeredEventStreamCount() == 0)
        #expect(await secondSignal.registeredEventStreamCount() == 0)
    }

    @Test func soleCancelledWaiterRetiresLateConnectAndNextLeaseStartsFresh() async throws {
        let connection = try DatabaseSessionPoolFixtures.connection()
        let lateSession = try DatabaseSessionPoolFixtures.session(
            connection: connection,
            honorsContextCancellation: false)
        let freshIdentity = DatabaseSessionPoolFixtures.identity(server: "fresh")
        let freshSession = try DatabaseSessionPoolFixtures.session(
            connection: connection,
            identity: freshIdentity,
            report: DatabaseSessionPoolFixtures.report(
                identity: freshIdentity,
                marker: "fresh"))
        let connectGate = DatabaseExecutorTestGate(open: false)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: lateSession,
            honorsContextCancellation: false,
            gates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))
        let cancellation = DatabaseAdapterCancellationSignal()

        let cancelled = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context(cancellation: cancellation))
        }
        await connectGate.waitForEntries()
        await cancellation.cancel(.deadlineExceeded)
        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            try await cancelled.value
        }

        let retired = await DatabaseSessionPoolFixtures.waitForDiagnostics(pool) {
            $0.connectWaiters == 0
                && $0.completionObservers == 0
                && $0.sharedCancellationObservers == 0
                && $0.activeTasks == 0
                && $0.cleanupTasks == 1
        }
        #expect(retired.cleanupTasks == 1)
        #expect(await pool.disconnect(connectionID: connection.id) == false)

        await adapter.setSession(freshSession)
        let fresh = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context())
        }
        await connectGate.waitForEntries(2)
        await connectGate.releaseAll()

        let lease = try await fresh.value
        #expect(lease.session.id == freshSession.id)
        #expect(await adapter.recordedInvocations().count == 2)
        #expect(await lateSession.snapshot().disconnectCount == 1)
        #expect(await freshSession.snapshot().disconnectCount == 0)
        #expect(await cancellation.registeredEventStreamCount() == 0)
        #expect(
            await DatabaseSessionPoolFixtures.waitForIdle(pool)
                == DatabaseSessionPoolDiagnostics(
                    connectWaiters: 0,
                    refreshWaiters: 0,
                    completionObservers: 0,
                    sharedCancellationObservers: 0,
                    activeTasks: 0,
                    cleanupTasks: 0))
    }

    @Test func completionWinningBeforeSoleCancellationDoesNotCacheSession() async throws {
        let connection = try DatabaseSessionPoolFixtures.connection()
        let lifecycleGate = DatabaseExecutorTestGate(open: false)
        let completedSession = try DatabaseSessionPoolFixtures.session(
            connection: connection,
            gates: DatabaseExecutorTestSessionGates(lifecycleState: lifecycleGate))
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: completedSession)
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))
        let cancellation = DatabaseAdapterCancellationSignal()

        let cancelled = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context(cancellation: cancellation))
        }
        await lifecycleGate.waitForEntries()
        await lifecycleGate.releaseOne()
        await lifecycleGate.waitForEntries(2)
        await lifecycleGate.releaseOne()
        await lifecycleGate.waitForEntries(3)
        await cancellation.cancel(.userRequested)
        await lifecycleGate.releaseOne()

        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            try await cancelled.value
        }
        #expect(await completedSession.snapshot().disconnectCount == 1)
        #expect(await pool.disconnect(connectionID: connection.id) == false)

        let freshIdentity = DatabaseSessionPoolFixtures.identity(server: "replacement")
        let freshSession = try DatabaseSessionPoolFixtures.session(
            connection: connection,
            identity: freshIdentity,
            report: DatabaseSessionPoolFixtures.report(
                identity: freshIdentity,
                marker: "replacement"))
        await adapter.setSession(freshSession)
        let freshLease = try await pool.lease(
            for: connection,
            context: DatabaseSessionPoolFixtures.context())

        #expect(freshLease.session.id == freshSession.id)
        #expect(await adapter.recordedInvocations().count == 2)
        #expect(await cancellation.registeredEventStreamCount() == 0)
        #expect(
            await DatabaseSessionPoolFixtures.waitForIdle(pool)
                == DatabaseSessionPoolDiagnostics(
                    connectWaiters: 0,
                    refreshWaiters: 0,
                    completionObservers: 0,
                    sharedCancellationObservers: 0,
                    activeTasks: 0,
                    cleanupTasks: 0))
    }

    @Test(arguments: [true, false])
    func completionWinningBeforeSharedCancellationKeepsSessionForSurvivor(
        cancelFirstCaller: Bool
    ) async throws {
        let connection = try DatabaseSessionPoolFixtures.connection()
        let lifecycleGate = DatabaseExecutorTestGate(open: false)
        let session = try DatabaseSessionPoolFixtures.session(
            connection: connection,
            gates: DatabaseExecutorTestSessionGates(lifecycleState: lifecycleGate))
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: session)
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))
        let firstSignal = DatabaseAdapterCancellationSignal()
        let secondSignal = DatabaseAdapterCancellationSignal()

        let first = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context(
                    cancellation: firstSignal))
        }
        await lifecycleGate.waitForEntries()
        let second = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context(
                    cancellation: secondSignal))
        }
        _ = await DatabaseSessionPoolFixtures.waitForDiagnostics(pool) {
            $0.connectWaiters == 2
        }
        await lifecycleGate.releaseOne()
        await lifecycleGate.waitForEntries(2)
        await lifecycleGate.releaseOne()
        await lifecycleGate.waitForEntries(4)

        if cancelFirstCaller {
            await firstSignal.cancel(.userRequested)
        } else {
            await secondSignal.cancel(.userRequested)
        }
        await lifecycleGate.releaseAll()

        let lease: DatabaseSessionLease
        if cancelFirstCaller {
            await #expect(throws: DatabaseAdapterFailure.cancelled) {
                try await first.value
            }
            lease = try await second.value
        } else {
            await #expect(throws: DatabaseAdapterFailure.cancelled) {
                try await second.value
            }
            lease = try await first.value
        }

        #expect(lease.session.id == session.id)
        #expect(await session.snapshot().disconnectCount == 0)
        #expect(await firstSignal.registeredEventStreamCount() == 0)
        #expect(await secondSignal.registeredEventStreamCount() == 0)
        #expect(
            await DatabaseSessionPoolFixtures.waitForIdle(pool)
                == DatabaseSessionPoolDiagnostics(
                    connectWaiters: 0,
                    refreshWaiters: 0,
                    completionObservers: 0,
                    sharedCancellationObservers: 0,
                    activeTasks: 0,
                    cleanupTasks: 0))
    }

    @Test func expiredAndForcedCapabilityReportsSingleFlightRefresh() async throws {
        let connection = try DatabaseSessionPoolFixtures.connection()
        let initial = DatabaseSessionPoolFixtures.report(
            marker: "initial",
            expiresAt: DatabaseSessionPoolFixtures.now.addingTimeInterval(100))
        let session = try DatabaseSessionPoolFixtures.session(
            connection: connection,
            report: initial)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: session)
        let clock = DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now)
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: clock)

        let initialLease = try await pool.lease(
            for: connection,
            context: DatabaseSessionPoolFixtures.context())
        #expect(initialLease.report == initial)

        let forced = DatabaseSessionPoolFixtures.report(
            marker: "forced",
            expiresAt: DatabaseSessionPoolFixtures.now.addingTimeInterval(1))
        await session.setCapabilities(forced)
        let forcedLease = try await pool.lease(
            for: connection,
            resolution: .refresh,
            context: DatabaseSessionPoolFixtures.context())
        #expect(forcedLease.report == forced)
        #expect(forcedLease.reportSource == .discovered)

        clock.set(DatabaseSessionPoolFixtures.now.addingTimeInterval(2))
        let replacement = DatabaseSessionPoolFixtures.report(
            marker: "replacement",
            discoveredAt: DatabaseSessionPoolFixtures.now.addingTimeInterval(2),
            expiresAt: DatabaseSessionPoolFixtures.now.addingTimeInterval(100))
        await session.setCapabilities(replacement)
        let refreshedLease = try await pool.lease(
            for: connection,
            context: DatabaseSessionPoolFixtures.context())

        #expect(refreshedLease.report == replacement)
        #expect(refreshedLease.reportSource == .discovered)
        #expect(await DatabaseSessionPoolFixtures.discoveryCount(session) == 3)
    }

    @Test func refreshCancellationPreservesSurvivorAndPriorReadyLease() async throws {
        let connection = try DatabaseSessionPoolFixtures.connection()
        let discoveryGate = DatabaseExecutorTestGate()
        let initialReport = DatabaseSessionPoolFixtures.report(
            marker: "initial",
            expiresAt: DatabaseSessionPoolFixtures.now.addingTimeInterval(600))
        let session = try DatabaseSessionPoolFixtures.session(
            connection: connection,
            report: initialReport,
            honorsContextCancellation: false,
            gates: DatabaseExecutorTestSessionGates(
                discoverCapabilities: discoveryGate))
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: session)
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))

        _ = try await pool.lease(
            for: connection,
            context: DatabaseSessionPoolFixtures.context())
        await discoveryGate.block()
        let sharedReport = DatabaseSessionPoolFixtures.report(
            marker: "shared",
            expiresAt: DatabaseSessionPoolFixtures.now.addingTimeInterval(600))
        await session.setCapabilities(sharedReport)
        let cancelledSignal = DatabaseAdapterCancellationSignal()
        let survivorSignal = DatabaseAdapterCancellationSignal()
        let cancelled = Task {
            try await pool.lease(
                for: connection,
                resolution: .refresh,
                context: DatabaseSessionPoolFixtures.context(
                    cancellation: cancelledSignal))
        }
        await discoveryGate.waitForEntries(2)
        let survivor = Task {
            try await pool.lease(
                for: connection,
                resolution: .refresh,
                context: DatabaseSessionPoolFixtures.context(
                    cancellation: survivorSignal))
        }
        _ = await DatabaseSessionPoolFixtures.waitForDiagnostics(pool) {
            $0.refreshWaiters == 2
        }
        await cancelledSignal.cancel(.userRequested)

        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            try await cancelled.value
        }
        #expect(await discoveryGate.blockedCount() == 1)
        await discoveryGate.releaseOne()
        let sharedLease = try await survivor.value
        #expect(sharedLease.report == sharedReport)
        #expect(await survivorSignal.reason() == nil)
        #expect(await session.snapshot().disconnectCount == 0)
        #expect(await cancelledSignal.registeredEventStreamCount() == 0)

        let cancelledReport = DatabaseSessionPoolFixtures.report(
            marker: "cancelled",
            expiresAt: DatabaseSessionPoolFixtures.now.addingTimeInterval(600))
        await session.setCapabilities(cancelledReport)
        let soleSignal = DatabaseAdapterCancellationSignal()
        let sole = Task {
            try await pool.lease(
                for: connection,
                resolution: .refresh,
                context: DatabaseSessionPoolFixtures.context(cancellation: soleSignal))
        }
        await discoveryGate.waitForEntries(3)
        await soleSignal.cancel(.deadlineExceeded)
        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            try await sole.value
        }
        let retired = await DatabaseSessionPoolFixtures.waitForDiagnostics(pool) {
            $0.refreshWaiters == 0 && $0.activeTasks == 0 && $0.cleanupTasks == 1
        }
        #expect(retired.cleanupTasks == 1)

        let retained = try await pool.lease(
            for: connection,
            context: DatabaseSessionPoolFixtures.context())
        #expect(retained.report == sharedReport)
        await discoveryGate.releaseOne()
        _ = await DatabaseSessionPoolFixtures.waitForIdle(pool)

        let finalReport = DatabaseSessionPoolFixtures.report(
            marker: "final",
            expiresAt: DatabaseSessionPoolFixtures.now.addingTimeInterval(600))
        await session.setCapabilities(finalReport)
        let final = Task {
            try await pool.lease(
                for: connection,
                resolution: .refresh,
                context: DatabaseSessionPoolFixtures.context())
        }
        await discoveryGate.waitForEntries(4)
        await discoveryGate.releaseOne()
        let finalLease = try await final.value

        #expect(finalLease.report == finalReport)
        #expect(await session.snapshot().disconnectCount == 0)
        #expect(await survivorSignal.registeredEventStreamCount() == 0)
        #expect(await soleSignal.registeredEventStreamCount() == 0)
        #expect(
            await DatabaseSessionPoolFixtures.waitForIdle(pool)
                == DatabaseSessionPoolDiagnostics(
                    connectWaiters: 0,
                    refreshWaiters: 0,
                    completionObservers: 0,
                    sharedCancellationObservers: 0,
                    activeTasks: 0,
                    cleanupTasks: 0))
    }

    @Test func lateStaleGenerationCannotReplaceRevisionAndDisconnects() async throws {
        let timestamp = DatabaseSessionPoolFixtures.now.addingTimeInterval(-10)
        let oldDefinition = try DatabaseSessionPoolFixtures.connection(
            name: "Old",
            updatedAt: timestamp)
        let newDefinition = try DatabaseSessionPoolFixtures.connection(
            name: "New",
            updatedAt: timestamp)
        let oldSession = try DatabaseSessionPoolFixtures.session(
            connection: oldDefinition,
            honorsContextCancellation: false)
        let newIdentity = DatabaseSessionPoolFixtures.identity(server: "new")
        let newSession = try DatabaseSessionPoolFixtures.session(
            connection: newDefinition,
            identity: newIdentity,
            report: DatabaseSessionPoolFixtures.report(
                identity: newIdentity,
                marker: "new"))
        let connectGate = DatabaseExecutorTestGate(open: false)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: oldSession,
            honorsContextCancellation: false,
            gates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))
        let oldSignal = DatabaseAdapterCancellationSignal()

        let old = Task {
            try await pool.lease(
                for: oldDefinition,
                context: DatabaseSessionPoolFixtures.context(cancellation: oldSignal))
        }
        await connectGate.waitForEntries()
        await adapter.setSession(newSession)
        let new = Task {
            try await pool.lease(
                for: newDefinition,
                context: DatabaseSessionPoolFixtures.context())
        }
        await connectGate.waitForEntries(2)

        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            try await old.value
        }
        await connectGate.releaseAll()
        let newLease = try await new.value

        #expect(newLease.definition == newDefinition)
        #expect(newLease.session.id == newSession.id)
        #expect(await oldSession.snapshot().disconnectCount == 1)
        #expect(await newSession.snapshot().disconnectCount == 0)
        #expect(await oldSignal.reason() == .sessionDisconnected)
        #expect(await oldSignal.registeredEventStreamCount() == 0)
        #expect(
            await DatabaseSessionPoolFixtures.waitForIdle(pool)
                == DatabaseSessionPoolDiagnostics(
                    connectWaiters: 0,
                    refreshWaiters: 0,
                    completionObservers: 0,
                    sharedCancellationObservers: 0,
                    activeTasks: 0,
                    cleanupTasks: 0))
    }

    @Test func ephemeralTestsNeverCacheAndAlwaysDisconnect() async throws {
        let connection = try DatabaseSessionPoolFixtures.connection()
        let testedSession = try DatabaseSessionPoolFixtures.session(connection: connection)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: testedSession)
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))

        let tested = try await pool.testConnection(
            definition: connection,
            context: DatabaseSessionPoolFixtures.context())
        #expect(tested.report == DatabaseSessionPoolFixtures.report())
        #expect(await testedSession.snapshot().disconnectCount == 1)

        let cachedSession = try DatabaseSessionPoolFixtures.session(
            connection: connection,
            identity: DatabaseSessionPoolFixtures.identity(server: "cached"),
            report: DatabaseSessionPoolFixtures.report(
                identity: DatabaseSessionPoolFixtures.identity(server: "cached"),
                marker: "cached"))
        await adapter.setSession(cachedSession)
        let cachedLease = try await pool.lease(
            for: connection,
            context: DatabaseSessionPoolFixtures.context())

        let failedSession = try DatabaseSessionPoolFixtures.session(connection: connection)
        let failure = DatabaseAdapterFailure.reported(
            DatabaseErrorEnvelope(category: .server, message: "discovery failed"))
        await failedSession.enqueueCapabilities(.failure(failure))
        await adapter.setSession(failedSession)
        await #expect(throws: failure) {
            try await pool.testConnection(
                definition: connection,
                context: DatabaseSessionPoolFixtures.context())
        }

        let retainedLease = try await pool.lease(
            for: connection,
            context: DatabaseSessionPoolFixtures.context())
        #expect(retainedLease.session.id == cachedLease.session.id)
        #expect(await failedSession.snapshot().disconnectCount == 1)
        #expect(await adapter.recordedInvocations().count == 3)
    }

    @Test func cancelledEphemeralTestReturnsBeforeLateSessionAndNeverCaches() async throws {
        let connection = try DatabaseSessionPoolFixtures.connection()
        let lateSession = try DatabaseSessionPoolFixtures.session(
            connection: connection,
            honorsContextCancellation: false)
        let connectGate = DatabaseExecutorTestGate(open: false)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: lateSession,
            honorsContextCancellation: false,
            gates: DatabaseExecutorTestAdapterGates(connect: connectGate))
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))
        let cancellation = DatabaseAdapterCancellationSignal()

        let tested = Task {
            try await pool.testConnection(
                definition: connection,
                context: DatabaseSessionPoolFixtures.context(
                    cancellation: cancellation))
        }
        await connectGate.waitForEntries()
        await cancellation.cancel(.userRequested)
        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            try await tested.value
        }
        let retired = await DatabaseSessionPoolFixtures.waitForDiagnostics(pool) {
            $0.activeTasks == 0 && $0.cleanupTasks == 1
        }
        #expect(retired.cleanupTasks == 1)
        #expect(await pool.disconnect(connectionID: connection.id) == false)

        let freshIdentity = DatabaseSessionPoolFixtures.identity(server: "fresh-test")
        let freshSession = try DatabaseSessionPoolFixtures.session(
            connection: connection,
            identity: freshIdentity,
            report: DatabaseSessionPoolFixtures.report(
                identity: freshIdentity,
                marker: "fresh-test"))
        await adapter.setSession(freshSession)
        let lease = Task {
            try await pool.lease(
                for: connection,
                context: DatabaseSessionPoolFixtures.context())
        }
        await connectGate.waitForEntries(2)
        await connectGate.releaseAll()

        let freshLease = try await lease.value
        #expect(freshLease.session.id == freshSession.id)
        #expect(await lateSession.snapshot().disconnectCount == 1)
        #expect(await freshSession.snapshot().disconnectCount == 0)
        #expect(await cancellation.registeredEventStreamCount() == 0)
        #expect(
            await DatabaseSessionPoolFixtures.waitForIdle(pool)
                == DatabaseSessionPoolDiagnostics(
                    connectWaiters: 0,
                    refreshWaiters: 0,
                    completionObservers: 0,
                    sharedCancellationObservers: 0,
                    activeTasks: 0,
                    cleanupTasks: 0))
    }

    @Test func reportsUseExactSessionSecretsForRedactionAcrossRefresh() async throws {
        let connection = try DatabaseSessionPoolFixtures.connection(includesSecrets: true)
        let originalSecret = "original-session-secret"
        let rotatedSecret = "rotated-store-secret"
        let identity = DatabaseProductIdentity(
            product: .postgresql,
            version: DatabaseVersion(string: "17.4-\(originalSecret)"),
            distribution: "distribution-\(originalSecret)",
            topology: DatabaseTopology(
                kind: .standalone,
                name: "topology-\(originalSecret)"),
            serverIdentifier: "server-\(originalSecret)")
        let initialReport = DatabaseSessionPoolFixtures.report(
            identity: identity,
            marker: originalSecret,
            expiresAt: DatabaseSessionPoolFixtures.now.addingTimeInterval(600))
        let session = try DatabaseSessionPoolFixtures.session(
            connection: connection,
            identity: identity,
            report: initialReport)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: session)
        let store = try InMemoryDatabaseSecretStore(initialValues: [
            DatabaseSessionPoolFixtures.passwordReference: Data(originalSecret.utf8),
            DatabaseSessionPoolFixtures.privateKeyReference: Data("private-key".utf8),
        ])
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: store,
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))

        let initial = try await pool.lease(
            for: connection,
            context: DatabaseSessionPoolFixtures.context())
        #expect(initial.report.productIdentity.serverIdentifier == "server-[REDACTED]")
        #expect(initial.report.safetyLimitations == ["[REDACTED]"])
        #expect(initial.report.capabilities[0].attributes[0].value == "[REDACTED]")

        try await store.store(
            Data(rotatedSecret.utf8),
            for: DatabaseSessionPoolFixtures.passwordReference)
        let refreshedReport = DatabaseCapabilityReport(
            productIdentity: identity,
            capabilities: [
                DatabaseCapabilityStatus(
                    id: .browse,
                    requirement: .sharedRequired,
                    availability: .available,
                    attributes: [
                        DatabaseStringAttribute(
                            name: "marker",
                            value: "\(originalSecret):\(rotatedSecret)")
                    ])
            ],
            safetyLimitations: [originalSecret, rotatedSecret],
            discoveredAt: DatabaseSessionPoolFixtures.now,
            expiresAt: DatabaseSessionPoolFixtures.now.addingTimeInterval(600))
        await session.setCapabilities(refreshedReport)
        let refreshed = try await pool.lease(
            for: connection,
            resolution: .refresh,
            context: DatabaseSessionPoolFixtures.context())

        #expect(
            refreshed.report.capabilities[0].attributes[0].value
                == "[REDACTED]:\(rotatedSecret)")
        #expect(
            refreshed.report.safetyLimitations
                == ["[REDACTED]", rotatedSecret])
        #expect(refreshed.report.productIdentity.serverIdentifier == "server-[REDACTED]")
        #expect(await adapter.recordedInvocations().count == 1)
        #expect(
            await DatabaseSessionPoolFixtures.waitForIdle(pool)
                == DatabaseSessionPoolDiagnostics(
                    connectWaiters: 0,
                    refreshWaiters: 0,
                    completionObservers: 0,
                    sharedCancellationObservers: 0,
                    activeTasks: 0,
                    cleanupTasks: 0))
    }

    @Test func rejectsProductLifecycleCapabilityAndTimestampViolations() async throws {
        let first = try DatabaseSessionPoolFixtures.connection()
        let second = try DatabaseSessionPoolFixtures.connection(
            id: DatabaseSessionPoolFixtures.secondID,
            name: "Second")
        let third = try DatabaseSessionPoolFixtures.connection(
            id: DatabaseSessionPoolFixtures.thirdID,
            name: "Third")
        let fourth = try DatabaseSessionPoolFixtures.connection(
            id: DatabaseSessionPoolFixtures.fourthID,
            name: "Fourth")
        let wrongProductIdentity = DatabaseSessionPoolFixtures.identity(product: .mysql)
        let wrongProduct = try DatabaseSessionPoolFixtures.session(
            connection: first,
            identity: wrongProductIdentity,
            report: DatabaseSessionPoolFixtures.report(identity: wrongProductIdentity))
        let failedLifecycle = try DatabaseSessionPoolFixtures.session(
            connection: second,
            state: .failed)
        let futureReport = DatabaseSessionPoolFixtures.report(
            marker: "future",
            discoveredAt: DatabaseSessionPoolFixtures.now.addingTimeInterval(1))
        let future = try DatabaseSessionPoolFixtures.session(
            connection: third,
            report: futureReport)
        let mismatchedReport = DatabaseSessionPoolFixtures.report(
            identity: wrongProductIdentity,
            marker: "mismatch")
        let mismatched = try DatabaseSessionPoolFixtures.session(
            connection: fourth,
            report: mismatchedReport)
        let adapter = DatabaseExecutorRecordingAdapter(
            id: "postgres",
            products: [.postgresql],
            session: wrongProduct)
        let pool = try DatabaseSessionPoolFixtures.pool(
            adapter: adapter,
            store: try InMemoryDatabaseSecretStore(),
            clock: DatabaseSessionPoolTestClock(DatabaseSessionPoolFixtures.now))

        await #expect(throws: DatabaseAdapterFailure.contractViolation(.staleSession)) {
            try await pool.lease(
                for: first,
                context: DatabaseSessionPoolFixtures.context())
        }
        await adapter.setSession(failedLifecycle)
        await #expect(throws: DatabaseAdapterFailure.contractViolation(.staleSession)) {
            try await pool.lease(
                for: second,
                context: DatabaseSessionPoolFixtures.context())
        }
        await adapter.setSession(future)
        await #expect(throws: DatabaseAdapterFailure.contractViolation(.staleSession)) {
            try await pool.lease(
                for: third,
                context: DatabaseSessionPoolFixtures.context())
        }
        await adapter.setSession(mismatched)
        await #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .capabilityIdentityMismatch)
        ) {
            try await pool.lease(
                for: fourth,
                context: DatabaseSessionPoolFixtures.context())
        }

        #expect(await wrongProduct.snapshot().disconnectCount == 1)
        #expect(await failedLifecycle.snapshot().disconnectCount == 1)
        #expect(await future.snapshot().disconnectCount == 1)
        #expect(await mismatched.snapshot().disconnectCount == 1)
    }
}
