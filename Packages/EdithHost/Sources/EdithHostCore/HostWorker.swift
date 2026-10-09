import Darwin
import Foundation

@MainActor
public final class HostWorker {
    private struct Pending {
        let continuation: CheckedContinuation<HostWorkerResponse, any Error>
        let timeout: Task<Void, Never>
    }

    public let configuration: HostWorkerConfiguration
    public private(set) var ready = false
    public var didExit: (@MainActor () -> Void)?
    public var processIdentifier: Int32? { process.isRunning ? process.processIdentifier : nil }
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let requestTimeout: Duration
    private var frames = HostWorkerFrames()
    private var pending: [UUID: Pending] = [:]
    private var launched = false
    private var exited = false
    private var processGroup: Int32?
    private var ownedProcessGroups: Set<Int32> = []
    private var readSource: DispatchSourceRead?
    private var outputIsNonblocking = false

    public init(
        configuration: HostWorkerConfiguration, executable: URL,
        arguments: [String] = ["--extension-worker"], requestTimeout: Duration = .seconds(15)
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
            process.environment = environment
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    public func start() async throws {
        guard !launched else { throw HostWorkerError.rejected }
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
            try process.run()
            processGroup = process.processIdentifier
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

    public func stop() async throws {
        ready = false
        if process.isRunning {
            _ = try? await request(HostWorkerRequest(operation: "stop"))
            try? input.fileHandleForWriting.close()
            do { try await awaitExit() } catch {
                terminate()
                try await awaitExit()
            }
        }
        finish()
        terminateGroup()
    }

    private func request(_ request: HostWorkerRequest) async throws -> HostWorkerResponse {
        guard process.isRunning, !exited else { throw HostWorkerError.exited }
        guard pending.isEmpty else { throw HostWorkerError.rejected }
        let data = try HostWorkerFrames.encode(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    self?.fail(HostWorkerError.timedOut)
                }
                pending[request.token] = Pending(continuation: continuation, timeout: timeout)
                do { try input.fileHandleForWriting.write(contentsOf: data) } catch { fail(error) }
                if Task.isCancelled { fail(CancellationError()) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(CancellationError()) }
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
                guard let request = pending.removeValue(forKey: response.token) else {
                    throw HostWorkerError.invalidResponse
                }
                request.timeout.cancel()
                if response.ok {
                    request.continuation.resume(returning: response)
                } else {
                    request.continuation.resume(throwing: HostWorkerError.rejected)
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
        guard resource.pid > 1, resource.pid != process.processIdentifier, resource.pid != getpid()
        else {
            throw HostWorkerError.invalidResponse
        }
        if resource.registered {
            let group = getpgid(resource.pid)
            guard
                group == resource.pid || group == process.processIdentifier
                    || (group == -1 && kill(-resource.pid, 0) == 0)
            else { return }
            guard ownedProcessGroups.count < 128 || ownedProcessGroups.contains(resource.pid) else {
                terminateResource(resource.pid)
                throw HostWorkerError.invalidResponse
            }
            ownedProcessGroups.insert(resource.pid)
        } else if getpgid(resource.pid) == -1, errno == ESRCH,
            kill(-resource.pid, 0) == -1, errno == ESRCH
        {
            ownedProcessGroups.remove(resource.pid)
        }
    }

    private func terminateResource(_ pid: Int32) {
        let group = getpgid(pid)
        if group == process.processIdentifier || group == pid { kill(pid, SIGKILL) }
        kill(-pid, SIGKILL)
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
                processGroup = pid; kill(-pid, SIGKILL)
            } else {
                kill(pid, SIGKILL)
            }
        }
        terminateGroup()
    }

    private func terminateGroup() {
        for pid in ownedProcessGroups { terminateResource(pid) }
        ownedProcessGroups.removeAll()
        if let processGroup { kill(-processGroup, SIGKILL) }
        processGroup = nil
    }

    private func awaitExit() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning {
            guard ContinuousClock.now < deadline else { throw HostWorkerError.stillRunning }
            try await Task.sleep(for: .milliseconds(20))
        }
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
        didExit?()
        terminateGroup()
    }
}
