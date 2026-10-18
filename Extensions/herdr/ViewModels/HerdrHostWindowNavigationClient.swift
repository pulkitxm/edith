import EdithExtensionSupport
import Foundation

@MainActor final class HerdrHostWindowNavigationClient {
    private struct Pending {
        let continuation: CheckedContinuation<Void, any Error>
        let deadline: Task<Void, Never>
        var hostToken: NSString?
    }

    private let bridge: NSObject
    private let timeout: Duration
    private var pending: [UUID: Pending] = [:]
    private var invalidated = false

    init?(bridge: NSObject, timeout: Duration = .seconds(6)) {
        guard bridge.responds(to: NSSelectorFromString("openHerdrWindow:completion:")),
            bridge.responds(to: NSSelectorFromString("cancelNavigation:")),
            timeout > .zero, timeout <= .seconds(6)
        else { return nil }
        self.bridge = bridge
        self.timeout = timeout
    }

    func open(_ descriptor: HerdrUIPresentation, presentationID: UUID) async throws {
        try descriptor.validate()
        guard !invalidated, pending.count < 8 else { throw ExtensionPeerError.unavailable }
        let input: [String: Any] = [
            "presentationID": presentationID.uuidString,
            "descriptor": try JSONEncoder().encode(descriptor),
        ]
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(
                        id,
                        result: .failure(
                            ExtensionPeerError.rejected("The owning app window request timed out.")),
                        cancel: true)
                }
                pending[id] = Pending(continuation: continuation, deadline: deadline)
                let selector = NSSelectorFromString("openHerdrWindow:completion:")
                typealias Open =
                    @convention(c) (
                        AnyObject, Selector, NSDictionary, @convention(block) (NSString?) -> Void
                    ) -> Unmanaged<NSString>?
                let open = unsafeBitCast(bridge.method(for: selector), to: Open.self)
                let completion: @convention(block) (NSString?) -> Void = { [weak self] error in
                    let message = error.map { String(($0 as String).prefix(1024)) }
                    Task { @MainActor [weak self] in
                        let result: Result<Void, any Error> =
                            message.map {
                                .failure(ExtensionPeerError.rejected($0))
                            } ?? .success(())
                        self?.finish(id, result: result, cancel: message != nil)
                    }
                }
                let token = open(bridge, selector, input as NSDictionary, completion)?
                    .takeUnretainedValue()
                guard let token, UUID(uuidString: token as String) != nil else {
                    finish(id, result: .failure(ExtensionPeerError.unavailable), cancel: true)
                    return
                }
                pending[id]?.hostToken = token
                if Task.isCancelled {
                    finish(id, result: .failure(CancellationError()), cancel: true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id, result: .failure(CancellationError()), cancel: true)
            }
        }
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        for id in Array(pending.keys) {
            finish(id, result: .failure(ExtensionPeerError.unavailable), cancel: true)
        }
    }

    private func finish(_ id: UUID, result: Result<Void, any Error>, cancel: Bool) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        if cancel, let token = request.hostToken {
            let selector = NSSelectorFromString("cancelNavigation:")
            typealias Cancel = @convention(c) (AnyObject, Selector, NSString) -> Void
            let cancel = unsafeBitCast(bridge.method(for: selector), to: Cancel.self)
            cancel(bridge, selector, token)
        }
        request.continuation.resume(with: result)
    }
}
