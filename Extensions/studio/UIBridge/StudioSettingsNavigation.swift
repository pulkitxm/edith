import EdithExtensionSupport
import Foundation

@MainActor final class StudioSettingsNavigation {
    private struct Pending {
        var token: NSString?
        let continuation: CheckedContinuation<Void, any Error>
        let deadline: Task<Void, Never>
    }

    private let bridge: NSObject
    private var pending: [UUID: Pending] = [:]
    private var invalidated = false

    init?(bridge: NSObject?) {
        guard let bridge, bridge.responds(to: NSSelectorFromString("navigate:completion:")),
            bridge.responds(to: NSSelectorFromString("cancelNavigation:"))
        else { return nil }
        self.bridge = bridge
    }

    func execute(_ payload: Data) async throws -> Data {
        guard !payload.isEmpty, payload.count <= 1024,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: String],
            Set(object.keys) == ["presentationID"],
            let value = object["presentationID"], let presentationID = UUID(uuidString: value)
        else { throw ExtensionPeerError.invalidRequest }
        try await navigate(presentationID)
        return Data("{}".utf8)
    }

    private func navigate(_ presentationID: UUID) async throws {
        try Task.checkCancellation()
        guard !invalidated, pending.count < 8 else { throw ExtensionPeerError.unavailable }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.finish(id, result: .failure(ExtensionPeerError.unavailable), cancel: true)
                }
                pending[id] = Pending(token: nil, continuation: continuation, deadline: deadline)
                let selector = NSSelectorFromString("navigate:completion:")
                typealias Navigate =
                    @convention(c) (
                        AnyObject, Selector, NSDictionary, @convention(block) (NSString?) -> Void
                    ) -> NSString?
                let navigate = unsafeBitCast(bridge.method(for: selector), to: Navigate.self)
                let completion: @convention(block) (NSString?) -> Void = {
                    @Sendable [weak self] message in
                    let message = message as String?
                    Task { @MainActor [weak self] in
                        self?.finish(
                            id,
                            result: message.map {
                                .failure(ExtensionPeerError.rejected($0))
                            } ?? .success(()))
                    }
                }
                let token = navigate(
                    bridge, selector,
                    [
                        "section": "studio", "presentationID": presentationID.uuidString,
                        "location": "settings",
                    ] as NSDictionary, completion)
                if let token, UUID(uuidString: token as String) != nil {
                    pending[id]?.token = token
                } else {
                    finish(id, result: .failure(ExtensionPeerError.unavailable))
                }
                if Task.isCancelled {
                    finish(id, result: .failure(CancellationError()), cancel: true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id, result: .failure(CancellationError()), cancel: true)
            }
        }
        try Task.checkCancellation()
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        for id in Array(pending.keys) {
            finish(id, result: .failure(ExtensionPeerError.unavailable), cancel: true)
        }
    }

    func stopAndWait() async {
        let deadlines = pending.values.map(\.deadline)
        invalidate()
        for task in deadlines { await task.value }
    }

    private func finish(
        _ id: UUID, result: Result<Void, any Error>, cancel: Bool = false
    ) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        if cancel, let token = request.token {
            let selector = NSSelectorFromString("cancelNavigation:")
            typealias Cancel = @convention(c) (AnyObject, Selector, NSString) -> Void
            let cancel = unsafeBitCast(bridge.method(for: selector), to: Cancel.self)
            cancel(bridge, selector, token)
        }
        request.continuation.resume(with: result)
    }
}
