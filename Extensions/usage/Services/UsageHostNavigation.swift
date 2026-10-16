import EdithExtensionSupport
import Foundation

struct UsageNavigationRequest: Codable, Equatable, Sendable {
    let presentationID: UUID
    let location: String

    func validate() throws {
        guard ["home", "notch"].contains(location) else {
            throw ExtensionPeerError.invalidRequest
        }
    }

    var dictionary: NSDictionary {
        ["section": "dashboard", "presentationID": presentationID.uuidString, "location": location]
    }
}

@MainActor final class UsageHostNavigation {
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

    func navigate(_ request: UsageNavigationRequest) async throws {
        try request.validate()
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
                let token = navigate(bridge, selector, request.dictionary, completion)
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
