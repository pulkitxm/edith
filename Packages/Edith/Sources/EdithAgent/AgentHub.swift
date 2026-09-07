import EdithKit
import Foundation
import Security

public final class AgentHub: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let runtime: AgentRuntime
    private let requirement: String

    public init(runtime: AgentRuntime, requirement: String = AgentHub.localRequirement()) {
        self.listener = NSXPCListener(machServiceName: AgentService.machServiceName)
        self.runtime = runtime
        self.requirement = requirement
        super.init()
        listener.delegate = self
    }

    public func resume() {
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.resume()
    }

    public func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: EdithAgentXPC.self)
        connection.remoteObjectInterface = NSXPCInterface(with: EdithAgentSubscriberXPC.self)
        let peer = AgentPeer(connection: connection, runtime: runtime)
        connection.exportedObject = peer
        connection.invalidationHandler = { [runtime] in
            Task { await runtime.forget(peer: peer.id) }
        }
        connection.interruptionHandler = { [runtime] in
            Task { await runtime.forget(peer: peer.id) }
        }
        connection.resume()
        return true
    }

    public static func localRequirement() -> String {
        AgentPeerIdentity.requirement(teamIdentifier: teamIdentifier())
    }

    static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return nil }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [String: Any]
        else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

final class AgentPeer: NSObject, EdithAgentXPC, @unchecked Sendable {
    let id = UUID()
    private weak var connection: NSXPCConnection?
    private let runtime: AgentRuntime
    private let lock = NSLock()
    private var authenticated = false

    init(connection: NSXPCConnection, runtime: AgentRuntime) {
        self.connection = connection
        self.runtime = runtime
    }

    func handshake(peerVersion: Int, reply: @escaping (Data?, String?) -> Void) {
        let verdict = AgentProtocolCompatibility.verdict(
            peer: peerVersion, agent: AgentService.protocolVersion)
        guard verdict == .compatible else {
            lock.withLock { authenticated = false }
            reply(nil, verdict.hint)
            return
        }
        lock.withLock { authenticated = true }
        Task { [runtime] in
            let value = await runtime.handshake()
            reply(try? AgentPayload.encode(value), nil)
        }
    }

    func snapshot(topic: String, reply: @escaping (Data?, String?) -> Void) {
        guard lock.withLock({ authenticated }) else { reply(nil, "Handshake required."); return }
        guard let value = AgentTopic(rawValue: topic) else {
            reply(nil, "Unknown topic \(topic).")
            return
        }
        Task { [runtime] in
            do {
                reply(try await runtime.snapshot(topic: value), nil)
            } catch {
                reply(nil, AgentError.response(error))
            }
        }
    }

    func subscribe(topic: String, reply: @escaping (String?) -> Void) {
        guard lock.withLock({ authenticated }) else { reply("Handshake required."); return }
        guard let value = AgentTopic(rawValue: topic) else {
            reply("Unknown topic \(topic).")
            return
        }
        let subscriber = connection?.remoteObjectProxy as? EdithAgentSubscriberXPC
        Task { [runtime, id] in
            await runtime.subscribe(peer: id, topic: value, subscriber: subscriber)
            reply(nil)
        }
    }

    func unsubscribe(topic: String, reply: @escaping (String?) -> Void) {
        guard lock.withLock({ authenticated }) else { reply("Handshake required."); return }
        guard let value = AgentTopic(rawValue: topic) else {
            reply("Unknown topic \(topic).")
            return
        }
        Task { [runtime, id] in
            await runtime.unsubscribe(peer: id, topic: value)
            reply(nil)
        }
    }

    func perform(operation: String, payload: Data, reply: @escaping (Data?, String?) -> Void) {
        guard lock.withLock({ authenticated }) else { reply(nil, "Handshake required."); return }
        if operation == AgentBus.publish || operation == AgentBus.subscribe
            || operation == AgentBus.unsubscribe
        {
            handleBus(operation: operation, payload: payload, reply: reply)
            return
        }
        Task { [runtime] in
            do {
                reply(try await runtime.perform(operation: operation, payload: payload), nil)
            } catch {
                reply(nil, AgentError.response(error))
            }
        }
    }

    private func handleBus(
        operation: String, payload: Data, reply: @escaping (Data?, String?) -> Void
    ) {
        guard let message = try? AgentPayload.decode(AgentBusMessage.self, from: payload) else {
            reply(nil, "Malformed bus message.")
            return
        }
        let subscriber = connection?.remoteObjectProxy as? EdithAgentSubscriberXPC
        Task { [runtime, id] in
            switch operation {
            case AgentBus.publish:
                await runtime.publishBus(message, from: id)
            case AgentBus.subscribe:
                await runtime.subscribeBus(
                    peer: id, channel: message.channel, subscriber: subscriber)
            default:
                await runtime.unsubscribeBus(peer: id, channel: message.channel)
            }
            reply(Data(), nil)
        }
    }
}
