import Foundation
import Testing

@testable import EdithDatabase

private struct DatabaseAdapterRegistryFixture: DatabaseAdapter {
    let id: DatabaseAdapterID
    let products: Set<DatabaseProduct>

    func connect(
        _ connection: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterSession {
        throw .contractViolation(.unsupportedProduct(connection.definition.productHint))
    }
}

private enum DatabaseAdapterContractFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static var target: DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: DatabaseConnectionFixtures.connectionID,
            object: DatabaseObjectIdentifier(kind: .table, path: ["public", "orders"]))
    }

    static func identity(_ product: DatabaseProduct = .postgresql) -> DatabaseProductIdentity {
        DatabaseProductIdentity(
            product: product,
            version: DatabaseVersion(string: "17.4", major: 17, minor: 4),
            topology: DatabaseTopology(kind: .standalone))
    }

    static func capability(
        _ id: DatabaseCapabilityID
    ) -> DatabaseCapabilityStatus {
        DatabaseCapabilityStatus(
            id: id,
            requirement: .sharedRequired,
            availability: .available)
    }

    static func report(
        identity: DatabaseProductIdentity,
        capabilities: [DatabaseCapabilityStatus]
    ) -> DatabaseCapabilityReport {
        DatabaseCapabilityReport(
            productIdentity: identity,
            capabilities: capabilities,
            discoveredAt: now)
    }

    static func record(_ value: Int64) -> DatabaseRecord {
        DatabaseRecord(
            fields: [
                DatabaseObjectField(name: "value", value: .signedInteger(value))
            ])
    }

    static func metadata(
        recordCount: Int,
        warnings: [DatabaseWarning] = [],
        partialFailures: [DatabasePartialFailure] = []
    ) -> DatabasePageMetadata {
        DatabasePageMetadata(
            completeness: DatabaseResultCompleteness(state: .complete),
            count: DatabaseCountMetadata(
                value: UInt64(recordCount),
                accuracy: .exact),
            warnings: warnings,
            partialFailures: partialFailures)
    }

    static func pageRequest(
        size: Int,
        continuation: DatabaseContinuationToken? = nil,
        projection: DatabaseProjection? = nil,
        sorts: [DatabaseSort] = []
    ) throws -> DatabasePageRequest {
        DatabasePageRequest(
            pageSize: try DatabasePageSize(size),
            continuation: continuation,
            projection: projection,
            sorts: sorts)
    }

    static func adapterPageRequest(size: Int) throws -> DatabaseAdapterPageRequest {
        try DatabaseAdapterPageRequest(
            target: target,
            page: pageRequest(size: size),
            continuation: nil)
    }

    static func secretReference(_ index: Int) -> DatabaseSecretReference {
        DatabaseSecretReference(
            identifier: UUID(
                uuid: (
                    0x4D, 0x3F, 0xB9, 0x0A, 0x3A, 0x90, 0x4A, 0x92,
                    0x8B, 0x32, 0x75, 0x14, 0x00, 0x00, UInt8(index / 256),
                    UInt8(index % 256)
                )),
            purpose: .password)
    }

    static func secrets(count: Int, bytes: Int = 1) -> [DatabaseSecretReference: Data] {
        Dictionary(
            uniqueKeysWithValues: (0..<count).map {
                (secretReference($0), Data(repeating: UInt8($0 % 256), count: bytes))
            })
    }

    static func query(page: DatabasePageRequest) -> DatabaseQueryRequest {
        DatabaseQueryRequest(
            target: target,
            language: .sql,
            command: "SELECT value FROM orders ORDER BY value",
            page: page)
    }
}

@Suite struct DatabaseAdapterBoundTests {
    @Test func continuationAcceptsTheLimitAndRejectsTheNextByte() throws {
        let accepted = try DatabaseAdapterContinuation(
            mode: .keyset,
            payload: Data(count: DatabaseAdapterBounds.maximumContinuationBytes))

        #expect(accepted.payload.count == DatabaseAdapterBounds.maximumContinuationBytes)
        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .continuationBytes,
                actual: DatabaseAdapterBounds.maximumContinuationBytes + 1,
                maximum: DatabaseAdapterBounds.maximumContinuationBytes)
        ) {
            try DatabaseAdapterContinuation(
                mode: .keyset,
                payload: Data(count: DatabaseAdapterBounds.maximumContinuationBytes + 1))
        }
    }

    @Test func pageRequestRejectsExcessProjectionAndSortFields() throws {
        let fields = (0...DatabaseAdapterBounds.maximumProjectionFields).map {
            DatabaseProjectedField(path: DatabaseFieldPath("field\($0)"))
        }
        let projectionPage = try DatabaseAdapterContractFixtures.pageRequest(
            size: 10,
            projection: DatabaseProjection(mode: .include, fields: fields))

        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .projectionFields,
                actual: DatabaseAdapterBounds.maximumProjectionFields + 1,
                maximum: DatabaseAdapterBounds.maximumProjectionFields)
        ) {
            try DatabaseAdapterPageRequest(
                target: DatabaseAdapterContractFixtures.target,
                page: projectionPage,
                continuation: nil)
        }

        let sorts = (0...DatabaseAdapterBounds.maximumSorts).map {
            DatabaseSort(field: DatabaseFieldPath("field\($0)"), direction: .ascending)
        }
        let sortPage = try DatabaseAdapterContractFixtures.pageRequest(size: 10, sorts: sorts)

        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .sorts,
                actual: DatabaseAdapterBounds.maximumSorts + 1,
                maximum: DatabaseAdapterBounds.maximumSorts)
        ) {
            try DatabaseAdapterPageRequest(
                target: DatabaseAdapterContractFixtures.target,
                page: sortPage,
                continuation: nil)
        }
    }

    @Test func pageAndBatchRejectTheirGlobalRecordLimits() {
        let pageRecords = (0...DatabaseAdapterBounds.maximumPageRecords).map {
            DatabaseAdapterContractFixtures.record(Int64($0))
        }
        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .pageRecords,
                actual: DatabaseAdapterBounds.maximumPageRecords + 1,
                maximum: DatabaseAdapterBounds.maximumPageRecords)
        ) {
            try DatabaseAdapterPage(
                records: pageRecords,
                metadata: DatabaseAdapterContractFixtures.metadata(
                    recordCount: pageRecords.count))
        }

        let batchRecords = (0...DatabaseAdapterBounds.maximumStreamBatchRecords).map {
            DatabaseAdapterContractFixtures.record(Int64($0))
        }
        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .streamBatchRecords,
                actual: DatabaseAdapterBounds.maximumStreamBatchRecords + 1,
                maximum: DatabaseAdapterBounds.maximumStreamBatchRecords)
        ) {
            try DatabaseAdapterRecordBatch(records: batchRecords)
        }
    }

    @Test func capabilityCollectionsHonorTheirHardLimit() {
        let identity = DatabaseAdapterContractFixtures.identity()
        let capabilities = (0...DatabaseAdapterBounds.maximumCapabilities).map {
            DatabaseAdapterContractFixtures.capability(
                DatabaseCapabilityID(rawValue: "capability.\($0)"))
        }
        let report = DatabaseAdapterContractFixtures.report(
            identity: identity,
            capabilities: capabilities)

        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .capabilities,
                actual: DatabaseAdapterBounds.maximumCapabilities + 1,
                maximum: DatabaseAdapterBounds.maximumCapabilities)
        ) {
            try DatabaseAdapterBounds.validate(report: report, identity: identity)
        }
    }
}

@Suite struct DatabaseAdapterCapabilityAndRegistryTests {
    @Test func capabilityReportMustMatchTheDetectedIdentity() {
        let detected = DatabaseAdapterContractFixtures.identity(.postgresql)
        let report = DatabaseAdapterContractFixtures.report(
            identity: DatabaseAdapterContractFixtures.identity(.mysql),
            capabilities: [])

        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .capabilityIdentityMismatch)
        ) {
            try DatabaseAdapterBounds.validate(report: report, identity: detected)
        }
    }

    @Test func capabilityIdentifiersMustBeUnique() {
        let identity = DatabaseAdapterContractFixtures.identity()
        let report = DatabaseAdapterContractFixtures.report(
            identity: identity,
            capabilities: [
                DatabaseAdapterContractFixtures.capability(.browse),
                DatabaseAdapterContractFixtures.capability(.browse),
            ])

        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .duplicateCapability(.browse))
        ) {
            try DatabaseAdapterBounds.validate(report: report, identity: identity)
        }
    }

    @Test func registryRejectsDuplicateAdapterIdentifiers() {
        let identifier: DatabaseAdapterID = "relational"
        let first = DatabaseAdapterRegistryFixture(
            id: identifier,
            products: [.postgresql])
        let second = DatabaseAdapterRegistryFixture(
            id: identifier,
            products: [.mysql])

        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .duplicateAdapterIdentifier(identifier))
        ) {
            try DatabaseAdapterRegistry(adapters: [first, second])
        }
    }

    @Test func registryRejectsDuplicateProductRegistrations() {
        let first = DatabaseAdapterRegistryFixture(
            id: "postgres-primary",
            products: [.postgresql])
        let second = DatabaseAdapterRegistryFixture(
            id: "postgres-secondary",
            products: [.postgresql])

        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .duplicateProductRegistration(.postgresql))
        ) {
            try DatabaseAdapterRegistry(adapters: [first, second])
        }
    }

    @Test func registryReportsUnsupportedProducts() throws {
        let adapter = DatabaseAdapterRegistryFixture(
            id: "postgres",
            products: [.postgresql])
        let registry = try DatabaseAdapterRegistry(adapters: [adapter])

        #expect(registry.supports(.postgresql))
        #expect(!registry.supports(.mongoDB))
        #expect(try registry.adapter(for: .postgresql).id == adapter.id)
        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .unsupportedProduct(.mongoDB))
        ) {
            try registry.adapter(for: .mongoDB)
        }
    }
}

@Suite struct DatabaseAdapterExecutionBoundaryTests {
    @Test func queryRequestStripsThePublicContinuation() throws {
        let publicContinuation = DatabaseContinuationToken(rawValue: "signed-public-token")
        let publicPage = try DatabaseAdapterContractFixtures.pageRequest(
            size: 25,
            continuation: publicContinuation)
        let query = DatabaseAdapterContractFixtures.query(page: publicPage)
        let withoutAdapterContinuation = try DatabaseAdapterQueryRequest(
            request: query,
            continuation: nil)

        #expect(withoutAdapterContinuation.source.continuation == nil)
        #expect(withoutAdapterContinuation.source.pageSize.value == 25)
        #expect(withoutAdapterContinuation.command == query.command)

        let adapterContinuation = try DatabaseAdapterContinuation(
            mode: .serverCursor,
            payload: Data("opaque-driver-cursor".utf8))
        let withAdapterContinuation = try DatabaseAdapterQueryRequest(
            request: query,
            continuation: adapterContinuation)

        #expect(withAdapterContinuation.source.continuation == adapterContinuation)
        #expect(
            withAdapterContinuation.source.continuation?.payload
                != Data(publicContinuation.rawValue.utf8))
    }

    @Test func pageAndBatchValidateTheRequestedLimit() throws {
        let records = [
            DatabaseAdapterContractFixtures.record(1),
            DatabaseAdapterContractFixtures.record(2),
        ]
        let page = try DatabaseAdapterPage(
            records: records,
            metadata: DatabaseAdapterContractFixtures.metadata(recordCount: records.count))
        let pageRequest = try DatabaseAdapterContractFixtures.adapterPageRequest(size: 1)

        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .pageExceedsRequest(actual: 2, requested: 1))
        ) {
            try page.validate(for: pageRequest)
        }

        let batch = try DatabaseAdapterRecordBatch(records: records)
        let streamRequest = DatabaseAdapterStreamRequest(
            source: .browse(pageRequest),
            batchSize: try DatabaseAdapterBatchSize(1))

        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .streamBatchExceedsRequest(actual: 2, requested: 1))
        ) {
            try batch.validate(for: streamRequest)
        }
    }

    @Test func resolvedConnectionBoundsSecretCountAndSize() throws {
        let connection = try DatabaseConnectionFixtures.connectionDefinition()
        let accepted = try DatabaseResolvedConnection(
            definition: connection,
            secrets: DatabaseAdapterContractFixtures.secrets(
                count: DatabaseAdapterBounds.maximumResolvedSecrets))

        #expect(accepted.secrets.count == DatabaseAdapterBounds.maximumResolvedSecrets)
        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .resolvedSecrets,
                actual: DatabaseAdapterBounds.maximumResolvedSecrets + 1,
                maximum: DatabaseAdapterBounds.maximumResolvedSecrets)
        ) {
            try DatabaseResolvedConnection(
                definition: connection,
                secrets: DatabaseAdapterContractFixtures.secrets(
                    count: DatabaseAdapterBounds.maximumResolvedSecrets + 1))
        }

        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .secretBytes,
                actual: DatabaseAdapterBounds.maximumSecretBytes + 1,
                maximum: DatabaseAdapterBounds.maximumSecretBytes)
        ) {
            try DatabaseResolvedConnection(
                definition: connection,
                secrets: DatabaseAdapterContractFixtures.secrets(
                    count: 1,
                    bytes: DatabaseAdapterBounds.maximumSecretBytes + 1))
        }
    }

    @Test func cancellationSignalKeepsTheFirstReason() async throws {
        let signal = DatabaseAdapterCancellationSignal()
        try await signal.checkCancellation()
        let stream = await signal.events()
        let waiting = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        await signal.cancel(.deadlineExceeded)
        await signal.cancel(.userRequested)

        #expect(await waiting.value == .deadlineExceeded)
        #expect(await signal.reason() == .deadlineExceeded)
        #expect(await signal.registeredEventStreamCount() == 0)
        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            try await signal.checkCancellation()
        }
    }

    @Test func cancellationEventsFinishImmediatelyAfterCancellation() async {
        let signal = DatabaseAdapterCancellationSignal()
        await signal.cancel(.sessionDisconnected)

        let stream = await signal.events()
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == .sessionDisconnected)
        #expect(await iterator.next() == nil)
        #expect(await signal.registeredEventStreamCount() == 0)
    }

    @Test func cancellationEventRegistrationIsRemovedWhenConsumptionStops() async {
        let signal = DatabaseAdapterCancellationSignal()
        let stream = await signal.events()
        #expect(await signal.registeredEventStreamCount() == 1)

        let consuming = Task {
            for await _ in stream {}
        }
        consuming.cancel()
        await consuming.value

        for _ in 0..<100 where await signal.registeredEventStreamCount() != 0 {
            await Task.yield()
        }
        #expect(await signal.registeredEventStreamCount() == 0)
    }

    @Test func mutationResultBoundsServerOperationIdentifier() throws {
        let acceptedIdentifier = String(
            repeating: "a",
            count: DatabaseAdapterBounds.maximumServerOperationIdentifierBytes)
        let result = try DatabaseAdapterMutationResult(
            disposition: .accepted,
            effect: .unknown,
            affectedRecords: DatabaseCountMetadata(value: 12, accuracy: .estimated),
            serverOperationIdentifier: acceptedIdentifier)

        #expect(result.serverOperationIdentifier == acceptedIdentifier)
        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .serverOperationIdentifierBytes,
                actual: DatabaseAdapterBounds.maximumServerOperationIdentifierBytes + 1,
                maximum: DatabaseAdapterBounds.maximumServerOperationIdentifierBytes)
        ) {
            try DatabaseAdapterMutationResult(
                disposition: .accepted,
                effect: .unknown,
                affectedRecords: DatabaseCountMetadata(value: 12, accuracy: .estimated),
                serverOperationIdentifier: String(
                    repeating: "a",
                    count: DatabaseAdapterBounds.maximumServerOperationIdentifierBytes + 1))
        }
    }

    @Test func mutationResultRejectsIncompleteReturnedPages() throws {
        let page = try DatabaseAdapterPage(
            records: [],
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(
                    state: .partial,
                    reason: "A shard did not respond."),
                count: DatabaseCountMetadata(value: 0, accuracy: .lowerBound)))

        #expect(
            throws: DatabaseAdapterFailure.contractViolation(.partialMutationResult)
        ) {
            try DatabaseAdapterMutationResult(
                disposition: .completed,
                effect: .applied,
                affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .lowerBound),
                returnedPage: page)
        }
    }

    @Test func mutationResultBoundsPartialFailures() throws {
        let error = DatabaseErrorEnvelope(
            category: .partialFailure,
            message: "A mutation item failed.")
        let failure = DatabasePartialFailure(itemIndex: 1, error: error)

        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .partialFailures,
                actual: DatabaseAdapterBounds.maximumPartialFailures + 1,
                maximum: DatabaseAdapterBounds.maximumPartialFailures)
        ) {
            try DatabaseAdapterMutationResult(
                disposition: .completed,
                effect: .partiallyApplied,
                affectedRecords: DatabaseCountMetadata(value: 1, accuracy: .lowerBound),
                partialFailures: Array(
                    repeating: failure,
                    count: DatabaseAdapterBounds.maximumPartialFailures + 1),
                error: error)
        }
    }

    @Test func terminalFailedAndCancelledStatusesRequireEffectOutcomes() throws {
        let error = DatabaseErrorEnvelope(
            category: .server,
            message: "The asynchronous mutation failed.")
        let failedOutcome = try DatabaseAdapterMutationResult(
            disposition: .completed,
            effect: .notApplied,
            affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .exact),
            serverOperationIdentifier: "server-task-1",
            error: error)
        let failed = try DatabaseAdapterMutationStatus(
            serverOperationIdentifier: "server-task-1",
            state: .failed,
            outcome: failedOutcome,
            error: error)
        let cancelledOutcome = try DatabaseAdapterMutationResult(
            disposition: .completed,
            effect: .notApplied,
            affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .exact),
            serverOperationIdentifier: "server-task-1")
        let cancelled = try DatabaseAdapterMutationStatus(
            serverOperationIdentifier: "server-task-1",
            state: .cancelled,
            outcome: cancelledOutcome)

        #expect(failed.outcome?.effect == .notApplied)
        #expect(cancelled.outcome?.effect == .notApplied)
        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .invalidMutationReconciliationResult)
        ) {
            try DatabaseAdapterMutationStatus(
                serverOperationIdentifier: "server-task-1",
                state: .failed,
                error: error)
        }
        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .invalidMutationReconciliationResult)
        ) {
            try DatabaseAdapterMutationStatus(
                serverOperationIdentifier: "server-task-1",
                state: .cancelled)
        }
    }

    @Test func mutationReconciliationRejectsAmbiguousAdapterResults() throws {
        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .invalidMutationReconciliationResult)
        ) {
            try DatabaseAdapterMutationResult(
                disposition: .accepted,
                effect: .unknown,
                affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .unknown))
        }

        let page = try DatabaseAdapterPage(
            records: [],
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(state: .complete),
                count: DatabaseCountMetadata(value: 0, accuracy: .exact)))
        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .invalidMutationReconciliationResult)
        ) {
            try DatabaseAdapterMutationResult(
                disposition: .accepted,
                effect: .unknown,
                affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .unknown),
                returnedPage: page,
                serverOperationIdentifier: "server-task-1")
        }

        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .invalidMutationReconciliationResult)
        ) {
            try DatabaseAdapterMutationStatus(
                serverOperationIdentifier: "server-task-1",
                state: .completed)
        }

        let running = try DatabaseAdapterMutationStatus(
            serverOperationIdentifier: "server-task-1",
            state: .running)
        #expect(
            throws: DatabaseAdapterFailure.contractViolation(
                .invalidMutationReconciliationResult)
        ) {
            try DatabaseAdapterMutationCancellationResult(
                serverOperationIdentifier: "server-task-1",
                disposition: .alreadyFinished,
                status: running)
        }
    }
}
