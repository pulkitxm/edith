import Darwin
import EdithExtensionSupport
import Foundation

@MainActor
public final class HostWorker {
    private struct Pending {
        let continuation: CheckedContinuation<HostWorkerResponse, any Error>
        let timeout: Task<Void, Never>
    }

    public private(set) var configuration: HostWorkerConfiguration
    public private(set) var ready = false
    public var didExit: (@MainActor () -> Void)?
    public var processIdentifier: Int32? { process.isRunning ? process.processIdentifier : nil }
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let requestTimeout: Duration
    private var frames = HostWorkerFrames()
    private var pending: [UUID: Pending] = [:]
    private var abandoned = Set<UUID>()
    private var preparationToken: UUID?
    private var launched = false
    private var exited = false
    private var ownedProcessGroups = HostWorkerProcessGroups()
    private var groupRefresh: Task<Void, Never>?
    private var readSource: DispatchSourceRead?
    private var outputIsNonblocking = false

    public init(
        configuration: HostWorkerConfiguration, executable: URL,
        arguments: [String] = ["--extension-worker"], requestTimeout: Duration = .seconds(15),
        errorOutput: FileHandle = .nullDevice
    ) {
        self.configuration = configuration
        self.requestTimeout = requestTimeout
        process.executableURL = executable
        process.arguments = arguments
        if let identity = try? configuration.identity() {
            var environment = ProcessInfo.processInfo.environment
            environment["EDITH_APPLICATION_IDENTIFIER"] = identity.identifier
            environment["EDITH_SHARED_DEFAULTS_SUITE"] = identity.extensionDefaultsSuite(
                configuration.extensionID)
            environment["EDITH_EXTENSION_DATA_ROOT"] =
                identity.extensionDirectory(configuration.extensionID).path
            environment["EDITH_SURFACE_DEFAULTS_SUITE"] = identity.identifier
            environment["EDITH_EXTENSION_ID"] = configuration.extensionID
            environment["EDITH_EXTENSION_STATE_ROOT"] =
                identity.root.appendingPathComponent("ExtensionState").path
            process.environment = environment
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
    }

    public func start(recoveryOnly: Bool = false) async throws {
        guard !launched else { throw HostWorkerError.rejected }
        configuration.recoveryOnly = recoveryOnly
        var environment = process.environment ?? ProcessInfo.processInfo.environment
        environment["EDITH_EXTENSION_RECOVERY_ONLY"] = recoveryOnly ? "1" : nil
        process.environment = environment
        launched = true
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw HostWorkerError.exited
        }
        outputIsNonblocking = true
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drainOutput() }
        }
        readSource = source
        source.resume()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish() }
        }
        do {
            try sharedState()?.clear(configuration.extensionID)
            try process.run()
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            let response = try await request(
                HostWorkerRequest(operation: "start", configuration: configuration))
            guard response.version == configuration.version else {
                throw HostWorkerError.invalidResponse
            }
            guard getpgid(process.processIdentifier) == process.processIdentifier else {
                throw HostWorkerError.invalidResponse
            }
            guard let identity = ExtensionProcessIdentity.read(process.processIdentifier) else {
                throw HostWorkerError.invalidResponse
            }
            try ownedProcessGroups.register(
                HostWorkerProcessGroup(
                    pid: identity.pid, generation: identity.generation, registered: true),
                owner: process.processIdentifier)
            groupRefresh = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let owner = self?.process.processIdentifier else { return }
                    self?.ownedProcessGroups.refresh(owner: owner)
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
            ready = true
        } catch {
            terminate()
            try? await awaitExit()
            throw error
        }
    }

    public func show() async throws {
        guard ready else { throw HostWorkerError.rejected }
        _ = try await request(HostWorkerRequest(operation: "show"))
    }

    public func synchronize(configuration: HostWorkerConfiguration? = nil) async throws {
        guard ready else { throw HostWorkerError.rejected }
        _ = try await request(
            HostWorkerRequest(operation: "synchronize", configuration: configuration))
    }

    public func status() async throws -> HostWorkerResponse {
        guard ready else { throw HostWorkerError.rejected }
        return try await request(HostWorkerRequest(operation: "status"))
    }

    public func prepareDisable(timeout: Duration? = nil) async throws {
        guard ready else { return }
        guard preparationToken == nil else { throw HostWorkerError.rejected }
        let request = HostWorkerRequest(operation: "prepareDisable")
        preparationToken = request.token
        defer { preparationToken = nil }
        _ = try await self.request(request, timeout: timeout)
    }

    public func stop() async throws {
        try await prepareDisable()
        ready = false
        if process.isRunning {
            _ = try? await request(
                HostWorkerRequest(operation: "stop"), timeout: min(requestTimeout, .seconds(3)))
            try? input.fileHandleForWriting.close()
            do { try await awaitExit() } catch {
                terminate()
                try await awaitExit()
            }
        }
        finish()
        terminateGroup()
    }

    private func request(_ request: HostWorkerRequest, timeout: Duration? = nil) async throws
        -> HostWorkerResponse
    {
        guard process.isRunning, !exited else { throw HostWorkerError.exited }
        guard pending.isEmpty, abandoned.count < 64 else { throw HostWorkerError.rejected }
        let data = try HostWorkerFrames.encode(request)
        let requestTimeout = timeout ?? self.requestTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    self?.cancelRequest(request.token, error: HostWorkerError.timedOut)
                }
                pending[request.token] = Pending(continuation: continuation, timeout: timeout)
                do { try input.fileHandleForWriting.write(contentsOf: data) } catch { fail(error) }
                if Task.isCancelled { cancelRequest(request.token, error: CancellationError()) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(request.token, error: CancellationError())
            }
        }
    }

    private func receive(_ bytes: Data) {
        guard !exited else { return }
        guard !bytes.isEmpty else {
            readSource?.cancel()
            readSource = nil
            if !pending.isEmpty { fail(HostWorkerError.exited) }
            return
        }
        do {
            for data in try frames.append(bytes) {
                if let resource = try? JSONDecoder().decode(
                    HostWorkerProcessGroup.self, from: data),
                    resource.kind == "processGroup"
                {
                    try receive(resource)
                    continue
                }
                let response = try JSONDecoder().decode(HostWorkerResponse.self, from: data)
                if abandoned.remove(response.token) != nil { continue }
                guard let request = pending.removeValue(forKey: response.token) else {
                    throw HostWorkerError.invalidResponse
                }
                request.timeout.cancel()
                if response.ok {
                    request.continuation.resume(returning: response)
                } else {
                    if response.token == preparationToken {
                        let message = response.message.flatMap {
                            $0.isEmpty || $0.count > 1024 ? nil : $0
                        }
                        request.continuation.resume(
                            throwing: HostWorkerError.disableRejected(
                                message
                                    ?? "Cleanup is pending. Restore system settings or finish macOS approval, then try again."
                            ))
                    } else {
                        request.continuation.resume(throwing: HostWorkerError.rejected)
                    }
                }
            }
        } catch { fail(HostWorkerError.invalidResponse) }
    }

    private func drainOutput() {
        guard !exited, outputIsNonblocking else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                receive(Data(buffer.prefix(count)))
            } else if count == 0 {
                receive(Data())
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                fail(HostWorkerError.exited)
                return
            }
        }
    }

    private func receive(_ resource: HostWorkerProcessGroup) throws {
        guard resource.pid != process.processIdentifier else {
            throw HostWorkerError.invalidResponse
        }
        if resource.registered {
            try ownedProcessGroups.register(resource, owner: process.processIdentifier)
        } else {
            ownedProcessGroups.release(resource, owner: process.processIdentifier)
        }
    }

    private func cancelRequest(_ token: UUID, error: any Error) {
        guard token == preparationToken else { fail(error); return }
        guard let request = pending.removeValue(forKey: token) else { return }
        abandoned.insert(token)
        request.timeout.cancel()
        request.continuation.resume(throwing: error)
    }

    private func fail(_ error: any Error) {
        ready = false
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
        terminate()
    }

    private func terminate() {
        if process.isRunning {
            let pid = process.processIdentifier
            if getpgid(pid) == pid {
                kill(-pid, SIGKILL)
            } else {
                kill(pid, SIGKILL)
            }
        }
        terminateGroup()
    }

    private func terminateGroup() {
        groupRefresh?.cancel()
        groupRefresh = nil
        ownedProcessGroups.terminate(owner: process.processIdentifier)
    }

    private func awaitExit() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning {
            guard ContinuousClock.now < deadline else { throw HostWorkerError.stillRunning }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func sharedState() -> ExtensionSharedState? {
        guard let identity = try? configuration.identity() else { return nil }
        return ExtensionSharedState(
            root: identity.root.appendingPathComponent("ExtensionState"),
            namespace: identity.identifier)
    }

    private func finish() {
        guard !exited else { return }
        drainOutput()
        exited = true
        ready = false
        readSource?.cancel()
        readSource = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: HostWorkerError.exited)
        }
        terminateGroup()
        try? sharedState()?.clear(configuration.extensionID)
        didExit?()
    }
}
