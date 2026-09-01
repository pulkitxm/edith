import Foundation

struct DatabaseAdapterID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        rawValue = value
    }
}

struct DatabaseAdapterSessionID: RawRepresentable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    init() {
        rawValue = UUID()
    }
}

enum DatabaseAdapterLimit: String, Hashable, Sendable {
    case adapterProducts
    case capabilities
    case capabilityReportBytes
    case capabilityReportNodes
    case capabilityReportCollectionElements
    case capabilityReportDepth
    case capabilityReportStringBytes
    case capabilityModules
    case capabilityPlugins
    case capabilityCompatibilityNotes
    case capabilityTopologyAttributes
    case capabilityMissingPermissions
    case capabilityReasonConstraints
    case capabilityLimits
    case capabilityAttributes
    case permissions
    case safetyLimitations
    case resolvedSecrets
    case secretBytes
    case projectionFields
    case sorts
    case continuationBytes
    case pageRecords
    case pageFields
    case recordFields
    case pageBytes
    case streamBatchRecords
    case streamBatchBytes
    case warnings
    case partialFailures
    case serverOperationIdentifierBytes
}

enum DatabaseAdapterContractViolation: Hashable, Sendable {
    case emptyAdapterIdentifier
    case duplicateAdapterIdentifier(DatabaseAdapterID)
    case duplicateProductRegistration(DatabaseProduct)
    case unsupportedProduct(DatabaseProduct)
    case capabilityIdentityMismatch
    case duplicateCapability(DatabaseCapabilityID)
    case pageExceedsRequest(actual: Int, requested: Int)
    case streamBatchExceedsRequest(actual: Int, requested: Int)
    case encodingFailed
    case staleSession
    case unexpectedMutationPlan
    case partialMutationResult
    case invalidMutationReconciliationResult
}

enum DatabaseAdapterFailure: Error, Hashable, Sendable {
    case reported(DatabaseErrorEnvelope)
    case cancelled
    case limitExceeded(limit: DatabaseAdapterLimit, actual: Int, maximum: Int)
    case contractViolation(DatabaseAdapterContractViolation)
}

enum DatabaseAdapterBounds {
    static let maximumProducts = DatabaseProduct.allCases.count
    static let maximumCapabilities = 256
    static let maximumPermissions = 512
    static let maximumSafetyLimitations = 100
    static let maximumResolvedSecrets = 16
    static let maximumSecretBytes = 1_048_576
    static let maximumProjectionFields = 512
    static let maximumSorts = 64
    static let maximumContinuationBytes = 65_536
    static let maximumPageRecords = DatabasePageSize.range.upperBound
    static let maximumPageFields = 512
    static let maximumRecordFields = 512
    static let maximumPageBytes = 16_777_216
    static let maximumStreamBatchRecords = 500
    static let maximumStreamBatchBytes = 4_194_304
    static let maximumWarnings = 100
    static let maximumPartialFailures = 100
    static let maximumServerOperationIdentifierBytes = 4_096

    static func validate(
        products: Set<DatabaseProduct>,
        adapterID: DatabaseAdapterID
    ) throws(DatabaseAdapterFailure) {
        guard !adapterID.rawValue.isEmpty else {
            throw .contractViolation(.emptyAdapterIdentifier)
        }
        guard !products.isEmpty, products.count <= maximumProducts else {
            throw .limitExceeded(
                limit: .adapterProducts,
                actual: products.count,
                maximum: maximumProducts)
        }
    }

    static func validate(
        report: DatabaseCapabilityReport,
        identity: DatabaseProductIdentity
    ) throws(DatabaseAdapterFailure) {
        try DatabaseAdapterCapabilityReportSanitizer.validate(
            report,
            identity: identity)
    }

    static func validate(
        records: [DatabaseRecord],
        fields: [DatabaseFieldDescriptor],
        warnings: [DatabaseWarning],
        partialFailures: [DatabasePartialFailure],
        recordLimit: Int,
        byteLimit: Int,
        recordLimitName: DatabaseAdapterLimit,
        byteLimitName: DatabaseAdapterLimit
    ) throws(DatabaseAdapterFailure) {
        try require(records.count, atMost: recordLimit, limit: recordLimitName)
        try require(fields.count, atMost: maximumPageFields, limit: .pageFields)
        try require(warnings.count, atMost: maximumWarnings, limit: .warnings)
        try require(
            partialFailures.count,
            atMost: maximumPartialFailures,
            limit: .partialFailures)
        for record in records {
            try require(
                record.fields.count,
                atMost: maximumRecordFields,
                limit: .recordFields)
        }
        let payload = DatabaseAdapterBoundedPayload(
            records: records,
            fields: fields,
            warnings: warnings,
            partialFailures: partialFailures)
        let byteCount: Int
        do {
            byteCount = try JSONEncoder().encode(payload).count
        } catch {
            throw .contractViolation(.encodingFailed)
        }
        try require(byteCount, atMost: byteLimit, limit: byteLimitName)
    }

    private static func require(
        _ actual: Int,
        atMost maximum: Int,
        limit: DatabaseAdapterLimit
    ) throws(DatabaseAdapterFailure) {
        guard actual <= maximum else {
            throw .limitExceeded(limit: limit, actual: actual, maximum: maximum)
        }
    }
}

struct DatabaseResolvedConnection: Sendable {
    let definition: DatabaseConnectionDefinition
    let secrets: [DatabaseSecretReference: Data]

    init(
        definition: DatabaseConnectionDefinition,
        secrets: [DatabaseSecretReference: Data]
    ) throws(DatabaseAdapterFailure) {
        guard secrets.count <= DatabaseAdapterBounds.maximumResolvedSecrets else {
            throw .limitExceeded(
                limit: .resolvedSecrets,
                actual: secrets.count,
                maximum: DatabaseAdapterBounds.maximumResolvedSecrets)
        }
        for secret in secrets.values {
            guard secret.count <= DatabaseAdapterBounds.maximumSecretBytes else {
                throw .limitExceeded(
                    limit: .secretBytes,
                    actual: secret.count,
                    maximum: DatabaseAdapterBounds.maximumSecretBytes)
            }
        }
        self.definition = definition
        self.secrets = secrets
    }
}

enum DatabaseAdapterCancellationReason: String, Hashable, Sendable {
    case userRequested
    case deadlineExceeded
    case sessionDisconnected
}

actor DatabaseAdapterCancellationSignal {
    private var cancellationReason: DatabaseAdapterCancellationReason?
    private var eventStreams: [UUID: AsyncStream<DatabaseAdapterCancellationReason>.Continuation] =
        [:]

    func cancel(_ reason: DatabaseAdapterCancellationReason) {
        guard cancellationReason == nil else { return }
        cancellationReason = reason
        let pending = eventStreams.values
        eventStreams.removeAll()
        for stream in pending {
            stream.yield(reason)
            stream.finish()
        }
    }

    func checkCancellation() throws(DatabaseAdapterFailure) {
        guard cancellationReason == nil, !Task.isCancelled else {
            throw .cancelled
        }
    }

    func reason() -> DatabaseAdapterCancellationReason? {
        cancellationReason
    }

    func events() -> AsyncStream<DatabaseAdapterCancellationReason> {
        let identifier = UUID()
        let pair = AsyncStream<DatabaseAdapterCancellationReason>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        if let cancellationReason {
            pair.continuation.yield(cancellationReason)
            pair.continuation.finish()
        } else {
            pair.continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeEventStream(identifier)
                }
            }
            eventStreams[identifier] = pair.continuation
        }
        return pair.stream
    }

    func registeredEventStreamCount() -> Int {
        eventStreams.count
    }

    private func removeEventStream(_ identifier: UUID) {
        eventStreams.removeValue(forKey: identifier)
    }
}

struct DatabaseAdapterOperationContext: Sendable {
    let operation: DatabaseOperationContext
    let cancellation: DatabaseAdapterCancellationSignal

    var operationID: DatabaseOperationID {
        operation.operationID
    }

    var deadline: Date? {
        operation.deadline
    }

    init(
        operation: DatabaseOperationContext,
        cancellation: DatabaseAdapterCancellationSignal
    ) {
        self.operation = operation
        self.cancellation = cancellation
    }

    func checkCancellation() async throws(DatabaseAdapterFailure) {
        try await cancellation.checkCancellation()
    }
}

typealias DatabaseAdapterConnectionContext = DatabaseAdapterOperationContext

enum DatabaseAdapterSessionState: String, Hashable, Sendable {
    case connected
    case disconnecting
    case disconnected
    case failed
}

struct DatabaseAdapterContinuation: Hashable, Sendable {
    let mode: DatabasePagingMode
    let payload: Data
    let expiresAt: Date?

    init(
        mode: DatabasePagingMode,
        payload: Data,
        expiresAt: Date? = nil
    ) throws(DatabaseAdapterFailure) {
        guard payload.count <= DatabaseAdapterBounds.maximumContinuationBytes else {
            throw .limitExceeded(
                limit: .continuationBytes,
                actual: payload.count,
                maximum: DatabaseAdapterBounds.maximumContinuationBytes)
        }
        self.mode = mode
        self.payload = payload
        self.expiresAt = expiresAt
    }
}

struct DatabaseAdapterPageRequest: Hashable, Sendable {
    let target: DatabaseTargetIdentifier
    let pageSize: DatabasePageSize
    let continuation: DatabaseAdapterContinuation?
    let projection: DatabaseProjection?
    let filter: DatabaseFilter?
    let sorts: [DatabaseSort]
    let consistency: DatabaseConsistencyPreference

    init(
        target: DatabaseTargetIdentifier,
        page: DatabasePageRequest,
        continuation: DatabaseAdapterContinuation?
    ) throws(DatabaseAdapterFailure) {
        let projectedFieldCount = page.projection?.fields.count ?? 0
        guard projectedFieldCount <= DatabaseAdapterBounds.maximumProjectionFields else {
            throw .limitExceeded(
                limit: .projectionFields,
                actual: projectedFieldCount,
                maximum: DatabaseAdapterBounds.maximumProjectionFields)
        }
        guard page.sorts.count <= DatabaseAdapterBounds.maximumSorts else {
            throw .limitExceeded(
                limit: .sorts,
                actual: page.sorts.count,
                maximum: DatabaseAdapterBounds.maximumSorts)
        }
        self.target = target
        pageSize = page.pageSize
        self.continuation = continuation
        projection = page.projection
        filter = page.filter
        sorts = page.sorts
        consistency = page.consistency
    }
}

struct DatabaseAdapterPage: Sendable {
    let records: [DatabaseRecord]
    let fields: [DatabaseFieldDescriptor]
    let nextContinuation: DatabaseAdapterContinuation?
    let metadata: DatabasePageMetadata

    init(
        records: [DatabaseRecord],
        fields: [DatabaseFieldDescriptor] = [],
        nextContinuation: DatabaseAdapterContinuation? = nil,
        metadata: DatabasePageMetadata
    ) throws(DatabaseAdapterFailure) {
        try DatabaseAdapterBounds.validate(
            records: records,
            fields: fields,
            warnings: metadata.warnings,
            partialFailures: metadata.partialFailures,
            recordLimit: DatabaseAdapterBounds.maximumPageRecords,
            byteLimit: DatabaseAdapterBounds.maximumPageBytes,
            recordLimitName: .pageRecords,
            byteLimitName: .pageBytes)
        self.records = records
        self.fields = fields
        self.nextContinuation = nextContinuation
        self.metadata = metadata
    }

    func validate(for request: DatabaseAdapterPageRequest) throws(DatabaseAdapterFailure) {
        guard records.count <= request.pageSize.value else {
            throw .contractViolation(
                .pageExceedsRequest(
                    actual: records.count,
                    requested: request.pageSize.value))
        }
    }
}

struct DatabaseAdapterQueryRequest: Hashable, Sendable {
    let source: DatabaseAdapterPageRequest
    let language: DatabaseQueryLanguage
    let command: String
    let parameters: [DatabaseQueryParameter]
    let body: DatabaseValue?

    init(
        request: DatabaseQueryRequest,
        continuation: DatabaseAdapterContinuation?
    ) throws(DatabaseAdapterFailure) {
        source = try DatabaseAdapterPageRequest(
            target: request.target,
            page: request.page,
            continuation: continuation)
        language = request.language
        command = request.command
        parameters = request.parameters
        body = request.body
    }
}

struct DatabaseAdapterBatchSize: Hashable, Sendable {
    static let range = 1...DatabaseAdapterBounds.maximumStreamBatchRecords
    static let defaultSize = DatabaseAdapterBatchSize(unchecked: 200)

    let value: Int

    init(_ value: Int) throws(DatabaseAdapterFailure) {
        guard Self.range.contains(value) else {
            throw .limitExceeded(
                limit: .streamBatchRecords,
                actual: value,
                maximum: Self.range.upperBound)
        }
        self.value = value
    }

    private init(unchecked value: Int) {
        self.value = value
    }
}

enum DatabaseAdapterStreamSource: Hashable, Sendable {
    case browse(DatabaseAdapterPageRequest)
    case query(DatabaseAdapterQueryRequest)
}

struct DatabaseAdapterStreamRequest: Hashable, Sendable {
    let source: DatabaseAdapterStreamSource
    let batchSize: DatabaseAdapterBatchSize

    init(
        source: DatabaseAdapterStreamSource,
        batchSize: DatabaseAdapterBatchSize = .defaultSize
    ) {
        self.source = source
        self.batchSize = batchSize
    }
}

struct DatabaseAdapterRecordBatch: Sendable {
    let records: [DatabaseRecord]
    let fields: [DatabaseFieldDescriptor]
    let progress: DatabaseOperationProgress?
    let bytesReceived: UInt64?
    let warnings: [DatabaseWarning]
    let partialFailures: [DatabasePartialFailure]

    init(
        records: [DatabaseRecord],
        fields: [DatabaseFieldDescriptor] = [],
        progress: DatabaseOperationProgress? = nil,
        bytesReceived: UInt64? = nil,
        warnings: [DatabaseWarning] = [],
        partialFailures: [DatabasePartialFailure] = []
    ) throws(DatabaseAdapterFailure) {
        try DatabaseAdapterBounds.validate(
            records: records,
            fields: fields,
            warnings: warnings,
            partialFailures: partialFailures,
            recordLimit: DatabaseAdapterBounds.maximumStreamBatchRecords,
            byteLimit: DatabaseAdapterBounds.maximumStreamBatchBytes,
            recordLimitName: .streamBatchRecords,
            byteLimitName: .streamBatchBytes)
        self.records = records
        self.fields = fields
        self.progress = progress
        self.bytesReceived = bytesReceived
        self.warnings = warnings
        self.partialFailures = partialFailures
    }

    func validate(for request: DatabaseAdapterStreamRequest) throws(DatabaseAdapterFailure) {
        guard records.count <= request.batchSize.value else {
            throw .contractViolation(
                .streamBatchExceedsRequest(
                    actual: records.count,
                    requested: request.batchSize.value))
        }
    }
}

enum DatabaseAdapterCancellationDisposition: Hashable, Sendable {
    case accepted
    case alreadyFinished
    case unavailable
    case failed(DatabaseErrorEnvelope)
}

struct DatabaseAdapterCancellationResult: Hashable, Sendable {
    let support: DatabaseCancellationSupport
    let disposition: DatabaseAdapterCancellationDisposition

    init(
        support: DatabaseCancellationSupport,
        disposition: DatabaseAdapterCancellationDisposition
    ) {
        self.support = support
        self.disposition = disposition
    }
}

struct DatabaseAdapterMutationResult: Sendable {
    let disposition: DatabaseMutationDisposition
    let effect: DatabaseMutationEffect
    let affectedRecords: DatabaseCountMetadata
    let returnedPage: DatabaseAdapterPage?
    let serverOperationIdentifier: String?
    let partialFailures: [DatabasePartialFailure]
    let error: DatabaseErrorEnvelope?

    init(
        disposition: DatabaseMutationDisposition,
        effect: DatabaseMutationEffect,
        affectedRecords: DatabaseCountMetadata,
        returnedPage: DatabaseAdapterPage? = nil,
        serverOperationIdentifier: String? = nil,
        partialFailures: [DatabasePartialFailure] = [],
        error: DatabaseErrorEnvelope? = nil
    ) throws(DatabaseAdapterFailure) {
        let identifierBytes = serverOperationIdentifier?.utf8.count ?? 0
        guard identifierBytes <= DatabaseAdapterBounds.maximumServerOperationIdentifierBytes,
            partialFailures.count <= DatabaseAdapterBounds.maximumPartialFailures
        else {
            if partialFailures.count > DatabaseAdapterBounds.maximumPartialFailures {
                throw .limitExceeded(
                    limit: .partialFailures,
                    actual: partialFailures.count,
                    maximum: DatabaseAdapterBounds.maximumPartialFailures)
            }
            throw .limitExceeded(
                limit: .serverOperationIdentifierBytes,
                actual: identifierBytes,
                maximum: DatabaseAdapterBounds.maximumServerOperationIdentifierBytes)
        }
        if let returnedPage {
            guard returnedPage.metadata.completeness.state == .complete,
                returnedPage.metadata.partialFailures.isEmpty,
                returnedPage.nextContinuation == nil
            else {
                throw .contractViolation(.partialMutationResult)
            }
        }
        switch disposition {
        case .accepted:
            guard let serverOperationIdentifier, !serverOperationIdentifier.isEmpty,
                effect == .unknown,
                returnedPage == nil,
                partialFailures.isEmpty,
                error == nil
            else {
                throw .contractViolation(.invalidMutationReconciliationResult)
            }
        case .completed:
            switch effect {
            case .applied:
                guard partialFailures.isEmpty, error == nil else {
                    throw .contractViolation(.invalidMutationReconciliationResult)
                }
            case .notApplied:
                guard returnedPage == nil, partialFailures.isEmpty else {
                    throw .contractViolation(.invalidMutationReconciliationResult)
                }
            case .partiallyApplied:
                guard !partialFailures.isEmpty else {
                    throw .contractViolation(.invalidMutationReconciliationResult)
                }
            case .unknown:
                guard returnedPage == nil else {
                    throw .contractViolation(.invalidMutationReconciliationResult)
                }
            }
        }
        self.disposition = disposition
        self.effect = effect
        self.affectedRecords = affectedRecords
        self.returnedPage = returnedPage
        self.serverOperationIdentifier = serverOperationIdentifier
        self.partialFailures = partialFailures
        self.error = error
    }
}

struct DatabaseAdapterMutationStatus: Sendable {
    let serverOperationIdentifier: String
    let state: DatabaseMutationOperationState
    let progress: DatabaseOperationProgress?
    let outcome: DatabaseAdapterMutationResult?
    let error: DatabaseErrorEnvelope?
    let warnings: [DatabaseWarning]

    init(
        serverOperationIdentifier: String,
        state: DatabaseMutationOperationState,
        progress: DatabaseOperationProgress? = nil,
        outcome: DatabaseAdapterMutationResult? = nil,
        error: DatabaseErrorEnvelope? = nil,
        warnings: [DatabaseWarning] = []
    ) throws(DatabaseAdapterFailure) {
        let identifierBytes = serverOperationIdentifier.utf8.count
        guard !serverOperationIdentifier.isEmpty,
            identifierBytes <= DatabaseAdapterBounds.maximumServerOperationIdentifierBytes,
            warnings.count <= DatabaseAdapterBounds.maximumWarnings
        else {
            if identifierBytes > DatabaseAdapterBounds.maximumServerOperationIdentifierBytes {
                throw .limitExceeded(
                    limit: .serverOperationIdentifierBytes,
                    actual: identifierBytes,
                    maximum: DatabaseAdapterBounds.maximumServerOperationIdentifierBytes)
            }
            if warnings.count > DatabaseAdapterBounds.maximumWarnings {
                throw .limitExceeded(
                    limit: .warnings,
                    actual: warnings.count,
                    maximum: DatabaseAdapterBounds.maximumWarnings)
            }
            throw .contractViolation(.invalidMutationReconciliationResult)
        }
        switch state {
        case .accepted, .running, .cancelling:
            guard outcome == nil, error == nil else {
                throw .contractViolation(.invalidMutationReconciliationResult)
            }
        case .completed:
            guard let outcome, outcome.disposition == .completed,
                outcome.effect == .applied || outcome.effect == .partiallyApplied,
                error == outcome.error,
                outcome.serverOperationIdentifier == nil
                    || outcome.serverOperationIdentifier == serverOperationIdentifier
            else {
                throw .contractViolation(.invalidMutationReconciliationResult)
            }
        case .failed:
            guard let outcome, outcome.disposition == .completed,
                outcome.effect != .applied,
                let error,
                error == outcome.error,
                outcome.serverOperationIdentifier == nil
                    || outcome.serverOperationIdentifier == serverOperationIdentifier
            else {
                throw .contractViolation(.invalidMutationReconciliationResult)
            }
        case .cancelled:
            guard let outcome, outcome.disposition == .completed,
                outcome.effect != .applied,
                error == outcome.error,
                outcome.serverOperationIdentifier == nil
                    || outcome.serverOperationIdentifier == serverOperationIdentifier
            else {
                throw .contractViolation(.invalidMutationReconciliationResult)
            }
        }
        self.serverOperationIdentifier = serverOperationIdentifier
        self.state = state
        self.progress = progress
        self.outcome = outcome
        self.error = error
        self.warnings = warnings
    }
}

struct DatabaseAdapterMutationCancellationResult: Sendable {
    let serverOperationIdentifier: String
    let disposition: DatabaseMutationCancellationDisposition
    let status: DatabaseAdapterMutationStatus?

    init(
        serverOperationIdentifier: String,
        disposition: DatabaseMutationCancellationDisposition,
        status: DatabaseAdapterMutationStatus? = nil
    ) throws(DatabaseAdapterFailure) {
        let identifierBytes = serverOperationIdentifier.utf8.count
        guard !serverOperationIdentifier.isEmpty,
            identifierBytes <= DatabaseAdapterBounds.maximumServerOperationIdentifierBytes,
            status?.serverOperationIdentifier == nil
                || status?.serverOperationIdentifier == serverOperationIdentifier
        else {
            if identifierBytes > DatabaseAdapterBounds.maximumServerOperationIdentifierBytes {
                throw .limitExceeded(
                    limit: .serverOperationIdentifierBytes,
                    actual: identifierBytes,
                    maximum: DatabaseAdapterBounds.maximumServerOperationIdentifierBytes)
            }
            throw .contractViolation(.invalidMutationReconciliationResult)
        }
        switch disposition {
        case .accepted:
            guard status.map({ !$0.state.isTerminal }) ?? true else {
                throw .contractViolation(.invalidMutationReconciliationResult)
            }
        case .alreadyFinished:
            guard status?.state.isTerminal == true else {
                throw .contractViolation(.invalidMutationReconciliationResult)
            }
        case .notFound, .unavailable:
            guard status == nil else {
                throw .contractViolation(.invalidMutationReconciliationResult)
            }
        }
        self.serverOperationIdentifier = serverOperationIdentifier
        self.disposition = disposition
        self.status = status
    }
}

extension DatabaseMutationOperationState {
    fileprivate var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .accepted, .running, .cancelling:
            false
        }
    }
}

protocol DatabaseAdapterRecordStream: Sendable {
    func nextBatch() async throws(DatabaseAdapterFailure) -> DatabaseAdapterRecordBatch?
    func close() async
}

protocol DatabaseAdapterSession: Sendable {
    var id: DatabaseAdapterSessionID { get }
    var connection: DatabaseConnectionDefinition { get }
    var productIdentity: DatabaseProductIdentity { get }

    func lifecycleState() async -> DatabaseAdapterSessionState
    func discoverCapabilities(
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseCapabilityReport
    func readPage(
        _ request: DatabaseAdapterPageRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage
    func query(
        _ request: DatabaseAdapterQueryRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage
    func normalizeMutation(
        _ request: DatabaseDestructiveRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan
    func executeMutation(
        _ plan: DatabaseDestructivePlan,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationResult
    func mutationStatus(
        _ serverOperationIdentifier: String,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationStatus
    func cancelMutation(
        _ serverOperationIdentifier: String,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationCancellationResult
    func openStream(
        _ request: DatabaseAdapterStreamRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterRecordStream
    func cancel(_ operationID: DatabaseOperationID) async -> DatabaseAdapterCancellationResult
    func disconnect() async
}

extension DatabaseAdapterSession {
    func mutationStatus(
        _ serverOperationIdentifier: String,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationStatus {
        throw .reported(
            DatabaseErrorEnvelope(
                category: .unsupported,
                message: "Mutation status is not supported by this database adapter."))
    }

    func cancelMutation(
        _ serverOperationIdentifier: String,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationCancellationResult {
        throw .reported(
            DatabaseErrorEnvelope(
                category: .unsupported,
                message: "Mutation cancellation is not supported by this database adapter."))
    }
}

protocol DatabaseAdapter: Sendable {
    var id: DatabaseAdapterID { get }
    var products: Set<DatabaseProduct> { get }

    func connect(
        _ connection: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterSession
}

private struct DatabaseAdapterBoundedPayload: Encodable {
    let records: [DatabaseRecord]
    let fields: [DatabaseFieldDescriptor]
    let warnings: [DatabaseWarning]
    let partialFailures: [DatabasePartialFailure]
}
