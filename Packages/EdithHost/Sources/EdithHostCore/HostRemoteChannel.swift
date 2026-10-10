import EdithExtensionSupport
import Foundation

@MainActor
public final class HostRemoteChannel {
    private struct Pending {
        let continuation: CheckedContinuation<HostRemoteReply, any Error>
        let timeout: Task<Void, Never>
    }

    public private(set) var peer: HostRemoteProcessIdentity?
    public var didInvalidate: (@MainActor () -> Void)?
    private let connection: NSXPCConnection
    private var pending: [UUID: Pending] = [:]
    private var invalidated = false
    private let events: HostRemoteEngineReceiver

    public init(
        connection: NSXPCConnection,
        receive: @escaping @MainActor (HostRemoteEvent) -> Void = { _ in },
        executeEngine:
            @escaping @MainActor @Sendable (ExtensionEngineRequest) async throws -> Data = {
                _ in throw HostWorkerError.rejected
            }
    ) {
        self.connection = connection
        events = HostRemoteEngineReceiver(receive: receive, execute: executeEngine)
        connection.remoteObjectInterface = NSXPCInterface(with: HostRemoteControl.self)
        connection.exportedInterface = NSXPCInterface(with: HostRemoteEvents.self)
        connection.exportedObject = events
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in self?.invalidate() }
        }
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in self?.invalidate() }
        }
        connection.resume()
    }

    public static func connect(
        through bootstrap: NSXPCConnection, executable: URL,
        expectedPeer: HostRemoteProcessIdentity? = nil,
        rejectedPeer: @escaping @MainActor (HostRemoteProcessIdentity) -> Void = { _ in },
        receive: @escaping @MainActor (HostRemoteEvent) -> Void = { _ in },
        executeEngine:
            @escaping @MainActor @Sendable (ExtensionEngineRequest) async throws -> Data = {
                _ in throw HostWorkerError.rejected
            }
    ) async throws -> HostRemoteChannel {
        let endpoint = try await endpoint(through: bootstrap)
        return try await connect(
            to: endpoint.value, executable: executable, expectedPeer: expectedPeer,
            rejectedPeer: rejectedPeer, receive: receive,
            executeEngine: executeEngine)
    }

    public static func connect(
        to endpoint: NSXPCListenerEndpoint, executable: URL,
        expectedPeer: HostRemoteProcessIdentity? = nil,
        rejectedPeer: @escaping @MainActor (HostRemoteProcessIdentity) -> Void = { _ in },
        receive: @escaping @MainActor (HostRemoteEvent) -> Void = { _ in },
        executeEngine:
            @escaping @MainActor @Sendable (ExtensionEngineRequest) async throws -> Data = {
                _ in throw HostWorkerError.rejected
            }
    ) async throws -> HostRemoteChannel {
        let channel = HostRemoteChannel(
            connection: NSXPCConnection(listenerEndpoint: endpoint), receive: receive,
            executeEngine: executeEngine)
        do {
            _ = try await channel.request(HostRemoteCommand(operation: "authenticate"))
            let actual = try HostRemoteProcessIdentity.read(channel.connection.processIdentifier)
            let peer: HostRemoteProcessIdentity
            do {
                peer = try HostRemoteProcessIdentity.verify(
                    channel.connection, executable: executable)
            } catch {
                rejectedPeer(actual)
                throw error
            }
            guard expectedPeer == nil || expectedPeer == peer else {
                throw HostWorkerError.rejected
            }
            channel.peer = peer
            channel.events.authenticate(peer)
            return channel
        } catch {
            channel.invalidate()
            throw error
        }
    }

    public func request(_ command: HostRemoteCommand, timeout: Duration = .seconds(15)) async throws
        -> HostRemoteReply
    {
        guard !invalidated, (pending.count < 8), (timeout > .zero), timeout <= .seconds(30),
            peer?.isRunning ?? (command.operation == "authenticate")
        else { throw HostWorkerError.rejected }
        let bytes = try HostRemoteWire.encode(command)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(command.token, result: .failure(HostWorkerError.timedOut))
                    self?.cancel(command.token)
                }
                pending[command.token] = Pending(continuation: continuation, timeout: deadline)
                guard
                    let proxy = connection.remoteObjectProxyWithErrorHandler({
                        @Sendable [weak self] _ in
                        Task { @MainActor [weak self] in self?.invalidate() }
                    }) as? HostRemoteControl
                else {
                    invalidate()
                    return
                }
                proxy.exchange(bytes) { @Sendable [weak self] data in
                    Task { @MainActor [weak self] in
                        do {
                            let reply = try HostRemoteWire.decode(HostRemoteReply.self, from: data)
                            guard reply.token == command.token else {
                                throw HostWorkerError.invalidResponse
                            }
                            self?.finish(
                                command.token,
                                result: reply.ok
                                    ? .success(reply) : .failure(HostWorkerError.rejected))
                        } catch { self?.invalidate() }
                    }
                }
                if Task.isCancelled {
                    finish(command.token, result: .failure(CancellationError()))
                    cancel(command.token)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(command.token, result: .failure(CancellationError()))
                self?.cancel(command.token)
            }
        }
    }

    public func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        events.invalidate()
        for token in Array(pending.keys) {
            finish(token, result: .failure(HostWorkerError.exited))
        }
        didInvalidate?()
    }

    private func finish(_ token: UUID, result: Result<HostRemoteReply, any Error>) {
        guard let request = pending.removeValue(forKey: token) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func cancel(_ token: UUID) {
        guard !invalidated, let payload = try? HostRemoteWire.encode(token),
            let bytes = try? HostRemoteWire.encode(
                HostRemoteCommand(operation: "cancel", payload: payload)),
            let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in })
                as? HostRemoteControl
        else { return }
        proxy.exchange(bytes) { _ in }
    }

    private static func endpoint(through connection: NSXPCConnection) async throws -> Endpoint {
        connection.remoteObjectInterface = NSXPCInterface(with: HostRemoteBootstrap.self)
        connection.resume()
        let completion = EndpointCompletion()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.continuation = continuation
                completion.timeout = Task {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    completion.finish(.failure(HostWorkerError.timedOut))
                }
                guard
                    let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
                        Task { @MainActor in completion.finish(.failure(HostWorkerError.exited)) }
                    }) as? HostRemoteBootstrap
                else {
                    completion.finish(.failure(HostWorkerError.invalidResponse))
                    return
                }
                proxy.endpoint { @Sendable endpoint in
                    let value = Endpoint(value: endpoint)
                    Task { @MainActor in completion.finish(.success(value)) }
                }
                if Task.isCancelled { completion.finish(.failure(CancellationError())) }
            }
        } onCancel: {
            Task { @MainActor in completion.finish(.failure(CancellationError())) }
        }
    }

    private struct Endpoint: @unchecked Sendable {
        let value: NSXPCListenerEndpoint
    }

    @MainActor private final class EndpointCompletion {
        var continuation: CheckedContinuation<Endpoint, any Error>?
        var timeout: Task<Void, Never>?

        func finish(_ result: Result<Endpoint, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            continuation.resume(with: result)
        }
    }

}
