import Foundation

@MainActor
public final class HostWorkerNavigationClient: NSObject {
    private struct Pending {
        let finish: @MainActor (Result<Void, any Error>) -> Void
        let deadline: Task<Void, Never>
    }

    private let configuration: HostWorkerConfiguration
    private let available: @MainActor () -> Bool
    private let send: @MainActor (HostWorkerNavigationRequest) throws -> Void
    private let sendCancel: @MainActor (HostWorkerNavigationCancel) throws -> Void
    private var pending: [UUID: Pending] = [:]
    private var invalidated = false

    public init(
        configuration: HostWorkerConfiguration, available: @escaping @MainActor () -> Bool,
        send: @escaping @MainActor (HostWorkerNavigationRequest) throws -> Void,
        cancel: @escaping @MainActor (HostWorkerNavigationCancel) throws -> Void
    ) {
        self.configuration = configuration
        self.available = available
        self.send = send
        sendCancel = cancel
    }

    public func request(
        section: String? = nil, relativePath: String? = nil,
        presentationID: UUID? = nil, location: String? = nil,
        timeout: Duration = .seconds(5)
    ) async throws {
        let request = HostWorkerNavigationRequest(
            configuration: configuration, section: section, relativePath: relativePath,
            presentationID: presentationID, location: location)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try begin(request, timeout: timeout) { continuation.resume(with: $0) }
                    if Task.isCancelled { cancel(request.token) }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(request.token) }
        }
    }

    @objc(navigate:completion:)
    public func navigate(_ input: NSDictionary, completion: @escaping (NSString?) -> Void)
        -> NSString?
    {
        let keys = ["section", "relativePath", "presentationID", "location"]
        guard input.allKeys.allSatisfy({ ($0 as? String).map(keys.contains) == true }),
            keys.allSatisfy({ input[$0] == nil || input[$0] is String }),
            input["presentationID"] == nil
                || UUID(uuidString: input["presentationID"] as? String ?? "") != nil
        else { completion("Navigation was rejected."); return nil }
        let request = HostWorkerNavigationRequest(
            configuration: configuration, section: input["section"] as? String,
            relativePath: input["relativePath"] as? String,
            presentationID: (input["presentationID"] as? String).flatMap(UUID.init(uuidString:)),
            location: input["location"] as? String)
        do {
            try begin(request, timeout: .seconds(5)) { result in
                switch result {
                case .success: completion(nil)
                case .failure: completion("The owning window could not apply this navigation.")
                }
            }
            return request.token.uuidString as NSString
        } catch { completion("Navigation was rejected."); return nil }
    }

    @objc(openWindow:completion:)
    public func openWindow(_ input: NSDictionary, completion: @escaping (NSString?) -> Void)
        -> NSString?
    {
        let keys = ["kind", "machineID", "path", "presentationID"]
        guard input.allKeys.allSatisfy({ ($0 as? String).map(keys.contains) == true }),
            keys.allSatisfy({ input[$0] == nil || input[$0] is String }),
            let kind = (input["kind"] as? String).flatMap(
                HostMachinesWindowTarget.Kind.init(rawValue:)),
            let machine = (input["machineID"] as? String).flatMap(UUID.init(uuidString:)),
            let presentation = (input["presentationID"] as? String).flatMap(UUID.init(uuidString:))
        else { completion("The owning window request was rejected."); return nil }
        let target = HostMachinesWindowTarget(
            kind: kind, machineID: machine, path: input["path"] as? String)
        let request = HostWorkerNavigationRequest(
            configuration: configuration,
            presentationID: presentation, machinesWindow: target)
        do {
            try begin(request, timeout: .seconds(5)) { result in
                switch result {
                case .success: completion(nil)
                case .failure: completion("The owning window could not open this view.")
                }
            }
            return request.token.uuidString as NSString
        } catch { completion("The owning window request was rejected."); return nil }
    }

    @objc(openHerdrWindow:completion:)
    public func openHerdrWindow(_ input: NSDictionary, completion: @escaping (NSString?) -> Void)
        -> NSString?
    {
        do {
            guard
                Set(input.allKeys.compactMap { $0 as? String }) == [
                    "presentationID", "descriptor",
                ],
                input.count == 2, let data = input["descriptor"] as? Data,
                let value = input["presentationID"] as? String,
                let presentation = UUID(uuidString: value)
            else { throw HostWorkerError.rejected }
            let target = try HostHerdrWindowTarget.decode(data)
            let request = HostWorkerNavigationRequest(
                configuration: configuration,
                presentationID: presentation, herdrWindow: target)
            try begin(request, timeout: .seconds(5)) { result in
                switch result {
                case .success: completion(nil)
                case .failure: completion("The owning window could not open this view.")
                }
            }
            return request.token.uuidString as NSString
        } catch { completion("The owning window request was rejected."); return nil }
    }

    @objc(cancelNavigation:)
    public func cancelNavigation(_ token: NSString) {
        guard let id = UUID(uuidString: token as String) else { return }
        cancel(id)
    }

    public func receive(_ reply: HostWorkerNavigationReply) throws {
        try reply.validate(configuration: configuration)
        finish(reply.token, result: reply.ok ? .success(()) : .failure(HostWorkerError.rejected))
    }

    public func cancelPending() {
        for token in Array(pending.keys) { cancel(token, error: HostWorkerError.rejected) }
    }

    public func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        for token in Array(pending.keys) { cancel(token, error: HostWorkerError.exited) }
    }

    private func begin(
        _ request: HostWorkerNavigationRequest, timeout: Duration,
        finish: @escaping @MainActor (Result<Void, any Error>) -> Void
    ) throws {
        guard !invalidated, available(), !configuration.recoveryOnly,
            pending.count < 8, pending[request.token] == nil,
            timeout > .zero, timeout <= .seconds(5)
        else { throw HostWorkerError.rejected }
        try request.validate(configuration: configuration)
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.cancel(request.token, error: HostWorkerError.timedOut)
        }
        pending[request.token] = Pending(finish: finish, deadline: deadline)
        do { try send(request) } catch {
            if let value = pending.removeValue(forKey: request.token) {
                value.deadline.cancel()
                throw error
            }
        }
    }

    private func cancel(_ token: UUID, error: any Error = CancellationError()) {
        guard pending[token] != nil else { return }
        try? sendCancel(HostWorkerNavigationCancel(token: token, configuration: configuration))
        finish(token, result: .failure(error))
    }

    private func finish(_ token: UUID, result: Result<Void, any Error>) {
        guard let value = pending.removeValue(forKey: token) else { return }
        value.deadline.cancel()
        value.finish(result)
    }
}
