import Foundation

@MainActor
public final class ExtensionEngineClient {
    private struct Pending {
        let continuation: CheckedContinuation<Data, any Error>
        let timeout: Task<Void, Never>
    }

    public let presentationID: UUID
    private let bridge: NSObject
    private var pending: [UUID: Pending] = [:]
    private var invalidated = false

    public init?(bridge: NSObject, presentationID: UUID) {
        guard bridge.responds(to: NSSelectorFromString("invoke:completion:")),
            bridge.responds(to: NSSelectorFromString("cancel:"))
        else { return nil }
        self.bridge = bridge
        self.presentationID = presentationID
    }

    public func invoke(
        _ operation: String, payload: Data = Data("{}".utf8), timeout: Double = 30
    ) async throws -> Data {
        let request = ExtensionEngineRequest(
            presentationID: presentationID, operation: operation, payload: payload, timeout: timeout
        )
        try request.validate()
        guard !invalidated, pending.count < 8 else { throw ExtensionEngineError.unavailable }
        let data = try ExtensionEngineWire.encode(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.finish(request.token, result: .failure(ExtensionEngineError.timedOut))
                    self?.cancel(request.token)
                }
                pending[request.token] = Pending(continuation: continuation, timeout: deadline)
                let selector = NSSelectorFromString("invoke:completion:")
                typealias Invoke =
                    @convention(c) (
                        AnyObject, Selector, NSData, @convention(block) (NSData) -> Void
                    ) -> Void
                let invoke = unsafeBitCast(bridge.method(for: selector), to: Invoke.self)
                let completion: @convention(block) (NSData) -> Void = {
                    @Sendable [weak self] bytes in
                    let bytes = bytes as Data
                    Task { @MainActor [weak self] in
                        do {
                            let reply = try ExtensionEngineWire.decode(
                                ExtensionEngineReply.self, from: bytes)
                            guard reply.token == request.token, reply.ok,
                                reply.payload.count <= ExtensionEngineWire.maximumPayloadBytes,
                                (try? JSONSerialization.jsonObject(
                                    with: reply.payload, options: .fragmentsAllowed)) != nil
                            else { throw ExtensionEngineError.rejected }
                            self?.finish(request.token, result: .success(reply.payload))
                        } catch { self?.finish(request.token, result: .failure(error)) }
                    }
                }
                invoke(bridge, selector, data as NSData, completion)
                if Task.isCancelled {
                    finish(request.token, result: .failure(CancellationError()))
                    cancel(request.token)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(request.token, result: .failure(CancellationError()))
                self?.cancel(request.token)
            }
        }
    }

    public func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        for token in Array(pending.keys) {
            cancel(token)
            finish(token, result: .failure(ExtensionEngineError.unavailable))
        }
    }

    private func finish(_ token: UUID, result: Result<Data, any Error>) {
        guard let request = pending.removeValue(forKey: token) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func cancel(_ token: UUID) {
        let selector = NSSelectorFromString("cancel:")
        typealias Cancel = @convention(c) (AnyObject, Selector, NSString) -> Void
        let cancel = unsafeBitCast(bridge.method(for: selector), to: Cancel.self)
        cancel(bridge, selector, token.uuidString as NSString)
    }
}
