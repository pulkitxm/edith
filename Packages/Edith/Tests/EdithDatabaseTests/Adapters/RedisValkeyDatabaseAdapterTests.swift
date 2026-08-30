import Foundation
import NIOCore
import NIOPosix
@preconcurrency import RediStack
import Testing

@testable import EdithDatabase

private enum RedisValkeyAdapterFixtures {
    static func definition(
        product: DatabaseProduct = .redis,
        location: DatabaseConnectionLocation? = nil,
        username: String? = nil,
        logicalDatabase: String? = nil,
        deploymentMode: DatabaseDeploymentMode = .automatic,
        authentication: DatabaseAuthentication = DatabaseAuthentication(kind: .none),
        tls: DatabaseTLSConfiguration = DatabaseTLSConfiguration(
            mode: .disabled,
            verification: .none),
        tunnel: DatabaseTunnelDefinition? = nil,
        poolSize: Int = 1,
        options: [DatabaseNonSecretOption] = []
    ) throws -> DatabaseConnectionDefinition {
        let resolvedLocation: DatabaseConnectionLocation
        if let location {
            resolvedLocation = location
        } else {
            resolvedLocation = .network([
                DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: try DatabasePort(product == .redis ? 56_379 : 56_380))
            ])
        }
        return DatabaseConnectionDefinition(
            id: DatabaseConnectionID(),
            displayName: "\(product.displayName) fixture",
            productHint: product,
            location: resolvedLocation,
            username: username,
            namespaces: DatabaseNamespaceDefaults(logicalDatabase: logicalDatabase),
            deploymentMode: deploymentMode,
            authentication: authentication,
            tls: tls,
            tunnel: tunnel,
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 2_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 2_000),
                poolSize: try DatabasePoolSize(poolSize)),
            readOnlyPolicy: .required,
            productionPolicy: .prohibitMutations,
            environment: DatabaseEnvironmentMetadata(
                kind: .testing,
                label: "Testing",
                protection: .readOnly),
            options: options,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func resolved(
        _ definition: DatabaseConnectionDefinition,
        secrets: [DatabaseSecretReference: Data] = [:]
    ) throws(DatabaseAdapterFailure) -> DatabaseResolvedConnection {
        try DatabaseResolvedConnection(definition: definition, secrets: secrets)
    }

    static func context(
        operationID: DatabaseOperationID = DatabaseOperationID(),
        deadline: Date? = nil,
        cancellation: DatabaseAdapterCancellationSignal = DatabaseAdapterCancellationSignal()
    ) -> DatabaseAdapterOperationContext {
        DatabaseAdapterOperationContext(
            operation: DatabaseOperationContext(
                operationID: operationID,
                deadline: deadline),
            cancellation: cancellation)
    }

    static func target(_ connectionID: DatabaseConnectionID) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: .keyspace, path: ["0"]))
    }

    static func pageRequest(
        _ connectionID: DatabaseConnectionID,
        pageSize: Int = 25,
        continuation: DatabaseAdapterContinuation? = nil,
        projection: DatabaseProjection? = nil,
        filter: DatabaseFilter? = nil,
        sorts: [DatabaseSort] = []
    ) throws -> DatabaseAdapterPageRequest {
        try DatabaseAdapterPageRequest(
            target: target(connectionID),
            page: DatabasePageRequest(
                pageSize: try DatabasePageSize(pageSize),
                projection: projection,
                filter: filter,
                sorts: sorts),
            continuation: continuation)
    }

    static func queryRequest(
        _ connectionID: DatabaseConnectionID,
        command: String,
        key: DatabaseValue = .string("key"),
        parameterName: String? = "key"
    ) throws -> DatabaseAdapterQueryRequest {
        try DatabaseAdapterQueryRequest(
            request: DatabaseQueryRequest(
                target: target(connectionID),
                language: .redisCommand,
                command: command,
                parameters: [DatabaseQueryParameter(name: parameterName, value: key)],
                page: DatabasePageRequest(pageSize: try DatabasePageSize(1))),
            continuation: nil)
    }

    static func envelope(
        _ operation: () async throws -> Void
    ) async -> DatabaseErrorEnvelope? {
        do {
            try await operation()
            return nil
        } catch let failure as DatabaseAdapterFailure {
            if case let .reported(envelope) = failure {
                return envelope
            }
            return nil
        } catch {
            return nil
        }
    }

    static func field(_ name: String, in record: DatabaseRecord) -> DatabaseValue? {
        record.fields.first(where: { $0.name == name })?.value
    }
}

private func waitForCancellationObserversToDrain(
    _ cancellation: DatabaseAdapterCancellationSignal
) async -> Bool {
    for _ in 0..<2_000 {
        if await cancellation.registeredEventStreamCount() == 0 { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

private enum FakeRedisValue: Sendable {
    case string(Data)
    case hash([(Data, Data)])
    case list([Data])
    case set([Data])
    case sortedSet([(Data, Data)])
    case stream([(Data, [(Data, Data)])])
    case unknown(String)

    var type: String {
        switch self {
        case .string:
            "string"
        case .hash:
            "hash"
        case .list:
            "list"
        case .set:
            "set"
        case .sortedSet:
            "zset"
        case .stream:
            "stream"
        case let .unknown(type):
            type
        }
    }
}

private actor FakeRedisClient: RedisDatabaseClient {
    let product: DatabaseProduct
    var values: [Data: FakeRedisValue]
    var ttls: [Data: Int64]
    var operations: [RedisDatabaseReadOperation] = []
    var closed = false
    var pauseOnScan = false
    var scanPaused = false
    var scanContinuation: CheckedContinuation<Void, Never>?
    let scanExtraKeys: Int

    init(
        product: DatabaseProduct,
        values: [Data: FakeRedisValue] = [:],
        ttls: [Data: Int64] = [:],
        scanExtraKeys: Int = 0
    ) {
        self.product = product
        self.values = values
        self.ttls = ttls
        self.scanExtraKeys = scanExtraKeys
    }

    func execute(
        _ operation: RedisDatabaseReadOperation,
        context _: DatabaseAdapterOperationContext,
        deadline _: Date
    ) async throws -> RedisDatabaseReply {
        guard !closed else { throw RedisDatabaseClientFailure.connection }
        operations.append(operation)
        switch operation {
        case .ping:
            return .bytes(Data("PONG".utf8))
        case let .info(section):
            return .bytes(info(section))
        case let .scan(cursor, count):
            if pauseOnScan {
                scanPaused = true
                await withCheckedContinuation { continuation in
                    scanContinuation = continuation
                }
                guard !closed else { throw RedisDatabaseClientFailure.connection }
            }
            let keys = values.keys.sorted(by: { $0.lexicographicallyPrecedes($1) })
            let start = min(Int(cursor), keys.count)
            let end = min(start + count + scanExtraKeys, keys.count)
            let next = end == keys.count ? UInt64(0) : UInt64(end)
            return .array([
                .bytes(Data(next.description.utf8)),
                .array(keys[start..<end].map(RedisDatabaseReply.bytes)),
            ])
        case let .type(key):
            return .bytes(Data((values[key]?.type ?? "none").utf8))
        case let .pttl(key):
            return .integer(values[key] == nil ? -2 : ttls[key] ?? -1)
        case let .exists(key):
            return .integer(values[key] == nil ? 0 : 1)
        case let .stringLength(key):
            guard case let .string(value) = values[key] else { return .integer(0) }
            return .integer(Int64(value.count))
        case let .stringRange(key, maximumBytes):
            guard case let .string(value) = values[key] else { return .bytes(Data()) }
            return .bytes(Data(value.prefix(maximumBytes)))
        case let .hashLength(key):
            guard case let .hash(value) = values[key] else { return .integer(0) }
            return .integer(Int64(value.count))
        case let .hashScan(key, count):
            guard case let .hash(value) = values[key] else {
                return .array([.bytes(Data("0".utf8)), .array([])])
            }
            let sample = Array(value.prefix(count))
            return .array([
                .bytes(Data(value.count > sample.count ? "1".utf8 : "0".utf8)),
                .array(sample.flatMap { [.bytes($0.0), .bytes($0.1)] }),
            ])
        case let .listLength(key):
            guard case let .list(value) = values[key] else { return .integer(0) }
            return .integer(Int64(value.count))
        case let .listRange(key, count):
            guard case let .list(value) = values[key] else { return .array([]) }
            return .array(value.prefix(count).map(RedisDatabaseReply.bytes))
        case let .setCardinality(key):
            guard case let .set(value) = values[key] else { return .integer(0) }
            return .integer(Int64(value.count))
        case let .setScan(key, count):
            guard case let .set(value) = values[key] else {
                return .array([.bytes(Data("0".utf8)), .array([])])
            }
            let sample = Array(value.prefix(count))
            return .array([
                .bytes(Data(value.count > sample.count ? "1".utf8 : "0".utf8)),
                .array(sample.map(RedisDatabaseReply.bytes)),
            ])
        case let .sortedSetCardinality(key):
            guard case let .sortedSet(value) = values[key] else { return .integer(0) }
            return .integer(Int64(value.count))
        case let .sortedSetRange(key, count):
            guard case let .sortedSet(value) = values[key] else { return .array([]) }
            return .array(
                value.prefix(count).flatMap { [.bytes($0.0), .bytes($0.1)] })
        case let .streamLength(key):
            guard case let .stream(value) = values[key] else { return .integer(0) }
            return .integer(Int64(value.count))
        case let .streamRange(key, count):
            guard case let .stream(value) = values[key] else { return .array([]) }
            return .array(
                value.prefix(count).map { entry in
                    .array([
                        .bytes(entry.0),
                        .array(entry.1.flatMap { [.bytes($0.0), .bytes($0.1)] }),
                    ])
                })
        }
    }

    func close() {
        closed = true
        scanContinuation?.resume()
        scanContinuation = nil
    }

    func setPauseOnScan(_ value: Bool) {
        pauseOnScan = value
    }

    func snapshot() -> [RedisDatabaseReadOperation] {
        operations
    }

    func isClosed() -> Bool {
        closed
    }

    func isScanPaused() -> Bool {
        scanPaused
    }

    private func info(_ section: String) -> Data {
        switch section {
        case "server":
            if product == .valkey {
                return Data(
                    "valkey_version:9.1.1\r\nredis_version:7.2.4\r\nserver_mode:standalone\r\nrun_id:valkey-fixture\r\n"
                        .utf8)
            }
            return Data(
                "redis_version:8.10.0\r\nredis_mode:standalone\r\nrun_id:redis-fixture\r\n"
                    .utf8)
        case "replication":
            return Data("role:master\r\nconnected_slaves:0\r\n".utf8)
        default:
            return Data("cluster_enabled:0\r\n".utf8)
        }
    }
}

private actor FakeRedisClientFactory: RedisDatabaseClientFactory {
    let client: FakeRedisClient
    var plans: [RedisDatabaseConnectionPlan] = []

    init(client: FakeRedisClient) {
        self.client = client
    }

    func connect(
        _ plan: RedisDatabaseConnectionPlan,
        context _: DatabaseAdapterConnectionContext,
        deadline _: Date
    ) async throws -> any RedisDatabaseClient {
        plans.append(plan)
        return client
    }

    func lastPlan() -> RedisDatabaseConnectionPlan? {
        plans.last
    }

    func connectionCount() -> Int {
        plans.count
    }
}

private enum RedisHostileServerBehavior: Sendable {
    case connectedReplicaCount(String)
    case noAuthentication
    case oversizedArray
    case oversizedBulk
    case oversizedScan
    case replica
    case rejectAuthentication
    case valkeySentinel
    case stall(String)
}

private final class RedisHostileServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var commands: [String] = []

    func opened(_ channel: Channel) {
        lock.lock()
        channels[ObjectIdentifier(channel)] = channel
        lock.unlock()
    }

    func closed(_ channel: Channel) {
        lock.lock()
        channels.removeValue(forKey: ObjectIdentifier(channel))
        lock.unlock()
    }

    func received(_ command: String) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func contains(_ command: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return commands.contains(command)
    }

    func activeConnectionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return channels.count
    }

    func closeAll() -> [EventLoopFuture<Void>] {
        lock.lock()
        let channels = Array(channels.values)
        self.channels.removeAll()
        lock.unlock()
        return channels.map { $0.close(mode: .all) }
    }
}

private final class RedisHostileServerHandler: ChannelInboundHandler {
    typealias InboundIn = RESPValue

    private let behavior: RedisHostileServerBehavior
    private let state: RedisHostileServerState

    init(behavior: RedisHostileServerBehavior, state: RedisHostileServerState) {
        self.behavior = behavior
        self.state = state
    }

    func channelActive(context: ChannelHandlerContext) {
        state.opened(context.channel)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.closed(context.channel)
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case let .array(parts) = unwrapInboundIn(data),
            let command = parts.first.flatMap(text)?.uppercased()
        else {
            context.close(mode: .all, promise: nil)
            return
        }
        state.received(command)
        if case let .stall(stalled) = behavior, command == stalled {
            return
        }
        switch (behavior, command) {
        case (.rejectAuthentication, "AUTH"):
            write("-WRONGPASS invalid username-password pair\r\n", context: context)
        case (.noAuthentication, "PING"):
            write("-NOAUTH Authentication required\r\n", context: context)
        case (.oversizedBulk, "PING"):
            write("$1048577\r\n", context: context)
        case (.oversizedArray, "PING"):
            write("*4097\r\n", context: context)
        case (.oversizedScan, "SCAN"):
            write("$1048577\r\n", context: context)
        case (_, "AUTH"), (_, "SELECT"):
            write("+OK\r\n", context: context)
        case (_, "PING"):
            write("+PONG\r\n", context: context)
        case (_, "INFO"):
            let section = parts.dropFirst().first.flatMap(text) ?? ""
            let payload: String
            switch section {
            case "server":
                if case .valkeySentinel = behavior {
                    payload =
                        "valkey_version:9.1.1\r\nredis_version:7.2.4\r\nserver_mode:sentinel\r\nrun_id:hostile-fixture\r\n"
                } else {
                    payload =
                        "redis_version:8.10.0\r\nredis_mode:standalone\r\nrun_id:hostile-fixture\r\n"
                }
            case "replication":
                if case let .connectedReplicaCount(count) = behavior {
                    payload = "role:master\r\nconnected_slaves:\(count)\r\n"
                } else if case .replica = behavior {
                    payload = "role:replica\r\nconnected_slaves:0\r\n"
                } else {
                    payload = "role:master\r\nconnected_slaves:0\r\n"
                }
            default:
                payload = "cluster_enabled:0\r\n"
            }
            write("$\(payload.utf8.count)\r\n\(payload)\r\n", context: context)
        case (_, "SCAN"):
            write("*2\r\n$1\r\n0\r\n*0\r\n", context: context)
        default:
            write("-ERR unsupported\r\n", context: context)
        }
    }

    private func text(_ value: RESPValue) -> String? {
        let buffer: ByteBuffer
        switch value {
        case let .simpleString(value), let .bulkString(.some(value)):
            buffer = value
        default:
            return nil
        }
        return buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
    }

    private func write(_ value: String, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: value.utf8.count)
        buffer.writeString(value)
        context.channel.writeAndFlush(buffer, promise: nil)
    }
}

private final class RedisHostileServer: @unchecked Sendable {
    let state: RedisHostileServerState
    let port: Int

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(
        state: RedisHostileServerState,
        port: Int,
        group: MultiThreadedEventLoopGroup,
        channel: Channel
    ) {
        self.state = state
        self.port = port
        self.group = group
        self.channel = channel
    }

    static func withServer<Output: Sendable>(
        behavior: RedisHostileServerBehavior,
        operation: (RedisHostileServer) async throws -> Output
    ) async throws -> Output {
        let server = try await start(behavior: behavior)
        do {
            let output = try await operation(server)
            await server.stop()
            return output
        } catch {
            await server.stop()
            throw error
        }
    }

    func waitForCommand(_ command: String) async -> Bool {
        for _ in 0..<2_000 {
            if state.contains(command) { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    func waitUntilClosed() async -> Bool {
        for _ in 0..<2_000 {
            if state.activeConnectionCount() == 0 { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    private static func start(
        behavior: RedisHostileServerBehavior
    ) async throws -> RedisHostileServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let state = RedisHostileServerState()
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 8)
                .childChannelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandlers([
                            ByteToMessageHandler(RedisByteDecoder()),
                            RedisHostileServerHandler(behavior: behavior, state: state),
                        ])
                        return channel.eventLoop.makeSucceededFuture(())
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            guard let port = channel.localAddress?.port else {
                try? await channel.close(mode: .all).get()
                try await group.shutdownGracefully()
                throw RedisDatabaseClientFailure.connection
            }
            return RedisHostileServer(
                state: state,
                port: port,
                group: group,
                channel: channel)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func stop() async {
        for future in state.closeAll() {
            try? await future.get()
        }
        try? await channel.close(mode: .all).get()
        try? await group.shutdownGracefully()
    }
}

@Suite("Redis and Valkey adapter")
struct RedisValkeyDatabaseAdapterTests {
    @Test("connects with resolved authentication and discovers exact products")
    func authenticationAndIdentity() async throws {
        for product in [DatabaseProduct.redis, .valkey] {
            let secretReference = DatabaseSecretReference(
                identifier: UUID(),
                purpose: .password)
            let definition = try RedisValkeyAdapterFixtures.definition(
                product: product,
                logicalDatabase: "3",
                authentication: DatabaseAuthentication(
                    kind: .password,
                    secretReferences: [secretReference]))
            let client = FakeRedisClient(product: product)
            let factory = FakeRedisClientFactory(client: client)
            let session = try await RedisValkeyDatabaseAdapter(clientFactory: factory).connect(
                try RedisValkeyAdapterFixtures.resolved(
                    definition,
                    secrets: [secretReference: Data("fixture-secret".utf8)]),
                context: RedisValkeyAdapterFixtures.context())
            #expect(session.productIdentity.product == product)
            #expect(
                session.productIdentity.version?.string == (product == .redis ? "8.10.0" : "9.1.1"))
            #expect(session.productIdentity.topology.kind == .standalone)
            let plan = await factory.lastPlan()
            #expect(plan?.password == "fixture-secret")
            #expect(plan?.database == 3)
            #expect(plan?.username == nil)
            await session.disconnect()
            #expect(await client.isClosed())
        }
    }

    @Test("rejects invalid product, location, security, and authentication before dialing")
    func invalidConnections() async throws {
        let client = FakeRedisClient(product: .redis)
        let factory = FakeRedisClientFactory(client: client)
        let adapter = RedisValkeyDatabaseAdapter(clientFactory: factory)
        let invalid = [
            try RedisValkeyAdapterFixtures.definition(product: .sqlite),
            try RedisValkeyAdapterFixtures.definition(location: .memory(name: nil)),
            try RedisValkeyAdapterFixtures.definition(
                tls: DatabaseTLSConfiguration(mode: .required, verification: .full)),
            try RedisValkeyAdapterFixtures.definition(deploymentMode: .cluster),
            try RedisValkeyAdapterFixtures.definition(poolSize: 2),
            try RedisValkeyAdapterFixtures.definition(
                options: [DatabaseNonSecretOption(name: "ignored", value: .boolean(true))]),
        ]
        for definition in invalid {
            let envelope = await RedisValkeyAdapterFixtures.envelope {
                _ = try await adapter.connect(
                    try RedisValkeyAdapterFixtures.resolved(definition),
                    context: RedisValkeyAdapterFixtures.context())
            }
            #expect(envelope?.productCode == "redis.connection.invalid")
        }
        #expect(await factory.connectionCount() == 0)
    }

    @Test("rejects oversized partial RESP frames before decoding")
    func hostileResponseBounds() async throws {
        for behavior in [
            RedisHostileServerBehavior.oversizedBulk,
            RedisHostileServerBehavior.oversizedArray,
        ] {
            try await RedisHostileServer.withServer(behavior: behavior) { server in
                let definition = try RedisValkeyAdapterFixtures.definition(
                    location: .network([
                        DatabaseNetworkEndpoint(
                            host: "127.0.0.1", port: try DatabasePort(server.port))
                    ]))
                let envelope = await RedisValkeyAdapterFixtures.envelope {
                    _ = try await RedisValkeyDatabaseAdapter().connect(
                        try RedisValkeyAdapterFixtures.resolved(definition),
                        context: RedisValkeyAdapterFixtures.context(
                            deadline: Date(timeIntervalSinceNow: 1)))
                }
                #expect(envelope?.productCode == "redis.result.too_large")
                #expect(await server.waitUntilClosed())
            }
        }
    }

    @Test("rejects hostile identity metadata without overflow or topology bypass")
    func hostileIdentityMetadata() async throws {
        let cases: [(RedisHostileServerBehavior, DatabaseProduct, String)] = [
            (.connectedReplicaCount(String(Int.max)), .redis, "redis.connection.failed"),
            (.valkeySentinel, .valkey, "redis.topology.unsupported"),
        ]
        for (behavior, product, expectedCode) in cases {
            try await RedisHostileServer.withServer(behavior: behavior) { server in
                let definition = try RedisValkeyAdapterFixtures.definition(
                    product: product,
                    location: .network([
                        DatabaseNetworkEndpoint(
                            host: "127.0.0.1", port: try DatabasePort(server.port))
                    ]))
                let envelope = await RedisValkeyAdapterFixtures.envelope {
                    _ = try await RedisValkeyDatabaseAdapter().connect(
                        try RedisValkeyAdapterFixtures.resolved(definition),
                        context: RedisValkeyAdapterFixtures.context(
                            deadline: Date(timeIntervalSinceNow: 1)))
                }
                #expect(envelope?.productCode == expectedCode)
                #expect(await server.waitUntilClosed())
            }
        }
    }

    @Test("counts an attached primary for replica identity")
    func replicaIdentityCountsPrimary() async throws {
        try await RedisHostileServer.withServer(behavior: .replica) { server in
            let definition = try RedisValkeyAdapterFixtures.definition(
                location: .network([
                    DatabaseNetworkEndpoint(
                        host: "127.0.0.1", port: try DatabasePort(server.port))
                ]))
            let session = try await RedisValkeyDatabaseAdapter().connect(
                try RedisValkeyAdapterFixtures.resolved(definition),
                context: RedisValkeyAdapterFixtures.context(
                    deadline: Date(timeIntervalSinceNow: 1)))
            #expect(session.productIdentity.topology.kind == .primaryReplica)
            #expect(session.productIdentity.topology.nodeCount == 2)
            #expect(session.productIdentity.topology.replicaCount == 1)
            await session.disconnect()
        }
    }

    @Test("classifies missing authentication and closes an oversized read session")
    func serverFailureClassificationAndReadLifecycle() async throws {
        try await RedisHostileServer.withServer(behavior: .noAuthentication) { server in
            let definition = try RedisValkeyAdapterFixtures.definition(
                location: .network([
                    DatabaseNetworkEndpoint(
                        host: "127.0.0.1", port: try DatabasePort(server.port))
                ]))
            let envelope = await RedisValkeyAdapterFixtures.envelope {
                _ = try await RedisValkeyDatabaseAdapter().connect(
                    try RedisValkeyAdapterFixtures.resolved(definition),
                    context: RedisValkeyAdapterFixtures.context(
                        deadline: Date(timeIntervalSinceNow: 1)))
            }
            #expect(envelope?.productCode == "redis.authentication.failed")
            #expect(await server.waitUntilClosed())
        }

        try await RedisHostileServer.withServer(behavior: .oversizedScan) { server in
            let definition = try RedisValkeyAdapterFixtures.definition(
                location: .network([
                    DatabaseNetworkEndpoint(
                        host: "127.0.0.1", port: try DatabasePort(server.port))
                ]))
            let session = try await RedisValkeyDatabaseAdapter().connect(
                try RedisValkeyAdapterFixtures.resolved(definition),
                context: RedisValkeyAdapterFixtures.context(
                    deadline: Date(timeIntervalSinceNow: 1)))
            let envelope = await RedisValkeyAdapterFixtures.envelope {
                _ = try await session.readPage(
                    try RedisValkeyAdapterFixtures.pageRequest(definition.id),
                    context: RedisValkeyAdapterFixtures.context(
                        deadline: Date(timeIntervalSinceNow: 1)))
            }
            #expect(envelope?.productCode == "redis.result.too_large")
            #expect(await session.lifecycleState() == .failed)
            #expect(await server.waitUntilClosed())
            await session.disconnect()
        }
    }

    @Test("bounds every connection setup phase and releases its channel")
    func stalledConnectionPhases() async throws {
        let phases: [(command: String, authenticated: Bool, database: String?)] = [
            ("AUTH", true, nil),
            ("SELECT", false, "1"),
            ("PING", false, nil),
            ("INFO", false, nil),
        ]
        for phase in phases {
            try await RedisHostileServer.withServer(behavior: .stall(phase.command)) { server in
                let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
                let authentication =
                    phase.authenticated
                    ? DatabaseAuthentication(kind: .password, secretReferences: [reference])
                    : DatabaseAuthentication(kind: .none)
                let definition = try RedisValkeyAdapterFixtures.definition(
                    location: .network([
                        DatabaseNetworkEndpoint(
                            host: "127.0.0.1", port: try DatabasePort(server.port))
                    ]),
                    logicalDatabase: phase.database,
                    authentication: authentication)
                let secrets =
                    phase.authenticated
                    ? [reference: Data("fixture-secret".utf8)]
                    : [:]
                let context = RedisValkeyAdapterFixtures.context(
                    deadline: Date(timeIntervalSinceNow: 0.2))
                let startedAt = Date()
                let envelope = await RedisValkeyAdapterFixtures.envelope {
                    _ = try await RedisValkeyDatabaseAdapter().connect(
                        try RedisValkeyAdapterFixtures.resolved(definition, secrets: secrets),
                        context: context)
                }
                #expect(envelope?.productCode == "redis.deadline_exceeded")
                #expect(Date().timeIntervalSince(startedAt) < 1)
                #expect(await server.waitForCommand(phase.command))
                #expect(await server.waitUntilClosed())
                #expect(await waitForCancellationObserversToDrain(context.cancellation))
            }
        }
    }

    @Test("closes the owned channel after authentication failure")
    func rejectedAuthenticationReleasesChannel() async throws {
        try await RedisHostileServer.withServer(behavior: .rejectAuthentication) { server in
            let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
            let definition = try RedisValkeyAdapterFixtures.definition(
                location: .network([
                    DatabaseNetworkEndpoint(host: "127.0.0.1", port: try DatabasePort(server.port))
                ]),
                authentication: DatabaseAuthentication(
                    kind: .password,
                    secretReferences: [reference]))
            let envelope = await RedisValkeyAdapterFixtures.envelope {
                _ = try await RedisValkeyDatabaseAdapter().connect(
                    try RedisValkeyAdapterFixtures.resolved(
                        definition,
                        secrets: [reference: Data("fixture-secret".utf8)]),
                    context: RedisValkeyAdapterFixtures.context(
                        deadline: Date(timeIntervalSinceNow: 1)))
            }
            #expect(envelope?.productCode == "redis.authentication.failed")
            #expect(await server.waitUntilClosed())
        }
    }

    @Test("task cancellation interrupts connection setup immediately")
    func cancelledConnectionSetup() async throws {
        try await RedisHostileServer.withServer(behavior: .stall("PING")) { server in
            let definition = try RedisValkeyAdapterFixtures.definition(
                location: .network([
                    DatabaseNetworkEndpoint(host: "127.0.0.1", port: try DatabasePort(server.port))
                ]))
            let context = RedisValkeyAdapterFixtures.context()
            let task = Task {
                try await RedisValkeyDatabaseAdapter().connect(
                    try RedisValkeyAdapterFixtures.resolved(definition),
                    context: context)
            }
            #expect(await server.waitForCommand("PING"))
            let startedAt = Date()
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("The cancelled connection setup unexpectedly completed.")
            } catch let failure as DatabaseAdapterFailure {
                #expect(failure == .cancelled)
            }
            #expect(Date().timeIntervalSince(startedAt) < 1)
            #expect(await server.waitUntilClosed())
            #expect(await waitForCancellationObserversToDrain(context.cancellation))
        }
    }

    @Test("deadline, cancellation, and disconnect interrupt a stalled production read")
    func stalledProductionRead() async throws {
        for mode in ["deadline", "cancel", "disconnect"] {
            try await RedisHostileServer.withServer(behavior: .stall("SCAN")) { server in
                let definition = try RedisValkeyAdapterFixtures.definition(
                    location: .network([
                        DatabaseNetworkEndpoint(
                            host: "127.0.0.1", port: try DatabasePort(server.port))
                    ]))
                let session = try await RedisValkeyDatabaseAdapter().connect(
                    try RedisValkeyAdapterFixtures.resolved(definition),
                    context: RedisValkeyAdapterFixtures.context(
                        deadline: Date(timeIntervalSinceNow: 1)))
                let operationID = DatabaseOperationID()
                let context = RedisValkeyAdapterFixtures.context(
                    operationID: operationID,
                    deadline: mode == "deadline" ? Date(timeIntervalSinceNow: 0.2) : nil)
                let task = Task {
                    try await session.readPage(
                        try RedisValkeyAdapterFixtures.pageRequest(definition.id),
                        context: context)
                }
                #expect(await server.waitForCommand("SCAN"))
                let startedAt = Date()
                if mode == "cancel" {
                    let result = await session.cancel(operationID)
                    #expect(result.disposition == .accepted)
                } else if mode == "disconnect" {
                    await session.disconnect()
                }
                do {
                    _ = try await task.value
                    Issue.record("The interrupted read unexpectedly completed.")
                } catch let failure as DatabaseAdapterFailure {
                    if mode != "deadline" {
                        #expect(failure == .cancelled)
                    } else if case let .reported(envelope) = failure {
                        #expect(envelope.productCode == "redis.deadline_exceeded")
                    } else {
                        Issue.record("The stalled read returned an unexpected failure.")
                    }
                }
                #expect(Date().timeIntervalSince(startedAt) < 1)
                #expect(await server.waitUntilClosed())
                #expect(
                    await session.lifecycleState()
                        == (mode == "disconnect" ? .disconnected : .failed))
                #expect(await waitForCancellationObserversToDrain(context.cancellation))
                if mode != "disconnect" {
                    await session.disconnect()
                }
            }
        }
    }

    @Test("rejects a discovered product mismatch without leaking server details")
    func productMismatch() async throws {
        let definition = try RedisValkeyAdapterFixtures.definition(product: .redis)
        let client = FakeRedisClient(product: .valkey)
        let sessionResult = await RedisValkeyAdapterFixtures.envelope {
            _ = try await RedisValkeyDatabaseAdapter(
                clientFactory: FakeRedisClientFactory(client: client)
            ).connect(
                try RedisValkeyAdapterFixtures.resolved(definition),
                context: RedisValkeyAdapterFixtures.context())
        }
        #expect(sessionResult?.productCode == "redis.product.mismatch")
        #expect(await client.isClosed())
    }

    @Test("reports only implemented read capabilities")
    func capabilities() async throws {
        let definition = try RedisValkeyAdapterFixtures.definition(product: .valkey)
        let session = try await RedisValkeyDatabaseAdapter(
            clientFactory: FakeRedisClientFactory(
                client: FakeRedisClient(product: .valkey))
        ).connect(
            try RedisValkeyAdapterFixtures.resolved(definition),
            context: RedisValkeyAdapterFixtures.context())
        let report = try await session.discoverCapabilities(
            context: RedisValkeyAdapterFixtures.context())
        #expect(report.productIdentity.product == .valkey)
        #expect(report.supports(.connectionTest))
        #expect(report.supports(.objectDiscovery))
        #expect(report.supports(.browse))
        #expect(report.supports(.query))
        #expect(report.supports(.queryCancellation))
        #expect(report.status(for: .insert)?.availability == .unavailable)
        #expect(report.unavailableReason(for: .insert)?.category == .notImplemented)
        #expect(report.pagingModes == [.scanCursor])
        #expect(report.mutationModes == [.unsupported])
        #expect(report.transactionModes == [.none])
        await session.disconnect()
    }

    @Test("pages a large keyspace incrementally without a full scan")
    func boundedScanPaging() async throws {
        var values: [Data: FakeRedisValue] = [:]
        for index in 0..<10_000 {
            let key = Data(String(format: "key:%05d", index).utf8)
            values[key] = .string(Data("value".utf8))
        }
        let definition = try RedisValkeyAdapterFixtures.definition()
        let client = FakeRedisClient(product: .redis, values: values)
        let session = try await RedisValkeyDatabaseAdapter(
            clientFactory: FakeRedisClientFactory(client: client)
        ).connect(
            try RedisValkeyAdapterFixtures.resolved(definition),
            context: RedisValkeyAdapterFixtures.context())
        let first = try await session.readPage(
            try RedisValkeyAdapterFixtures.pageRequest(definition.id, pageSize: 2_000),
            context: RedisValkeyAdapterFixtures.context())
        #expect(first.records.count == 100)
        #expect(first.nextContinuation != nil)
        let scans = await client.snapshot().filter {
            if case .scan = $0 { return true }
            return false
        }
        #expect(scans.count == 1)
        #expect(await client.snapshot().count < 500)
        let second = try await session.readPage(
            try RedisValkeyAdapterFixtures.pageRequest(
                definition.id,
                pageSize: 3,
                continuation: first.nextContinuation),
            context: RedisValkeyAdapterFixtures.context())
        #expect(second.records.count == 3)
        #expect(Set(first.records).isDisjoint(with: Set(second.records)))
        await session.disconnect()
    }

    @Test("drains a final cursor continuation without restarting scan")
    func finalCursorPendingKeys() async throws {
        let values: [Data: FakeRedisValue] = [
            Data("a".utf8): .string(Data("1".utf8)),
            Data("b".utf8): .string(Data("2".utf8)),
            Data("c".utf8): .string(Data("3".utf8)),
        ]
        let definition = try RedisValkeyAdapterFixtures.definition()
        let client = FakeRedisClient(
            product: .redis,
            values: values,
            scanExtraKeys: 1)
        let session = try await RedisValkeyDatabaseAdapter(
            clientFactory: FakeRedisClientFactory(client: client)
        ).connect(
            try RedisValkeyAdapterFixtures.resolved(definition),
            context: RedisValkeyAdapterFixtures.context())
        let first = try await session.readPage(
            try RedisValkeyAdapterFixtures.pageRequest(definition.id, pageSize: 2),
            context: RedisValkeyAdapterFixtures.context())
        let second = try await session.readPage(
            try RedisValkeyAdapterFixtures.pageRequest(
                definition.id,
                pageSize: 2,
                continuation: first.nextContinuation),
            context: RedisValkeyAdapterFixtures.context())
        let scans = await client.snapshot().filter {
            if case .scan = $0 { return true }
            return false
        }
        #expect(first.records.count == 2)
        #expect(second.records.count == 1)
        #expect(first.nextContinuation != nil)
        #expect(second.nextContinuation == nil)
        #expect(scans.count == 1)
        #expect(Set(first.records).isDisjoint(with: Set(second.records)))
        #expect(first.metadata.completeness.state == .sampled)
        #expect(second.metadata.completeness.state == .sampled)
        #expect(first.metadata.count.accuracy == .unknown)
        #expect(second.metadata.count.accuracy == .unknown)
        await session.disconnect()
    }

    @Test("converts all supported value families including binary and Unicode")
    func valueConversion() async throws {
        let binaryKey = Data([0, 255, 1])
        let unicodeKey = Data("ключ:😀".utf8)
        let values: [Data: FakeRedisValue] = [
            binaryKey: .string(Data([0, 1, 255])),
            unicodeKey: .string(Data("значение".utf8)),
            Data("hash".utf8): .hash([
                (Data("β".utf8), Data("two".utf8)),
                (Data([0]), Data([255])),
            ]),
            Data("list".utf8): .list([Data("one".utf8), Data([0, 255])]),
            Data("set".utf8): .set([Data("z".utf8), Data("a".utf8)]),
            Data("zset".utf8): .sortedSet([
                (Data("member".utf8), Data("1.25".utf8))
            ]),
            Data("stream".utf8): .stream([
                (
                    Data("1-0".utf8),
                    [(Data("field".utf8), Data("value".utf8))]
                )
            ]),
        ]
        let definition = try RedisValkeyAdapterFixtures.definition()
        let session = try await RedisValkeyDatabaseAdapter(
            clientFactory: FakeRedisClientFactory(
                client: FakeRedisClient(product: .redis, values: values))
        ).connect(
            try RedisValkeyAdapterFixtures.resolved(definition),
            context: RedisValkeyAdapterFixtures.context())
        let page = try await session.readPage(
            try RedisValkeyAdapterFixtures.pageRequest(definition.id, pageSize: values.count),
            context: RedisValkeyAdapterFixtures.context())
        #expect(page.records.count == values.count)
        let types = Set<String>(
            page.records.compactMap {
                guard case let .string(type) = RedisValkeyAdapterFixtures.field("type", in: $0)
                else { return nil }
                return type
            })
        #expect(types == ["string", "hash", "list", "set", "zset", "stream"])
        let binaryRecord = try #require(
            page.records.first {
                $0.identity?.components.first?.value
                    == .binary(.complete(data: binaryKey, mediaType: nil, digest: nil))
            })
        #expect(
            RedisValkeyAdapterFixtures.field("value", in: binaryRecord)
                == .binary(.complete(data: Data([0, 1, 255]), mediaType: nil, digest: nil)))
        #expect(
            page.records.contains {
                $0.identity?.components.first?.value == .string("ключ:😀")
            })
        await session.disconnect()
    }

    @Test("uses a parameter-bound strict read-only command allowlist")
    func queryAllowlist() async throws {
        let injectedKey = Data("safe\r\nDEL victim".utf8)
        let definition = try RedisValkeyAdapterFixtures.definition()
        let client = FakeRedisClient(
            product: .redis,
            values: [injectedKey: .string(Data("value".utf8))])
        let session = try await RedisValkeyDatabaseAdapter(
            clientFactory: FakeRedisClientFactory(client: client)
        ).connect(
            try RedisValkeyAdapterFixtures.resolved(definition),
            context: RedisValkeyAdapterFixtures.context())
        let before = await client.snapshot().count
        let page = try await session.query(
            try RedisValkeyAdapterFixtures.queryRequest(
                definition.id,
                command: "GET",
                key: .binary(.complete(data: injectedKey, mediaType: nil, digest: nil))),
            context: RedisValkeyAdapterFixtures.context())
        #expect(page.records.count == 1)
        #expect(RedisValkeyAdapterFixtures.field("result", in: page.records[0]) == .string("value"))
        #expect(page.metadata.completeness.state == .complete)
        #expect(page.metadata.count.value == 1)
        #expect(page.metadata.count.accuracy == .exact)
        let queryOperations = Array((await client.snapshot()).dropFirst(before))
        #expect(queryOperations.first == .type(injectedKey))
        #expect(queryOperations.contains(.stringRange(injectedKey, maximumBytes: 65_536)))

        let forbidden = [
            "SET", "DEL", "UNLINK", "MSET", "HSET", "LPUSH", "SADD", "ZADD", "XADD",
            "EVAL", "EVALSHA", "FCALL", "FUNCTION", "MODULE", "MULTI", "EXEC", "WATCH",
            "SUBSCRIBE", "PSUBSCRIBE", "BLPOP", "BRPOP", "XREAD", "MONITOR", "CONFIG",
            "CLIENT", "ACL", "SCRIPT", "SCAN", "KEYS", "GET;DEL", "GET key", " GET",
        ]
        let operationCount = await client.snapshot().count
        for command in forbidden {
            let envelope = await RedisValkeyAdapterFixtures.envelope {
                _ = try await session.query(
                    try RedisValkeyAdapterFixtures.queryRequest(
                        definition.id,
                        command: command),
                    context: RedisValkeyAdapterFixtures.context())
            }
            #expect(envelope?.productCode == "redis.query.read_only_violation")
        }
        #expect(await client.snapshot().count == operationCount)
        await session.disconnect()
    }

    @Test("reads and queries an empty binary-safe key across pages")
    func emptyKey() async throws {
        let empty = Data()
        let other = Data("other".utf8)
        let definition = try RedisValkeyAdapterFixtures.definition()
        let session = try await RedisValkeyDatabaseAdapter(
            clientFactory: FakeRedisClientFactory(
                client: FakeRedisClient(
                    product: .redis,
                    values: [
                        empty: .string(Data("empty-value".utf8)),
                        other: .string(Data("other-value".utf8)),
                    ]))
        ).connect(
            try RedisValkeyAdapterFixtures.resolved(definition),
            context: RedisValkeyAdapterFixtures.context())
        let first = try await session.readPage(
            try RedisValkeyAdapterFixtures.pageRequest(definition.id, pageSize: 1),
            context: RedisValkeyAdapterFixtures.context())
        #expect(first.records.first?.identity?.components.first?.value == .string(""))
        let continuation = try #require(first.nextContinuation)
        let second = try await session.readPage(
            try RedisValkeyAdapterFixtures.pageRequest(
                definition.id,
                pageSize: 1,
                continuation: continuation),
            context: RedisValkeyAdapterFixtures.context())
        #expect(second.records.first?.identity?.components.first?.value == .string("other"))
        let query = try await session.query(
            try RedisValkeyAdapterFixtures.queryRequest(
                definition.id,
                command: "GET",
                key: .binary(.complete(data: empty, mediaType: nil, digest: nil))),
            context: RedisValkeyAdapterFixtures.context())
        #expect(
            RedisValkeyAdapterFixtures.field("result", in: query.records[0])
                == .string("empty-value"))
        await session.disconnect()
    }

    @Test("rejects browse shaping that cannot be honored safely")
    func rejectedBrowseShaping() async throws {
        let definition = try RedisValkeyAdapterFixtures.definition()
        let session = try await RedisValkeyDatabaseAdapter(
            clientFactory: FakeRedisClientFactory(
                client: FakeRedisClient(product: .redis))
        ).connect(
            try RedisValkeyAdapterFixtures.resolved(definition),
            context: RedisValkeyAdapterFixtures.context())
        let projection = DatabaseProjection(
            mode: .include,
            fields: [DatabaseProjectedField(path: DatabaseFieldPath("key"))])
        let envelope = await RedisValkeyAdapterFixtures.envelope {
            _ = try await session.readPage(
                try RedisValkeyAdapterFixtures.pageRequest(
                    definition.id,
                    projection: projection),
                context: RedisValkeyAdapterFixtures.context())
        }
        #expect(envelope?.productCode == "redis.read.invalid")
        await session.disconnect()
    }

    @Test("enforces value, key, and continuation byte limits")
    func byteLimits() async throws {
        let largeValue = Data(repeating: 255, count: 100_000)
        let definition = try RedisValkeyAdapterFixtures.definition()
        let session = try await RedisValkeyDatabaseAdapter(
            clientFactory: FakeRedisClientFactory(
                client: FakeRedisClient(
                    product: .redis,
                    values: [Data("large".utf8): .string(largeValue)]))
        ).connect(
            try RedisValkeyAdapterFixtures.resolved(definition),
            context: RedisValkeyAdapterFixtures.context())
        let page = try await session.readPage(
            try RedisValkeyAdapterFixtures.pageRequest(definition.id, pageSize: 1),
            context: RedisValkeyAdapterFixtures.context())
        guard
            case let .binary(.preview(byteCount, bytes, _, _)) =
                RedisValkeyAdapterFixtures.field("value", in: page.records[0])
        else {
            Issue.record("The large value was not returned as a bounded preview.")
            await session.disconnect()
            return
        }
        #expect(byteCount == UInt64(largeValue.count))
        #expect(bytes.count == 65_536)

        let invalidContinuation = try DatabaseAdapterContinuation(
            mode: .scanCursor,
            payload: Data("invalid".utf8))
        let invalidEnvelope = await RedisValkeyAdapterFixtures.envelope {
            _ = try await session.readPage(
                try RedisValkeyAdapterFixtures.pageRequest(
                    definition.id,
                    continuation: invalidContinuation),
                context: RedisValkeyAdapterFixtures.context())
        }
        #expect(invalidEnvelope?.productCode == "redis.continuation.invalid")
        await session.disconnect()

        let oversizedDefinition = try RedisValkeyAdapterFixtures.definition()
        let oversizedSession = try await RedisValkeyDatabaseAdapter(
            clientFactory: FakeRedisClientFactory(
                client: FakeRedisClient(
                    product: .redis,
                    values: [Data(repeating: 1, count: 4_097): .string(Data())]))
        ).connect(
            try RedisValkeyAdapterFixtures.resolved(oversizedDefinition),
            context: RedisValkeyAdapterFixtures.context())
        let oversizedEnvelope = await RedisValkeyAdapterFixtures.envelope {
            _ = try await oversizedSession.readPage(
                try RedisValkeyAdapterFixtures.pageRequest(oversizedDefinition.id),
                context: RedisValkeyAdapterFixtures.context())
        }
        #expect(oversizedEnvelope?.productCode == "redis.result.too_large")
        await oversizedSession.disconnect()
    }

    @Test("enforces cancellation, deadlines, and clean lifecycle release")
    func cancellationDeadlineAndLifecycle() async throws {
        let definition = try RedisValkeyAdapterFixtures.definition()
        let client = FakeRedisClient(
            product: .redis,
            values: [Data("key".utf8): .string(Data("value".utf8))])
        let session = try await RedisValkeyDatabaseAdapter(
            clientFactory: FakeRedisClientFactory(client: client)
        ).connect(
            try RedisValkeyAdapterFixtures.resolved(definition),
            context: RedisValkeyAdapterFixtures.context())
        let expired = await RedisValkeyAdapterFixtures.envelope {
            _ = try await session.readPage(
                try RedisValkeyAdapterFixtures.pageRequest(definition.id),
                context: RedisValkeyAdapterFixtures.context(
                    deadline: Date(timeIntervalSinceNow: -1)))
        }
        #expect(expired?.productCode == "redis.deadline_exceeded")

        await client.setPauseOnScan(true)
        let operationID = DatabaseOperationID()
        let context = RedisValkeyAdapterFixtures.context(operationID: operationID)
        let task = Task {
            try await session.readPage(
                try RedisValkeyAdapterFixtures.pageRequest(definition.id),
                context: context)
        }
        for _ in 0..<1_000 {
            if await client.isScanPaused() { break }
            await Task.yield()
        }
        #expect(await client.isScanPaused())
        let cancellation = await session.cancel(operationID)
        #expect(cancellation.disposition == .accepted)
        do {
            _ = try await task.value
            Issue.record("The cancelled read unexpectedly completed.")
        } catch let failure as DatabaseAdapterFailure {
            #expect(failure == .cancelled)
        }
        #expect(await session.lifecycleState() == .failed)
        #expect(await client.isClosed())
        await session.disconnect()
        #expect(await session.lifecycleState() == .disconnected)
    }

    @Test("task cancellation closes the active connection")
    func taskCancellation() async throws {
        let definition = try RedisValkeyAdapterFixtures.definition()
        let client = FakeRedisClient(
            product: .redis,
            values: [Data("key".utf8): .string(Data("value".utf8))])
        await client.setPauseOnScan(true)
        let session = try await RedisValkeyDatabaseAdapter(
            clientFactory: FakeRedisClientFactory(client: client)
        ).connect(
            try RedisValkeyAdapterFixtures.resolved(definition),
            context: RedisValkeyAdapterFixtures.context())
        let task = Task {
            try await session.readPage(
                try RedisValkeyAdapterFixtures.pageRequest(definition.id),
                context: RedisValkeyAdapterFixtures.context())
        }
        for _ in 0..<1_000 {
            if await client.isScanPaused() { break }
            await Task.yield()
        }
        #expect(await client.isScanPaused())
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("The cancelled task unexpectedly completed.")
        } catch let failure as DatabaseAdapterFailure {
            #expect(failure == .cancelled)
        }
        #expect(await client.isClosed())
        #expect(await session.lifecycleState() == .failed)
        await session.disconnect()
    }
}

private enum RedisValkeyLiveEnvironment {
    static let isConfigured = [
        "EDITH_DATABASE_REDIS_HOST",
        "EDITH_DATABASE_REDIS_PORT",
        "EDITH_DATABASE_REDIS_PASSWORD",
        "EDITH_DATABASE_VALKEY_HOST",
        "EDITH_DATABASE_VALKEY_PORT",
        "EDITH_DATABASE_VALKEY_PASSWORD",
    ].allSatisfy { ProcessInfo.processInfo.environment[$0] != nil }

    static func configuration(
        product: DatabaseProduct
    ) throws -> (
        definition: DatabaseConnectionDefinition,
        secrets: [DatabaseSecretReference: Data]
    )? {
        let prefix =
            product == .redis
            ? "EDITH_DATABASE_REDIS"
            : "EDITH_DATABASE_VALKEY"
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["\(prefix)_HOST"],
            let portText = environment["\(prefix)_PORT"],
            let port = Int(portText),
            let password = environment["\(prefix)_PASSWORD"]
        else {
            return nil
        }
        let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
        let definition = try RedisValkeyAdapterFixtures.definition(
            product: product,
            location: .network([
                DatabaseNetworkEndpoint(
                    host: host,
                    port: try DatabasePort(port))
            ]),
            authentication: DatabaseAuthentication(
                kind: .password,
                secretReferences: [reference]))
        return (definition, [reference: Data(password.utf8)])
    }
}

@Suite("Redis and Valkey adapter live")
struct RedisValkeyDatabaseAdapterIntegrationTests {
    @Test(
        "reads live Redis and Valkey through bounded authenticated sessions",
        .enabled(if: RedisValkeyLiveEnvironment.isConfigured))
    func liveRead() async throws {
        for product in [DatabaseProduct.redis, .valkey] {
            guard
                let configuration = try RedisValkeyLiveEnvironment.configuration(
                    product: product)
            else {
                continue
            }
            let session = try await RedisValkeyDatabaseAdapter().connect(
                try RedisValkeyAdapterFixtures.resolved(
                    configuration.definition,
                    secrets: configuration.secrets),
                context: RedisValkeyAdapterFixtures.context(
                    deadline: Date(timeIntervalSinceNow: 10)))
            #expect(session.productIdentity.product == product)
            #expect(
                session.productIdentity.version?.string
                    == (product == .redis ? "8.10.0" : "9.1.1"))
            var continuation: DatabaseAdapterContinuation?
            var firstKey: DatabaseValue?
            var observedTypes = Set<String>()
            for _ in 0..<5 {
                let page = try await session.readPage(
                    try RedisValkeyAdapterFixtures.pageRequest(
                        configuration.definition.id,
                        pageSize: 100,
                        continuation: continuation),
                    context: RedisValkeyAdapterFixtures.context(
                        deadline: Date(timeIntervalSinceNow: 10)))
                #expect(!page.records.isEmpty)
                #expect(page.records.count <= 100)
                firstKey = firstKey ?? page.records.first?.identity?.components.first?.value
                for record in page.records {
                    if case let .string(type) = RedisValkeyAdapterFixtures.field(
                        "type",
                        in: record)
                    {
                        observedTypes.insert(type)
                    }
                }
                continuation = page.nextContinuation
                if observedTypes.isSuperset(
                    of: ["string", "hash", "list", "set", "zset", "stream"])
                {
                    break
                }
                if continuation == nil {
                    break
                }
            }
            #expect(
                observedTypes.isSuperset(
                    of: ["string", "hash", "list", "set", "zset", "stream"]))
            let key = try #require(firstKey)
            let query = try await session.query(
                try RedisValkeyAdapterFixtures.queryRequest(
                    configuration.definition.id,
                    command: "TYPE",
                    key: key),
                context: RedisValkeyAdapterFixtures.context(
                    deadline: Date(timeIntervalSinceNow: 10)))
            #expect(query.records.count == 1)
            await session.disconnect()
            #expect(await session.lifecycleState() == .disconnected)

            let reconnected = try await RedisValkeyDatabaseAdapter().connect(
                try RedisValkeyAdapterFixtures.resolved(
                    configuration.definition,
                    secrets: configuration.secrets),
                context: RedisValkeyAdapterFixtures.context(
                    deadline: Date(timeIntervalSinceNow: 10)))
            #expect(reconnected.productIdentity.product == product)
            await reconnected.disconnect()
        }
    }
}
