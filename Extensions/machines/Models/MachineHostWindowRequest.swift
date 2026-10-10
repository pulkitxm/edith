import Foundation

struct MachineHostWindowRequest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case machine, files, docker, terminal }
    var kind: Kind
    var machineID: UUID
    var path: String?
    var presentationID: UUID?

    func validate() throws {
        guard path.map({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }) ?? true,
            path == nil || kind == .files
        else { throw MachineUIError.invalidRequest }
    }
}

@MainActor enum MachinesHostWindowNavigation {
    static var open: (MachineHostWindowRequest) async throws -> Void = { _ in
        throw MachineUIFailure(message: "The owning app window bridge is unavailable.")
    }
}

@MainActor final class MachineHostWindowNavigationClient {
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
        guard bridge.responds(to: NSSelectorFromString("openWindow:completion:")),
            bridge.responds(to: NSSelectorFromString("cancelNavigation:")),
            timeout > .zero, timeout <= .seconds(6)
        else { return nil }
        self.bridge = bridge
        self.timeout = timeout
    }

    func open(_ request: MachineHostWindowRequest) async throws {
        try request.validate()
        guard let presentation = request.presentationID else { throw MachineUIError.invalidRequest }
        guard !invalidated, pending.count < 8 else { throw MachineUIError.unavailable }
        var input: [String: String] = [
            "kind": request.kind.rawValue, "machineID": request.machineID.uuidString,
            "presentationID": presentation.uuidString,
        ]
        if let path = request.path { input["path"] = path }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(
                        id,
                        result: .failure(
                            MachineUIFailure(
                                message: "The owning app window request timed out.")), cancel: true)
                }
                pending[id] = Pending(continuation: continuation, deadline: deadline)
                let selector = NSSelectorFromString("openWindow:completion:")
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
                                .failure(MachineUIFailure(message: $0))
                            } ?? .success(())
                        self?.finish(id, result: result, cancel: message != nil)
                    }
                }
                let token = open(bridge, selector, input as NSDictionary, completion)?
                    .takeUnretainedValue()
                guard let token, UUID(uuidString: token as String) != nil else {
                    finish(id, result: .failure(MachineUIError.unavailable), cancel: true)
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
            finish(id, result: .failure(MachineUIError.unavailable), cancel: true)
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
