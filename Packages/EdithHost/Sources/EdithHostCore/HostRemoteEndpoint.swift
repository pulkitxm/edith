import Darwin
import Foundation
import Security

public final class HostRemoteEndpoint: NSObject, NSXPCListenerDelegate, HostRemoteBootstrap,
    @unchecked Sendable
{
    public typealias Execute = @MainActor @Sendable (HostRemoteCommand) async throws -> Data

    private let listener = NSXPCListener.anonymous()
    private let executable: URL
    private let requirement: String
    private let execute: Execute
    private let didDisconnect: @MainActor @Sendable () -> Void
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []
    private var invalidated = false

    public init(
        executable: URL, requirement: String, execute: @escaping Execute,
        didDisconnect: @escaping @MainActor @Sendable () -> Void = {}
    ) throws {
        var parsed: SecRequirement?
        guard !requirement.isEmpty, requirement.utf8.count <= 4096,
            !requirement.utf8.contains(0),
            SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess
        else { throw HostWorkerError.rejected }
        self.executable = executable.resolvingSymlinksInPath()
        self.requirement = requirement
        self.execute = execute
        self.didDisconnect = didDisconnect
        super.init()
        listener.delegate = self
        listener.resume()
    }

    public func acceptBootstrap(_ connection: NSXPCConnection) -> Bool {
        guard let peer = try? HostRemoteKernelIdentity.read(connection.processIdentifier),
            peer.executable == executable, (try? peer.verify(connection)) != nil,
            retain(connection)
        else { return false }
        connection.exportedInterface = NSXPCInterface(with: HostRemoteBootstrap.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let connection else { return }
            self?.remove(connection)
        }
        connection.resume()
        return true
    }

    public func endpoint(reply: @escaping (NSXPCListenerEndpoint) -> Void) {
        guard lock.withLock({ !invalidated }) else { return }
        reply(listener.endpoint)
    }

    public func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    )
        -> Bool
    {
        guard let peer = try? HostRemoteKernelIdentity.read(connection.processIdentifier),
            peer.executable == executable, (try? peer.verify(connection)) != nil,
            retain(connection)
        else { return false }
        let receiver = Exchange(
            connection: connection, peer: peer, execute: execute, didDisconnect: didDisconnect)
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: HostRemoteControl.self)
        connection.exportedObject = receiver
        connection.remoteObjectInterface = NSXPCInterface(with: HostRemoteEvents.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let connection else { return }
            self?.remove(connection)
            Task { @MainActor in receiver.invalidate() }
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.resume()
        return true
    }

    public func invalidate() {
        let values = lock.withLock {
            invalidated = true
            let values = connections
            connections.removeAll()
            return values
        }
        listener.invalidate()
        values.forEach { $0.invalidate() }
    }

    private func retain(_ connection: NSXPCConnection) -> Bool {
        lock.withLock {
            guard !invalidated, connections.count < 16 else { return false }
            connections.append(connection)
            return true
        }
    }

    private func remove(_ connection: NSXPCConnection) {
        lock.withLock { connections.removeAll { $0 === connection } }
    }

    private final class Exchange: NSObject, HostRemoteControl, @unchecked Sendable {
        private let connection: NSXPCConnection
        private let peer: HostRemoteKernelIdentity
        private let execute: Execute
        private let didDisconnect: @MainActor @Sendable () -> Void
        @MainActor private var pending: [UUID: Task<Void, Never>] = [:]
        @MainActor private var authenticated = false
        @MainActor private var invalidated = false

        init(
            connection: NSXPCConnection, peer: HostRemoteKernelIdentity, execute: @escaping Execute,
            didDisconnect: @escaping @MainActor @Sendable () -> Void
        ) {
            self.connection = connection
            self.peer = peer
            self.execute = execute
            self.didDisconnect = didDisconnect
        }

        func exchange(_ data: Data, reply: @escaping (Data) -> Void) {
            let completion = Reply(send: reply)
            Task { @MainActor [self] in
                guard !invalidated, (try? peer.verify(connection)) != nil,
                    let command = try? HostRemoteWire.decode(HostRemoteCommand.self, from: data),
                    !command.operation.isEmpty, command.operation.utf8.count <= 64,
                    !command.operation.utf8.contains(0), pending[command.token] == nil
                else { connection.invalidate(); return }
                if command.operation == "authenticate" {
                    guard !authenticated, command.payload.isEmpty else {
                        completion.finish(command, ok: false)
                        return
                    }
                    authenticated = true
                    completion.finish(command, ok: true)
                    return
                }
                guard authenticated else { completion.finish(command, ok: false); return }
                if command.operation == "cancel" {
                    guard let token = try? HostRemoteWire.decode(UUID.self, from: command.payload)
                    else { completion.finish(command, ok: false); return }
                    pending[token]?.cancel()
                    completion.finish(command, ok: true)
                    return
                }
                guard pending.count < 8 else { completion.finish(command, ok: false); return }
                pending[command.token] = Task { @MainActor [self] in
                    defer { pending[command.token] = nil }
                    do {
                        let bytes = try await execute(command)
                        try Task.checkCancellation()
                        guard !invalidated, (try? peer.verify(connection)) != nil else {
                            throw HostWorkerError.exited
                        }
                        completion.finish(command, ok: true, payload: bytes)
                    } catch { completion.finish(command, ok: false) }
                }
            }
        }

        @MainActor func invalidate() {
            guard !invalidated else { return }
            invalidated = true
            pending.values.forEach { $0.cancel() }
            pending.removeAll()
            if authenticated { didDisconnect() }
        }
    }

    private final class Reply: @unchecked Sendable {
        private let send: (Data) -> Void

        init(send: @escaping (Data) -> Void) { self.send = send }

        func finish(_ command: HostRemoteCommand, ok: Bool, payload: Data = Data()) {
            guard
                let data = try? HostRemoteWire.encode(
                    HostRemoteReply(token: command.token, ok: ok, payload: payload))
            else {
                if let rejected = try? HostRemoteWire.encode(
                    HostRemoteReply(token: command.token, ok: false))
                {
                    send(rejected)
                }
                return
            }
            send(data)
        }
    }
}
