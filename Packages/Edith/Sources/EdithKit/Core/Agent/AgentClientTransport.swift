import Foundation

protocol AgentClientConnection: AnyObject, Sendable {
    func remote(onError: @escaping @Sendable (Error) -> Void) throws -> EdithAgentXPC
    func invalidate()
}

final class AgentXPCConnection: AgentClientConnection, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(
        disconnected: @escaping @Sendable () -> Void,
        received: @escaping @Sendable (String, Data) -> Void
    ) {
        connection = NSXPCConnection(machServiceName: AgentService.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: EdithAgentXPC.self)
        connection.exportedInterface = NSXPCInterface(with: EdithAgentSubscriberXPC.self)
        connection.exportedObject = AgentSubscriberBridge(received: received)
        connection.invalidationHandler = disconnected
        connection.interruptionHandler = disconnected
        connection.resume()
    }

    func remote(onError: @escaping @Sendable (Error) -> Void) throws -> EdithAgentXPC {
        guard let remote = connection.remoteObjectProxyWithErrorHandler(onError) as? EdithAgentXPC
        else { throw AgentError.unavailable }
        return remote
    }

    func invalidate() { connection.invalidate() }
}

final class AgentReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var completions: [(Result<Value, Error>) -> Void] = []
    private var timer: DispatchWorkItem?

    var isFinished: Bool { lock.withLock { result != nil } }
    var completedValue: Value? { lock.withLock { try? result?.get() } }
    var completedResult: Result<Value, Error>? { lock.withLock { result } }

    @discardableResult
    func finish(_ value: Result<Value, Error>) -> Bool {
        let resolved = lock.withLock { () -> (Bool, [(Result<Value, Error>) -> Void]) in
            guard result == nil else { return (false, []) }
            result = value
            timer?.cancel()
            timer = nil
            let callbacks = completions
            completions.removeAll()
            return (true, callbacks)
        }
        for callback in resolved.1 { callback(value) }
        return resolved.0
    }

    func observe(_ callback: @escaping (Result<Value, Error>) -> Void) {
        let completed = lock.withLock { () -> Result<Value, Error>? in
            if let result { return result }
            completions.append(callback)
            return nil
        }
        if let completed { callback(completed) }
    }

    func deadline(after timeout: TimeInterval, expired: @escaping @Sendable () -> Void) {
        let timer = DispatchWorkItem(block: expired)
        let scheduled = lock.withLock {
            guard result == nil else { return false }
            self.timer = timer
            return true
        }
        if scheduled {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0, timeout), execute: timer)
        }
    }
}

private final class AgentSubscriberBridge: NSObject, EdithAgentSubscriberXPC {
    private let received: @Sendable (String, Data) -> Void

    init(received: @escaping @Sendable (String, Data) -> Void) {
        self.received = received
    }

    func topicChanged(topic: String, payload: Data) { received(topic, payload) }
}
