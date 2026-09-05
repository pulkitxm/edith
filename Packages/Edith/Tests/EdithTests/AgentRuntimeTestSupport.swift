import Foundation

@testable import EdithAgent
@testable import EdithKit

final class AgentRuntimeTestListener: NSObject, @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    private let hub: AgentHub

    init(runtime: AgentRuntime) {
        hub = AgentHub(runtime: runtime)
        super.init()
        listener.delegate = hub
        listener.resume()
    }

    func client() -> AgentClient {
        AgentClient(connectionFactory: { [self] disconnected, received in
            AgentRuntimeTestConnection(
                endpoint: listener.endpoint, disconnected: disconnected, received: received)
        })
    }

    func stop() { listener.invalidate() }
}

private final class AgentRuntimeTestConnection: AgentClientConnection, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(
        endpoint: NSXPCListenerEndpoint, disconnected: @escaping @Sendable () -> Void,
        received: @escaping @Sendable (String, Data) -> Void
    ) {
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: EdithAgentXPC.self)
        connection.exportedInterface = NSXPCInterface(with: EdithAgentSubscriberXPC.self)
        connection.exportedObject = AgentRuntimeTestSubscriber(received: received)
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

private final class AgentRuntimeTestSubscriber: NSObject, EdithAgentSubscriberXPC {
    private let received: @Sendable (String, Data) -> Void
    init(received: @escaping @Sendable (String, Data) -> Void) { self.received = received }
    func topicChanged(topic: String, payload: Data) { received(topic, payload) }
}
