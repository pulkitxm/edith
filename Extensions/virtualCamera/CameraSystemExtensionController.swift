import Foundation
import SystemExtensions

enum CameraSystemExtensionOperation: Equatable {
    case activate
    case deactivate
}

enum CameraSystemExtensionEvent {
    case approvalRequired
    case completed
    case restartRequired
    case failed(String)
}

@MainActor
protocol CameraSystemExtensionSubmitting: AnyObject {
    func submit(
        _ operation: CameraSystemExtensionOperation, identifier: String,
        completion: @escaping @MainActor (CameraSystemExtensionEvent) -> Void)
}

@MainActor
final class CameraSystemExtensionController {
    enum Phase: Equatable {
        case idle, activating, awaitingApproval, active, deactivating, stopped, restartRequired
        case failed(String)
    }

    private struct Flight {
        let token: UUID
        let operation: CameraSystemExtensionOperation
        let previouslyActive: Bool
    }
    private struct Waiter {
        let operation: CameraSystemExtensionOperation
        let continuation: CheckedContinuation<Void, Error>
    }

    private let identifier: String
    private let broker: any CameraSystemExtensionSubmitting
    private let providerExited: @MainActor () async throws -> Bool
    private var flight: Flight?
    private var waiters: [UUID: Waiter] = [:]
    private var verification: Task<Void, Never>?
    private var wantsInactive = false
    private(set) var ownsProvider: Bool
    private(set) var phase: Phase
    var changed: ((Phase) -> Void)?
    var pendingRequest: Bool { flight != nil || verification != nil }

    init(
        identifier: String, broker: any CameraSystemExtensionSubmitting,
        initiallyActive: Bool = false,
        providerExited: @escaping @MainActor () async throws -> Bool
    ) {
        self.identifier = identifier; self.broker = broker; self.ownsProvider = initiallyActive
        self.phase = initiallyActive ? .active : .idle; self.providerExited = providerExited
    }

    func activate() async throws {
        guard !wantsInactive, phase != .deactivating, phase != .restartRequired else {
            throw failure(
                "Finish disabling the camera or restart macOS before activating it again.")
        }
        try await request(.activate)
    }
    func deactivate() async throws {
        guard phase != .restartRequired else {
            throw failure("Restart macOS before finishing the camera extension change.")
        }
        try await request(.deactivate)
    }

    private func request(_ operation: CameraSystemExtensionOperation) async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard waiters.count < 8 else {
                    continuation.resume(
                        throwing: failure("Another camera request is still in progress."))
                    return
                }
                waiters[token] = .init(operation: operation, continuation: continuation)
                if operation == .deactivate { wantsInactive = true }
                advance()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(token) }
        }
    }

    private func cancel(_ token: UUID) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if waiter.operation == .activate { wantsInactive = true }
        advance()
    }

    private func advance() {
        guard flight == nil, verification == nil else { return }
        if wantsInactive {
            if ownsProvider {
                submit(.deactivate)
            } else {
                setPhase(.stopped); wantsInactive = false; finish(.deactivate, error: nil)
            }
        } else if waiters.values.contains(where: { $0.operation == .activate }) {
            if ownsProvider {
                setPhase(.active); finish(.activate, error: nil)
            } else {
                submit(.activate)
            }
        }
    }

    private func submit(_ operation: CameraSystemExtensionOperation) {
        let next = Flight(token: UUID(), operation: operation, previouslyActive: ownsProvider)
        flight = next
        ownsProvider = true
        setPhase(operation == .activate ? .activating : .deactivating)
        broker.submit(operation, identifier: identifier) { [weak self] event in
            self?.receive(event, token: next.token)
        }
    }

    private func receive(_ event: CameraSystemExtensionEvent, token: UUID) {
        guard let current = flight, current.token == token, verification == nil else { return }
        switch event {
        case .approvalRequired:
            setPhase(.awaitingApproval)
        case .completed:
            if current.operation == .activate {
                flight = nil; ownsProvider = true
                if wantsInactive {
                    finish(.activate, error: CancellationError())
                    advance()
                } else {
                    setPhase(.active); finish(.activate, error: nil)
                }
            } else {
                verification = Task { [weak self, providerExited] in
                    do {
                        let exited = try await providerExited()
                        guard let self, self.flight?.token == token else { return }
                        self.verification = nil; self.flight = nil
                        if exited {
                            self.ownsProvider = false; self.wantsInactive = false
                            self.setPhase(.stopped); self.finish(.deactivate, error: nil)
                            self.advance()
                        } else {
                            self.failedStop(
                                "The camera provider is still running. Try disabling it again.")
                        }
                    } catch {
                        guard let self, self.flight?.token == token else { return }
                        self.verification = nil; self.flight = nil
                        self.failedStop(error.localizedDescription)
                    }
                }
            }
        case .restartRequired:
            flight = nil
            ownsProvider = true
            wantsInactive = false
            setPhase(.restartRequired)
            let error = failure(
                "macOS requires a restart before the camera extension change completes.")
            finish(.activate, error: error); finish(.deactivate, error: error)
        case let .failed(message):
            flight = nil
            ownsProvider = current.operation == .deactivate || current.previouslyActive
            setPhase(.failed(message))
            finish(current.operation, error: failure(message))
            if current.operation == .deactivate {
                wantsInactive = false
                finish(.activate, error: failure(message))
            } else {
                advance()
            }
        }
    }

    private func failedStop(_ message: String) {
        ownsProvider = true; wantsInactive = false
        setPhase(.failed(message)); finish(.deactivate, error: failure(message))
    }

    private func finish(_ operation: CameraSystemExtensionOperation, error: Error?) {
        let completed = waiters.filter { $0.value.operation == operation }
        for (token, waiter) in completed {
            waiters.removeValue(forKey: token)
            if let error {
                waiter.continuation.resume(throwing: error)
            } else {
                waiter.continuation.resume()
            }
        }
    }

    private func setPhase(_ phase: Phase) { self.phase = phase; changed?(phase) }
    private func failure(_ message: String) -> NSError {
        .init(domain: "EdithCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
final class CameraSystemExtensionBroker: NSObject, CameraSystemExtensionSubmitting,
    OSSystemExtensionRequestDelegate
{
    private struct Pending {
        let request: OSSystemExtensionRequest
        let completion: @MainActor (CameraSystemExtensionEvent) -> Void
    }
    private var pending: [ObjectIdentifier: Pending] = [:]

    func submit(
        _ operation: CameraSystemExtensionOperation, identifier: String,
        completion: @escaping @MainActor (CameraSystemExtensionEvent) -> Void
    ) {
        let request =
            operation == .activate
            ? OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: identifier, queue: .main)
            : OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pending[ObjectIdentifier(request)] = .init(request: request, completion: completion)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated {
            pending[ObjectIdentifier(request)]?.completion(.approvalRequired)
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        MainActor.assumeIsolated {
            pending.removeValue(forKey: ObjectIdentifier(request))?.completion(
                result == .completed ? .completed : .restartRequired)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            pending.removeValue(forKey: ObjectIdentifier(request))?.completion(
                .failed(error.localizedDescription))
        }
    }
}
