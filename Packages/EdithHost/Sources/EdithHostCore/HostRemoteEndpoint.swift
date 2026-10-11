import Darwin
import EdithExtensionSupport
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
    private var receivers: [Exchange] = []
    private var draining = false
    private var activeStop: UUID?
    private let retirements = HostRemoteCallbackRetirement()
    private let engineCallbacks = HostRemoteCallbackRetirement()
    @MainActor private let engineInvocations = HostRemoteInvocationRetirement()

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
            connection: connection, peer: peer, execute: execute, didDisconnect: didDisconnect,
            admit: { [weak self] command in self?.admit(command) == true },
            mayExecute: { [weak self] command in self?.mayExecute(command) == true },
            stopReturned: { [weak self] token in self?.releaseStop(token) })
        let accepted = lock.withLock {
            guard !invalidated, connections.contains(where: { $0 === connection }),
                receivers.count < 16
            else { return false }
            receivers.append(receiver)
            return true
        }
        guard accepted else { connection.invalidate(); return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: HostRemoteControl.self)
        connection.exportedObject = receiver
        connection.remoteObjectInterface = NSXPCInterface(with: HostRemoteEvents.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let connection else { return }
            self?.remove(connection)
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.resume()
        return true
    }

    @MainActor public func invokeEngine(_ request: ExtensionEngineRequest) async throws -> Data {
        guard !lock.withLock({ invalidated || draining }), engineInvocations.accepts(request.token)
        else { throw HostWorkerError.rejected }
        let bytes = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                beginEngineRequest(request) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            self.engineCallbacks.schedule { self.cancelEngine(request.token) }
        }
        try Task.checkCancellation()
        let reply = try ExtensionEngineWire.decode(ExtensionEngineReply.self, from: bytes)
        guard reply.token == request.token, reply.ok else { throw HostWorkerError.rejected }
        return reply.payload
    }

    @MainActor public func beginEngineRequest(
        _ request: ExtensionEngineRequest, completion: @escaping @MainActor (Data) -> Void
    ) {
        guard !lock.withLock({ invalidated || draining }), engineInvocations.accepts(request.token)
        else { completion(Data()); return }
        let task = Task { @MainActor [self] in
            let outcome: Result<Data, any Error>
            do {
                try Task.checkCancellation()
                guard !lock.withLock({ invalidated || draining }) else {
                    throw HostWorkerError.exited
                }
                let receivers = lock.withLock { self.receivers }
                var selected: Exchange?
                for receiver in receivers where receiver.isAuthenticated {
                    guard selected == nil else { throw HostWorkerError.rejected }
                    selected = receiver
                }
                guard let selected else { throw HostWorkerError.rejected }
                let payload = try await selected.engineCalls.request(request)
                try Task.checkCancellation()
                guard !lock.withLock({ invalidated || draining }) else {
                    throw HostWorkerError.exited
                }
                outcome = .success(payload)
            } catch { outcome = .failure(error) }
            completion(
                (try? ExtensionEngineWire.encode(
                    ExtensionEngineReply(
                        token: request.token, ok: (try? outcome.get()) != nil,
                        payload: (try? outcome.get()) ?? Data()))) ?? Data())
        }
        engineInvocations.retain(task, token: request.token)
    }

    @MainActor public func cancelEngine(_ token: UUID) {
        engineInvocations.cancel(token)
        let receivers = lock.withLock { self.receivers }
        receivers.forEach { $0.engineCalls.cancel(token) }
    }

    public func closeMutationAdmission() { lock.withLock { draining = true } }

    @MainActor public func prepareToStop(excluding token: UUID? = nil) async {
        let receivers = lock.withLock {
            draining = true
            return self.receivers
        }
        await engineCallbacks.closeAndWait()
        await engineInvocations.closeAndWait()
        for receiver in receivers { await receiver.prepareToStop(excluding: token) }
    }

    private func admit(_ command: HostRemoteCommand) -> Bool {
        lock.withLock {
            guard !invalidated else { return false }
            if command.operation == "stop" {
                guard activeStop == nil else { return false }
                activeStop = command.token
                draining = true
                return true
            }
            return !draining
        }
    }

    private func mayExecute(_ command: HostRemoteCommand) -> Bool {
        lock.withLock {
            !invalidated
                && (!draining || (command.operation == "stop" && activeStop == command.token))
        }
    }

    private func releaseStop(_ token: UUID) {
        lock.withLock { if activeStop == token { activeStop = nil } }
    }

    public func invalidate() {
        let snapshot = lock.withLock { () -> ([NSXPCConnection], [Exchange])? in
            guard !invalidated else { return nil }
            invalidated = true
            draining = true
            let values = connections
            connections.removeAll()
            return (values, receivers)
        }
        guard let snapshot else { return }
        for receiver in snapshot.1 {
            retirements.schedule { await receiver.invalidateAndWait() }
        }
        retirements.close()
        listener.invalidate()
        snapshot.0.forEach { $0.invalidate() }
    }

    @MainActor public func invalidateAndWait() async {
        invalidate()
        await engineCallbacks.closeAndWait()
        await engineInvocations.closeAndWait()
        let receivers = lock.withLock { self.receivers }
        for receiver in receivers { await receiver.invalidateAndWait() }
        await retirements.closeAndWait()
        lock.withLock { self.receivers.removeAll() }
    }

    private func retain(_ connection: NSXPCConnection) -> Bool {
        lock.withLock {
            guard !invalidated, connections.count < 16, receivers.count < 16 else { return false }
            connections.append(connection)
            return true
        }
    }

    private func remove(_ connection: NSXPCConnection) {
        let receiver = lock.withLock {
            connections.removeAll { $0 === connection }
            return receivers.first { $0.connection === connection }
        }
        guard let receiver else { return }
        retirements.schedule { [self] in
            await receiver.invalidateAndWait()
            lock.withLock { receivers.removeAll { $0 === receiver } }
        }
    }

    private final class Exchange: NSObject, HostRemoteControl, @unchecked Sendable {
        let connection: NSXPCConnection
        private let peer: HostRemoteKernelIdentity
        private let execute: Execute
        private let didDisconnect: @MainActor @Sendable () -> Void
        private let callbacks = HostRemoteCallbackRetirement()
        private let admit: @Sendable (HostRemoteCommand) -> Bool
        private let mayExecute: @Sendable (HostRemoteCommand) -> Bool
        private let stopReturned: @Sendable (UUID) -> Void
        @MainActor private let ownership = HostRemoteInvocationRetirement()
        @MainActor private var authenticated = false
        @MainActor private var invalidated = false
        @MainActor var isAuthenticated: Bool {
            authenticated && !invalidated && (try? peer.verify(connection)) != nil
        }
        @MainActor lazy var engineCalls = HostRemoteEngineCalls(connection: connection) {
            [weak self] in
            self?.isAuthenticated == true
        }

        init(
            connection: NSXPCConnection, peer: HostRemoteKernelIdentity, execute: @escaping Execute,
            didDisconnect: @escaping @MainActor @Sendable () -> Void,
            admit: @escaping @Sendable (HostRemoteCommand) -> Bool,
            mayExecute: @escaping @Sendable (HostRemoteCommand) -> Bool,
            stopReturned: @escaping @Sendable (UUID) -> Void
        ) {
            self.connection = connection
            self.peer = peer
            self.execute = execute
            self.didDisconnect = didDisconnect
            self.admit = admit
            self.mayExecute = mayExecute
            self.stopReturned = stopReturned
        }

        func exchange(_ data: Data, reply: @escaping (Data) -> Void) {
            let completion = Reply(send: reply)
            let accepted = callbacks.schedule { [self] in
                guard !invalidated, (try? peer.verify(connection)) != nil,
                    let command = try? HostRemoteWire.decode(HostRemoteCommand.self, from: data),
                    !command.operation.isEmpty, command.operation.utf8.count <= 64,
                    !command.operation.utf8.contains(0), !ownership.contains(command.token)
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
                    ownership.cancel(token)
                    completion.finish(command, ok: true)
                    return
                }
                guard ownership.accepts(command.token), admit(command) else {
                    completion.finish(command, ok: false); return
                }
                let actual = Task { @MainActor [self] in
                    do {
                        try Task.checkCancellation()
                        guard mayExecute(command), (try? peer.verify(connection)) != nil else {
                            throw HostWorkerError.exited
                        }
                        let bytes = try await execute(command)
                        try Task.checkCancellation()
                        guard !invalidated, (try? peer.verify(connection)) != nil else {
                            throw HostWorkerError.exited
                        }
                        completion.finish(command, ok: true, payload: bytes)
                    } catch { completion.finish(command, ok: false) }
                }
                ownership.retain(actual, token: command.token)
                if command.operation == "stop" {
                    Task { [stopReturned] in
                        await actual.value
                        stopReturned(command.token)
                    }
                }
            }
            if accepted == nil { reply(Data()) }
        }

        @MainActor func prepareToStop(excluding token: UUID?) async {
            await callbacks.joinCurrent()
            await ownership.cancelAndJoin(excluding: token)
            await engineCalls.invalidateAndWait()
        }

        @MainActor func invalidate() {
            guard !invalidated else { return }
            invalidated = true
            callbacks.close()
            ownership.close()
            engineCalls.invalidate()
            if authenticated { didDisconnect() }
        }

        @MainActor func invalidateAndWait() async {
            invalidate()
            await callbacks.closeAndWait()
            await ownership.closeAndWait()
            await engineCalls.invalidateAndWait()
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
