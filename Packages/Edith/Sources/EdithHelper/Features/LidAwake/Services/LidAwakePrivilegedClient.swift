import EdithKit
import Foundation
import ServiceManagement

enum LidAwakePrivilegedClientState: String, Equatable {
    case notRegistered
    case awaitingApproval
    case enabled
    case notFound
}

enum LidAwakePrivilegedClientError: LocalizedError {
    case helperUnavailable(LidAwakePrivilegedClientState)
    case connectionFailed(String)
    case remoteError(Error)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let state):
            switch state {
            case .awaitingApproval:
                return
                    "Approve Edith in System Settings > General > Login Items, then run the command again."
            case .notFound:
                return "Edith's privileged helper is missing. Reinstall Edith and try again."
            case .notRegistered:
                return
                    "Edith's privileged helper could not be registered. Reopen Edith and try again."
            case .enabled:
                return "Edith's privileged helper is unavailable."
            }
        case .connectionFailed(let detail):
            return "Could not connect to Edith's privileged helper: \(detail)"
        case .remoteError(let error):
            return error.localizedDescription
        case .timedOut:
            return "Edith's privileged helper did not answer in time."
        }
    }
}

@MainActor
final class LidAwakePrivilegedClient {
    private let service = SMAppService.daemon(
        plistName: LidAwakePrivilegedService.plistName)
    private let requestTimeout: Duration

    init(requestTimeout: Duration = .seconds(15)) {
        self.requestTimeout = requestTimeout
    }

    var state: LidAwakePrivilegedClientState {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .awaitingApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    var isUsable: Bool { state == .enabled }

    func setSleepDisabled(_ disable: Bool) async throws {
        let currentState = state
        if let error = Self.requestError(for: currentState) {
            if currentState == .awaitingApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
            throw error
        }
        let connection = makeConnection()
        defer { connection.invalidate() }
        let connectionBox = LidAwakeXPCConnectionBox(connection)
        let reply = LidAwakePrivilegedReply()
        try await reply.wait(
            timeout: requestTimeout,
            cancel: { connectionBox.connection.invalidate() },
            send: { requestReply in
                guard
                    let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                        requestReply.resume(
                            throwing: LidAwakePrivilegedClientError.connectionFailed(
                                error.localizedDescription))
                    }) as? LidAwakePrivilegedProtocol
                else {
                    requestReply.resume(
                        throwing: LidAwakePrivilegedClientError.connectionFailed(
                            "The helper proxy is unavailable."))
                    return
                }
                proxy.setSleepDisabled(disable) { error in
                    if let error {
                        requestReply.resume(
                            throwing: LidAwakePrivilegedClientError.remoteError(error))
                    } else {
                        requestReply.resume()
                    }
                }
            })
    }

    nonisolated static func requestError(
        for state: LidAwakePrivilegedClientState
    ) -> LidAwakePrivilegedClientError? {
        guard state != .enabled else { return nil }
        return .helperUnavailable(state)
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: LidAwakePrivilegedService.machServiceName,
            options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(
            with: LidAwakePrivilegedProtocol.self)
        connection.resume()
        return connection
    }

}

private final class LidAwakeXPCConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

final class LidAwakePrivilegedReply: @unchecked Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Void, Error>)
        case finished(Result<Void, Error>)
    }

    private let lock = NSLock()
    private var state = State.pending

    func wait(
        timeout: Duration, cancel: @escaping @Sendable () -> Void,
        send: (LidAwakePrivilegedReply) -> Void
    ) async throws {
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            if self.resume(throwing: LidAwakePrivilegedClientError.timedOut) { cancel() }
        }
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if install(continuation) { send(self) }
            }
        } onCancel: {
            if self.resume(throwing: CancellationError()) { cancel() }
        }
    }

    @discardableResult
    func resume() -> Bool {
        finish(.success(()))
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) -> Bool {
        var continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        switch state {
        case .pending:
            state = .finished(result)
        case .waiting(let waiting):
            state = .finished(result)
            continuation = waiting
        case .finished:
            lock.unlock()
            return false
        }
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }

    private func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        var result: Result<Void, Error>?
        lock.lock()
        switch state {
        case .pending:
            state = .waiting(continuation)
        case .waiting:
            result = .failure(LidAwakePrivilegedClientError.connectionFailed("Duplicate request."))
        case .finished(let finished):
            result = finished
        }
        lock.unlock()
        if let result {
            continuation.resume(with: result)
            return false
        }
        return true
    }
}
