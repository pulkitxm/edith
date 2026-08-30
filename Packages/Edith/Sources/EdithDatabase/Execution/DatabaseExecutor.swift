import Foundation

public actor DatabaseExecutor {
    static let maximumActiveOperations = 256
    static let historyFinalizationWarning = DatabaseWarning(
        code: "database.operation.history_not_finalized",
        message:
            "The database action completed, but its durable operation history could not be finalized.",
        severity: .caution)

    private let metadataStore: any DatabaseMetadataStore
    private let secretStore: any DatabaseSecretStore
    private let runtimeOwner: DatabaseRuntimeOwnerToken
    private let sessionPool: DatabaseSessionPool
    private let validator: DatabaseExecutionValidator
    private let currentDate: @Sendable () -> Date
    private var activeOperations: [DatabaseOperationID: DatabaseExecutorActiveOperation] = [:]

    init(
        metadataStore: any DatabaseMetadataStore,
        secretStore: any DatabaseSecretStore,
        runtimeOwner: DatabaseRuntimeOwnerToken,
        adapters: [any DatabaseAdapter],
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) throws(DatabaseAdapterFailure) {
        let registry = try DatabaseAdapterRegistry(adapters: adapters)
        self.metadataStore = metadataStore
        self.secretStore = secretStore
        self.runtimeOwner = runtimeOwner
        sessionPool = DatabaseSessionPool(
            registry: registry,
            secretStore: secretStore,
            currentDate: currentDate)
        validator = DatabaseExecutionValidator(currentDate: currentDate)
        self.currentDate = currentDate
    }

    public func connect(
        _ request: DatabaseConnectRequest
    ) async -> DatabaseCommandResult<DatabaseConnectResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let definition = try await connection(id: request.connectionID)
            return await execute(
                operation: request.operation,
                kind: .databaseConnect,
                definition: definition,
                timeout: definition.limits.connectionTimeout,
                cancellationSupport: .serverSide,
                retryClassification: .safeIdempotent,
                terminalProgress: .determinate(completed: 1, total: 1, unit: .steps)
            ) { [self, sessionPool, currentDate] context, mapper in
                let lease = try await sessionPool.lease(
                    for: definition,
                    context: context)
                await attachSession(lease.session, to: context.operationID)
                return DatabaseConnectResult(
                    connection: mapper.sanitize(definition.identity),
                    productIdentity: lease.report.productIdentity,
                    capabilities: lease.report,
                    connectedAt: currentDate())
            }
        } catch {
            return failure(error)
        }
    }

    public func disconnect(
        _ request: DatabaseDisconnectRequest
    ) async -> DatabaseCommandResult<DatabaseDisconnectResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let definition = try await connection(id: request.connectionID)
            return await execute(
                operation: request.operation,
                kind: .databaseDisconnect,
                definition: definition,
                timeout: definition.limits.operationTimeout,
                cancellationSupport: .cooperative,
                retryClassification: .safeIdempotent,
                terminalProgress: .determinate(completed: 1, total: 1, unit: .steps)
            ) { [self, sessionPool, currentDate] context, mapper in
                await cancelOtherOperations(
                    connectionID: request.connectionID,
                    excluding: context.operationID)
                try await context.checkCancellation()
                let disconnected = await sessionPool.disconnect(
                    connectionID: request.connectionID)
                try await context.checkCancellation()
                return DatabaseDisconnectResult(
                    connection: mapper.sanitize(definition.identity),
                    disconnected: disconnected,
                    disconnectedAt: currentDate())
            }
        } catch {
            return failure(error)
        }
    }

    public func testConnection(
        _ request: DatabaseConnectionTestRequest
    ) async -> DatabaseCommandResult<DatabaseConnectionTestResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let started = DispatchTime.now().uptimeNanoseconds
            return await execute(
                operation: request.operation,
                kind: .databaseConnectionTest,
                definition: request.connection,
                requiresSavedConnection: false,
                timeout: request.connection.limits.connectionTimeout,
                cancellationSupport: .cooperative,
                retryClassification: .safeIdempotent,
                terminalProgress: .determinate(completed: 1, total: 1, unit: .steps)
            ) { [sessionPool, currentDate] context, mapper in
                let tested = try await sessionPool.testConnection(
                    definition: request.connection,
                    context: context)
                let finished = DispatchTime.now().uptimeNanoseconds
                let elapsed = finished >= started ? finished - started : 0
                return DatabaseConnectionTestResult(
                    connection: mapper.sanitize(request.connection.identity),
                    productIdentity: tested.productIdentity,
                    capabilities: tested.report,
                    latencyMilliseconds: elapsed / 1_000_000,
                    testedAt: currentDate())
            }
        } catch {
            return failure(error)
        }
    }

    public func capabilities(
        _ request: DatabaseCapabilitiesRequest
    ) async -> DatabaseCommandResult<DatabaseCapabilitiesResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let definition = try await connection(id: request.connectionID)
            return await execute(
                operation: request.operation,
                kind: .databaseCapabilities,
                definition: definition,
                timeout: definition.limits.operationTimeout,
                cancellationSupport: .serverSide,
                retryClassification: .safeIdempotent,
                terminalProgress: .determinate(completed: 1, total: 1, unit: .steps)
            ) { [self, sessionPool] context, _ in
                let cached = try await sessionPool.lease(
                    for: definition,
                    context: context)
                await attachSession(cached.session, to: context.operationID)
                let lease: DatabaseSessionLease
                if request.resolution == .refresh {
                    lease = try await sessionPool.lease(
                        for: definition,
                        resolution: .refresh,
                        context: context)
                } else {
                    lease = cached
                }
                return DatabaseCapabilitiesResult(
                    report: lease.report,
                    source: lease.reportSource)
            }
        } catch {
            return failure(error)
        }
    }

    public func operation(
        _ request: DatabaseOperationGetRequest
    ) async -> DatabaseCommandResult<DatabaseOperationGetResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let operation = try await metadataStore.operation(id: request.operationID)
            return .success(
                DatabaseOperationGetResult(operation: operation),
                metadata: completeMetadata())
        } catch {
            return failure(error)
        }
    }

    public func operations(
        _ request: DatabaseOperationListRequest
    ) async -> DatabaseCommandResult<DatabaseOperationListResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let operations = try await metadataStore.operations(matching: request.search)
            return .success(
                DatabaseOperationListResult(operations: operations),
                metadata: completeMetadata())
        } catch {
            return failure(error)
        }
    }

    public func cancel(
        _ request: DatabaseOperationCancelRequest
    ) async -> DatabaseCommandResult<DatabaseOperationCancelResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            if let cancellation = await cancelActiveOperation(
                request.operationID,
                reason: .userRequested)
            {
                let warning =
                    cancellation.historyFinalized
                    ? nil
                    : Self.historyFinalizationWarning
                return .success(
                    DatabaseOperationCancelResult(
                        operationID: request.operationID,
                        disposition: cancellation.disposition,
                        cancellationSupport: cancellation.cancellationSupport,
                        operation: cancellation.operation),
                    metadata: completeMetadata(warning: warning))
            }
            let operation = try await metadataStore.operation(id: request.operationID)
            let disposition: DatabaseOperationCancellationDisposition
            if let operation {
                disposition = Self.isTerminal(operation.state) ? .alreadyFinished : .notActive
            } else {
                disposition = .notFound
            }
            return .success(
                DatabaseOperationCancelResult(
                    operationID: request.operationID,
                    disposition: disposition,
                    cancellationSupport: operation?.cancellationSupport ?? .unavailable,
                    operation: operation),
                metadata: completeMetadata())
        } catch {
            return failure(error)
        }
    }

    func disconnectAll() async {
        let operationIDs = Array(activeOperations.keys)
        for operationID in operationIDs {
            _ = await cancelActiveOperation(
                operationID,
                reason: .sessionDisconnected)
        }
        await sessionPool.disconnectAll()
    }

    func activeOperationCount() -> Int {
        activeOperations.count
    }

    private func requireActiveOwner() async throws {
        guard let owner = try await metadataStore.runtimeOwner(),
            owner.token == runtimeOwner,
            owner.isActive
        else {
            throw DatabaseExecutionValidationError.runtimeOwnerNotActive
        }
    }

    private func connection(
        id: DatabaseConnectionID
    ) async throws -> DatabaseConnectionDefinition {
        guard let definition = try await metadataStore.connection(id: id) else {
            _ = await sessionPool.disconnect(connectionID: id)
            throw DatabaseMetadataStoreError.connectionNotFound(id)
        }
        return definition
    }

    private func execute<Payload: Sendable>(
        operation: DatabaseOperationContext,
        kind: DatabaseOperationKind,
        definition: DatabaseConnectionDefinition,
        target: DatabaseTargetIdentifier? = nil,
        requiresSavedConnection: Bool = true,
        timeout: DatabaseTimeout,
        cancellationSupport: DatabaseCancellationSupport,
        retryClassification: DatabaseRetryClassification,
        terminalProgress: DatabaseOperationProgress?,
        body:
            @escaping @Sendable (
                DatabaseAdapterOperationContext,
                DatabaseExecutionErrorMapper
            ) async throws -> Payload
    ) async -> DatabaseCommandResult<Payload> {
        let reservationMapper = DatabaseExecutionErrorMapper()
        let startedAt = currentDate()
        let effectiveOperation = effectiveOperation(
            operation,
            timeout: timeout,
            startedAt: startedAt)
        let reservedRunning = DatabaseOperationRecordSummary(
            id: effectiveOperation.operationID,
            kind: kind,
            state: .running,
            connection: reservationMapper.sanitize(definition.identity),
            target: reservationMapper.sanitize(target),
            startedAt: startedAt,
            deadline: effectiveOperation.deadline,
            progress: .indeterminate(),
            cancellationSupport: cancellationSupport,
            retryClassification: retryClassification)
        let cancellation = DatabaseAdapterCancellationSignal()
        do {
            try registerActiveOperation(
                reservedRunning,
                cancellation: cancellation)
        } catch {
            return .failure(
                reservationMapper.map(error, target: target),
                metadata: completeMetadata())
        }
        do {
            let reservation =
                if requiresSavedConnection {
                    try await metadataStore.reserveOperation(
                        reservedRunning,
                        for: definition,
                        owner: runtimeOwner)
                } else {
                    try await metadataStore.reserveEphemeralOperation(
                        reservedRunning,
                        owner: runtimeOwner)
                }
            switch reservation {
            case .reserved:
                break
            case .operationIdentifierExists:
                throw DatabaseExecutionValidationError.operationIdentifierAlreadyExists(
                    effectiveOperation.operationID)
            case .connectionChangedOrMissing:
                throw DatabaseExecutionValidationError.connectionDefinitionChanged(
                    definition.id)
            case .runtimeOwnerNotActive:
                throw DatabaseExecutionValidationError.runtimeOwnerNotActive
            }
        } catch {
            finishActiveOperation(effectiveOperation.operationID)
            return .failure(
                reservationMapper.map(error, target: target),
                metadata: completeMetadata())
        }

        beginDeadline(
            operationID: effectiveOperation.operationID,
            deadline: effectiveOperation.deadline)
        let context = DatabaseAdapterOperationContext(
            operation: effectiveOperation,
            cancellation: cancellation)

        let mapper = await errorMapper(for: definition)
        let running = DatabaseOperationRecordSummary(
            id: reservedRunning.id,
            kind: reservedRunning.kind,
            state: reservedRunning.state,
            connection: mapper.sanitize(definition.identity),
            target: mapper.sanitize(target),
            startedAt: reservedRunning.startedAt,
            deadline: reservedRunning.deadline,
            progress: reservedRunning.progress,
            cancellationSupport: reservedRunning.cancellationSupport,
            retryClassification: reservedRunning.retryClassification)
        replaceActiveRunning(running)
        do {
            guard
                try await metadataStore.transitionOperation(
                    running,
                    from: [.running],
                    owner: runtimeOwner)
            else {
                if let cancellationTask = activeOperations[effectiveOperation.operationID]?
                    .cancellationTask
                {
                    _ = await cancellationTask.value
                }
                if let reason = await cancellation.reason() {
                    throw DatabaseExecutorControlFailure(reason)
                }
                throw DatabaseExecutionValidationError.runtimeOwnerNotActive
            }
        } catch {
            let envelope: DatabaseErrorEnvelope
            if let reason = await cancellation.reason() {
                envelope = controlEnvelope(reason, mapper: mapper, target: target)
            } else {
                envelope = mapper.map(error, target: target)
            }
            let state: DatabaseOperationState =
                envelope.category == .cancelled
                ? .cancelled
                : .failed
            let terminal = terminalSummary(
                from: running,
                state: state,
                progress: terminalProgress,
                error: envelope)
            let finalized = await finalizeOperation(terminal)
            finishActiveOperation(effectiveOperation.operationID)
            let reported =
                finalized
                ? terminal
                : terminalSummary(
                    from: running,
                    state: state,
                    progress: terminalProgress,
                    warnings: [Self.historyFinalizationWarning],
                    error: envelope)
            return .failure(
                envelope,
                metadata: DatabaseResultMetadata(
                    operation: reported,
                    completeness: DatabaseResultCompleteness(state: .complete),
                    warnings: finalized ? [] : [Self.historyFinalizationWarning]))
        }

        do {
            try await checkControl(context)
            let bodyTask = Task {
                try await body(context, mapper)
            }
            await attachExecutionCancellation(
                { bodyTask.cancel() },
                to: effectiveOperation.operationID)
            let payload = try await withTaskCancellationHandler {
                try await bodyTask.value
            } onCancel: { [weak self] in
                bodyTask.cancel()
                Task {
                    _ = await self?.cancelActiveOperation(
                        effectiveOperation.operationID,
                        reason: .userRequested)
                }
            }
            try await checkControl(context)
            let terminal = terminalSummary(
                from: running,
                state: .succeeded,
                progress: terminalProgress,
                error: nil)
            let finalized = await finalizeOperation(terminal)
            finishActiveOperation(effectiveOperation.operationID)
            let reported =
                finalized
                ? terminal
                : terminalSummary(
                    from: running,
                    state: .succeeded,
                    progress: terminalProgress,
                    warnings: [Self.historyFinalizationWarning],
                    error: nil)
            return .success(
                payload,
                metadata: DatabaseResultMetadata(
                    operation: reported,
                    completeness: DatabaseResultCompleteness(state: .complete),
                    warnings: finalized ? [] : [Self.historyFinalizationWarning]))
        } catch {
            let envelope: DatabaseErrorEnvelope
            if let reason = await cancellation.reason() {
                envelope = controlEnvelope(reason, mapper: mapper, target: target)
            } else {
                envelope = mapper.map(error, target: target)
            }
            let state: DatabaseOperationState =
                envelope.category == .cancelled
                ? .cancelled
                : .failed
            let terminal = terminalSummary(
                from: running,
                state: state,
                progress: terminalProgress,
                error: envelope)
            let finalized = await finalizeOperation(terminal)
            finishActiveOperation(effectiveOperation.operationID)
            let reported =
                finalized
                ? terminal
                : terminalSummary(
                    from: running,
                    state: state,
                    progress: terminalProgress,
                    warnings: [Self.historyFinalizationWarning],
                    error: envelope)
            return .failure(
                envelope,
                metadata: DatabaseResultMetadata(
                    operation: reported,
                    completeness: DatabaseResultCompleteness(state: .complete),
                    warnings: finalized ? [] : [Self.historyFinalizationWarning]))
        }
    }

    private func effectiveOperation(
        _ operation: DatabaseOperationContext,
        timeout: DatabaseTimeout,
        startedAt: Date
    ) -> DatabaseOperationContext {
        let configuredDeadline = startedAt.addingTimeInterval(
            Double(timeout.milliseconds) / 1_000)
        let deadline =
            operation.deadline.map { min($0, configuredDeadline) }
            ?? configuredDeadline
        return DatabaseOperationContext(
            operationID: operation.operationID,
            deadline: deadline)
    }

    private func registerActiveOperation(
        _ running: DatabaseOperationRecordSummary,
        cancellation: DatabaseAdapterCancellationSignal
    ) throws {
        guard activeOperations[running.id] == nil else {
            throw DatabaseExecutionValidationError.operationIdentifierAlreadyExists(running.id)
        }
        guard activeOperations.count < Self.maximumActiveOperations else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "active database operations",
                actual: activeOperations.count + 1,
                maximum: Self.maximumActiveOperations)
        }
        activeOperations[running.id] = DatabaseExecutorActiveOperation(
            running: running,
            cancellation: cancellation)
    }

    private func replaceActiveRunning(_ running: DatabaseOperationRecordSummary) {
        guard var active = activeOperations[running.id] else { return }
        active.running = running
        activeOperations[running.id] = active
    }

    private func beginDeadline(
        operationID: DatabaseOperationID,
        deadline: Date?
    ) {
        guard var active = activeOperations[operationID], let deadline else { return }
        let delay = max(0, deadline.timeIntervalSince(currentDate()))
        let maximumDelay = Double(UInt64.max - 1_000_000) / 1_000_000_000
        let nanoseconds =
            delay >= maximumDelay
            ? UInt64.max - 1_000_000
            : UInt64(delay * 1_000_000_000)
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = await self?.cancelActiveOperation(
                operationID,
                reason: .deadlineExceeded)
        }
        active.deadlineTask = task
        activeOperations[operationID] = active
    }

    private func attachSession(
        _ session: any DatabaseAdapterSession,
        to operationID: DatabaseOperationID
    ) async {
        guard var active = activeOperations[operationID] else { return }
        if active.session == nil {
            active.session = session
        }
        let cancellationTask = active.cancellationTask
        let shouldCancel = cancellationTask != nil && !active.serverCancellationInvoked
        if shouldCancel {
            active.serverCancellationInvoked = true
        }
        activeOperations[operationID] = active
        if shouldCancel, let cancellationTask {
            let cancellation = await cancellationTask.value
            if cancellation.disposition == .accepted {
                _ = await session.cancel(operationID)
            }
        }
    }

    private func attachExecutionCancellation(
        _ cancellation: @escaping @Sendable () -> Void,
        to operationID: DatabaseOperationID
    ) async {
        guard var active = activeOperations[operationID] else {
            cancellation()
            return
        }
        active.executionCancellation = cancellation
        let cancellationTask = active.cancellationTask
        let shouldCancel = cancellationTask != nil && !active.executionCancellationInvoked
        if shouldCancel {
            active.executionCancellationInvoked = true
        }
        activeOperations[operationID] = active
        if shouldCancel, let cancellationTask {
            let outcome = await cancellationTask.value
            if outcome.disposition == .accepted {
                cancellation()
            }
        }
    }

    private func cancelOtherOperations(
        connectionID: DatabaseConnectionID,
        excluding excludedOperationID: DatabaseOperationID
    ) async {
        let operationIDs = activeOperations.values.compactMap { active in
            active.running.id != excludedOperationID
                && active.running.connection.id == connectionID
                ? active.running.id
                : nil
        }
        for operationID in operationIDs {
            _ = await cancelActiveOperation(
                operationID,
                reason: .sessionDisconnected)
        }
    }

    private func cancelActiveOperation(
        _ operationID: DatabaseOperationID,
        reason: DatabaseAdapterCancellationReason
    ) async -> DatabaseExecutorActiveCancellation? {
        guard var active = activeOperations[operationID] else { return nil }
        if let cancellationTask = active.cancellationTask {
            return await cancellationTask.value
        }
        let metadataStore = metadataStore
        let runtimeOwner = runtimeOwner
        let session = active.session
        let executionCancellation = active.executionCancellation
        let cancelling = operationSummary(
            from: active.running,
            state: .cancelling,
            finishedAt: nil,
            progress: active.running.progress,
            warnings: active.running.warnings,
            error: nil)
        let cancellationSignal = active.cancellation
        let cancellationSupport = active.running.cancellationSupport
        let cancellationTask = Task {
            var stored: DatabaseOperationRecordSummary?
            var transitioned = false
            do {
                transitioned = try await metadataStore.transitionOperation(
                    cancelling,
                    from: [.running],
                    owner: runtimeOwner)
                if !transitioned {
                    stored = try await metadataStore.operation(id: operationID)
                } else {
                    stored = nil
                }
            } catch {
                transitioned = false
                stored = nil
            }

            if !transitioned, let stored, Self.isTerminal(stored.state) {
                return DatabaseExecutorActiveCancellation(
                    disposition: .alreadyFinished,
                    operation: stored,
                    cancellationSupport: stored.cancellationSupport,
                    historyFinalized: true)
            }

            await cancellationSignal.cancel(reason)
            executionCancellation?()
            var support = cancellationSupport
            if let session {
                support = await session.cancel(operationID).support
            }
            return DatabaseExecutorActiveCancellation(
                disposition: .accepted,
                operation: cancelling,
                cancellationSupport: support,
                historyFinalized: transitioned)
        }
        active.serverCancellationInvoked = session != nil
        active.executionCancellationInvoked = executionCancellation != nil
        active.cancellationTask = cancellationTask
        activeOperations[operationID] = active
        return await cancellationTask.value
    }

    private func checkControl(
        _ context: DatabaseAdapterOperationContext
    ) async throws {
        if Task.isCancelled {
            _ = await cancelActiveOperation(
                context.operationID,
                reason: .userRequested)
        } else if let deadline = context.deadline, deadline <= currentDate() {
            _ = await cancelActiveOperation(
                context.operationID,
                reason: .deadlineExceeded)
        }
        if let reason = await context.cancellation.reason() {
            throw DatabaseExecutorControlFailure(reason)
        }
    }

    private func finalizeOperation(
        _ terminal: DatabaseOperationRecordSummary
    ) async -> Bool {
        do {
            return try await metadataStore.transitionOperation(
                terminal,
                from: [.running, .cancelling],
                owner: runtimeOwner)
        } catch {
            return false
        }
    }

    private func finishActiveOperation(_ operationID: DatabaseOperationID) {
        activeOperations.removeValue(forKey: operationID)?.deadlineTask?.cancel()
    }

    private func terminalSummary(
        from running: DatabaseOperationRecordSummary,
        state: DatabaseOperationState,
        progress: DatabaseOperationProgress?,
        warnings: [DatabaseWarning] = [],
        error: DatabaseErrorEnvelope?
    ) -> DatabaseOperationRecordSummary {
        let observedAt = currentDate()
        let finishedAt = running.startedAt.map { max($0, observedAt) } ?? observedAt
        return operationSummary(
            from: running,
            state: state,
            finishedAt: finishedAt,
            progress: progress,
            warnings: warnings,
            error: error)
    }

    private func operationSummary(
        from running: DatabaseOperationRecordSummary,
        state: DatabaseOperationState,
        finishedAt: Date?,
        progress: DatabaseOperationProgress?,
        warnings: [DatabaseWarning],
        error: DatabaseErrorEnvelope?
    ) -> DatabaseOperationRecordSummary {
        DatabaseOperationRecordSummary(
            id: running.id,
            kind: running.kind,
            state: state,
            connection: running.connection,
            target: running.target,
            startedAt: running.startedAt,
            finishedAt: finishedAt,
            deadline: running.deadline,
            progress: progress,
            cancellationSupport: running.cancellationSupport,
            retryClassification: running.retryClassification,
            pageCount: running.pageCount,
            recordCount: running.recordCount,
            byteCount: running.byteCount,
            warnings: warnings,
            partialFailures: running.partialFailures,
            error: error)
    }

    private func errorMapper(
        for definition: DatabaseConnectionDefinition
    ) async -> DatabaseExecutionErrorMapper {
        var references = definition.authentication.secretReferences
        if let privateKey = definition.tls.clientPrivateKey {
            references.append(privateKey)
        }
        references = references.filter { $0.purpose != .confirmationSigningKey }
        guard
            let redactor = try? await DatabaseSecretRedactor(
                store: secretStore,
                references: references)
        else {
            return DatabaseExecutionErrorMapper()
        }
        return DatabaseExecutionErrorMapper(redactor: redactor)
    }

    private func controlEnvelope(
        _ reason: DatabaseAdapterCancellationReason,
        mapper: DatabaseExecutionErrorMapper,
        target: DatabaseTargetIdentifier?
    ) -> DatabaseErrorEnvelope {
        let envelope: DatabaseErrorEnvelope
        switch reason {
        case .userRequested:
            envelope = DatabaseErrorEnvelope(
                category: .cancelled,
                message: "The database operation was cancelled.",
                target: target)
        case .deadlineExceeded:
            envelope = DatabaseErrorEnvelope(
                category: .timeout,
                message: "The database operation exceeded its deadline.",
                target: target,
                retry: DatabaseRetryGuidance(
                    action: .retry,
                    message: "Retry with a longer deadline if the operation is still safe."))
        case .sessionDisconnected:
            envelope = DatabaseErrorEnvelope(
                category: .connectionFailed,
                message: "The database session disconnected during the operation.",
                target: target,
                retry: DatabaseRetryGuidance(
                    action: .reconnect,
                    message: "Reconnect before retrying the operation."))
        }
        return mapper.map(envelope, target: target)
    }

    private func completeMetadata(
        warning: DatabaseWarning? = nil
    ) -> DatabaseResultMetadata {
        DatabaseResultMetadata(
            completeness: DatabaseResultCompleteness(state: .complete),
            warnings: warning.map { [$0] } ?? [])
    }

    private func failure<Payload: Sendable>(
        _ error: any Error
    ) -> DatabaseCommandResult<Payload> {
        .failure(
            DatabaseExecutionErrorMapper().map(error),
            metadata: completeMetadata())
    }

    private static func isTerminal(_ state: DatabaseOperationState) -> Bool {
        switch state {
        case .succeeded, .failed, .cancelled, .partiallySucceeded:
            true
        case .queued, .running, .cancelling:
            false
        }
    }
}

private struct DatabaseExecutorActiveOperation: Sendable {
    var running: DatabaseOperationRecordSummary
    let cancellation: DatabaseAdapterCancellationSignal
    var session: (any DatabaseAdapterSession)?
    var serverCancellationInvoked: Bool
    var executionCancellation: (@Sendable () -> Void)?
    var executionCancellationInvoked: Bool
    var deadlineTask: Task<Void, Never>?
    var cancellationTask: Task<DatabaseExecutorActiveCancellation, Never>?

    init(
        running: DatabaseOperationRecordSummary,
        cancellation: DatabaseAdapterCancellationSignal
    ) {
        self.running = running
        self.cancellation = cancellation
        session = nil
        serverCancellationInvoked = false
        executionCancellation = nil
        executionCancellationInvoked = false
        deadlineTask = nil
        cancellationTask = nil
    }
}

private struct DatabaseExecutorActiveCancellation: Sendable {
    let disposition: DatabaseOperationCancellationDisposition
    let operation: DatabaseOperationRecordSummary
    let cancellationSupport: DatabaseCancellationSupport
    let historyFinalized: Bool
}

private struct DatabaseExecutorControlFailure: Error, Sendable {
    let reason: DatabaseAdapterCancellationReason

    init(_ reason: DatabaseAdapterCancellationReason) {
        self.reason = reason
    }
}
