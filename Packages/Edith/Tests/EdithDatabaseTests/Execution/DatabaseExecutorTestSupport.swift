import Foundation

@testable import EdithDatabase

actor DatabaseExecutorTestGate {
    private var isOpen: Bool
    private var permits = 0
    private var entries = 0
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var observers:
        [(
            minimum: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []

    init(open: Bool = true) {
        isOpen = open
    }

    func enter() async {
        entries += 1
        let ready = observers.filter { entries >= $0.minimum }
        observers.removeAll { entries >= $0.minimum }
        for observer in ready {
            observer.continuation.resume()
        }
        if isOpen {
            return
        }
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { blocked.append($0) }
    }

    func block() {
        isOpen = false
        permits = 0
    }

    func releaseOne() {
        if blocked.isEmpty {
            permits += 1
        } else {
            blocked.removeFirst().resume()
        }
    }

    func releaseAll() {
        isOpen = true
        permits = 0
        let pending = blocked
        blocked.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func waitForEntries(_ minimum: Int = 1) async {
        if entries >= minimum {
            return
        }
        await withCheckedContinuation { continuation in
            observers.append((minimum, continuation))
        }
    }

    func entryCount() -> Int {
        entries
    }

    func blockedCount() -> Int {
        blocked.count
    }
}

struct DatabaseExecutorTestAdapterGates: Sendable {
    let connect: DatabaseExecutorTestGate

    init(connect: DatabaseExecutorTestGate = DatabaseExecutorTestGate()) {
        self.connect = connect
    }
}

struct DatabaseExecutorTestSessionGates: Sendable {
    let lifecycleState: DatabaseExecutorTestGate
    let discoverCapabilities: DatabaseExecutorTestGate
    let readPage: DatabaseExecutorTestGate
    let query: DatabaseExecutorTestGate
    let normalizeMutation: DatabaseExecutorTestGate
    let executeMutation: DatabaseExecutorTestGate
    let openStream: DatabaseExecutorTestGate
    let cancel: DatabaseExecutorTestGate
    let disconnect: DatabaseExecutorTestGate

    init(
        lifecycleState: DatabaseExecutorTestGate = DatabaseExecutorTestGate(),
        discoverCapabilities: DatabaseExecutorTestGate = DatabaseExecutorTestGate(),
        readPage: DatabaseExecutorTestGate = DatabaseExecutorTestGate(),
        query: DatabaseExecutorTestGate = DatabaseExecutorTestGate(),
        normalizeMutation: DatabaseExecutorTestGate = DatabaseExecutorTestGate(),
        executeMutation: DatabaseExecutorTestGate = DatabaseExecutorTestGate(),
        openStream: DatabaseExecutorTestGate = DatabaseExecutorTestGate(),
        cancel: DatabaseExecutorTestGate = DatabaseExecutorTestGate(),
        disconnect: DatabaseExecutorTestGate = DatabaseExecutorTestGate()
    ) {
        self.lifecycleState = lifecycleState
        self.discoverCapabilities = discoverCapabilities
        self.readPage = readPage
        self.query = query
        self.normalizeMutation = normalizeMutation
        self.executeMutation = executeMutation
        self.openStream = openStream
        self.cancel = cancel
        self.disconnect = disconnect
    }
}

struct DatabaseExecutorTestStreamGates: Sendable {
    let nextBatch: DatabaseExecutorTestGate
    let close: DatabaseExecutorTestGate

    init(
        nextBatch: DatabaseExecutorTestGate = DatabaseExecutorTestGate(),
        close: DatabaseExecutorTestGate = DatabaseExecutorTestGate()
    ) {
        self.nextBatch = nextBatch
        self.close = close
    }
}

struct DatabaseExecutorTestConnectInvocation: Equatable, Sendable {
    let definition: DatabaseConnectionDefinition
    let secrets: [DatabaseSecretReference: Data]
    let operation: DatabaseOperationContext
}

enum DatabaseExecutorTestSessionInvocation: Hashable, Sendable {
    case lifecycleState
    case discoverCapabilities(DatabaseOperationContext)
    case readPage(DatabaseAdapterPageRequest, DatabaseOperationContext)
    case query(DatabaseAdapterQueryRequest, DatabaseOperationContext)
    case normalizeMutation(DatabaseDestructiveRequest, DatabaseOperationContext)
    case executeMutation(DatabaseDestructivePlan, DatabaseOperationContext)
    case openStream(DatabaseAdapterStreamRequest, DatabaseOperationContext)
    case cancel(DatabaseOperationID)
    case disconnect
}

enum DatabaseExecutorTestStreamInvocation: Hashable, Sendable {
    case nextBatch
    case close
}

struct DatabaseExecutorTestSessionSnapshot: Hashable, Sendable {
    let state: DatabaseAdapterSessionState
    let invocations: [DatabaseExecutorTestSessionInvocation]
    let cancelledOperationIDs: [DatabaseOperationID]
    let disconnectCount: Int
}

struct DatabaseExecutorTestStreamSnapshot: Hashable, Sendable {
    let invocations: [DatabaseExecutorTestStreamInvocation]
    let closeCount: Int
    let isClosed: Bool
}

private struct DatabaseExecutorTestOutcomeQueue<Value: Sendable>: Sendable {
    private var fallback: Value
    private var queued: [Result<Value, DatabaseAdapterFailure>] = []

    init(fallback: Value) {
        self.fallback = fallback
    }

    mutating func replaceFallback(_ value: Value) {
        fallback = value
    }

    mutating func enqueue(_ outcome: Result<Value, DatabaseAdapterFailure>) {
        queued.append(outcome)
    }

    mutating func take() -> Result<Value, DatabaseAdapterFailure> {
        if queued.isEmpty {
            return .success(fallback)
        }
        return queued.removeFirst()
    }
}

private func databaseExecutorTestResolve<Value>(
    _ outcome: Result<Value, DatabaseAdapterFailure>
) throws(DatabaseAdapterFailure) -> Value {
    switch outcome {
    case let .success(value):
        value
    case let .failure(error):
        throw error
    }
}

actor DatabaseExecutorRecordingStream: DatabaseAdapterRecordStream {
    nonisolated let gates: DatabaseExecutorTestStreamGates

    private var batches: DatabaseExecutorTestOutcomeQueue<DatabaseAdapterRecordBatch?>
    private var invocations: [DatabaseExecutorTestStreamInvocation] = []
    private var closeCount = 0
    private var isClosed = false

    init(
        fallbackBatch: DatabaseAdapterRecordBatch? = nil,
        gates: DatabaseExecutorTestStreamGates = DatabaseExecutorTestStreamGates()
    ) {
        batches = DatabaseExecutorTestOutcomeQueue(fallback: fallbackBatch)
        self.gates = gates
    }

    func setFallbackBatch(_ batch: DatabaseAdapterRecordBatch?) {
        batches.replaceFallback(batch)
    }

    func enqueueBatch(
        _ outcome: Result<DatabaseAdapterRecordBatch?, DatabaseAdapterFailure>
    ) {
        batches.enqueue(outcome)
    }

    func enqueueFailure(_ failure: DatabaseAdapterFailure) {
        batches.enqueue(.failure(failure))
    }

    func nextBatch() async throws(DatabaseAdapterFailure) -> DatabaseAdapterRecordBatch? {
        invocations.append(.nextBatch)
        let outcome = batches.take()
        await gates.nextBatch.enter()
        if isClosed {
            return nil
        }
        return try databaseExecutorTestResolve(outcome)
    }

    func close() async {
        invocations.append(.close)
        closeCount += 1
        await gates.close.enter()
        isClosed = true
    }

    func snapshot() -> DatabaseExecutorTestStreamSnapshot {
        DatabaseExecutorTestStreamSnapshot(
            invocations: invocations,
            closeCount: closeCount,
            isClosed: isClosed)
    }
}

actor DatabaseExecutorRecordingSession: DatabaseAdapterSession {
    nonisolated let id: DatabaseAdapterSessionID
    nonisolated let connection: DatabaseConnectionDefinition
    nonisolated let productIdentity: DatabaseProductIdentity
    nonisolated let gates: DatabaseExecutorTestSessionGates

    private var state: DatabaseAdapterSessionState
    private var honorsContextCancellation: Bool
    private var capabilities: DatabaseExecutorTestOutcomeQueue<DatabaseCapabilityReport>
    private var pages: DatabaseExecutorTestOutcomeQueue<DatabaseAdapterPage>
    private var queryPages: DatabaseExecutorTestOutcomeQueue<DatabaseAdapterPage>
    private var mutationPlans: DatabaseExecutorTestOutcomeQueue<DatabaseDestructivePlan>
    private var mutationResults: DatabaseExecutorTestOutcomeQueue<DatabaseAdapterMutationResult>
    private var streams: DatabaseExecutorTestOutcomeQueue<any DatabaseAdapterRecordStream>
    private var cancellationResults:
        DatabaseExecutorTestOutcomeQueue<
            DatabaseAdapterCancellationResult
        >
    private var invocations: [DatabaseExecutorTestSessionInvocation] = []
    private var cancelledOperationIDs: [DatabaseOperationID] = []
    private var disconnectCount = 0

    init(
        id: DatabaseAdapterSessionID,
        connection: DatabaseConnectionDefinition,
        productIdentity: DatabaseProductIdentity,
        capabilities: DatabaseCapabilityReport,
        page: DatabaseAdapterPage,
        queryPage: DatabaseAdapterPage,
        mutationPlan: DatabaseDestructivePlan,
        mutationResult: DatabaseAdapterMutationResult,
        stream: any DatabaseAdapterRecordStream = DatabaseExecutorRecordingStream(),
        cancellationResult: DatabaseAdapterCancellationResult =
            DatabaseAdapterCancellationResult(
                support: .serverSide,
                disposition: .accepted),
        state: DatabaseAdapterSessionState = .connected,
        honorsContextCancellation: Bool = true,
        gates: DatabaseExecutorTestSessionGates = DatabaseExecutorTestSessionGates()
    ) {
        self.id = id
        self.connection = connection
        self.productIdentity = productIdentity
        self.capabilities = DatabaseExecutorTestOutcomeQueue(fallback: capabilities)
        pages = DatabaseExecutorTestOutcomeQueue(fallback: page)
        queryPages = DatabaseExecutorTestOutcomeQueue(fallback: queryPage)
        mutationPlans = DatabaseExecutorTestOutcomeQueue(fallback: mutationPlan)
        mutationResults = DatabaseExecutorTestOutcomeQueue(fallback: mutationResult)
        streams = DatabaseExecutorTestOutcomeQueue(fallback: stream)
        cancellationResults = DatabaseExecutorTestOutcomeQueue(
            fallback: cancellationResult)
        self.state = state
        self.honorsContextCancellation = honorsContextCancellation
        self.gates = gates
    }

    func setState(_ state: DatabaseAdapterSessionState) {
        self.state = state
    }

    func setHonorsContextCancellation(_ enabled: Bool) {
        honorsContextCancellation = enabled
    }

    func setCapabilities(_ report: DatabaseCapabilityReport) {
        capabilities.replaceFallback(report)
    }

    func enqueueCapabilities(
        _ outcome: Result<DatabaseCapabilityReport, DatabaseAdapterFailure>
    ) {
        capabilities.enqueue(outcome)
    }

    func setPage(_ page: DatabaseAdapterPage) {
        pages.replaceFallback(page)
    }

    func enqueuePage(_ outcome: Result<DatabaseAdapterPage, DatabaseAdapterFailure>) {
        pages.enqueue(outcome)
    }

    func setQueryPage(_ page: DatabaseAdapterPage) {
        queryPages.replaceFallback(page)
    }

    func enqueueQueryPage(
        _ outcome: Result<DatabaseAdapterPage, DatabaseAdapterFailure>
    ) {
        queryPages.enqueue(outcome)
    }

    func setMutationPlan(_ plan: DatabaseDestructivePlan) {
        mutationPlans.replaceFallback(plan)
    }

    func enqueueMutationPlan(
        _ outcome: Result<DatabaseDestructivePlan, DatabaseAdapterFailure>
    ) {
        mutationPlans.enqueue(outcome)
    }

    func setMutationResult(_ result: DatabaseAdapterMutationResult) {
        mutationResults.replaceFallback(result)
    }

    func enqueueMutationResult(
        _ outcome: Result<DatabaseAdapterMutationResult, DatabaseAdapterFailure>
    ) {
        mutationResults.enqueue(outcome)
    }

    func setStream(_ stream: any DatabaseAdapterRecordStream) {
        streams.replaceFallback(stream)
    }

    func enqueueStream(
        _ outcome: Result<any DatabaseAdapterRecordStream, DatabaseAdapterFailure>
    ) {
        streams.enqueue(outcome)
    }

    func setCancellationResult(_ result: DatabaseAdapterCancellationResult) {
        cancellationResults.replaceFallback(result)
    }

    func enqueueCancellationResult(_ result: DatabaseAdapterCancellationResult) {
        cancellationResults.enqueue(.success(result))
    }

    func lifecycleState() async -> DatabaseAdapterSessionState {
        invocations.append(.lifecycleState)
        await gates.lifecycleState.enter()
        return state
    }

    func discoverCapabilities(
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseCapabilityReport {
        invocations.append(.discoverCapabilities(context.operation))
        let outcome = capabilities.take()
        let checksCancellation = honorsContextCancellation
        await gates.discoverCapabilities.enter()
        if checksCancellation {
            try await context.checkCancellation()
        }
        return try databaseExecutorTestResolve(outcome)
    }

    func readPage(
        _ request: DatabaseAdapterPageRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        invocations.append(.readPage(request, context.operation))
        let outcome = pages.take()
        let checksCancellation = honorsContextCancellation
        await gates.readPage.enter()
        if checksCancellation {
            try await context.checkCancellation()
        }
        return try databaseExecutorTestResolve(outcome)
    }

    func query(
        _ request: DatabaseAdapterQueryRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        invocations.append(.query(request, context.operation))
        let outcome = queryPages.take()
        let checksCancellation = honorsContextCancellation
        await gates.query.enter()
        if checksCancellation {
            try await context.checkCancellation()
        }
        return try databaseExecutorTestResolve(outcome)
    }

    func normalizeMutation(
        _ request: DatabaseDestructiveRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        invocations.append(.normalizeMutation(request, context.operation))
        let outcome = mutationPlans.take()
        let checksCancellation = honorsContextCancellation
        await gates.normalizeMutation.enter()
        if checksCancellation {
            try await context.checkCancellation()
        }
        return try databaseExecutorTestResolve(outcome)
    }

    func executeMutation(
        _ plan: DatabaseDestructivePlan,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationResult {
        invocations.append(.executeMutation(plan, context.operation))
        let outcome = mutationResults.take()
        let checksCancellation = honorsContextCancellation
        await gates.executeMutation.enter()
        if checksCancellation {
            try await context.checkCancellation()
        }
        return try databaseExecutorTestResolve(outcome)
    }

    func openStream(
        _ request: DatabaseAdapterStreamRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterRecordStream {
        invocations.append(.openStream(request, context.operation))
        let outcome = streams.take()
        let checksCancellation = honorsContextCancellation
        await gates.openStream.enter()
        if checksCancellation {
            try await context.checkCancellation()
        }
        return try databaseExecutorTestResolve(outcome)
    }

    func cancel(_ operationID: DatabaseOperationID) async -> DatabaseAdapterCancellationResult {
        invocations.append(.cancel(operationID))
        cancelledOperationIDs.append(operationID)
        let outcome = cancellationResults.take()
        await gates.cancel.enter()
        switch outcome {
        case let .success(result):
            return result
        case .failure:
            return DatabaseAdapterCancellationResult(
                support: .unavailable,
                disposition: .failed(
                    DatabaseErrorEnvelope(
                        category: .internalFailure,
                        message: "The cancellation fixture failed.")))
        }
    }

    func disconnect() async {
        invocations.append(.disconnect)
        disconnectCount += 1
        if state != .disconnected {
            state = .disconnecting
        }
        await gates.disconnect.enter()
        state = .disconnected
    }

    func snapshot() -> DatabaseExecutorTestSessionSnapshot {
        DatabaseExecutorTestSessionSnapshot(
            state: state,
            invocations: invocations,
            cancelledOperationIDs: cancelledOperationIDs,
            disconnectCount: disconnectCount)
    }
}

actor DatabaseExecutorRecordingAdapter: DatabaseAdapter {
    nonisolated let id: DatabaseAdapterID
    nonisolated let products: Set<DatabaseProduct>
    nonisolated let gates: DatabaseExecutorTestAdapterGates

    private var sessions: DatabaseExecutorTestOutcomeQueue<any DatabaseAdapterSession>
    private var honorsContextCancellation: Bool
    private var invocations: [DatabaseExecutorTestConnectInvocation] = []

    init(
        id: DatabaseAdapterID,
        products: Set<DatabaseProduct>,
        session: any DatabaseAdapterSession,
        honorsContextCancellation: Bool = true,
        gates: DatabaseExecutorTestAdapterGates = DatabaseExecutorTestAdapterGates()
    ) {
        self.id = id
        self.products = products
        sessions = DatabaseExecutorTestOutcomeQueue(fallback: session)
        self.honorsContextCancellation = honorsContextCancellation
        self.gates = gates
    }

    func setSession(_ session: any DatabaseAdapterSession) {
        sessions.replaceFallback(session)
    }

    func enqueueSession(_ session: any DatabaseAdapterSession) {
        sessions.enqueue(.success(session))
    }

    func enqueueFailure(_ failure: DatabaseAdapterFailure) {
        sessions.enqueue(.failure(failure))
    }

    func setHonorsContextCancellation(_ enabled: Bool) {
        honorsContextCancellation = enabled
    }

    func connect(
        _ connection: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterSession {
        invocations.append(
            DatabaseExecutorTestConnectInvocation(
                definition: connection.definition,
                secrets: connection.secrets,
                operation: context.operation))
        let outcome = sessions.take()
        let checksCancellation = honorsContextCancellation
        await gates.connect.enter()
        if checksCancellation {
            try await context.checkCancellation()
        }
        return try databaseExecutorTestResolve(outcome)
    }

    func recordedInvocations() -> [DatabaseExecutorTestConnectInvocation] {
        invocations
    }
}
