import Foundation
import NIOCore
import NIOPosix
@preconcurrency import RediStack

struct RedisValkeyDatabaseAdapter: DatabaseAdapter {
    let id: DatabaseAdapterID = "redis-valkey"
    let products: Set<DatabaseProduct> = [.redis, .valkey]

    private let clientFactory: any RedisDatabaseClientFactory

    init(clientFactory: any RedisDatabaseClientFactory = RediStackDatabaseClientFactory()) {
        self.clientFactory = clientFactory
    }

    func connect(
        _ connection: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterSession {
        try await RedisValkeyDatabaseAdapterSupport.check(context)
        let validatedPlan = try RedisValkeyDatabaseAdapterSupport.validate(connection)
        let plan = RedisValkeyDatabaseAdapterSupport.connectionPlan(
            validatedPlan,
            context: context)
        let deadline = RedisValkeyDatabaseAdapterSupport.operationDeadline(
            context: context,
            timeout: connection.definition.limits.connectionTimeout)
        var client: (any RedisDatabaseClient)?
        do {
            client = try await clientFactory.connect(
                plan,
                context: context,
                deadline: deadline)
            guard let client else {
                throw RedisValkeyDatabaseAdapterSupport.connectionFailed
            }
            _ = try await client.execute(.ping, context: context, deadline: deadline)
            let identity = try await RedisValkeyDatabaseAdapterSupport.discoverIdentity(
                client: client,
                expectedProduct: connection.definition.productHint,
                context: context,
                deadline: deadline)
            try RedisValkeyDatabaseAdapterSupport.validateTopology(
                identity,
                requested: connection.definition.deploymentMode)
            try await RedisValkeyDatabaseAdapterSupport.check(context)
            return RedisValkeyDatabaseAdapterSession(
                connection: connection.definition,
                productIdentity: identity,
                client: client)
        } catch let failure as DatabaseAdapterFailure {
            await client?.close()
            throw failure
        } catch let failure as RedisDatabaseClientFailure {
            await client?.close()
            throw RedisValkeyDatabaseAdapterSupport.connectionFailure(for: failure)
        } catch {
            await client?.close()
            throw RedisValkeyDatabaseAdapterSupport.connectionFailed
        }
    }
}

actor RedisValkeyDatabaseAdapterSession: DatabaseAdapterSession {
    nonisolated let id = DatabaseAdapterSessionID()
    nonisolated let connection: DatabaseConnectionDefinition
    nonisolated let productIdentity: DatabaseProductIdentity

    private var client: (any RedisDatabaseClient)?
    private var state: DatabaseAdapterSessionState = .connected
    private var activeOperation: RedisDatabaseActiveOperation?

    init(
        connection: DatabaseConnectionDefinition,
        productIdentity: DatabaseProductIdentity,
        client: any RedisDatabaseClient
    ) {
        self.connection = connection
        self.productIdentity = productIdentity
        self.client = client
    }

    func lifecycleState() -> DatabaseAdapterSessionState {
        state
    }

    func discoverCapabilities(
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseCapabilityReport {
        let expectedIdentity = productIdentity
        let discovered = try await perform(
            context: context,
            fallback: RedisValkeyDatabaseAdapterSupport.connectionFailed
        ) { client, deadline in
            try await RedisValkeyDatabaseAdapterSupport.discoverIdentity(
                client: client,
                expectedProduct: expectedIdentity.product,
                context: context,
                deadline: deadline)
        }
        guard discovered == expectedIdentity else {
            await failAndClose()
            throw RedisValkeyDatabaseAdapterSupport.connectionFailed
        }
        let report = RedisValkeyDatabaseAdapterSupport.capabilityReport(
            identity: productIdentity)
        try DatabaseAdapterBounds.validate(report: report, identity: productIdentity)
        return report
    }

    func readPage(
        _ request: DatabaseAdapterPageRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let startedAt = Date()
        let connectionID = connection.id
        let product = productIdentity.product
        let logicalDatabase = connection.namespaces.logicalDatabase ?? "0"
        let output = try await perform(
            context: context,
            fallback: RedisValkeyDatabaseAdapterSupport.readFailed
        ) { client, deadline in
            try await RedisValkeyDatabaseAdapterSupport.readPage(
                request,
                connectionID: connectionID,
                logicalDatabase: logicalDatabase,
                product: product,
                client: client,
                context: context,
                deadline: deadline)
        }
        let page = try RedisValkeyDatabaseAdapterSupport.page(
            output,
            request: request,
            startedAt: startedAt)
        try page.validate(for: request)
        return page
    }

    func query(
        _ request: DatabaseAdapterQueryRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let startedAt = Date()
        let connectionID = connection.id
        let product = productIdentity.product
        let logicalDatabase = connection.namespaces.logicalDatabase ?? "0"
        let output = try await perform(
            context: context,
            fallback: RedisValkeyDatabaseAdapterSupport.queryFailed
        ) { client, deadline in
            try await RedisValkeyDatabaseAdapterSupport.query(
                request,
                connectionID: connectionID,
                logicalDatabase: logicalDatabase,
                product: product,
                client: client,
                context: context,
                deadline: deadline)
        }
        let page = try RedisValkeyDatabaseAdapterSupport.page(
            output,
            request: request.source,
            startedAt: startedAt)
        try page.validate(for: request.source)
        return page
    }

    func normalizeMutation(
        _ request: DatabaseDestructiveRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        try await requireAvailableContext(context)
        return try RedisValkeyDatabaseMutationSupport.normalize(
            request,
            connectionID: connection.id,
            product: productIdentity.product)
    }

    func executeMutation(
        _ plan: DatabaseDestructivePlan,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationResult {
        let mutation = try RedisValkeyDatabaseMutationSupport.execution(
            plan,
            connectionID: connection.id,
            product: productIdentity.product)
        let reply = try await perform(
            context: context,
            fallback: RedisValkeyDatabaseMutationSupport.mutationFailed
        ) { client, deadline in
            try await client.execute(
                mutation.operation,
                context: context,
                deadline: deadline)
        }
        let applied = try RedisValkeyDatabaseMutationSupport.wasApplied(
            reply,
            operation: mutation.operation)
        if applied {
            return try DatabaseAdapterMutationResult(
                disposition: .completed,
                effect: .applied,
                affectedRecords: DatabaseCountMetadata(value: 1, accuracy: .exact))
        }
        return try DatabaseAdapterMutationResult(
            disposition: .completed,
            effect: .notApplied,
            affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .exact),
            error: DatabaseErrorEnvelope(
                category: .conflict,
                message: "The Redis-compatible key no longer matched the requested mutation.",
                productCode: "redis.mutation.key_not_found_or_exists"))
    }

    func openStream(
        _ request: DatabaseAdapterStreamRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterRecordStream {
        try await requireAvailableContext(context)
        throw RedisValkeyDatabaseAdapterSupport.capabilityUnavailable
    }

    func cancel(_ operationID: DatabaseOperationID) async -> DatabaseAdapterCancellationResult {
        guard let activeOperation, activeOperation.operationID == operationID else {
            return DatabaseAdapterCancellationResult(
                support: .cooperative,
                disposition: .alreadyFinished)
        }
        await activeOperation.cancellation.cancel(.userRequested)
        await interrupt(operationID: operationID)
        return DatabaseAdapterCancellationResult(
            support: .cooperative,
            disposition: .accepted)
    }

    func disconnect() async {
        guard state == .connected || state == .failed else { return }
        state = .disconnecting
        if let activeOperation {
            await activeOperation.cancellation.cancel(.sessionDisconnected)
        }
        let closingClient = client
        client = nil
        activeOperation = nil
        await closingClient?.close()
        state = .disconnected
    }

    func resourceIsOpen() -> Bool {
        client != nil
    }

    private func connectedClient() throws(DatabaseAdapterFailure) -> any RedisDatabaseClient {
        guard state == .connected, let client else {
            throw RedisValkeyDatabaseAdapterSupport.disconnected
        }
        return client
    }

    private func requireAvailableContext(
        _ context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) {
        try await RedisValkeyDatabaseAdapterSupport.check(context)
        _ = try connectedClient()
        try await RedisValkeyDatabaseAdapterSupport.check(context)
    }

    private func perform<Output: Sendable>(
        context: DatabaseAdapterOperationContext,
        fallback: DatabaseAdapterFailure,
        body:
            @escaping @Sendable (
                any RedisDatabaseClient,
                Date
            ) async throws -> Output
    ) async throws(DatabaseAdapterFailure) -> Output {
        try await RedisValkeyDatabaseAdapterSupport.check(context)
        let client = try connectedClient()
        guard activeOperation == nil else {
            throw RedisValkeyDatabaseAdapterSupport.operationBusy
        }
        let deadline = RedisValkeyDatabaseAdapterSupport.operationDeadline(
            context: context,
            timeout: connection.limits.operationTimeout)
        try await RedisValkeyDatabaseAdapterSupport.check(context, deadline: deadline)
        activeOperation = RedisDatabaseActiveOperation(
            operationID: context.operationID,
            cancellation: context.cancellation)

        let cancellationTask = Task { [weak self] in
            for await _ in await context.cancellation.events() {
                guard !Task.isCancelled else { return }
                await self?.interrupt(operationID: context.operationID)
                return
            }
        }
        let deadlineTask = Task { [weak self] in
            let delay = max(0, deadline.timeIntervalSinceNow)
            let nanoseconds = UInt64(min(delay * 1_000_000_000, Double(UInt64.max)))
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await context.cancellation.cancel(.deadlineExceeded)
            await self?.interrupt(operationID: context.operationID)
        }
        defer {
            cancellationTask.cancel()
            deadlineTask.cancel()
            if activeOperation?.operationID == context.operationID {
                activeOperation = nil
            }
        }

        do {
            let output = try await withTaskCancellationHandler {
                try await body(client, deadline)
            } onCancel: {
                Task {
                    await context.cancellation.cancel(.userRequested)
                    await client.close()
                }
            }
            try await RedisValkeyDatabaseAdapterSupport.check(context, deadline: deadline)
            return output
        } catch let failure as DatabaseAdapterFailure {
            let cancellationReason = await context.cancellation.reason()
            if failure == RedisValkeyDatabaseAdapterSupport.deadlineExceeded {
                await failAndClose()
            } else if failure == .cancelled || cancellationReason != nil
                || Task.isCancelled
            {
                await failAndClose()
            }
            throw failure
        } catch let failure as RedisDatabaseClientFailure {
            if failure == .responseTooLarge {
                await failAndClose()
                throw RedisValkeyDatabaseAdapterSupport.resultTooLarge
            }
            if failure == .authentication {
                await failAndClose()
                throw RedisValkeyDatabaseAdapterSupport.authenticationFailed
            }
            if failure == .deadlineExceeded {
                await failAndClose()
                throw RedisValkeyDatabaseAdapterSupport.deadlineExceeded
            }
            if failure == .cancelled {
                await failAndClose()
                throw .cancelled
            }
            let reason = await context.cancellation.reason()
            if reason == .deadlineExceeded {
                await failAndClose()
                throw RedisValkeyDatabaseAdapterSupport.deadlineExceeded
            }
            if reason != nil || Task.isCancelled {
                await failAndClose()
                throw .cancelled
            }
            if failure == .permission || failure == .server || failure == .wrongType {
                throw fallback
            }
            await failAndClose()
            throw fallback
        } catch {
            let reason = await context.cancellation.reason()
            if reason == .deadlineExceeded {
                await failAndClose()
                throw RedisValkeyDatabaseAdapterSupport.deadlineExceeded
            }
            if reason != nil || Task.isCancelled {
                await failAndClose()
                throw .cancelled
            }
            throw fallback
        }
    }

    private func interrupt(operationID: DatabaseOperationID) async {
        guard activeOperation?.operationID == operationID else { return }
        state = .failed
        let closingClient = client
        client = nil
        await closingClient?.close()
    }

    private func failAndClose() async {
        guard state != .disconnected && state != .disconnecting else { return }
        state = .failed
        let closingClient = client
        client = nil
        await closingClient?.close()
    }
}

struct RedisDatabaseActiveOperation: Sendable {
    let operationID: DatabaseOperationID
    let cancellation: DatabaseAdapterCancellationSignal
}

struct RedisDatabaseConnectionPlan: Sendable {
    let host: String
    let port: Int
    let username: String?
    let password: String?
    let database: Int
    let connectionTimeoutMilliseconds: Int64
}

protocol RedisDatabaseClientFactory: Sendable {
    func connect(
        _ plan: RedisDatabaseConnectionPlan,
        context: DatabaseAdapterConnectionContext,
        deadline: Date
    ) async throws -> any RedisDatabaseClient
}

protocol RedisDatabaseClient: Sendable {
    func execute(
        _ operation: RedisDatabaseOperation,
        context: DatabaseAdapterOperationContext,
        deadline: Date
    ) async throws -> RedisDatabaseReply
    func executeBatch(
        _ operations: [RedisDatabaseOperation],
        context: DatabaseAdapterOperationContext,
        deadline: Date
    ) async throws -> [RedisDatabaseCommandResult]
    func close() async
}

enum RedisDatabaseClientFailure: Error, Equatable, Sendable {
    case authentication
    case cancelled
    case connection
    case deadlineExceeded
    case permission
    case protocolFailure
    case responseTooLarge
    case server
    case wrongType
}

enum RedisDatabaseSetCondition: Equatable, Sendable {
    case onlyIfMissing
    case onlyIfPresent
}

enum RedisDatabaseSetTTL: Equatable, Sendable {
    case persistent
    case preserve
    case milliseconds(Int64)
}

enum RedisDatabaseOperation: Equatable, Sendable {
    case ping
    case info(section: String)
    case scan(cursor: UInt64, count: Int)
    case type(Data)
    case pttl(Data)
    case exists(Data)
    case stringLength(Data)
    case stringRange(Data, maximumBytes: Int)
    case hashLength(Data)
    case hashScan(Data, count: Int)
    case listLength(Data)
    case listRange(Data, count: Int)
    case setCardinality(Data)
    case setScan(Data, count: Int)
    case sortedSetCardinality(Data)
    case sortedSetRange(Data, count: Int)
    case streamLength(Data)
    case streamRange(Data, count: Int)
    case set(
        key: Data,
        value: Data,
        condition: RedisDatabaseSetCondition,
        ttl: RedisDatabaseSetTTL)
    case delete(Data)
    case expire(Data, milliseconds: Int64)
    case persist(Data)
}

enum RedisDatabaseCommandResult: Sendable {
    case reply(RedisDatabaseReply)
    case failure(RedisDatabaseClientFailure)
}

indirect enum RedisDatabaseReply: Equatable, Sendable {
    case null
    case bytes(Data)
    case integer(Int64)
    case array([RedisDatabaseReply])
}

struct RediStackDatabaseClientFactory: RedisDatabaseClientFactory {
    func connect(
        _ plan: RedisDatabaseConnectionPlan,
        context: DatabaseAdapterConnectionContext,
        deadline: Date
    ) async throws -> any RedisDatabaseClient {
        let channels = RedisDatabasePendingChannels()
        let eventLoop = NIOSingletons.posixEventLoopGroup.next()
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(.milliseconds(plan.connectionTimeoutMilliseconds))
            .channelOption(
                ChannelOptions.recvAllocator,
                value: FixedSizeRecvByteBufferAllocator(capacity: 16_384)
            )
            .channelInitializer { channel in
                guard channels.register(channel) else {
                    return channel.close(mode: .all)
                }
                do {
                    try channel.pipeline.syncOperations.addHandlers([
                        RedisDatabaseInboundFrameHandler(),
                        ByteToMessageHandler(
                            RedisByteDecoder(),
                            maximumBufferSize:
                                RedisValkeyDatabaseAdapterSupport.maximumInboundReplyBytes),
                        MessageToByteHandler(RedisMessageEncoder()),
                        RedisCommandHandler(initialQueueCapacity: 1),
                    ])
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        do {
            let channel = try await RedisDatabaseFutureAwaiter.value(
                bootstrap.connect(host: plan.host, port: plan.port),
                context: context,
                deadline: deadline,
                interrupt: { channels.cancel() })
            channels.claim(channel)
            let client = RediStackDatabaseClient(channel: channel)
            do {
                if let password = plan.password {
                    try await client.authenticate(
                        username: plan.username,
                        password: password,
                        context: context,
                        deadline: deadline)
                }
                if plan.database != 0 {
                    try await client.select(
                        plan.database,
                        context: context,
                        deadline: deadline)
                }
                return client
            } catch {
                await client.close()
                throw error
            }
        } catch let failure as RedisDatabaseClientFailure {
            channels.cancel()
            throw failure
        } catch let failure as RedisDatabaseAwaitFailure {
            channels.cancel()
            throw failure == .deadlineExceeded
                ? RedisDatabaseClientFailure.deadlineExceeded
                : RedisDatabaseClientFailure.cancelled
        } catch {
            channels.cancel()
            if Task.isCancelled {
                throw RedisDatabaseClientFailure.cancelled
            }
            if deadline <= Date() {
                await context.cancellation.cancel(.deadlineExceeded)
                throw RedisDatabaseClientFailure.deadlineExceeded
            }
            throw RedisDatabaseClientFailure.connection
        }
    }
}

final class RediStackDatabaseClient: RedisDatabaseClient, @unchecked Sendable {
    private let channel: Channel

    init(channel: Channel) {
        self.channel = channel
    }

    func execute(
        _ operation: RedisDatabaseOperation,
        context: DatabaseAdapterOperationContext,
        deadline: Date
    ) async throws -> RedisDatabaseReply {
        let request = operation.request
        do {
            let response = try await send(
                command: request.command,
                arguments: request.arguments,
                context: context,
                deadline: deadline)
            var budget = RedisValkeyDatabaseAdapterSupport.maximumRawReplyBytes
            var elements = 0
            return try RedisDatabaseReply.convert(
                response,
                budget: &budget,
                elements: &elements,
                depth: 0)
        } catch let failure as RedisDatabaseClientFailure {
            throw failure
        } catch let failure as RedisDatabaseAwaitFailure {
            throw failure == .deadlineExceeded
                ? RedisDatabaseClientFailure.deadlineExceeded
                : RedisDatabaseClientFailure.cancelled
        } catch let failure as RedisDatabaseInboundFrameFailure {
            throw failure == .responseTooLarge
                ? RedisDatabaseClientFailure.responseTooLarge
                : RedisDatabaseClientFailure.protocolFailure
        } catch is ByteToMessageDecoderError.PayloadTooLargeError {
            throw RedisDatabaseClientFailure.responseTooLarge
        } catch let failure as RedisError {
            throw clientFailure(failure)
        } catch {
            throw RedisDatabaseClientFailure.protocolFailure
        }
    }

    func executeBatch(
        _ operations: [RedisDatabaseOperation],
        context: DatabaseAdapterOperationContext,
        deadline: Date
    ) async throws -> [RedisDatabaseCommandResult] {
        guard operations.count <= RedisValkeyDatabaseAdapterSupport.maximumBatchOperations else {
            throw RedisDatabaseClientFailure.responseTooLarge
        }
        guard !operations.isEmpty else { return [] }
        let budget = RedisDatabaseBatchBudget(
            maximumBytes: DatabaseAdapterBounds.maximumPageBytes)
        let futures = operations.map { operation in
            let request = operation.request
            return sendFuture(command: request.command, arguments: request.arguments)
                .map { response -> RedisDatabaseCommandResult in
                    do {
                        var bytes = RedisValkeyDatabaseAdapterSupport.maximumRawReplyBytes
                        var elements = 0
                        let reply = try RedisDatabaseReply.convert(
                            response,
                            budget: &bytes,
                            elements: &elements,
                            depth: 0)
                        guard
                            budget.consume(
                                RedisValkeyDatabaseAdapterSupport.maximumRawReplyBytes - bytes)
                        else {
                            return .failure(.responseTooLarge)
                        }
                        return .reply(reply)
                    } catch let failure as RedisDatabaseClientFailure {
                        return .failure(failure)
                    } catch {
                        return .failure(.protocolFailure)
                    }
                }
                .flatMapError { error -> EventLoopFuture<RedisDatabaseCommandResult> in
                    self.channel.eventLoop.makeSucceededFuture(
                        RedisDatabaseCommandResult.failure(self.clientFailure(error)))
                }
        }
        do {
            return try await RedisDatabaseFutureAwaiter.value(
                EventLoopFuture.whenAllSucceed(futures, on: channel.eventLoop),
                context: context,
                deadline: deadline,
                interrupt: { [channel] in
                    channel.close(mode: .all, promise: nil)
                })
        } catch {
            throw clientFailure(error)
        }
    }

    func close() async {
        try? await channel.close(mode: .all).get()
    }

    fileprivate func authenticate(
        username: String?,
        password: String,
        context: DatabaseAdapterConnectionContext,
        deadline: Date
    ) async throws {
        var arguments: [RESPValue] = []
        if let username {
            arguments.append(RESPValue(from: username))
        }
        arguments.append(RESPValue(from: password))
        do {
            _ = try await send(
                command: "AUTH",
                arguments: arguments,
                context: context,
                deadline: deadline)
        } catch {
            throw clientFailure(error)
        }
    }

    fileprivate func select(
        _ database: Int,
        context: DatabaseAdapterConnectionContext,
        deadline: Date
    ) async throws {
        do {
            _ = try await send(
                command: "SELECT",
                arguments: [RESPValue(from: database)],
                context: context,
                deadline: deadline)
        } catch {
            throw clientFailure(error)
        }
    }

    private func send(
        command: String,
        arguments: [RESPValue],
        context: DatabaseAdapterOperationContext,
        deadline: Date
    ) async throws -> RESPValue {
        return try await RedisDatabaseFutureAwaiter.value(
            sendFuture(command: command, arguments: arguments),
            context: context,
            deadline: deadline,
            interrupt: { [channel] in
                channel.close(mode: .all, promise: nil)
            })
    }

    private func sendFuture(
        command: String,
        arguments: [RESPValue]
    ) -> EventLoopFuture<RESPValue> {
        var message = [RESPValue(from: command)]
        message.append(contentsOf: arguments)
        let response = channel.eventLoop.makePromise(of: RESPValue.self)
        let request = RedisCommand(message: .array(message), responsePromise: response)
        let write: EventLoopFuture<Void> = channel.writeAndFlush(request)
        return write.flatMap { response.futureResult }
    }

    private func clientFailure(_ error: any Error) -> RedisDatabaseClientFailure {
        if let failure = error as? RedisDatabaseClientFailure {
            return failure
        }
        if let failure = error as? RedisDatabaseAwaitFailure {
            return failure == .deadlineExceeded ? .deadlineExceeded : .cancelled
        }
        if let failure = error as? RedisDatabaseInboundFrameFailure {
            return failure == .responseTooLarge ? .responseTooLarge : .protocolFailure
        }
        if error is ByteToMessageDecoderError.PayloadTooLargeError {
            return .responseTooLarge
        }
        if let error = error as? RedisError {
            let message = error.message.uppercased()
            if message.contains("NOAUTH") || message.contains("WRONGPASS")
                || message.contains("AUTHENTICATION") || message.contains("INVALID PASSWORD")
            {
                return .authentication
            }
            if message.contains("WRONGTYPE") { return .wrongType }
            if message.contains("NOPERM") { return .permission }
            return .server
        }
        return .connection
    }
}

private final class RedisDatabaseBatchBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingBytes: Int

    init(maximumBytes: Int) {
        remainingBytes = maximumBytes
    }

    func consume(_ bytes: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard bytes >= 0, bytes <= remainingBytes else { return false }
        remainingBytes -= bytes
        return true
    }
}

private enum RedisDatabaseAwaitFailure: Error, Equatable, Sendable {
    case cancelled
    case deadlineExceeded
}

private final class RedisDatabaseFutureRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let interrupt: @Sendable () -> Void
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pending: Result<Value, any Error>?
    private var tasks: [Task<Void, Never>] = []
    private var completed = false

    init(interrupt: @escaping @Sendable () -> Void) {
        self.interrupt = interrupt
    }

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func add(_ task: Task<Void, Never>) {
        lock.lock()
        if completed {
            lock.unlock()
            task.cancel()
            return
        }
        tasks.append(task)
        lock.unlock()
    }

    func finish(_ result: Result<Value, any Error>, interrupting: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pending = result
        }
        let tasks = tasks
        self.tasks.removeAll()
        lock.unlock()
        if interrupting {
            interrupt()
        }
        for task in tasks {
            task.cancel()
        }
        continuation?.resume(with: result)
    }
}

private enum RedisDatabaseFutureAwaiter {
    static func value<Value: Sendable>(
        _ future: EventLoopFuture<Value>,
        context: DatabaseAdapterOperationContext,
        deadline: Date,
        interrupt: @escaping @Sendable () -> Void
    ) async throws -> Value {
        let race = RedisDatabaseFutureRace<Value>(interrupt: interrupt)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                future.whenComplete { result in
                    race.finish(result, interrupting: false)
                }
                let cancellationObserver = Task {
                    for await reason in await context.cancellation.events() {
                        let failure: RedisDatabaseAwaitFailure =
                            reason == .deadlineExceeded ? .deadlineExceeded : .cancelled
                        race.finish(.failure(failure), interrupting: true)
                        return
                    }
                }
                race.add(cancellationObserver)
                let deadlineObserver = Task {
                    let delay = max(0, deadline.timeIntervalSinceNow)
                    let nanoseconds = UInt64(delay * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    await context.cancellation.cancel(.deadlineExceeded)
                    race.finish(
                        .failure(RedisDatabaseAwaitFailure.deadlineExceeded),
                        interrupting: true)
                }
                race.add(deadlineObserver)
            }
        } onCancel: {
            race.finish(
                .failure(RedisDatabaseAwaitFailure.cancelled),
                interrupting: true)
        }
    }
}

private final class RedisDatabasePendingChannels: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var cancelled = false

    func register(_ channel: Channel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        channels[ObjectIdentifier(channel)] = channel
        return true
    }

    func claim(_ selected: Channel) {
        lock.lock()
        let remaining = channels.values.filter { $0 !== selected }
        channels.removeAll()
        lock.unlock()
        for channel in remaining {
            channel.close(mode: .all, promise: nil)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = Array(channels.values)
        channels.removeAll()
        lock.unlock()
        for channel in pending {
            channel.close(mode: .all, promise: nil)
        }
    }
}

private enum RedisDatabaseInboundFrameFailure: Error, Equatable, Sendable {
    case responseTooLarge
    case protocolFailure
}

private final class RedisDatabaseInboundFrameHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var validator = RedisDatabaseInboundFrameValidator()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        do {
            try validator.consume(buffer)
            context.fireChannelRead(data)
        } catch {
            context.fireErrorCaught(error)
            context.close(mode: .all, promise: nil)
        }
    }
}

private struct RedisDatabaseInboundFrameValidator {
    private enum Phase {
        case token
        case line(LineKind)
        case bulk(Int)
    }

    private enum LineKind: Equatable {
        case scalar
        case bulk
        case array
    }

    private var phase = Phase.token
    private var lineBytes: [UInt8] = []
    private var previousLineByte: UInt8?
    private var arrayRemaining: [Int] = []
    private var frameBytes = 0
    private var elementCount = 0

    mutating func consume(_ buffer: ByteBuffer) throws {
        var index = buffer.readerIndex
        while index < buffer.writerIndex {
            switch phase {
            case let .bulk(remaining):
                let count = min(remaining, buffer.writerIndex - index)
                try addFrameBytes(count)
                index += count
                if count == remaining {
                    phase = .token
                    try completeValue()
                } else {
                    phase = .bulk(remaining - count)
                }
            case .token:
                guard let token = buffer.getInteger(at: index, as: UInt8.self) else { return }
                try addFrameBytes(1)
                index += 1
                elementCount += 1
                guard elementCount <= RedisValkeyDatabaseAdapterSupport.maximumReplyElements else {
                    throw RedisDatabaseInboundFrameFailure.responseTooLarge
                }
                switch token {
                case 43, 45, 58:
                    beginLine(.scalar)
                case 36:
                    beginLine(.bulk)
                case 42:
                    beginLine(.array)
                default:
                    throw RedisDatabaseInboundFrameFailure.protocolFailure
                }
            case let .line(kind):
                guard let byte = buffer.getInteger(at: index, as: UInt8.self) else { return }
                try addFrameBytes(1)
                index += 1
                let previous = previousLineByte
                previousLineByte = byte
                if kind != .scalar {
                    guard lineBytes.count < 32 else {
                        throw RedisDatabaseInboundFrameFailure.protocolFailure
                    }
                    lineBytes.append(byte)
                }
                guard byte == 10 else { continue }
                guard previous == 13 else {
                    throw RedisDatabaseInboundFrameFailure.protocolFailure
                }
                try finishLine(kind)
            }
        }
    }

    private mutating func beginLine(_ kind: LineKind) {
        phase = .line(kind)
        lineBytes.removeAll(keepingCapacity: true)
        previousLineByte = nil
    }

    private mutating func finishLine(_ kind: LineKind) throws {
        phase = .token
        previousLineByte = nil
        if kind == .scalar {
            try completeValue()
            return
        }
        guard lineBytes.count >= 2,
            lineBytes.suffix(2).elementsEqual([13, 10]),
            let text = String(bytes: lineBytes.dropLast(2), encoding: .ascii),
            let value = Int(text)
        else {
            throw RedisDatabaseInboundFrameFailure.protocolFailure
        }
        lineBytes.removeAll(keepingCapacity: true)
        if kind == .bulk {
            guard value >= -1,
                value <= RedisValkeyDatabaseAdapterSupport.maximumRawReplyBytes
            else {
                throw RedisDatabaseInboundFrameFailure.responseTooLarge
            }
            if value == -1 {
                try completeValue()
            } else {
                phase = .bulk(value + 2)
            }
            return
        }
        guard value >= -1,
            value <= RedisValkeyDatabaseAdapterSupport.maximumReplyElements
        else {
            throw RedisDatabaseInboundFrameFailure.responseTooLarge
        }
        if value <= 0 {
            try completeValue()
            return
        }
        guard arrayRemaining.count < RedisValkeyDatabaseAdapterSupport.maximumReplyDepth else {
            throw RedisDatabaseInboundFrameFailure.responseTooLarge
        }
        arrayRemaining.append(value)
    }

    private mutating func addFrameBytes(_ count: Int) throws {
        guard count <= RedisValkeyDatabaseAdapterSupport.maximumInboundReplyBytes - frameBytes
        else {
            throw RedisDatabaseInboundFrameFailure.responseTooLarge
        }
        frameBytes += count
    }

    private mutating func completeValue() throws {
        while let remaining = arrayRemaining.last {
            guard remaining > 0 else {
                throw RedisDatabaseInboundFrameFailure.protocolFailure
            }
            if remaining > 1 {
                arrayRemaining[arrayRemaining.count - 1] = remaining - 1
                return
            }
            arrayRemaining.removeLast()
        }
        frameBytes = 0
        elementCount = 0
    }
}

private extension RedisDatabaseOperation {
    var request: (command: String, arguments: [RESPValue]) {
        switch self {
        case .ping:
            ("PING", [])
        case let .info(section):
            ("INFO", [RESPValue(from: section)])
        case let .scan(cursor, count):
            (
                "SCAN",
                [
                    RESPValue(from: cursor.description),
                    RESPValue(from: "COUNT"),
                    RESPValue(from: count),
                ]
            )
        case let .type(key):
            ("TYPE", [RESPValue(from: key)])
        case let .pttl(key):
            ("PTTL", [RESPValue(from: key)])
        case let .exists(key):
            ("EXISTS", [RESPValue(from: key)])
        case let .stringLength(key):
            ("STRLEN", [RESPValue(from: key)])
        case let .stringRange(key, maximumBytes):
            (
                "GETRANGE",
                [
                    RESPValue(from: key),
                    RESPValue(from: 0),
                    RESPValue(from: maximumBytes - 1),
                ]
            )
        case let .hashLength(key):
            ("HLEN", [RESPValue(from: key)])
        case let .hashScan(key, count):
            (
                "HSCAN",
                [
                    RESPValue(from: key),
                    RESPValue(from: 0),
                    RESPValue(from: "COUNT"),
                    RESPValue(from: count),
                ]
            )
        case let .listLength(key):
            ("LLEN", [RESPValue(from: key)])
        case let .listRange(key, count):
            (
                "LRANGE",
                [
                    RESPValue(from: key),
                    RESPValue(from: 0),
                    RESPValue(from: count - 1),
                ]
            )
        case let .setCardinality(key):
            ("SCARD", [RESPValue(from: key)])
        case let .setScan(key, count):
            (
                "SSCAN",
                [
                    RESPValue(from: key),
                    RESPValue(from: 0),
                    RESPValue(from: "COUNT"),
                    RESPValue(from: count),
                ]
            )
        case let .sortedSetCardinality(key):
            ("ZCARD", [RESPValue(from: key)])
        case let .sortedSetRange(key, count):
            (
                "ZRANGE",
                [
                    RESPValue(from: key),
                    RESPValue(from: 0),
                    RESPValue(from: count - 1),
                    RESPValue(from: "WITHSCORES"),
                ]
            )
        case let .streamLength(key):
            ("XLEN", [RESPValue(from: key)])
        case let .streamRange(key, count):
            (
                "XRANGE",
                [
                    RESPValue(from: key),
                    RESPValue(from: "-"),
                    RESPValue(from: "+"),
                    RESPValue(from: "COUNT"),
                    RESPValue(from: count),
                ]
            )
        case let .set(key, value, condition, ttl):
            Self.setRequest(
                key: key,
                value: value,
                condition: condition,
                ttl: ttl)
        case let .delete(key):
            ("DEL", [RESPValue(from: key)])
        case let .expire(key, milliseconds):
            (
                "PEXPIRE",
                [RESPValue(from: key), RESPValue(from: milliseconds)]
            )
        case let .persist(key):
            ("PERSIST", [RESPValue(from: key)])
        }
    }

    private static func setRequest(
        key: Data,
        value: Data,
        condition: RedisDatabaseSetCondition,
        ttl: RedisDatabaseSetTTL
    ) -> (command: String, arguments: [RESPValue]) {
        var arguments = [RESPValue(from: key), RESPValue(from: value)]
        arguments.append(
            RESPValue(from: condition == .onlyIfMissing ? "NX" : "XX"))
        switch ttl {
        case let .milliseconds(ttlMilliseconds):
            arguments.append(RESPValue(from: "PX"))
            arguments.append(RESPValue(from: ttlMilliseconds))
        case .preserve:
            arguments.append(RESPValue(from: "KEEPTTL"))
        case .persistent:
            break
        }
        return ("SET", arguments)
    }
}

private extension RedisDatabaseReply {
    static func convert(
        _ value: RESPValue,
        budget: inout Int,
        elements: inout Int,
        depth: Int
    ) throws -> RedisDatabaseReply {
        guard depth <= RedisValkeyDatabaseAdapterSupport.maximumReplyDepth else {
            throw RedisDatabaseClientFailure.responseTooLarge
        }
        elements += 1
        guard elements <= RedisValkeyDatabaseAdapterSupport.maximumReplyElements else {
            throw RedisDatabaseClientFailure.responseTooLarge
        }
        switch value {
        case .null:
            return .null
        case .bulkString(nil):
            return .bytes(Data())
        case let .simpleString(buffer), let .bulkString(.some(buffer)):
            let data = Data(buffer.readableBytesView)
            guard data.count <= budget else {
                throw RedisDatabaseClientFailure.responseTooLarge
            }
            budget -= data.count
            return .bytes(data)
        case let .integer(integer):
            guard let value = Int64(exactly: integer) else {
                throw RedisDatabaseClientFailure.protocolFailure
            }
            return .integer(value)
        case .error:
            throw RedisDatabaseClientFailure.protocolFailure
        case let .array(values):
            return .array(
                try values.map {
                    try convert(
                        $0,
                        budget: &budget,
                        elements: &elements,
                        depth: depth + 1)
                })
        }
    }
}

private struct RedisDatabaseContinuationPayload: Codable, Sendable {
    let version: Int
    let cursor: UInt64
    let replay: RedisDatabaseScanReplay?
}

private struct RedisDatabaseScanReplay: Codable, Sendable {
    let cursor: UInt64
    let count: Int
    let offset: Int
}

private struct RedisDatabaseReadOutput: Sendable {
    let records: [DatabaseRecord]
    let fields: [DatabaseFieldDescriptor]
    let continuation: DatabaseAdapterContinuation?
    let sampledValues: Bool
    let scanTraversal: Bool
}

private struct RedisDatabaseInspectedValue: Sendable {
    let value: DatabaseValue
    let length: UInt64?
    let completeness: String
}

private enum RedisValkeyDatabaseAdapterSupport {
    static let maximumPageRecords = 100
    static let maximumKeyBytes = 4_096
    static let maximumValueBytes = 65_536
    static let maximumCollectionEntries = 32
    static let maximumRawReplyBytes = 1_048_576
    static let maximumReplyElements = 4_096
    static let maximumReplyDepth = 8
    static let maximumInboundReplyBytes = maximumRawReplyBytes + 65_536
    static let maximumScanCallsPerPage = 256
    static let maximumBatchOperations = maximumPageRecords * 2

    static let connectionFailed = failure(
        category: .connectionFailed,
        message: "The Redis-compatible database connection could not be established.",
        code: "redis.connection.failed",
        retry: .reconnect)
    static let authenticationFailed = failure(
        category: .authenticationFailed,
        message: "The Redis-compatible database rejected authentication.",
        code: "redis.authentication.failed",
        retry: .reauthenticate)
    static let disconnected = failure(
        category: .connectionFailed,
        message: "The Redis-compatible database session is disconnected.",
        code: "redis.session.disconnected",
        retry: .reconnect)
    static let operationBusy = failure(
        category: .conflict,
        message: "The Redis-compatible database session is already executing an operation.",
        code: "redis.operation.busy",
        retry: .retry)
    static let readFailed = failure(
        category: .server,
        message: "The Redis-compatible keyspace page could not be read.",
        code: "redis.read.failed")
    static let queryFailed = failure(
        category: .server,
        message: "The bounded Redis-compatible command could not be executed.",
        code: "redis.query.failed")
    static let invalidConnection = failure(
        category: .invalidRequest,
        message: "The Redis-compatible connection configuration is invalid.",
        code: "redis.connection.invalid")
    static let productMismatch = failure(
        category: .invalidRequest,
        message: "The discovered database product does not match the requested product.",
        code: "redis.product.mismatch")
    static let unsupportedTopology = failure(
        category: .unsupported,
        message: "The discovered Redis-compatible topology is not supported by this adapter.",
        code: "redis.topology.unsupported")
    static let invalidRead = failure(
        category: .invalidRequest,
        message: "The Redis-compatible keyspace page request is invalid.",
        code: "redis.read.invalid")
    static let invalidQuery = failure(
        category: .invalidRequest,
        message: "The bounded Redis-compatible command request is invalid.",
        code: "redis.query.invalid")
    static let unsafeQuery = failure(
        category: .readOnlyViolation,
        message: "The Redis-compatible command is outside the bounded read-only allowlist.",
        code: "redis.query.read_only_violation")
    static let invalidContinuation = failure(
        category: .invalidRequest,
        message: "The Redis-compatible continuation is invalid.",
        code: "redis.continuation.invalid")
    static let capabilityUnavailable = failure(
        category: .unsupported,
        message: "The requested Redis-compatible capability is unavailable.",
        code: "redis.capability.not_implemented")
    static let resultTooLarge = failure(
        category: .resourceLimit,
        message: "The Redis-compatible result exceeds the bounded response limit.",
        code: "redis.result.too_large")
    static let deadlineExceeded = failure(
        category: .timeout,
        message: "The database operation deadline was exceeded.",
        code: "redis.deadline_exceeded")

    static func failure(
        category: DatabaseErrorCategory,
        message: String,
        code: String,
        retry: DatabaseRetryAction = .none
    ) -> DatabaseAdapterFailure {
        .reported(
            DatabaseErrorEnvelope(
                category: category,
                message: message,
                productCode: code,
                retry: DatabaseRetryGuidance(action: retry)))
    }

    static func connectionFailure(
        for failure: RedisDatabaseClientFailure
    ) -> DatabaseAdapterFailure {
        switch failure {
        case .authentication:
            authenticationFailed
        case .cancelled:
            .cancelled
        case .deadlineExceeded:
            deadlineExceeded
        case .responseTooLarge:
            resultTooLarge
        case .connection, .permission, .protocolFailure, .server, .wrongType:
            connectionFailed
        }
    }

    static func check(
        _ context: DatabaseAdapterOperationContext,
        deadline: Date? = nil
    ) async throws(DatabaseAdapterFailure) {
        switch await context.cancellation.reason() {
        case .deadlineExceeded:
            throw deadlineExceeded
        case .userRequested, .sessionDisconnected:
            throw .cancelled
        case nil:
            break
        }
        if Task.isCancelled {
            throw .cancelled
        }
        let effectiveDeadline = [context.deadline, deadline].compactMap { $0 }.min()
        guard let effectiveDeadline else { return }
        guard effectiveDeadline.timeIntervalSinceReferenceDate.isFinite,
            effectiveDeadline > Date()
        else {
            throw deadlineExceeded
        }
    }

    static func operationDeadline(
        context: DatabaseAdapterOperationContext,
        timeout: DatabaseTimeout
    ) -> Date {
        let timeoutDeadline = Date().addingTimeInterval(
            Double(timeout.milliseconds) / 1_000)
        guard let requested = context.deadline,
            requested.timeIntervalSinceReferenceDate.isFinite
        else {
            return timeoutDeadline
        }
        return min(requested, timeoutDeadline)
    }

    static func connectionPlan(
        _ plan: RedisDatabaseConnectionPlan,
        context: DatabaseAdapterConnectionContext
    ) -> RedisDatabaseConnectionPlan {
        guard let deadline = context.deadline,
            deadline.timeIntervalSinceReferenceDate.isFinite
        else {
            return plan
        }
        let remaining = Int64(
            min(
                max(1, deadline.timeIntervalSinceNow * 1_000),
                Double(Int64.max)))
        return RedisDatabaseConnectionPlan(
            host: plan.host,
            port: plan.port,
            username: plan.username,
            password: plan.password,
            database: plan.database,
            connectionTimeoutMilliseconds: min(
                plan.connectionTimeoutMilliseconds,
                remaining))
    }

    static func validate(
        _ connection: DatabaseResolvedConnection
    ) throws(DatabaseAdapterFailure) -> RedisDatabaseConnectionPlan {
        let definition = connection.definition
        guard definition.version == DatabaseConnectionDefinition.schemaVersion,
            definition.productHint == .redis || definition.productHint == .valkey,
            definition.tunnel == nil,
            definition.options.isEmpty,
            definition.tls.mode == .disabled,
            definition.tls.verification == .none,
            definition.tls.serverName == nil,
            definition.tls.certificateAuthority == nil,
            definition.tls.clientCertificate == nil,
            definition.tls.clientPrivateKey == nil,
            definition.namespaces.catalog == nil,
            definition.namespaces.schema == nil,
            definition.namespaces.database == nil,
            definition.limits.poolSize.value == 1,
            definition.deploymentMode == .automatic
                || definition.deploymentMode == .standalone
        else {
            throw invalidConnection
        }
        guard case let .network(endpoints) = definition.location,
            endpoints.count == 1,
            let endpoint = endpoints.first,
            endpoint.role == .primary,
            validHost(endpoint.host)
        else {
            throw invalidConnection
        }
        let database: Int
        if let logicalDatabase = definition.namespaces.logicalDatabase {
            guard let parsed = Int(logicalDatabase),
                parsed >= 0,
                parsed <= Int(Int32.max),
                parsed.description == logicalDatabase
            else {
                throw invalidConnection
            }
            database = parsed
        } else {
            database = 0
        }
        let credentials = try credentials(
            definition: definition,
            resolvedSecrets: connection.secrets)
        return RedisDatabaseConnectionPlan(
            host: endpoint.host,
            port: endpoint.port.value,
            username: credentials.username,
            password: credentials.password,
            database: database,
            connectionTimeoutMilliseconds: Int64(
                definition.limits.connectionTimeout.milliseconds))
    }

    static func validateTopology(
        _ identity: DatabaseProductIdentity,
        requested: DatabaseDeploymentMode
    ) throws(DatabaseAdapterFailure) {
        guard
            identity.topology.kind == .standalone
                || identity.topology.kind == .primaryReplica
        else {
            throw unsupportedTopology
        }
        if requested == .standalone, identity.topology.kind != .standalone {
            throw unsupportedTopology
        }
    }

    static func discoverIdentity(
        client: any RedisDatabaseClient,
        expectedProduct: DatabaseProduct,
        context: DatabaseAdapterOperationContext,
        deadline: Date
    ) async throws -> DatabaseProductIdentity {
        try await check(context, deadline: deadline)
        let server = try info(
            try await client.execute(
                .info(section: "server"),
                context: context,
                deadline: deadline))
        try await check(context, deadline: deadline)
        let replication = try info(
            try await client.execute(
                .info(section: "replication"),
                context: context,
                deadline: deadline))
        try await check(context, deadline: deadline)
        let cluster = try info(
            try await client.execute(
                .info(section: "cluster"),
                context: context,
                deadline: deadline))
        let product: DatabaseProduct = server["valkey_version"] == nil ? .redis : .valkey
        guard product == expectedProduct else {
            throw productMismatch
        }
        let versionString =
            product == .valkey
            ? server["valkey_version"]
            : server["redis_version"]
        guard let versionString, !versionString.isEmpty,
            versionString.utf8.count <= 128
        else {
            throw RedisDatabaseClientFailure.protocolFailure
        }
        let components = versionString.split(separator: ".", maxSplits: 3)
        let role = replication["role"]
        guard let connectedReplicaCount = Int(replication["connected_slaves"] ?? "0"),
            connectedReplicaCount >= 0
        else {
            throw RedisDatabaseClientFailure.protocolFailure
        }
        let isReplica = role == "slave" || role == "replica"
        let (replicaCount, replicaOverflow) = connectedReplicaCount.addingReportingOverflow(
            isReplica ? 1 : 0)
        let (nodeCount, nodeOverflow) = replicaCount.addingReportingOverflow(1)
        guard !replicaOverflow, !nodeOverflow else {
            throw RedisDatabaseClientFailure.protocolFailure
        }
        let clusterEnabled = cluster["cluster_enabled"] == "1"
        let mode = server["server_mode"] ?? server["redis_mode"]
        let topologyKind: DatabaseTopologyKind
        if clusterEnabled {
            topologyKind = .cluster
        } else if mode == "sentinel" {
            topologyKind = .sentinel
        } else if replicaCount > 0 {
            topologyKind = .primaryReplica
        } else {
            topologyKind = .standalone
        }
        var notes: [String] = []
        if product == .valkey, let compatibility = server["redis_version"] {
            notes.append("Redis protocol compatibility version \(compatibility).")
        }
        notes.append("Module discovery is not performed by the read-only adapter.")
        return DatabaseProductIdentity(
            product: product,
            version: DatabaseVersion(
                string: versionString,
                major: components.indices.contains(0) ? Int(components[0]) : nil,
                minor: components.indices.contains(1) ? Int(components[1]) : nil,
                patch: components.indices.contains(2) ? Int(components[2]) : nil),
            distribution: product.displayName,
            topology: DatabaseTopology(
                kind: topologyKind,
                localRole: role,
                nodeCount: topologyKind == .primaryReplica ? nodeCount : 1,
                replicaCount: topologyKind == .primaryReplica ? replicaCount : 0),
            serverIdentifier: bounded(server["run_id"], maximumBytes: 256),
            compatibilityNotes: notes)
    }

    static func capabilityReport(
        identity: DatabaseProductIdentity
    ) -> DatabaseCapabilityReport {
        let unavailableReason = DatabaseCapabilityUnavailableReason(
            category: .notImplemented,
            message: "This capability is not implemented by the read-only Redis-compatible adapter."
        )
        let unavailable: [(DatabaseCapabilityID, DatabaseCapabilityRequirement)] = [
            (.objectDescription, .familyRequired),
            (.explain, .familyRequired),
            (.bulkMutation, .sharedRequired),
            (.importData, .sharedRequired),
            (.exportData, .sharedRequired),
            (.transactions, .familyRequired),
            (.schemaMutation, .productRequired),
            (.monitoring, .productRequired),
            (.administration, .productRequired),
        ]
        let capabilities =
            [
                DatabaseCapabilityStatus(
                    id: .connectionTest,
                    requirement: .sharedRequired,
                    availability: .available),
                DatabaseCapabilityStatus(
                    id: .objectDiscovery,
                    requirement: .sharedRequired,
                    availability: .available,
                    limits: [
                        DatabaseCapabilityLimit(
                            name: "maximumPageRecords",
                            value: UInt64(maximumPageRecords),
                            unit: "records")
                    ]),
                DatabaseCapabilityStatus(
                    id: .browse,
                    requirement: .sharedRequired,
                    availability: .available,
                    limits: [
                        DatabaseCapabilityLimit(
                            name: "maximumValuePreviewBytes",
                            value: UInt64(maximumValueBytes),
                            unit: "bytes")
                    ]),
                DatabaseCapabilityStatus(
                    id: .query,
                    requirement: .familyRequired,
                    availability: .available,
                    attributes: [
                        DatabaseStringAttribute(
                            name: "allowlist",
                            value: "EXISTS,GET,HLEN,LLEN,PTTL,SCARD,STRLEN,TYPE,XLEN,ZCARD")
                    ]),
                DatabaseCapabilityStatus(
                    id: .queryCancellation,
                    requirement: .sharedRequired,
                    availability: .available),
                DatabaseCapabilityStatus(
                    id: .insert,
                    requirement: .sharedRequired,
                    availability: .available,
                    attributes: [
                        DatabaseStringAttribute(name: "types", value: "string")
                    ]),
                DatabaseCapabilityStatus(
                    id: .update,
                    requirement: .sharedRequired,
                    availability: .available,
                    attributes: [
                        DatabaseStringAttribute(name: "operations", value: "value,ttl")
                    ]),
                DatabaseCapabilityStatus(
                    id: .delete,
                    requirement: .sharedRequired,
                    availability: .available),
            ]
            + unavailable.map { identifier, requirement in
                DatabaseCapabilityStatus(
                    id: identifier,
                    requirement: requirement,
                    availability: .unavailable,
                    reason: unavailableReason)
            }
        return DatabaseCapabilityReport(
            productIdentity: identity,
            capabilities: capabilities,
            pagingModes: [.scanCursor],
            mutationModes: [.singleRecord],
            transactionModes: [.none],
            cancellationModes: [.cooperative],
            safetyLimitations: [
                "SCAN pages can contain duplicates or omit keys while the keyspace changes.",
                "Values and collection members are returned as bounded previews.",
                "Cancellation closes the session and requires reconnection.",
                "String key creation, value updates, TTL changes, and single-key deletion are supported with confirmation.",
                "Cluster, sentinel, TLS, tunnels, streaming, collection mutation, scripts, modules, transactions, pubsub, blocking operations, and arbitrary commands are unavailable.",
            ],
            discoveredAt: Date())
    }

    static func readPage(
        _ request: DatabaseAdapterPageRequest,
        connectionID: DatabaseConnectionID,
        logicalDatabase: String,
        product: DatabaseProduct,
        client: any RedisDatabaseClient,
        context: DatabaseAdapterOperationContext,
        deadline: Date
    ) async throws -> RedisDatabaseReadOutput {
        try validateReadRequest(
            request,
            connectionID: connectionID,
            logicalDatabase: logicalDatabase)
        var continuation = try continuationState(request.continuation)
        var keys: [Data] = []
        var seen = Set<Data>()
        var scanCalls = 0
        let limit = min(request.pageSize.value, maximumPageRecords)

        while keys.count < limit {
            try await check(context, deadline: deadline)
            if continuation.replay == nil, scanCalls > 0, continuation.cursor == 0 {
                break
            }
            guard scanCalls < maximumScanCallsPerPage else { break }
            let scanCursor = continuation.replay?.cursor ?? continuation.cursor
            let requestedCount =
                continuation.replay?.count
                ?? max(1, min(limit - keys.count, maximumPageRecords))
            let replayOffset = continuation.replay?.offset ?? 0
            let scan = try scanReply(
                try await client.execute(
                    .scan(cursor: scanCursor, count: requestedCount),
                    context: context,
                    deadline: deadline))
            scanCalls += 1
            continuation = RedisDatabaseContinuationPayload(
                version: 2,
                cursor: scan.cursor,
                replay: nil)
            var consumed = min(replayOffset, scan.keys.count)
            for key in scan.keys.dropFirst(consumed) {
                consumed += 1
                guard seen.insert(key).inserted else { continue }
                keys.append(key)
                if keys.count == limit {
                    if consumed < scan.keys.count {
                        continuation = RedisDatabaseContinuationPayload(
                            version: 2,
                            cursor: scan.cursor,
                            replay: RedisDatabaseScanReplay(
                                cursor: scanCursor,
                                count: requestedCount,
                                offset: consumed))
                    }
                    break
                }
            }
        }
        let records = try await inspectRecords(
            keys: keys,
            product: product,
            client: client,
            context: context,
            deadline: deadline)
        let next = try makeContinuation(continuation)
        return RedisDatabaseReadOutput(
            records: records,
            fields: fields,
            continuation: next,
            sampledValues: records.contains { record in
                record.metadata.contains { $0.value != "complete" }
            },
            scanTraversal: true)
    }

    static func query(
        _ request: DatabaseAdapterQueryRequest,
        connectionID: DatabaseConnectionID,
        logicalDatabase: String,
        product: DatabaseProduct,
        client: any RedisDatabaseClient,
        context: DatabaseAdapterOperationContext,
        deadline: Date
    ) async throws -> RedisDatabaseReadOutput {
        let key = try validateQueryRequest(
            request,
            connectionID: connectionID,
            logicalDatabase: logicalDatabase)
        try await check(context, deadline: deadline)
        let command = request.command.uppercased()
        let result: DatabaseValue
        switch command {
        case "GET":
            let type = try text(
                try await client.execute(.type(key), context: context, deadline: deadline))
            guard type == "string" || type == "none" else {
                throw invalidQuery
            }
            if type == "none" {
                result = .missing
            } else {
                let length = try nonnegative(
                    try await client.execute(
                        .stringLength(key),
                        context: context,
                        deadline: deadline))
                let bytes = try bytes(
                    try await client.execute(
                        .stringRange(key, maximumBytes: maximumValueBytes),
                        context: context,
                        deadline: deadline))
                result = scalar(
                    bytes,
                    totalByteCount: length,
                    maximumBytes: maximumValueBytes)
            }
        case "TYPE":
            result = .string(
                try text(
                    try await client.execute(
                        .type(key),
                        context: context,
                        deadline: deadline)))
        case "PTTL":
            result = .signedInteger(
                try integer(
                    try await client.execute(
                        .pttl(key),
                        context: context,
                        deadline: deadline)))
        case "EXISTS":
            result = .boolean(
                try integer(
                    try await client.execute(
                        .exists(key),
                        context: context,
                        deadline: deadline)) == 1)
        case "STRLEN":
            result = .unsignedInteger(
                try nonnegative(
                    try await client.execute(
                        .stringLength(key),
                        context: context,
                        deadline: deadline)))
        case "HLEN":
            result = .unsignedInteger(
                try nonnegative(
                    try await client.execute(
                        .hashLength(key),
                        context: context,
                        deadline: deadline)))
        case "LLEN":
            result = .unsignedInteger(
                try nonnegative(
                    try await client.execute(
                        .listLength(key),
                        context: context,
                        deadline: deadline)))
        case "SCARD":
            result = .unsignedInteger(
                try nonnegative(
                    try await client.execute(
                        .setCardinality(key),
                        context: context,
                        deadline: deadline)))
        case "ZCARD":
            result = .unsignedInteger(
                try nonnegative(
                    try await client.execute(
                        .sortedSetCardinality(key),
                        context: context,
                        deadline: deadline)))
        case "XLEN":
            result = .unsignedInteger(
                try nonnegative(
                    try await client.execute(
                        .streamLength(key),
                        context: context,
                        deadline: deadline)))
        default:
            throw unsafeQuery
        }
        try await check(context, deadline: deadline)
        let record = DatabaseRecord(
            identity: DatabaseRecordIdentity(
                kind: .key,
                components: [DatabaseIdentityComponent(name: "key", value: scalar(key))]),
            fields: [
                DatabaseObjectField(name: "key", value: scalar(key)),
                DatabaseObjectField(name: "result", value: result),
            ],
            metadata: [DatabaseStringAttribute(name: "command", value: command)])
        return RedisDatabaseReadOutput(
            records: [record],
            fields: queryFields,
            continuation: nil,
            sampledValues: command == "GET"
                && resultIsPreview(result),
            scanTraversal: false)
    }

    static func page(
        _ output: RedisDatabaseReadOutput,
        request: DatabaseAdapterPageRequest,
        startedAt: Date
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let bytes: Int
        do {
            bytes = try JSONEncoder().encode(output.records).count
        } catch {
            throw resultTooLarge
        }
        guard bytes <= DatabaseAdapterBounds.maximumPageBytes else {
            throw resultTooLarge
        }
        let incomplete = output.scanTraversal || output.continuation != nil || output.sampledValues
        let incompleteReason =
            output.scanTraversal
            ? "Redis-compatible SCAN traversal is weakly consistent."
            : "The returned value has additional bounded data."
        return try DatabaseAdapterPage(
            records: output.records,
            fields: output.fields,
            nextContinuation: output.continuation,
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(
                    state: incomplete ? .sampled : .complete,
                    reason: incomplete ? incompleteReason : nil),
                count: DatabaseCountMetadata(
                    value: output.scanTraversal ? nil : UInt64(output.records.count),
                    accuracy: output.scanTraversal ? .unknown : .exact),
                timing: DatabaseQueryTiming(
                    durationMilliseconds: UInt64(
                        max(0, Date().timeIntervalSince(startedAt) * 1_000))),
                bytesReceived: UInt64(bytes)))
    }

    private static let fields = [
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("key"),
            displayName: "Key",
            typeName: "bytes",
            isNullable: false,
            isSortable: false,
            isFilterable: false),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("type"),
            displayName: "Type",
            typeName: "string",
            isNullable: false,
            isSortable: false,
            isFilterable: false),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("ttlMilliseconds"),
            displayName: "TTL milliseconds",
            typeName: "int64",
            isNullable: false,
            isSortable: false,
            isFilterable: false),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("length"),
            displayName: "Length",
            typeName: "uint64",
            isNullable: true,
            isSortable: false,
            isFilterable: false),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("value"),
            displayName: "Value",
            typeName: "native",
            isNullable: true,
            isSortable: false,
            isFilterable: false),
    ]

    private static let queryFields = [
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("key"),
            displayName: "Key",
            typeName: "bytes",
            isNullable: false,
            isSortable: false,
            isFilterable: false),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("result"),
            displayName: "Result",
            typeName: "native",
            isNullable: true,
            isSortable: false,
            isFilterable: false),
    ]

    private static func validateReadRequest(
        _ request: DatabaseAdapterPageRequest,
        connectionID: DatabaseConnectionID,
        logicalDatabase: String
    ) throws(DatabaseAdapterFailure) {
        guard request.target.connectionID == connectionID,
            request.target.record == nil,
            let object = request.target.object,
            object.kind == .keyspace,
            object.nativeIdentifier == nil,
            object.path.isEmpty || object.path == [logicalDatabase],
            request.projection == nil,
            request.filter == nil,
            request.sorts.isEmpty,
            request.consistency == .productDefault
                || request.consistency == .bestEffort,
            request.continuation?.mode == .scanCursor || request.continuation == nil,
            request.continuation?.expiresAt.map({ $0 > Date() }) ?? true
        else {
            throw invalidRead
        }
    }

    private static func validateQueryRequest(
        _ request: DatabaseAdapterQueryRequest,
        connectionID: DatabaseConnectionID,
        logicalDatabase: String
    ) throws(DatabaseAdapterFailure) -> Data {
        let command = request.command
        let uppercased = command.uppercased()
        let allowlist: Set<String> = [
            "EXISTS", "GET", "HLEN", "LLEN", "PTTL", "SCARD", "STRLEN", "TYPE",
            "XLEN", "ZCARD",
        ]
        guard request.source.target.connectionID == connectionID,
            request.source.target.record == nil,
            let object = request.source.target.object,
            object.kind == .keyspace,
            object.nativeIdentifier == nil,
            object.path.isEmpty || object.path == [logicalDatabase],
            request.language == .redisCommand,
            command == command.trimmingCharacters(in: .whitespacesAndNewlines),
            !command.isEmpty,
            command.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte)
            }),
            allowlist.contains(uppercased),
            request.parameters.count == 1,
            request.parameters[0].name == nil || request.parameters[0].name == "key",
            request.body == nil,
            request.source.continuation == nil,
            request.source.projection == nil,
            request.source.filter == nil,
            request.source.sorts.isEmpty,
            request.source.consistency == .productDefault
                || request.source.consistency == .bestEffort
        else {
            if request.language == .redisCommand, !allowlist.contains(uppercased) {
                throw unsafeQuery
            }
            throw invalidQuery
        }
        let key: Data
        switch request.parameters[0].value {
        case let .string(value):
            key = Data(value.utf8)
        case let .binary(.complete(data, _, _)):
            key = data
        default:
            throw invalidQuery
        }
        guard key.count <= maximumKeyBytes else {
            throw invalidQuery
        }
        return key
    }

    private static func continuationState(
        _ continuation: DatabaseAdapterContinuation?
    ) throws(DatabaseAdapterFailure) -> RedisDatabaseContinuationPayload {
        guard let continuation else {
            return RedisDatabaseContinuationPayload(version: 2, cursor: 0, replay: nil)
        }
        guard continuation.mode == .scanCursor,
            continuation.expiresAt.map({ $0 > Date() }) ?? true,
            let state = try? JSONDecoder().decode(
                RedisDatabaseContinuationPayload.self,
                from: continuation.payload),
            state.version == 2,
            state.cursor != 0 || state.replay != nil,
            state.replay.map({ replay in
                replay.count > 0 && replay.count <= maximumPageRecords
                    && replay.offset > 0 && replay.offset <= maximumReplyElements
            }) ?? true
        else {
            throw invalidContinuation
        }
        return state
    }

    private static func makeContinuation(
        _ state: RedisDatabaseContinuationPayload
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterContinuation? {
        guard state.cursor != 0 || state.replay != nil else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(state),
            payload.count <= DatabaseAdapterBounds.maximumContinuationBytes
        else {
            throw resultTooLarge
        }
        return try DatabaseAdapterContinuation(mode: .scanCursor, payload: payload)
    }

    private static func inspectRecords(
        keys: [Data],
        product: DatabaseProduct,
        client: any RedisDatabaseClient,
        context: DatabaseAdapterOperationContext,
        deadline: Date
    ) async throws -> [DatabaseRecord] {
        guard !keys.isEmpty else { return [] }
        let metadataOperations = keys.flatMap {
            [RedisDatabaseOperation.type($0), .pttl($0)]
        }
        let metadataResults = try await client.executeBatch(
            metadataOperations,
            context: context,
            deadline: deadline)
        guard metadataResults.count == metadataOperations.count else {
            throw RedisDatabaseClientFailure.protocolFailure
        }
        var seeds: [(key: Data, type: String, ttl: Int64)] = []
        for index in keys.indices {
            seeds.append(
                (
                    keys[index],
                    try text(try commandReply(metadataResults[index * 2])),
                    try integer(try commandReply(metadataResults[index * 2 + 1]))
                ))
        }
        try await check(context, deadline: deadline)
        var valueOperations: [RedisDatabaseOperation] = []
        var ranges: [Range<Int>] = []
        for seed in seeds {
            let start = valueOperations.count
            valueOperations.append(contentsOf: inspectionOperations(type: seed.type, key: seed.key))
            ranges.append(start..<valueOperations.count)
        }
        let valueResults = try await client.executeBatch(
            valueOperations,
            context: context,
            deadline: deadline)
        guard valueResults.count == valueOperations.count else {
            throw RedisDatabaseClientFailure.protocolFailure
        }
        try await check(context, deadline: deadline)
        return try zip(seeds, ranges).map { seed, range in
            let inspected = try inspectValue(
                type: seed.type,
                product: product,
                results: valueResults[range])
            let fields = [
                DatabaseObjectField(name: "key", value: scalar(seed.key)),
                DatabaseObjectField(name: "type", value: .string(seed.type)),
                DatabaseObjectField(
                    name: "ttlMilliseconds",
                    value: .signedInteger(seed.type == "none" ? -2 : seed.ttl)),
                DatabaseObjectField(
                    name: "length",
                    value: inspected.length.map(DatabaseValue.unsignedInteger) ?? .null),
                DatabaseObjectField(name: "value", value: inspected.value),
            ]
            return DatabaseRecord(
                identity: DatabaseRecordIdentity(
                    kind: .key,
                    components: [
                        DatabaseIdentityComponent(name: "key", value: scalar(seed.key))
                    ]),
                fields: fields,
                metadata: [
                    DatabaseStringAttribute(
                        name: "valueCompleteness",
                        value: inspected.completeness)
                ])
        }
    }

    private static func inspectionOperations(
        type: String,
        key: Data
    ) -> [RedisDatabaseOperation] {
        switch type {
        case "string":
            [.stringLength(key), .stringRange(key, maximumBytes: maximumValueBytes)]
        case "hash":
            [.hashLength(key), .hashScan(key, count: maximumCollectionEntries)]
        case "list":
            [.listLength(key), .listRange(key, count: maximumCollectionEntries)]
        case "set":
            [.setCardinality(key), .setScan(key, count: maximumCollectionEntries)]
        case "zset":
            [
                .sortedSetCardinality(key),
                .sortedSetRange(key, count: maximumCollectionEntries),
            ]
        case "stream":
            [.streamLength(key), .streamRange(key, count: maximumCollectionEntries)]
        default:
            []
        }
    }

    private static func inspectValue(
        type: String,
        product: DatabaseProduct,
        results: ArraySlice<RedisDatabaseCommandResult>
    ) throws -> RedisDatabaseInspectedValue {
        if results.contains(where: { result in
            if case .failure(.wrongType) = result { return true }
            return false
        }) {
            return unavailableValue(type: type, product: product)
        }
        let replies = try results.map(commandReply)
        switch type {
        case "none":
            return RedisDatabaseInspectedValue(
                value: .missing,
                length: nil,
                completeness: "complete")
        case "string":
            guard replies.count == 2 else { throw RedisDatabaseClientFailure.protocolFailure }
            let length = try nonnegative(replies[0])
            let data = try bytes(replies[1])
            return RedisDatabaseInspectedValue(
                value: scalar(data, totalByteCount: length),
                length: length,
                completeness: length > UInt64(data.count) ? "truncated" : "complete")
        case "hash":
            guard replies.count == 2 else { throw RedisDatabaseClientFailure.protocolFailure }
            let pairs = try paired(collectionScanReply(replies[1]).values)
                .sorted { $0.0.lexicographicallyPrecedes($1.0) }
            return RedisDatabaseInspectedValue(
                value: boundedPairs(pairs, firstName: "field", secondName: "value"),
                length: try nonnegative(replies[0]),
                completeness: "sampled")
        case "list":
            guard replies.count == 2 else { throw RedisDatabaseClientFailure.protocolFailure }
            return RedisDatabaseInspectedValue(
                value: boundedArray(try byteArray(replies[1])),
                length: try nonnegative(replies[0]),
                completeness: "sampled")
        case "set":
            guard replies.count == 2 else { throw RedisDatabaseClientFailure.protocolFailure }
            let values = try collectionScanReply(replies[1]).values.sorted {
                $0.lexicographicallyPrecedes($1)
            }
            return RedisDatabaseInspectedValue(
                value: boundedArray(values),
                length: try nonnegative(replies[0]),
                completeness: "sampled")
        case "zset":
            guard replies.count == 2 else { throw RedisDatabaseClientFailure.protocolFailure }
            return RedisDatabaseInspectedValue(
                value: boundedPairs(
                    try paired(byteArray(replies[1])),
                    firstName: "member",
                    secondName: "score"),
                length: try nonnegative(replies[0]),
                completeness: "sampled")
        case "stream":
            guard replies.count == 2 else { throw RedisDatabaseClientFailure.protocolFailure }
            return RedisDatabaseInspectedValue(
                value: boundedStream(try streamEntries(replies[1])),
                length: try nonnegative(replies[0]),
                completeness: "sampled")
        default:
            return unavailableValue(type: type, product: product)
        }
    }

    private static func unavailableValue(
        type: String,
        product: DatabaseProduct
    ) -> RedisDatabaseInspectedValue {
        RedisDatabaseInspectedValue(
            value: .productSpecific(
                DatabaseProductValue(
                    product: product,
                    typeName: type,
                    attributes: [
                        DatabaseStringAttribute(name: "retrieval", value: "unavailable")
                    ])),
            length: nil,
            completeness: "unavailable")
    }

    private static func commandReply(
        _ result: RedisDatabaseCommandResult
    ) throws -> RedisDatabaseReply {
        switch result {
        case let .reply(reply):
            return reply
        case let .failure(failure):
            throw failure
        }
    }

    private static func boundedArray(_ values: [Data]) -> DatabaseValue {
        var remaining = maximumValueBytes
        var output: [DatabaseValue] = []
        for value in values where remaining > 0 {
            let available = min(value.count, remaining)
            output.append(
                scalar(
                    Data(value.prefix(available)),
                    totalByteCount: UInt64(value.count),
                    maximumBytes: available))
            remaining -= available
        }
        return .array(output)
    }

    private static func boundedPairs(
        _ pairs: [(Data, Data)],
        firstName: String,
        secondName: String
    ) -> DatabaseValue {
        var remaining = maximumValueBytes
        var output: [DatabaseValue] = []
        for pair in pairs where remaining > 0 {
            let firstCount = min(pair.0.count, remaining)
            remaining -= firstCount
            let secondCount = min(pair.1.count, remaining)
            remaining -= secondCount
            output.append(
                .object([
                    DatabaseObjectField(
                        name: firstName,
                        value: scalar(
                            Data(pair.0.prefix(firstCount)),
                            totalByteCount: UInt64(pair.0.count),
                            maximumBytes: firstCount)),
                    DatabaseObjectField(
                        name: secondName,
                        value: scalar(
                            Data(pair.1.prefix(secondCount)),
                            totalByteCount: UInt64(pair.1.count),
                            maximumBytes: secondCount)),
                ]))
        }
        return .array(output)
    }

    private static func boundedStream(
        _ entries: [(Data, [(Data, Data)])]
    ) -> DatabaseValue {
        var remaining = maximumValueBytes
        var output: [DatabaseValue] = []
        for entry in entries where remaining > 0 {
            let identifierCount = min(entry.0.count, remaining)
            remaining -= identifierCount
            var fields: [DatabaseValue] = []
            for pair in entry.1 where remaining > 0 {
                let fieldCount = min(pair.0.count, remaining)
                remaining -= fieldCount
                let valueCount = min(pair.1.count, remaining)
                remaining -= valueCount
                fields.append(
                    .object([
                        DatabaseObjectField(
                            name: "field",
                            value: scalar(
                                Data(pair.0.prefix(fieldCount)),
                                totalByteCount: UInt64(pair.0.count),
                                maximumBytes: fieldCount)),
                        DatabaseObjectField(
                            name: "value",
                            value: scalar(
                                Data(pair.1.prefix(valueCount)),
                                totalByteCount: UInt64(pair.1.count),
                                maximumBytes: valueCount)),
                    ]))
            }
            output.append(
                .object([
                    DatabaseObjectField(
                        name: "id",
                        value: scalar(
                            Data(entry.0.prefix(identifierCount)),
                            totalByteCount: UInt64(entry.0.count),
                            maximumBytes: identifierCount)),
                    DatabaseObjectField(name: "fields", value: .array(fields)),
                ]))
        }
        return .array(output)
    }

    private static func scalar(
        _ data: Data,
        totalByteCount: UInt64? = nil,
        maximumBytes: Int = maximumValueBytes
    ) -> DatabaseValue {
        let total = totalByteCount ?? UInt64(data.count)
        let prefix = Data(data.prefix(maximumBytes))
        if total <= UInt64(prefix.count), let string = String(data: prefix, encoding: .utf8) {
            return .string(string)
        }
        if total <= UInt64(prefix.count) {
            return .binary(.complete(data: prefix, mediaType: nil, digest: nil))
        }
        return .binary(
            .preview(
                byteCount: total,
                bytes: prefix,
                mediaType: nil,
                digest: nil))
    }

    private static func resultIsPreview(_ value: DatabaseValue) -> Bool {
        if case .binary(.preview) = value { return true }
        return false
    }

    private static func scanReply(
        _ reply: RedisDatabaseReply
    ) throws -> (cursor: UInt64, keys: [Data]) {
        guard case let .array(parts) = reply,
            parts.count == 2,
            let cursor = try? unsigned(parts[0]),
            case let .array(values) = parts[1]
        else {
            throw readFailed
        }
        let keys = try values.map(bytes)
        guard keys.count <= maximumReplyElements,
            keys.allSatisfy({ $0.count <= maximumKeyBytes })
        else {
            throw resultTooLarge
        }
        return (cursor, keys)
    }

    private static func collectionScanReply(
        _ reply: RedisDatabaseReply
    ) throws -> (cursor: UInt64, values: [Data]) {
        guard case let .array(parts) = reply,
            parts.count == 2,
            let cursor = try? unsigned(parts[0]),
            case let .array(values) = parts[1]
        else {
            throw readFailed
        }
        return (cursor, try values.map(bytes))
    }

    private static func streamEntries(
        _ reply: RedisDatabaseReply
    ) throws -> [(Data, [(Data, Data)])] {
        guard case let .array(entries) = reply else { throw readFailed }
        return try entries.map { entry in
            guard case let .array(parts) = entry,
                parts.count == 2,
                case let .array(fields) = parts[1]
            else {
                throw readFailed
            }
            return (try bytes(parts[0]), try paired(fields.map(bytes)))
        }
    }

    private static func paired(_ values: [RedisDatabaseReply]) throws -> [(Data, Data)] {
        try paired(values.map(bytes))
    }

    private static func paired(_ values: [Data]) throws -> [(Data, Data)] {
        guard values.count.isMultiple(of: 2) else {
            throw RedisDatabaseClientFailure.protocolFailure
        }
        return stride(from: 0, to: values.count, by: 2).map {
            (values[$0], values[$0 + 1])
        }
    }

    private static func byteArray(
        _ reply: RedisDatabaseReply
    ) throws(DatabaseAdapterFailure) -> [Data] {
        guard case let .array(values) = reply else { throw readFailed }
        do {
            return try values.map(bytes)
        } catch {
            throw readFailed
        }
    }

    private static func info(
        _ reply: RedisDatabaseReply
    ) throws -> [String: String] {
        let data = try bytes(reply)
        guard data.count <= maximumRawReplyBytes,
            let text = String(data: data, encoding: .utf8)
        else {
            throw RedisDatabaseClientFailure.protocolFailure
        }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            guard key.utf8.count <= 128, value.utf8.count <= 4_096 else {
                throw RedisDatabaseClientFailure.responseTooLarge
            }
            result[key] = value
        }
        return result
    }

    private static func bytes(_ reply: RedisDatabaseReply) throws -> Data {
        guard case let .bytes(data) = reply else {
            throw RedisDatabaseClientFailure.protocolFailure
        }
        return data
    }

    private static func text(_ reply: RedisDatabaseReply) throws -> String {
        let data = try bytes(reply)
        guard let string = String(data: data, encoding: .utf8),
            string.utf8.count <= 4_096
        else {
            throw RedisDatabaseClientFailure.protocolFailure
        }
        return string
    }

    private static func integer(_ reply: RedisDatabaseReply) throws -> Int64 {
        if case let .integer(value) = reply { return value }
        let data = try bytes(reply)
        guard let text = String(data: data, encoding: .ascii),
            let value = Int64(text)
        else {
            throw RedisDatabaseClientFailure.protocolFailure
        }
        return value
    }

    private static func nonnegative(_ reply: RedisDatabaseReply) throws -> UInt64 {
        let value = try integer(reply)
        guard value >= 0 else { throw RedisDatabaseClientFailure.protocolFailure }
        return UInt64(value)
    }

    private static func unsigned(_ reply: RedisDatabaseReply) throws -> UInt64 {
        if case let .integer(value) = reply, value >= 0 { return UInt64(value) }
        let data = try bytes(reply)
        guard let text = String(data: data, encoding: .ascii),
            let value = UInt64(text)
        else {
            throw RedisDatabaseClientFailure.protocolFailure
        }
        return value
    }

    private static func credentials(
        definition: DatabaseConnectionDefinition,
        resolvedSecrets: [DatabaseSecretReference: Data]
    ) throws(DatabaseAdapterFailure) -> (username: String?, password: String?) {
        guard definition.authentication.source == nil,
            Set(definition.authentication.secretReferences) == Set(resolvedSecrets.keys)
        else {
            throw invalidConnection
        }
        switch definition.authentication.kind {
        case .none:
            guard definition.username == nil,
                definition.authentication.secretReferences.isEmpty,
                resolvedSecrets.isEmpty
            else {
                throw invalidConnection
            }
            return (nil, nil)
        case .password, .usernameAndPassword:
            guard definition.authentication.secretReferences.count == 1,
                let reference = definition.authentication.secretReferences.first,
                reference.purpose == .password,
                let secret = resolvedSecrets[reference],
                !secret.isEmpty,
                secret.count <= 4_096,
                let password = String(data: secret, encoding: .utf8),
                !password.contains("\0")
            else {
                throw invalidConnection
            }
            if definition.authentication.kind == .password {
                guard definition.username == nil else { throw invalidConnection }
                return (nil, password)
            }
            guard let username = definition.username,
                !username.isEmpty,
                username.utf8.count <= 256,
                !username.contains("\0")
            else {
                throw invalidConnection
            }
            return (username, password)
        default:
            throw invalidConnection
        }
    }

    private static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253
            && host.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte)
                    || (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 58
            }
    }

    private static func bounded(_ value: String?, maximumBytes: Int) -> String? {
        guard let value, value.utf8.count <= maximumBytes else { return nil }
        return value
    }
}
