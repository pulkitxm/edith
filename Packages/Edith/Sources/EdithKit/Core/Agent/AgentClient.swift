import EdithCore
import Foundation

public final class AgentClient: NSObject, @unchecked Sendable {
    public static let shared = AgentClient()

    private let queue = DispatchQueue(label: "com.pulkit.edith.agent.client")
    private var connection: NSXPCConnection?
    private var handshake: AgentHandshake?
    private var subscriptions: [String: [UUID: @Sendable (Data) -> Void]] = [:]

    public override init() {
        super.init()
    }

    public var isAvailable: Bool {
        (try? runtimeSnapshot()) != nil
    }

    public func reset() {
        queue.sync {
            connection?.invalidate()
            connection = nil
            handshake = nil
        }
    }

    private func proxy() throws -> EdithAgentXPC {
        try queue.sync {
            if connection == nil {
                let created = NSXPCConnection(
                    machServiceName: AgentService.machServiceName, options: [])
                created.remoteObjectInterface = NSXPCInterface(with: EdithAgentXPC.self)
                created.exportedInterface = NSXPCInterface(with: EdithAgentSubscriberXPC.self)
                created.exportedObject = AgentSubscriberBridge(owner: self)
                created.invalidationHandler = { [weak self] in self?.clear() }
                created.interruptionHandler = { [weak self] in self?.clear() }
                created.resume()
                connection = created
            }
            guard
                let remote = connection?.remoteObjectProxyWithErrorHandler({ _ in })
                    as? EdithAgentXPC
            else { throw AgentError.unavailable }
            return remote
        }
    }

    private func clear() {
        queue.async { [weak self] in
            self?.connection = nil
            self?.handshake = nil
        }
    }

    fileprivate func deliver(topic: String, payload: Data) {
        let handlers = queue.sync { subscriptions[topic]?.values.map { $0 } ?? [] }
        for handler in handlers { handler(payload) }
    }

    private func call<T>(
        _ body: (EdithAgentXPC, @escaping (T?, String?) -> Void) -> Void
    ) throws -> T {
        let remote = try proxy()
        let semaphore = DispatchSemaphore(value: 0)
        var value: T?
        var failure: String?
        var replied = false
        body(remote) { result, message in
            guard !replied else { return }
            replied = true
            value = result
            failure = message
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            clear()
            throw AgentError(.unavailable, "The background agent did not answer in time.")
        }
        if let failure { throw AgentError(.failed, failure) }
        guard let value else { throw AgentError.unavailable }
        return value
    }

    @discardableResult
    public func verifyHandshake() throws -> AgentHandshake {
        if let handshake { return handshake }
        let data: Data = try call { remote, reply in
            remote.handshake(peerVersion: AgentService.protocolVersion) { reply($0, $1) }
        }
        let value = try AgentPayload.decode(AgentHandshake.self, from: data)
        let verdict = AgentProtocolCompatibility.verdict(
            peer: AgentService.protocolVersion, agent: value.protocolVersion)
        guard verdict == .compatible else {
            throw AgentError(.incompatible, verdict.hint ?? "Protocol mismatch.")
        }
        queue.sync { handshake = value }
        return value
    }

    public func snapshot<T: Decodable>(_ type: T.Type, topic: AgentTopic) throws -> T {
        try verifyHandshake()
        let data: Data = try call { remote, reply in
            remote.snapshot(topic: topic.rawValue) { reply($0, $1) }
        }
        return try AgentPayload.decode(type, from: data)
    }

    public func perform(_ operation: UserOperationID, payload: Data = Data()) throws -> Data {
        guard AgentOperationCatalog.serves(operation) else {
            throw AgentError(
                .unknownOperation, "The agent does not serve \(operation.rawValue).")
        }
        try verifyHandshake()
        return try call { remote, reply in
            remote.perform(operation: operation.rawValue, payload: payload) { reply($0, $1) }
        }
    }

    public func perform<T: Decodable>(
        _ type: T.Type, operation: UserOperationID, payload: Data = Data()
    ) throws -> T {
        try AgentPayload.decode(type, from: perform(operation, payload: payload))
    }

    public func runtimeSnapshot() throws -> AgentRuntimeSnapshot {
        try perform(
            AgentRuntimeSnapshot.self, operation: AgentControlOperation.status.descriptor.id)
    }

    public func jobSnapshots() throws -> [AgentJobSnapshot] {
        try perform(
            [AgentJobSnapshot].self, operation: AgentControlOperation.jobs.descriptor.id)
    }

    public func restart() throws {
        _ = try perform(AgentControlOperation.restart.descriptor.id)
        reset()
    }

    public func logLines(last: String) throws -> [String] {
        try perform(
            [String].self, operation: AgentControlOperation.logs.descriptor.id,
            payload: Data(last.utf8))
    }

    public func subscribe(
        _ topic: AgentTopic, handler: @escaping @Sendable (Data) -> Void
    ) throws -> AgentSubscription {
        try verifyHandshake()
        let token = UUID()
        queue.sync { subscriptions[topic.rawValue, default: [:]][token] = handler }
        let remote = try proxy()
        remote.subscribe(topic: topic.rawValue) { _ in }
        return AgentSubscription(topic: topic, token: token, client: self)
    }

    fileprivate func cancel(topic: AgentTopic, token: UUID) {
        let empty = queue.sync { () -> Bool in
            subscriptions[topic.rawValue]?.removeValue(forKey: token)
            return subscriptions[topic.rawValue]?.isEmpty ?? true
        }
        guard empty, let remote = try? proxy() else { return }
        remote.unsubscribe(topic: topic.rawValue) { _ in }
    }
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

    public func cancel() {
        client.cancel(topic: topic, token: token)
    }

    deinit { client.cancel(topic: topic, token: token) }
}

private final class AgentSubscriberBridge: NSObject, EdithAgentSubscriberXPC {
    private weak var owner: AgentClient?

    init(owner: AgentClient) {
        self.owner = owner
    }

    func topicChanged(topic: String, payload: Data) {
        owner?.deliver(topic: topic, payload: payload)
    }
}
