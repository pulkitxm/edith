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
    private var frames = HostWorkerFrames()
    private var pending:
        [UUID: (
            HostCoreOperation, CheckedContinuation<HostCoreSnapshot?, Error>, Task<Void, Never>
        )] = [:]
    private var abandoned: Set<UUID> = []
    private var identity: ExtensionProcessIdentity?
    private var launched = false

    public init(identity: HostIdentity, executable: URL) {
        configuration = HostWorkerConfiguration(
            identity: identity, extensionID: "core", version: "1")
        process.executableURL = executable
        process.arguments = ["--extension-core"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    public func start() async throws -> HostCoreSnapshot {
        guard !launched else { throw HostWorkerError.rejected }
        launched = true
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw HostWorkerError.exited
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drain() }
        }
        self.source = source
        source.resume()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish() }
        }
        do {
            try process.run()
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            guard let snapshot = try await request(.start, configuration: configuration),
                snapshot.pid == process.processIdentifier,
                getpgid(snapshot.pid) == snapshot.pid,
                let identity = ExtensionProcessIdentity.read(snapshot.pid)
            else { throw HostWorkerError.invalidResponse }
            self.identity = identity
            ready = true
            return snapshot
        } catch {
            terminate()
            throw error
        }
    }

    public func perform(_ operation: HostCoreOperation) async throws -> HostCoreSnapshot {
        guard ready, ![.start, .stop].contains(operation),
            let snapshot = try await request(operation)
        else { throw HostWorkerError.rejected }
        return snapshot
    }

    public func cancelCurrentTask() {
        guard ready, pending.values.contains(where: { $0.0 != .status }), abandoned.count < 63
        else { return }
        let request = HostCoreRequest(operation: .cancel)
        abandoned.insert(request.token)
        do {
            try input.fileHandleForWriting.write(contentsOf: HostWorkerFrames.encode(request))
        } catch { terminate(); finish() }
    }

    public func stop() async {
        ready = false
        if process.isRunning { _ = try? await request(.stop, timeout: .seconds(5)) }
        try? input.fileHandleForWriting.close()
        if process.isRunning { terminate() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        finish()
    }

    private func request(
        _ operation: HostCoreOperation,
        configuration: HostWorkerConfiguration? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> HostCoreSnapshot? {
        guard process.isRunning, pending.count < 2, abandoned.count < 64,
            !pending.values.contains(where: {
                $0.0 == operation || (operation != .status && $0.0 != .status)
            })
        else {
            throw HostWorkerError.rejected
        }
        let request = HostCoreRequest(operation: operation, configuration: configuration)
        let data = try HostWorkerFrames.encode(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.reject(request.token, error: HostWorkerError.timedOut)
                }
                pending[request.token] = (operation, continuation, timeoutTask)
                do { try input.fileHandleForWriting.write(contentsOf: data) } catch {
                    reject(request.token, error: error)
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
                        guard let pending = pending.removeValue(forKey: response.token) else {
                            throw HostWorkerError.invalidResponse
                        }
                        pending.2.cancel()
                        if response.failure != nil {
                            pending.1.resume(throwing: HostWorkerError.rejected)
                        } else {
                            pending.1.resume(returning: response.snapshot)
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
        guard let pending = pending.removeValue(forKey: token) else { return }
        abandoned.insert(token)
        pending.2.cancel()
        pending.1.resume(throwing: error)
    }

    private func finish() {
        ready = false
        source?.cancel()
        source = nil
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
