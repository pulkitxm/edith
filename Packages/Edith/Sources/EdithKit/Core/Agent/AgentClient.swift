import EdithCore
import Foundation

public final class AgentClient: NSObject, @unchecked Sendable {
    public static let shared = AgentClient()

    public static let replyTimeout: TimeInterval = 4
    public static let snapshotTimeout: TimeInterval = 120
    public static let logTimeout: TimeInterval = 30
    public static let unavailableCooldown: TimeInterval = 20

    typealias ConnectionFactory =
        @Sendable (
            @escaping @Sendable () -> Void, @escaping @Sendable (String, Data) -> Void
        ) -> AgentClientConnection

    private let queue = DispatchQueue(label: "com.pulkit.edith.agent.client")
    private let connectionFactory: ConnectionFactory
    private let reconnectDelay: TimeInterval
    private var connection: AgentClientConnection?
    private var connectionID = UUID()
    private var handshake: AgentHandshake?
    private var subscriptions: [String: [UUID: @Sendable (Data) -> Void]] = [:]
    private var pending: [UUID: @Sendable (Error) -> Void] = [:]
    private var unavailableUntil: Date?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectID = UUID()

    public override convenience init() {
        self.init(connectionFactory: { AgentXPCConnection(disconnected: $0, received: $1) })
    }

    init(
        connectionFactory: @escaping ConnectionFactory,
        reconnectDelay: TimeInterval = AgentClient.unavailableCooldown
    ) {
        self.connectionFactory = connectionFactory
        self.reconnectDelay = reconnectDelay
        super.init()
    }

    public var isAvailable: Bool { (try? runtimeSnapshot()) != nil }

    public var isCoolingDown: Bool {
        queue.sync { unavailableUntil.map { $0 > Date() } ?? false }
    }

    public func reset() {
        let old = queue.sync { () -> (AgentClientConnection?, [@Sendable (Error) -> Void]) in
            let old = connection
            connection = nil
            connectionID = UUID()
            handshake = nil
            unavailableUntil = nil
            let callbacks = Array(pending.values)
            pending.removeAll()
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectID = UUID()
            return (old, callbacks)
        }
        old.0?.invalidate()
        for callback in old.1 { callback(AgentError.unavailable) }
        scheduleReconnect()
    }

    private func deliver(topic: String, payload: Data, connectionID: UUID) {
        let handlers = queue.sync {
            self.connectionID == connectionID ? subscriptions[topic]?.values.map { $0 } ?? [] : []
        }
        for handler in handlers { handler(payload) }
    }

    private func disconnected(_ id: UUID) {
        queue.async { [weak self] in
            guard let self, connectionID == id else { return }
            let old = connection
            connection = nil
            connectionID = UUID()
            handshake = nil
            unavailableUntil = Date().addingTimeInterval(reconnectDelay)
            let callbacks = Array(pending.values)
            pending.removeAll()
            old?.invalidate()
            for callback in callbacks { callback(AgentError.unavailable) }
            scheduleReconnectLocked()
        }
    }

    private func scheduleReconnect() {
        queue.async { [weak self] in self?.scheduleReconnectLocked() }
    }

    private func scheduleReconnectLocked() {
        guard reconnectTask == nil, !subscriptions.isEmpty else { return }
        let delay = reconnectDelay
        let id = UUID()
        reconnectID = id
        reconnectTask = Task { [weak self] in
            defer {
                self?.queue.async { [weak self] in
                    guard let self, reconnectID == id else { return }
                    reconnectTask = nil
                    if handshake == nil { scheduleReconnectLocked() }
                }
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(delay))
                    guard let self, hasSubscriptions else { return }
                    _ = try await verifyHandshakeAsync()
                    try await restoreSubscriptionsAsync()
                    return
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
            }
        }
    }

    private var hasSubscriptions: Bool { queue.sync { !subscriptions.isEmpty } }
    var subscriptionRetryDelay: TimeInterval { reconnectDelay }

    private func begin<Value>(
        _ reply: AgentReply<Value>, timeout: TimeInterval,
        connected: AgentReply<UUID>? = nil,
        body: (EdithAgentXPC, @escaping (Value?, String?) -> Void) -> Void
    ) {
        guard !reply.isFinished else { return }
        let requestID = UUID()
        do {
            let transport = try queue.sync { () throws -> (AgentClientConnection, UUID) in
                if let unavailableUntil, unavailableUntil > Date() {
                    throw AgentError(.unavailable, "The background agent is not answering.")
                }
                if connection == nil {
                    let id = UUID()
                    connectionID = id
                    connection = connectionFactory(
                        { [weak self] in self?.disconnected(id) },
                        { [weak self] topic, payload in
                            self?.deliver(topic: topic, payload: payload, connectionID: id)
                        })
                }
                guard let connection else { throw AgentError.unavailable }
                pending[requestID] = { error in reply.finish(.failure(error)) }
                reply.observe { [weak self] _ in
                    self?.queue.async { [weak self] in self?.pending[requestID] = nil }
                }
                connected?.finish(.success(connectionID))
                return (connection, connectionID)
            }
            let finish: @Sendable (Result<Value, Error>) -> Void = { reply.finish($0) }
            reply.deadline(
                after: timeout,
                error: AgentError(.unavailable, "The background agent did not answer in time."))
            let remote: EdithAgentXPC
            do {
                remote = try transport.0.remote { [weak self] error in
                    finish(.failure(AgentError(.unavailable, error.localizedDescription)))
                    self?.disconnected(transport.1)
                }
            } catch {
                disconnected(transport.1)
                throw error
            }
            guard !reply.isFinished else { return }
            body(remote) { value, failure in
                if let failure {
                    finish(.failure(AgentError.fromResponse(failure)))
                } else if let value {
                    finish(.success(value))
                } else {
                    finish(.failure(AgentError.unavailable))
                }
            }
        } catch {
            reply.finish(.failure(error))
            queue.async { [weak self] in self?.pending[requestID] = nil }
        }
    }

    private func call<Value>(
        timeout: TimeInterval = AgentClient.replyTimeout, connected: AgentReply<UUID>? = nil,
        _ body: (EdithAgentXPC, @escaping (Value?, String?) -> Void) -> Void
    ) throws -> Value {
        let reply = AgentReply<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        reply.observe { _ in semaphore.signal() }
        begin(reply, timeout: timeout, connected: connected, body: body)
        semaphore.wait()
        guard let result = reply.completedResult else { throw AgentError.unavailable }
        return try result.get()
    }

    private func callAsync<Value: Sendable>(
        timeout: TimeInterval = AgentClient.replyTimeout, connected: AgentReply<UUID>? = nil,
        _ body: (EdithAgentXPC, @escaping (Value?, String?) -> Void) -> Void
    ) async throws -> Value {
        let reply = AgentReply<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.observe { continuation.resume(with: $0) }
                if Task.isCancelled { reply.finish(.failure(CancellationError())) }
                begin(reply, timeout: timeout, connected: connected, body: body)
            }
        } onCancel: {
            reply.finish(.failure(CancellationError()))
        }
    }

    private var cachedHandshake: AgentHandshake? { queue.sync { handshake } }

    private func acceptHandshake(_ data: Data, connectionID: UUID) throws -> AgentHandshake {
        let value = try AgentPayload.decode(AgentHandshake.self, from: data)
        let verdict = AgentProtocolCompatibility.verdict(
            peer: AgentService.protocolVersion, agent: value.protocolVersion)
        guard verdict == .compatible else {
            throw AgentError(.incompatible, verdict.hint ?? "Protocol mismatch.")
        }
        try queue.sync {
            guard self.connectionID == connectionID else { throw AgentError.unavailable }
            handshake = value
            unavailableUntil = nil
        }
        return value
    }

    @discardableResult
    public func verifyHandshake() throws -> AgentHandshake {
        if let cachedHandshake { return cachedHandshake }
        let connected = AgentReply<UUID>()
        let data: Data = try call(connected: connected) { remote, reply in
            remote.handshake(peerVersion: AgentService.protocolVersion) { reply($0, $1) }
        }
        guard let id = connected.completedValue else { throw AgentError.unavailable }
        return try acceptHandshake(data, connectionID: id)
    }

    @discardableResult
    public func verifyHandshakeAsync() async throws -> AgentHandshake {
        if let cachedHandshake { return cachedHandshake }
        let connected = AgentReply<UUID>()
        let data: Data = try await callAsync(connected: connected) { remote, reply in
            remote.handshake(peerVersion: AgentService.protocolVersion) { reply($0, $1) }
        }
        guard let id = connected.completedValue else { throw AgentError.unavailable }
        return try acceptHandshake(data, connectionID: id)
    }

    public func snapshot<Value: Decodable>(_ type: Value.Type, topic: AgentTopic) throws -> Value {
        try verifyHandshake()
        let data: Data = try call(timeout: Self.snapshotTimeout) { remote, reply in
            remote.snapshot(topic: topic.rawValue) { reply($0, $1) }
        }
        return try AgentPayload.decode(type, from: data)
    }

    public func snapshotAsync<Value: Decodable & Sendable>(
        _ type: Value.Type, topic: AgentTopic, timeout: TimeInterval = AgentClient.snapshotTimeout
    ) async throws -> Value {
        try await verifyHandshakeAsync()
        let data: Data = try await callAsync(timeout: timeout) { remote, reply in
            remote.snapshot(topic: topic.rawValue) { reply($0, $1) }
        }
        return try AgentPayload.decode(type, from: data)
    }

    public func perform(_ operation: UserOperationID, payload: Data = Data()) throws -> Data {
        try validate(operation)
        try verifyHandshake()
        return try call { remote, reply in
            remote.perform(operation: operation.rawValue, payload: payload) { reply($0, $1) }
        }
    }

    public func performAsync(
        _ operation: UserOperationID, payload: Data = Data(),
        timeout: TimeInterval = AgentClient.replyTimeout
    ) async throws -> Data {
        try validate(operation)
        try await verifyHandshakeAsync()
        return try await callAsync(timeout: timeout) { remote, reply in
            remote.perform(operation: operation.rawValue, payload: payload) { reply($0, $1) }
        }
    }

    private func validate(_ operation: UserOperationID) throws {
        guard AgentOperationCatalog.serves(operation) else {
            throw AgentError(.unknownOperation, "The agent does not serve \(operation.rawValue).")
        }
    }

    private func validateInternal(_ operation: String) throws {
        guard AgentOperationCatalog.servesInternal(operation) else {
            throw AgentError(.unknownOperation, "The agent does not serve \(operation).")
        }
    }

    public func performInternal(_ operation: String, payload: Data = Data()) throws -> Data {
        try validateInternal(operation)
        try verifyHandshake()
        return try call { remote, reply in
            remote.perform(operation: operation, payload: payload) { reply($0, $1) }
        }
    }

    public func performInternalAsync(
        _ operation: String, payload: Data = Data(),
        timeout: TimeInterval = AgentClient.replyTimeout
    ) async throws -> Data {
        try validateInternal(operation)
        try await verifyHandshakeAsync()
        return try await callAsync(timeout: timeout) { remote, reply in
            remote.perform(operation: operation, payload: payload) { reply($0, $1) }
        }
    }

    public func perform<Value: Decodable>(
        _ type: Value.Type, operation: UserOperationID, payload: Data = Data()
    ) throws -> Value {
        try AgentPayload.decode(type, from: perform(operation, payload: payload))
    }

    public func performAsync<Value: Decodable & Sendable>(
        _ type: Value.Type, operation: UserOperationID, payload: Data = Data(),
        timeout: TimeInterval = AgentClient.replyTimeout
    ) async throws -> Value {
        try AgentPayload.decode(
            type, from: await performAsync(operation, payload: payload, timeout: timeout))
    }

    public func runtimeSnapshot() throws -> AgentRuntimeSnapshot {
        try perform(
            AgentRuntimeSnapshot.self, operation: AgentControlOperation.status.descriptor.id)
    }

    public func jobSnapshots() throws -> [AgentJobSnapshot] {
        try perform([AgentJobSnapshot].self, operation: AgentControlOperation.jobs.descriptor.id)
    }

    public func restart() throws {
        _ = try perform(AgentControlOperation.restart.descriptor.id)
        reset()
    }

    public func logLines(last: String) throws -> [String] {
        try verifyHandshake()
        let data: Data = try call(timeout: Self.logTimeout) { remote, reply in
            remote.perform(
                operation: AgentControlOperation.logs.descriptor.id.rawValue,
                payload: Data(last.utf8)
            ) { reply($0, $1) }
        }
        return try AgentPayload.decode([String].self, from: data)
    }

    public func publishBus(channel: String, userInfo: [String: Any]) throws {
        let message = AgentBusMessage(channel: channel, userInfo: userInfo)
        _ = try performInternal(AgentBus.publish, payload: AgentPayload.encode(message))
    }

    private func insert(topic: String, handler: @escaping @Sendable (Data) -> Void) -> UUID {
        let token = UUID()
        queue.sync { subscriptions[topic, default: [:]][token] = handler }
        return token
    }

    private func subscribeRequest(
        topic: String, remote: EdithAgentXPC, reply: @escaping (Data?, String?) -> Void
    ) throws {
        if let channel = AgentBus.channel(fromTopic: topic) {
            let message = AgentBusMessage(channel: channel, body: Data())
            remote.perform(
                operation: AgentBus.subscribe, payload: try AgentPayload.encode(message),
                reply: reply)
        } else {
            remote.subscribe(topic: topic) { reply(Data(), $0) }
        }
    }

    private func restoreSubscriptionsAsync() async throws {
        let topics = queue.sync { Array(subscriptions.keys) }
        for topic in topics {
            let _: Data = try await callAsync { remote, reply in
                do { try self.subscribeRequest(topic: topic, remote: remote, reply: reply) } catch {
                    reply(nil, error.localizedDescription)
                }
            }
            removeRemoteSubscriptionIfUnused(topic)
        }
    }

    public func subscribeBus(
        channel: String, handler: @escaping @Sendable ([String: Any]) -> Void
    ) throws -> AgentBusSubscription {
        let topic = AgentBus.topic(for: channel)
        let token = insert(topic: topic) {
            handler(AgentBusMessage(channel: channel, body: $0).userInfo)
        }
        do {
            try verifyHandshake()
            let _: Data = try call { remote, reply in
                do { try self.subscribeRequest(topic: topic, remote: remote, reply: reply) } catch {
                    reply(nil, error.localizedDescription)
                }
            }
            return AgentBusSubscription(channel: channel, token: token, client: self)
        } catch {
            cancel(topic: topic, token: token)
            throw error
        }
    }

    public func subscribeBusAsync(
        channel: String, handler: @escaping @Sendable ([String: Any]) -> Void
    ) async throws -> AgentBusSubscription {
        try await subscribeBusDataAsync(channel: channel) {
            handler(AgentBusMessage(channel: channel, body: $0).userInfo)
        }
    }

    public func subscribeBusDataAsync(
        channel: String, handler: @escaping @Sendable (Data) -> Void
    ) async throws -> AgentBusSubscription {
        let topic = AgentBus.topic(for: channel)
        let token = insert(topic: topic, handler: handler)
        do {
            try await verifyHandshakeAsync()
            let _: Data = try await callAsync { remote, reply in
                do { try self.subscribeRequest(topic: topic, remote: remote, reply: reply) } catch {
                    reply(nil, error.localizedDescription)
                }
            }
            try Task.checkCancellation()
            return AgentBusSubscription(channel: channel, token: token, client: self)
        } catch {
            cancel(topic: topic, token: token)
            throw error
        }
    }

    public func subscribe(
        _ topic: AgentTopic, handler: @escaping @Sendable (Data) -> Void
    ) throws -> AgentSubscription {
        let token = insert(topic: topic.rawValue, handler: handler)
        do {
            try verifyHandshake()
            let _: Data = try call { remote, reply in
                remote.subscribe(topic: topic.rawValue) { reply(Data(), $0) }
            }
            return AgentSubscription(topic: topic, token: token, client: self)
        } catch {
            cancel(topic: topic.rawValue, token: token)
            throw error
        }
    }

    public func subscribeAsync(
        _ topic: AgentTopic, handler: @escaping @Sendable (Data) -> Void
    ) async throws -> AgentSubscription {
        let token = insert(topic: topic.rawValue, handler: handler)
        do {
            try await verifyHandshakeAsync()
            let _: Data = try await callAsync { remote, reply in
                remote.subscribe(topic: topic.rawValue) { reply(Data(), $0) }
            }
            try Task.checkCancellation()
            return AgentSubscription(topic: topic, token: token, client: self)
        } catch {
            cancel(topic: topic.rawValue, token: token)
            throw error
        }
    }

    fileprivate func cancel(topic: String, token: UUID) {
        let removed = queue.sync {
            guard subscriptions[topic]?.removeValue(forKey: token) != nil else { return false }
            if subscriptions[topic]?.isEmpty == true { subscriptions[topic] = nil }
            if subscriptions.isEmpty {
                reconnectTask?.cancel()
                reconnectTask = nil
                reconnectID = UUID()
            }
            return true
        }
        if removed { removeRemoteSubscriptionIfUnused(topic) }
    }

    private func removeRemoteSubscriptionIfUnused(_ topic: String) {
        queue.async { [weak self] in
            guard let self, subscriptions[topic] == nil, let connection,
                let remote = try? connection.remote(onError: { _ in })
            else { return }
            if let channel = AgentBus.channel(fromTopic: topic) {
                let message = AgentBusMessage(channel: channel, body: Data())
                guard let payload = try? AgentPayload.encode(message) else { return }
                remote.perform(operation: AgentBus.unsubscribe, payload: payload) { _, _ in }
            } else {
                remote.unsubscribe(topic: topic) { _ in }
            }
        }
    }
}

public final class AgentBusSubscription: Sendable {
    private let channel: String
    private let token: UUID
    private let client: AgentClient

    fileprivate init(channel: String, token: UUID, client: AgentClient) {
        self.channel = channel
        self.token = token
        self.client = client
    }

    public func cancel() { client.cancel(topic: AgentBus.topic(for: channel), token: token) }
    deinit { cancel() }
}

public final class AgentSubscription: Sendable {
    private let topic: AgentTopic
    private let token: UUID
    private let client: AgentClient

    fileprivate init(topic: AgentTopic, token: UUID, client: AgentClient) {
        self.topic = topic
        self.token = token
        self.client = client
    }

    public func cancel() { client.cancel(topic: topic.rawValue, token: token) }
    deinit { cancel() }
}
