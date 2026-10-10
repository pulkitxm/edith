import EdithExtensionSupport
import Foundation

@MainActor
final class HostRemoteEngineCalls {
    private struct Pending {
        let continuation: CheckedContinuation<Data, any Error>
        let timeout: Task<Void, Never>
    }
    private let connection: NSXPCConnection
    private let authorize: @MainActor () -> Bool
    private var pending: [UUID: Pending] = [:]
    private var invalidated = false

    init(connection: NSXPCConnection, authorize: @escaping @MainActor () -> Bool) {
        self.connection = connection
        self.authorize = authorize
    }

    func request(_ request: ExtensionEngineRequest) async throws -> Data {
        try request.validate()
        guard !invalidated, authorize(), pending.count < 8, pending[request.token] == nil else {
            throw HostWorkerError.rejected
        }
        let data = try ExtensionEngineWire.encode(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(request.timeout)) } catch { return }
                    self?.cancel(request.token)
                    self?.finish(request.token, result: .failure(HostWorkerError.timedOut))
                }
                pending[request.token] = Pending(continuation: continuation, timeout: timeout)
                guard
                    let proxy = connection.remoteObjectProxyWithErrorHandler({
                        @Sendable [weak self] _ in
                        Task { @MainActor [weak self] in self?.invalidate() }
                    }) as? HostRemoteEvents
                else { invalidate(); return }
                proxy.invoke(data) { @Sendable [weak self] bytes in
                    Task { @MainActor [weak self] in
                        do {
                            let reply = try ExtensionEngineWire.decode(
                                ExtensionEngineReply.self, from: bytes)
                            guard let self, self.authorize(), reply.token == request.token,
                                reply.ok,
                                reply.payload.count <= ExtensionEngineWire.maximumPayloadBytes,
                                (try? JSONSerialization.jsonObject(
                                    with: reply.payload, options: .fragmentsAllowed)) != nil
                            else { throw HostWorkerError.rejected }
                            self.finish(request.token, result: .success(reply.payload))
                        } catch { self?.finish(request.token, result: .failure(error)) }
                    }
                }
                if Task.isCancelled {
                    cancel(request.token)
                    finish(request.token, result: .failure(CancellationError()))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(request.token)
                self?.finish(request.token, result: .failure(CancellationError()))
            }
        }
    }

    func cancel(_ token: UUID) {
        guard !invalidated, pending[token] != nil,
            let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in })
                as? HostRemoteEvents
        else { return }
        proxy.cancelEngine(token.uuidString)
    }

    func invalidate() {
        guard !invalidated else { return }
        for token in Array(pending.keys) {
            cancel(token)
            finish(token, result: .failure(HostWorkerError.exited))
        }
        invalidated = true
    }

    private func finish(_ token: UUID, result: Result<Data, any Error>) {
        guard let request = pending.removeValue(forKey: token) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }
}

final class HostRemoteEngineReceiver: NSObject, HostRemoteEvents, @unchecked Sendable {
    typealias Execute = @MainActor @Sendable (ExtensionEngineRequest) async throws -> Data
    private struct Pending {
        let task: Task<Void, Never>
        let timeout: Task<Void, Never>
        let completion: Completion
    }
    private let receiveEvent: @MainActor (HostRemoteEvent) -> Void
    private let execute: Execute
    @MainActor private var peer: HostRemoteProcessIdentity?
    @MainActor private var pending: [UUID: Pending] = [:]
    @MainActor private var invalidated = false

    init(receive: @escaping @MainActor (HostRemoteEvent) -> Void, execute: @escaping Execute) {
        receiveEvent = receive
        self.execute = execute
    }

    @MainActor func authenticate(_ peer: HostRemoteProcessIdentity) { self.peer = peer }

    func receive(_ data: Data) {
        guard let event = try? HostRemoteWire.decode(HostRemoteEvent.self, from: data) else {
            return
        }
        Task { @MainActor [self] in
            guard !invalidated, peer?.isRunning == true else { return }
            receiveEvent(event)
        }
    }

    func invoke(_ data: Data, reply: @escaping (Data) -> Void) {
        let completion = Completion(reply: reply)
        Task { @MainActor [self] in
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion.rejectMalformed(); return }
            guard !invalidated, peer?.isRunning == true, (try? request.validate()) != nil,
                pending.count < 8, pending[request.token] == nil
            else { completion.finish(token: request.token, ok: false); return }
            let execution = Task { @MainActor [self] in
                do {
                    let payload = try await execute(request)
                    try Task.checkCancellation()
                    guard !invalidated, peer?.isRunning == true,
                        payload.count <= ExtensionEngineWire.maximumPayloadBytes,
                        (try? JSONSerialization.jsonObject(
                            with: payload, options: .fragmentsAllowed)) != nil
                    else { throw HostWorkerError.rejected }
                    finish(request.token, payload: payload)
                } catch { finish(request.token) }
            }
            let timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(request.timeout)) } catch { return }
                self?.finish(request.token)
            }
            pending[request.token] = Pending(
                task: execution, timeout: timeout, completion: completion)
        }
    }

    func cancelEngine(_ token: String) {
        guard token.utf8.count == 36, let token = UUID(uuidString: token) else { return }
        Task { @MainActor [self] in finish(token) }
    }

    @MainActor func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        for token in Array(pending.keys) { finish(token) }
    }

    @MainActor private func finish(_ token: UUID, payload: Data? = nil) {
        guard let request = pending.removeValue(forKey: token) else { return }
        request.task.cancel()
        request.timeout.cancel()
        request.completion.finish(token: token, ok: payload != nil, payload: payload ?? Data())
    }

    private final class Completion: @unchecked Sendable {
        private let reply: (Data) -> Void
        @MainActor private var finished = false
        init(reply: @escaping (Data) -> Void) { self.reply = reply }
        @MainActor func finish(token: UUID, ok: Bool, payload: Data = Data()) {
            guard !finished else { return }
            finished = true
            reply(
                (try? ExtensionEngineWire.encode(
                    ExtensionEngineReply(token: token, ok: ok, payload: payload))) ?? Data())
        }
        @MainActor func rejectMalformed() {
            guard !finished else { return }
            finished = true
            reply(Data())
        }
    }
}
