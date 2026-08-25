import EdithKit
import Foundation
import Security
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
    private static let fingerprintKey = "lidAwakePrivilegedHelperFingerprint"

    private let service = SMAppService.daemon(
        plistName: LidAwakePrivilegedService.plistName)
    private let fingerprint = LidAwakePrivilegedClient.helperFingerprint()
    private var connection: NSXPCConnection?
    private var approvalRequired = false
    private var registrationInFlight = false
    private let requestTimeout: Duration
    private(set) var registrationError: String?

    init(requestTimeout: Duration = .seconds(15)) {
        self.requestTimeout = requestTimeout
    }

    var state: LidAwakePrivilegedClientState {
        let serviceState: LidAwakePrivilegedClientState =
            switch service.status {
            case .notRegistered: .notRegistered
            case .enabled: .enabled
            case .requiresApproval: .awaitingApproval
            case .notFound: .notFound
            @unknown default: .notFound
            }
        return approvalRequired && serviceState != .enabled ? .awaitingApproval : serviceState
    }

    var isUsable: Bool { state == .enabled }

    func register() {
        guard !registrationInFlight else { return }
        let currentState = state
        if currentState == .awaitingApproval {
            persistFingerprint()
            return
        }
        if currentState == .enabled {
            guard let fingerprint else { return }
            if UserDefaults.standard.string(forKey: Self.fingerprintKey) == fingerprint { return }
            reregister()
            return
        }
        registerCurrent()
    }

    private func registerCurrent() {
        do {
            try service.register()
            approvalRequired = false
            registrationError = nil
            persistFingerprint()
        } catch {
            let failure = error as NSError
            if service.status == .requiresApproval
                || (failure.domain == "SMAppServiceErrorDomain" && failure.code == 1)
            {
                approvalRequired = true
                registrationError = nil
                persistFingerprint()
            } else {
                registrationError =
                    "Service Management registration failed (\(failure.domain) \(failure.code)): \(failure.localizedDescription)"
                NSLog("%@", registrationError ?? "Service Management registration failed")
            }
        }
    }

    private func reregister() {
        registrationInFlight = true
        service.unregister { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.registrationInFlight = false
                if let error {
                    let failure = error as NSError
                    self.registrationError =
                        "Service Management update failed (\(failure.domain) \(failure.code)): \(failure.localizedDescription)"
                    return
                }
                self.registerCurrent()
            }
        }
    }

    private func persistFingerprint() {
        if let fingerprint {
            UserDefaults.standard.set(fingerprint, forKey: Self.fingerprintKey)
        }
    }

    func unregister() {
        do {
            try service.unregister()
        } catch {
            NSLog("SMAppService unregistration failed: \((error as NSError).localizedDescription)")
        }
    }

    func setSleepDisabled(_ disable: Bool) async throws {
        var currentState = state
        if currentState == .awaitingApproval {
            registerCurrent()
            currentState = state
        }
        guard currentState == .enabled else {
            if currentState == .awaitingApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
            throw LidAwakePrivilegedClientError.helperUnavailable(currentState)
        }
        let connection = connection ?? makeConnection()
        self.connection = connection
        let connectionBox = LidAwakeXPCConnectionBox(connection)
        let reply = LidAwakePrivilegedReply()
        do {
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
        } catch {
            if self.connection === connection { self.connection = nil }
            connection.invalidate()
            throw error
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: LidAwakePrivilegedService.machServiceName,
            options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(
            with: LidAwakePrivilegedProtocol.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection else { return }
                self.clearConnection(connection)
            }
        }
        connection.interruptionHandler = { [weak self, weak connection] in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection else { return }
                self.clearConnection(connection)
            }
        }
        connection.resume()
        return connection
    }

    private func clearConnection(_ invalidatedConnection: NSXPCConnection) {
        if connection === invalidatedConnection { connection = nil }
    }

    private static func helperFingerprint() -> String? {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/PrivilegedHelperTools")
            .appendingPathComponent(LidAwakePrivilegedService.bundleIdentifier)
        var code: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess,
            let code
        else { return nil }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
            let values = information as? [CFString: Any],
            let data = values[kSecCodeInfoUnique] as? Data
        else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
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
