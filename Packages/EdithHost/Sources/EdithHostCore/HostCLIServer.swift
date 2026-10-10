import Darwin
import Foundation

@MainActor public final class HostCLIServer {
    public typealias Execute = @MainActor @Sendable (HostCLIRequest) async throws -> Data
    private struct Job {
        let connection: HostCLIConnection
        let task: Task<Void, Never>
        var deadline: Task<Void, Never>?
        var watcher: DispatchSourceRead?
    }
    private let identity: HostIdentity
    private let execute: Execute
    private var listener: DispatchSourceRead?
    private var listenerPaused = false
    private var jobs: [UUID: Job] = [:]
    private var retired: [UUID: Task<Void, Never>] = [:]
    private var replying = Set<UUID>()

    public init(identity: HostIdentity, execute: @escaping Execute) {
        self.identity = identity
        self.execute = execute
    }

    public func start() throws {
        guard listener == nil else {
            throw HostCLIError.rejected("CLI control is already running.")
        }
        try HostCLITransport.prepareDirectory()
        let path = try HostCLITransport.socketPath(identity: identity)
        let lease = open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lease >= 0 else { throw HostCLIError.unavailable }
        var info = stat()
        guard fstat(lease, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
            flock(lease, LOCK_EX | LOCK_NB) == 0
        else {
            Darwin.close(lease);
            throw HostCLIError.rejected("This Edith app already owns CLI control.")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { Darwin.close(lease); throw HostCLIError.unavailable }
        var boundSocket = false
        do {
            if lstat(path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
                    throw HostCLIError.unavailable
                }
                guard unlink(path) == 0 else { throw HostCLIError.unavailable }
            }
            var address = try HostCLITransport.address(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            boundSocket = bound == 0
            guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0,
                fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
            else { throw HostCLIError.unavailable }
        } catch {
            Darwin.close(descriptor)
            if boundSocket { unlink(path) }
            Darwin.close(lease)
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.accept(descriptor) }
        }
        source.setCancelHandler {
            Darwin.close(descriptor); unlink(path); Darwin.close(lease)
        }
        listener = source
        source.resume()
    }

    public func shutdown() {
        if listenerPaused { listener?.resume(); listenerPaused = false }
        listener?.cancel()
        listener = nil
        for token in Array(jobs.keys) { close(token) }
        for task in retired.values { task.cancel() }
    }

    private func accept(_ descriptor: Int32) {
        guard jobs.count + retired.count < 8 else {
            if !listenerPaused { listener?.suspend(); listenerPaused = true }
            return
        }
        let descriptor = Darwin.accept(descriptor, nil, nil)
        guard descriptor >= 0 else { return }
        let connection = HostCLIConnection(descriptor)
        let token = UUID()
        let task = Task { [weak self, execute] in
            defer { self?.retired.removeValue(forKey: token); self?.resumeListener() }
            do {
                let request = try await Task.detached(priority: .utility) {
                    try connection.configure(timeout: 5)
                    let peer = try HostCLIProcess.peer(descriptor)
                    let data = try connection.read(limit: HostCLITransport.maximumRequest)
                    guard HostCLIProcess.read(peer.pid) == peer else {
                        throw HostCLIError.unavailable
                    }
                    let request = try JSONDecoder().decode(HostCLIRequest.self, from: data)
                    try request.validate()
                    return request
                }.value
                try Task.checkCancellation()
                guard self?.jobs[token] != nil else { return }
                self?.watch(token, timeout: request.timeout)
                let data = try await execute(request)
                try Task.checkCancellation()
                await self?.respond(
                    token, response: HostCLIResponse(payload: data, error: nil, exitCode: 0))
            } catch {
                let failure = error as? HostCLIError ?? .rejected(error.localizedDescription)
                await self?.respond(
                    token,
                    response: HostCLIResponse(
                        payload: nil,
                        error: String(failure.localizedDescription.prefix(2048)),
                        exitCode: failure.exitCode))
            }
        }
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)); self?.close(token) } catch {}
        }
        jobs[token] = Job(connection: connection, task: task, deadline: deadline)
    }

    private func watch(_ token: UUID, timeout: Double) {
        guard var job = jobs[token] else { return }
        job.deadline?.cancel()
        job.deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
                guard let self, let job = self.jobs[token] else { return }
                job.task.cancel()
                await self.respond(
                    token,
                    response: HostCLIResponse(
                        payload: nil,
                        error: HostCLIError.timedOut.localizedDescription, exitCode: 4))
            } catch {}
        }
        let watcher = DispatchSource.makeReadSource(
            fileDescriptor: job.connection.descriptor, queue: .main)
        watcher.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.close(token) } }
        watcher.resume()
        job.watcher = watcher
        jobs[token] = job
    }

    private func respond(_ token: UUID, response: HostCLIResponse) async {
        guard let job = jobs[token], replying.insert(token).inserted else { return }
        _ = try? await Task.detached(priority: .utility) {
            try job.connection.configure(timeout: 2)
            try job.connection.write(
                JSONEncoder().encode(response), limit: HostCLITransport.maximumFrame)
        }.value
        close(token)
    }

    private func close(_ token: UUID) {
        guard let job = jobs.removeValue(forKey: token) else { return }
        replying.remove(token)
        retired[token] = job.task
        Task { [weak self] in
            await job.task.value
            self?.retired.removeValue(forKey: token)
            self?.resumeListener()
        }
        job.task.cancel()
        job.deadline?.cancel()
        job.watcher?.cancel()
        job.connection.cancel()
        resumeListener()
    }

    private func resumeListener() {
        if listenerPaused, jobs.count + retired.count < 8 {
            listener?.resume(); listenerPaused = false
        }
    }
}
