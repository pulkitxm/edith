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
    nonisolated private let callbacks = HostRemoteCallbackRetirement()

    init(connection: NSXPCConnection, authorize: @escaping @MainActor () -> Bool) {
        self.connection = connection
        self.authorize = authorize
    }

    func request(_ request: ExtensionEngineRequest) async throws -> Data {
        try request.validate()
        guard !invalidated, authorize(),
            pending.count < ExtensionEngineWire.maximumConcurrentRequests,
            pending[request.token] == nil
        else {
            throw HostWorkerError.rejected
        }
        let data = try ExtensionEngineWire.encode(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard
                    let timeout = callbacks.schedule({ [weak self] in
                        do { try await Task.sleep(for: .seconds(request.timeout)) } catch { return }
                        self?.cancel(request.token)
                        self?.finish(request.token, result: .failure(HostWorkerError.timedOut))
                    })
                else { continuation.resume(throwing: HostWorkerError.exited); return }
                pending[request.token] = Pending(continuation: continuation, timeout: timeout)
                guard
                    let proxy = connection.remoteObjectProxyWithErrorHandler({
                        @Sendable [weak self] _ in
                        self?.callbacks.schedule { [weak self] in self?.invalidate() }
                    }) as? HostRemoteEvents
                else { invalidate(); return }
                proxy.invoke(data) { @Sendable [weak self] bytes in
                    self?.callbacks.schedule { [weak self] in
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
        } onCancel: { [weak self] in
            self?.callbacks.schedule { [weak self] in
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
        callbacks.close()
    }

    func invalidateAndWait() async {
        invalidate()
        await callbacks.closeAndWait()
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
        #if EDITH_FUNCTIONAL_FIXTURE
        let invocation: HostRemoteSession.FixtureNativeRequest
        let observe: (HostRemoteSession.FixtureNativeReply) throws -> Void
        #endif
    }
    private let receiveEvent: @MainActor (HostRemoteEvent) -> Void
    private let execute: Execute
    private let admit: @MainActor @Sendable (ExtensionEngineRequest) -> Bool
    private let callbacks = HostRemoteCallbackRetirement()
    @MainActor private var peer: HostRemoteProcessIdentity?
    @MainActor private var pending: [UUID: Pending] = [:]
    @MainActor private var invalidated = false
    @MainActor private let ownership = HostRemoteInvocationRetirement()

    init(
        receive: @escaping @MainActor (HostRemoteEvent) -> Void,
        admit: @escaping @MainActor @Sendable (ExtensionEngineRequest) -> Bool = { _ in true },
        execute: @escaping Execute
    ) {
        receiveEvent = receive
        self.execute = execute
        self.admit = admit
    }

    @MainActor func authenticate(_ peer: HostRemoteProcessIdentity) { self.peer = peer }

    func receive(_ data: Data) {
        guard let event = try? HostRemoteWire.decode(HostRemoteEvent.self, from: data) else {
            return
        }
        callbacks.schedule { [self] in
            guard !invalidated, peer?.isRunning == true else { return }
            receiveEvent(event)
        }
    }

    func invoke(_ data: Data, reply: @escaping (Data) -> Void) {
        let completion = Completion(reply: reply)
        let callback = callbacks.schedule { [self] in
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion.rejectMalformed(); return }
            guard !invalidated, let peer, peer.isRunning, (try? request.validate()) != nil,
                ownership.accepts(request.token), pending[request.token] == nil, admit(request)
            else { completion.finish(token: request.token, ok: false); return }
            #if EDITH_FUNCTIONAL_FIXTURE
            guard let observe = HostRemoteSession.fixtureObserveNativeReply,
                let receiver = try? HostRemoteKernelIdentity.read(getpid())
            else { completion.finish(token: request.token, ok: false); return }
            let invocation = HostRemoteSession.FixtureNativeRequest(
                ui: peer, receiver: receiver, request: request)
            #endif
            let execution = Task { @MainActor [self] in
                do {
                    try Task.checkCancellation()
                    guard !invalidated, self.peer == peer, peer.isRunning,
                        let admission = ownership.admission(for: request.token)
                    else { throw HostWorkerError.rejected }
                    let payload = try await HostRemoteInvocationAdmission.$current.withValue(
                        admission
                    ) { try await execute(request) }
                    try Task.checkCancellation()
                    guard !invalidated, self.peer == peer, peer.isRunning,
                        payload.count <= ExtensionEngineWire.maximumPayloadBytes,
                        (try? JSONSerialization.jsonObject(
                            with: payload, options: .fragmentsAllowed)) != nil
                    else { throw HostWorkerError.rejected }
                    finish(request.token, payload: payload)
                } catch { finish(request.token) }
            }
            ownership.retain(execution, token: request.token)
            guard
                let timeout = callbacks.schedule({ [weak self] in
                    do { try await Task.sleep(for: .seconds(request.timeout)) } catch { return }
                    self?.finish(request.token)
                })
            else {
                ownership.cancel(request.token)
                completion.finish(token: request.token, ok: false)
                return
            }
            #if EDITH_FUNCTIONAL_FIXTURE
            pending[request.token] = Pending(
                task: execution, timeout: timeout, completion: completion,
                invocation: invocation, observe: observe)
            #else
            pending[request.token] = Pending(
                task: execution, timeout: timeout, completion: completion)
            #endif
        }
        if callback == nil { reply(Data()) }
    }

    func cancelEngine(_ token: String) {
        guard token.utf8.count == 36, let token = UUID(uuidString: token) else { return }
        callbacks.schedule { [self] in finish(token) }
    }

    @MainActor func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        callbacks.close()
        ownership.close()
        for token in Array(pending.keys) { finish(token) }
    }

    @MainActor func invalidateAndWait() async {
        invalidate()
        await callbacks.closeAndWait()
        await ownership.closeAndWait()
    }

    @MainActor private func finish(_ token: UUID, payload: Data? = nil) {
        guard let request = pending.removeValue(forKey: token) else { return }
        ownership.cancel(token)
        request.timeout.cancel()
        let reply = ExtensionEngineReply(
            token: token, ok: payload != nil, payload: payload ?? Data())
        let encoded = request.completion.finish(token: token, ok: reply.ok, payload: reply.payload)
        #if EDITH_FUNCTIONAL_FIXTURE
        if let encoded {
            do {
                try request.observe(
                    HostRemoteSession.FixtureNativeReply(
                        invocation: request.invocation, reply: reply, encodedReply: encoded))
            } catch { invalidate() }
        }
        #endif
    }

    private final class Completion: @unchecked Sendable {
        private let reply: (Data) -> Void
        @MainActor private var finished = false
        init(reply: @escaping (Data) -> Void) { self.reply = reply }
        @discardableResult
        @MainActor func finish(token: UUID, ok: Bool, payload: Data = Data()) -> Data? {
            guard !finished else { return nil }
            finished = true
            let encoded =
                (try? ExtensionEngineWire.encode(
                    ExtensionEngineReply(token: token, ok: ok, payload: payload))) ?? Data()
            reply(encoded)
            return encoded
        }
        @MainActor func rejectMalformed() {
            guard !finished else { return }
            finished = true
            reply(Data())
        }
    }
}
