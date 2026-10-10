import Darwin
import EdithExtensionSupport
import Foundation

struct HostApplicationQuitPolicy: Codable, Equatable, Sendable {
    static let command = "extension.lifecycle.applicationQuit"
    let reason: HostWorkerStopReason
    let restoreOnQuit: Bool
    let host: ExtensionProcessIdentity

    func validate() throws {
        guard reason == .applicationQuit, !restoreOnQuit, host.isAlive else {
            throw HostWorkerError.rejected
        }
    }
}

struct HostPrivilegedStop: Codable, Sendable {
    let reason: HostWorkerStopReason
    let owner: String
    let worker: ExtensionProcessIdentity
    let parent: ExtensionProcessIdentity
    let quitPolicy: HostApplicationQuitPolicy?

    func retainsState() throws -> Bool {
        guard worker == ExtensionProcessIdentity.current,
            parent == ExtensionProcessIdentity.read(getppid()), parent.isAlive
        else { throw HostWorkerError.rejected }
        guard let quitPolicy else { return false }
        guard reason == .applicationQuit, owner == "lidAwake" else {
            throw HostWorkerError.rejected
        }
        try quitPolicy.validate()
        return true
    }
}

struct HostPrivilegedRequest: Codable {
    let token: UUID
    let operation: String
    let command: String?
    let payload: Data?
    let stop: HostPrivilegedStop?
    init(
        _ operation: String, command: String? = nil, payload: Data? = nil,
        stop: HostPrivilegedStop? = nil
    ) {
        token = UUID(); self.operation = operation; self.command = command; self.payload = payload
        self.stop = stop
    }
}

struct HostPrivilegedResponse: Codable {
    let token: UUID
    let data: Data?
    let error: String?
}

@MainActor final class HostPrivilegedProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var frames = HostWorkerFrames()
    private var pending: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var abandoned = Set<UUID>()
    private let timeout: Duration
    private var identity: ExtensionProcessIdentity?
    var processIdentifier: Int32? { process.isRunning ? process.processIdentifier : nil }
    var didExit: (@MainActor () -> Void)?

    init(
        executable: URL, arguments: [String], environment: [String: String]? = nil,
        timeout: Duration = .seconds(20)
    ) {
        process.executableURL = executable; process.arguments = arguments
        process.environment =
            environment ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root"]
        process.standardInput = input; process.standardOutput = output;
        process.standardError = FileHandle.nullDevice
        self.timeout = timeout
    }

    func start() async throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish() }
        }
        try process.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        _ = try await request(.init("start"))
        guard getpgid(process.processIdentifier) == process.processIdentifier,
            let identity = ExtensionProcessIdentity.read(process.processIdentifier)
        else {
            throw HostWorkerError.invalidResponse
        }
        self.identity = identity
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        try await request(.init("invoke", command: command, payload: payload))
    }

    func stop(
        reason: HostWorkerStopReason = .disable, owner: String = "",
        quitPolicy: HostApplicationQuitPolicy? = nil
    ) async throws {
        guard process.isRunning else {
            if quitPolicy != nil { throw HostWorkerError.exited }
            return
        }
        guard let identity, identity.isAlive, let parent = ExtensionProcessIdentity.current else {
            throw HostWorkerError.rejected
        }
        if let quitPolicy {
            guard reason == .applicationQuit, owner == "lidAwake" else {
                throw HostWorkerError.rejected
            }
            try quitPolicy.validate()
        } else {
            _ = try await request(.init("prepareDisable"))
        }
        let stop = HostPrivilegedStop(
            reason: reason, owner: owner, worker: identity, parent: parent, quitPolicy: quitPolicy)
        do {
            _ = try await request(.init("stop", stop: stop))
        } catch HostWorkerError.exited {
            guard quitPolicy == nil, !process.isRunning, process.terminationReason == .exit,
                process.terminationStatus == 0
            else { throw HostWorkerError.exited }
        }
        try? input.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning {
            guard ContinuousClock.now < deadline else { throw HostWorkerError.stillRunning }
            try await Task.sleep(for: .milliseconds(20))
        }
        if quitPolicy != nil {
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw HostWorkerError.exited
            }
        }
        finish()
    }

    private func request(_ request: HostPrivilegedRequest) async throws -> Data {
        guard process.isRunning, pending.isEmpty, abandoned.count < 64 else {
            throw HostWorkerError.rejected
        }
        let bytes = try HostWorkerFrames.encode(request)
        let expiry = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.cancel(request.token, error: HostWorkerError.timedOut)
        }
        defer { expiry.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[request.token] = continuation
                do { try input.fileHandleForWriting.write(contentsOf: bytes) } catch {
                    cancel(request.token, error: error)
                }
                if Task.isCancelled { cancel(request.token, error: CancellationError()) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(request.token, error: CancellationError())
            }
        }
    }

    private func cancel(_ token: UUID, error: any Error) {
        guard let continuation = pending.removeValue(forKey: token) else { return }
        abandoned.insert(token); continuation.resume(throwing: error)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { finish(); return }
        do {
            for frame in try frames.append(data) {
                let response = try JSONDecoder().decode(HostPrivilegedResponse.self, from: frame)
                if abandoned.remove(response.token) != nil { continue }
                guard let continuation = pending.removeValue(forKey: response.token) else {
                    throw HostWorkerError.invalidResponse
                }
                if let message = response.error {
                    continuation.resume(
                        throwing: HostWorkerError.disableRejected(String(message.prefix(1024))))
                } else if let data = response.data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: HostWorkerError.invalidResponse)
                }
            }
        } catch {
            let requests = pending.values; pending.removeAll()
            requests.forEach { $0.resume(throwing: error) }
            try? input.fileHandleForWriting.close()
        }
    }

    private func finish() {
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        let requests = pending.values; pending.removeAll()
        requests.forEach { $0.resume(throwing: HostWorkerError.exited) }
        didExit?()
    }
}
