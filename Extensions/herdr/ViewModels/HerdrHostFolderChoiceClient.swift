import EdithExtensionSupport
import Foundation

@MainActor final class HerdrHostFolderChoiceClient {
    private struct Pending {
        let continuation: CheckedContinuation<String?, any Error>
        let deadline: Task<Void, Never>
        var token: NSString?
    }
    private let bridge: NSObject
    private let timeout: Duration
    private var pending: [UUID: Pending] = [:]
    private var invalidated = false

    init?(bridge: NSObject, timeout: Duration = .seconds(120)) {
        guard bridge.responds(to: NSSelectorFromString("chooseFolder:completion:")),
            bridge.responds(to: NSSelectorFromString("cancelNavigation:")),
            timeout > .zero, timeout <= .seconds(120)
        else { return nil }
        self.bridge = bridge
        self.timeout = timeout
    }

    func choose(presentationID: UUID) async throws -> String? {
        guard !invalidated, pending.isEmpty else { throw ExtensionPeerError.unavailable }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(id, .failure(ExtensionPeerError.unavailable), cancel: true)
                }
                pending[id] = Pending(continuation: continuation, deadline: deadline)
                let selector = NSSelectorFromString("chooseFolder:completion:")
                typealias Choose =
                    @convention(c) (
                        AnyObject, Selector, NSDictionary,
                        @convention(block) (NSDictionary?, NSString?) -> Void
                    ) -> Unmanaged<NSString>?
                let choose = unsafeBitCast(bridge.method(for: selector), to: Choose.self)
                let completion: @convention(block) (NSDictionary?, NSString?) -> Void = {
                    [weak self] reply, error in
                    let result: Result<String?, any Error>
                    do {
                        guard error == nil, let reply else { throw ExtensionPeerError.unavailable }
                        result = .success(try Self.path(reply))
                    } catch { result = .failure(error) }
                    Task { @MainActor [weak self] in
                        self?.finish(id, result, cancel: result.isFailure)
                    }
                }
                let token = choose(
                    bridge, selector, ["presentationID": presentationID.uuidString], completion)?
                    .takeUnretainedValue()
                guard let token, UUID(uuidString: token as String) != nil else {
                    finish(id, .failure(ExtensionPeerError.unavailable), cancel: true)
                    return
                }
                pending[id]?.token = token
                if Task.isCancelled { finish(id, .failure(CancellationError()), cancel: true) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id, .failure(CancellationError()), cancel: true)
            }
        }
    }

    nonisolated static func path(_ reply: NSDictionary) throws -> String? {
        if reply.count == 1, reply["cancelled"] as? Bool == true { return nil }
        guard reply.count == 1, let path = reply["selectedPath"] as? String,
            path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0),
            path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." })
        else { throw ExtensionPeerError.invalidRequest }
        return path
    }

    func invalidate() {
        invalidated = true
        for id in Array(pending.keys) {
            finish(id, .failure(ExtensionPeerError.unavailable), cancel: true)
        }
    }

    private func finish(_ id: UUID, _ result: Result<String?, any Error>, cancel: Bool) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        if cancel, let token = request.token {
            let selector = NSSelectorFromString("cancelNavigation:")
            typealias Cancel = @convention(c) (AnyObject, Selector, NSString) -> Void
            unsafeBitCast(bridge.method(for: selector), to: Cancel.self)(bridge, selector, token)
        }
        request.continuation.resume(with: result)
    }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { return true }; return false }
}
