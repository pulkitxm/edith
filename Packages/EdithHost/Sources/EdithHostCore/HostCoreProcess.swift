import Darwin
import EdithExtensionSupport
import Foundation

@MainActor public final class HostCoreProcess {
    public private(set) var ready = false
    public var processIdentifier: Int32? { process.isRunning ? process.processIdentifier : nil }
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let configuration: HostWorkerConfiguration
    private var source: DispatchSourceRead?
    private var writer: HostCorePipeWriter?
    private var frames = HostCoreFrames()
    private struct Pending {
        let operation: HostCoreOperation
        let continuation: CheckedContinuation<HostCoreResponse, Error>
        let timeout: Task<Void, Never>
        var write: Task<Void, Never>?
    }
    private var pending: [UUID: Pending] = [:]
    private var controls: [UUID: Task<Void, Never>] = [:]
    private var abandoned: Set<UUID> = []
    private var identity: ExtensionProcessIdentity?
    private var launched = false

    public init(identity: HostIdentity, executable: URL) {
        configuration = HostWorkerConfiguration(
            identity: identity, extensionID: "core", version: "1")
        process.executableURL = executable
        process.arguments = ["--extension-core"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    public func start() async throws -> HostCoreSnapshot {
        guard !launched else { throw HostWorkerError.rejected }
        launched = true
        writer = try HostCorePipeWriter(descriptor: input.fileHandleForWriting.fileDescriptor)
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw HostWorkerError.exited
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
        self.source = source; source.resume()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish() }
        }
        do {
            try process.run()
            try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
            guard let snapshot = try await request(.start, configuration: configuration).snapshot,
                snapshot.pid == process.processIdentifier, getpgid(snapshot.pid) == snapshot.pid,
                let identity = ExtensionProcessIdentity.read(snapshot.pid)
            else { throw HostWorkerError.invalidResponse }
            self.identity = identity; ready = true
            return snapshot
        } catch { terminate(); throw error }
    }

    public func perform(_ operation: HostCoreOperation) async throws -> HostCoreSnapshot {
        guard ready, ![.start, .stop, .command].contains(operation),
            let snapshot = try await request(operation).snapshot,
            snapshot.pid == processIdentifier
        else { throw HostWorkerError.rejected }
        return snapshot
    }

    public func performCommand(
        _ operation: HostAgentCommandOperation, payload: Data = Data("{}".utf8)
    ) async throws -> Data {
        try Task.checkCancellation()
        guard ready, let identity, ExtensionProcessIdentity.read(identity.pid) == identity,
            identity.isAlive, processIdentifier == identity.pid
        else {
            throw HostAgentCommandError(.unavailable, "The owned core command service is offline.")
        }
        let response = try await request(
            .command, command: .init(operation: operation, payload: payload))
        try Task.checkCancellation()
        guard ready, ExtensionProcessIdentity.read(identity.pid) == identity,
            identity.isAlive, processIdentifier == identity.pid
        else {
            throw HostAgentCommandError(
                .unavailable, "The core process changed during the command.")
        }
        guard let result = response.commandResult else { throw HostWorkerError.invalidResponse }
        return try result.encoded()
    }

    @discardableResult public func cancelCurrentTask() -> Bool {
        guard ready,
            pending.values.contains(where: { ![.status, .command, .cancel].contains($0.operation) }
            ),
            controls.count < 8, abandoned.count < 63, let writer
        else { return false }
        let request = HostCoreRequest(operation: .cancel)
        abandoned.insert(request.token)
        controls[request.token] = Task { [weak self] in
            defer { self?.controls.removeValue(forKey: request.token) }
            do { try await writer.send(request) } catch { self?.terminate(); self?.finish() }
        }
        return true
    }

    public func stop() async {
        ready = false
        if process.isRunning {
            let drain = Task { _ = try? await request(.stop, timeout: .seconds(5)) }
            await drain.value
        }
        for control in Array(controls.values) { await control.value }
        controls.removeAll()
        await writer?.shutdown(); writer = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { terminate() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        finish()
    }

    private func request(
        _ operation: HostCoreOperation, configuration: HostWorkerConfiguration? = nil,
        command: HostCoreCommandRequest? = nil, cancelling: UUID? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> HostCoreResponse {
        try Task.checkCancellation()
        let exclusive = ![.status, .command, .cancel, .stop].contains(operation)
        guard process.isRunning, let writer, pending.count < 8, abandoned.count < 64,
            !exclusive
                || !pending.values.contains(where: {
                    ![.status, .command, .cancel].contains($0.operation)
                })
        else { throw HostWorkerError.rejected }
        let request = HostCoreRequest(
            operation: operation, configuration: configuration, command: command,
            cancelling: cancelling)
        let data = try HostCoreFrames.encode(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.reject(request.token, error: HostWorkerError.timedOut)
                }
                pending[request.token] = Pending(
                    operation: operation, continuation: continuation, timeout: timer)
                pending[request.token]?.write = Task { [weak self] in
                    do { try await writer.send(data) } catch {
                        self?.reject(request.token, error: error)
                    }
                }
                if Task.isCancelled { reject(request.token, error: CancellationError()) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.reject(request.token, error: CancellationError())
            }
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                do {
                    for frame in try frames.append(Data(buffer.prefix(count))) {
                        let response = try JSONDecoder().decode(HostCoreResponse.self, from: frame)
                        if abandoned.remove(response.token) != nil { continue }
                        guard let entry = pending.removeValue(forKey: response.token) else {
                            throw HostWorkerError.invalidResponse
                        }
                        entry.timeout.cancel()
                        if response.cancelled {
                            entry.continuation.resume(throwing: CancellationError())
                        } else if let failure = response.commandFailure {
                            entry.continuation.resume(throwing: failure)
                        } else if response.failure != nil {
                            entry.continuation.resume(throwing: HostWorkerError.rejected)
                        } else {
                            entry.continuation.resume(returning: response)
                        }
                    }
                } catch { terminate(); finish(); return }
            } else if count == 0 {
                finish(); return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                terminate(); finish(); return
            }
        }
    }

    private func reject(_ token: UUID, error: Error) {
        guard let entry = pending.removeValue(forKey: token) else { return }
        abandoned.insert(token); entry.timeout.cancel(); entry.write?.cancel()
        entry.continuation.resume(throwing: error)
        if ![.status, .cancel, .stop].contains(entry.operation),
            error is CancellationError || (error as? HostWorkerError) == .timedOut,
            controls.count < 8
        {
            controls[token] = Task { [weak self] in
                defer { self?.controls.removeValue(forKey: token) }
                _ = try? await self?.request(.cancel, cancelling: token, timeout: .seconds(3))
            }
        }
    }

    private func finish() {
        ready = false; source?.cancel(); source = nil
        for token in Array(pending.keys) { reject(token, error: HostWorkerError.exited) }
    }

    private func terminate() {
        if let identity, ExtensionProcessIdentity.read(identity.pid) == identity,
            getpgid(identity.pid) == identity.pid
        {
            kill(-identity.pid, SIGKILL)
        } else if process.isRunning {
            process.terminate()
        }
    }
}
