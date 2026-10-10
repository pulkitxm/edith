import Foundation

private final class MachineLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [MachineLogChunk] = []
    private var byteCount = 0
    private var code: Int32?

    func append(_ text: String, isStderr: Bool) -> Bool {
        lock.withLock {
            guard code == nil else { return false }
            guard text.utf8.count <= 262_144 - byteCount, lines.count < 4_000 else {
                code = 1
                return false
            }
            lines.append(MachineLogChunk(text: text, isStderr: isStderr))
            byteCount += text.utf8.count
            return true
        }
    }

    func finish(_ status: Int32) { lock.withLock { if code == nil { code = status } } }

    func drain() -> ([MachineLogChunk], Int32?) {
        lock.withLock {
            let batch = Array(lines.prefix(128))
            lines.removeFirst(batch.count)
            byteCount -= batch.reduce(0) { $0 + $1.text.utf8.count }
            return (batch, lines.isEmpty ? code : nil)
        }
    }
}

@MainActor final class MachineLogEngine {
    private final class Log {
        let machineID: UUID
        let presentationID: UUID?
        let stream: SSHLineStream
        let buffer: MachineLogBuffer
        let owner: MachineExecutionOwner
        var touched = ContinuousClock.now
        var sequence: UInt64 = 0

        init(
            machineID: UUID, stream: SSHLineStream, buffer: MachineLogBuffer,
            owner: MachineExecutionOwner, presentationID: UUID?
        ) {
            self.presentationID = presentationID
            self.machineID = machineID
            self.stream = stream
            self.buffer = buffer
            self.owner = owner
        }
    }

    private let session: (UUID) throws -> MachineSession
    private let containers: @MainActor (MachineSession) -> [DockerContainer]
    private let process: @MainActor (MachineSession, DockerContainer) throws -> Process
    private var logs: [UUID: Log] = [:]
    private var retired: [SSHLineStream] = []
    private var reaper: Task<Void, Never>?
    private var stopped = false

    init(
        session: @escaping (UUID) throws -> MachineSession,
        containers: @escaping @MainActor (MachineSession) -> [DockerContainer] = { $0.containers },
        process: @escaping @MainActor (MachineSession, DockerContainer) throws -> Process = {
            session, container in
            let command = DockerCommands.logs(
                container.id, tail: 400, follow: true, platform: session.remotePlatform ?? .linux)
            if let connection = session.connectionRef {
                return connection.streamProcess(command: command)
            }
            guard session.isLocal else { throw MachineUIError.unavailable }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            return process
        }
    ) {
        self.session = session
        self.containers = containers
        self.process = process
    }

    func execute(_ request: MachineLogRequest) throws -> MachineLogFrame {
        try request.validate()
        guard !stopped else { throw MachineUIError.unavailable }
        switch request.operation {
        case .start:
            guard logs.count < 8 else { throw MachineUIError.unavailable }
            let session = try session(request.machineID)
            guard let container = containers(session).first(where: { $0.id == request.containerID })
            else { throw MachineUIError.invalidRequest }
            let id = UUID()
            let buffer = MachineLogBuffer()
            let owner = MachineExecutionOwner()
            let stream = SSHLineStream(
                process: try process(session, container),
                onLine: { text, isStderr in
                    if !buffer.append(text, isStderr: isStderr) { owner.cancel() }
                },
                onExit: { code in buffer.finish(code) })
            logs[id] = Log(
                machineID: session.id, stream: stream, buffer: buffer, owner: owner,
                presentationID: request.presentationID)
            do { try owner.start(stream) } catch { logs.removeValue(forKey: id); throw error }
            startReaper()
            return MachineLogFrame(handle: id, sequence: 0, nextSequence: 0, lines: [])
        case .read, .cancel:
            guard let id = request.handle, let log = logs[id], log.machineID == request.machineID,
                log.presentationID == request.presentationID
            else { throw MachineUIError.invalidRequest }
            guard request.sequence == log.sequence else { throw MachineUIError.stale }
            if request.operation == .cancel {
                retire(id)
                return MachineLogFrame(
                    handle: id, sequence: log.sequence, nextSequence: log.sequence, lines: [],
                    exitCode: 130)
            }
            log.touched = .now
            let (lines, code) = log.buffer.drain()
            let sequence = log.sequence
            log.sequence += UInt64(lines.count)
            let result = MachineLogFrame(
                handle: id, sequence: sequence, nextSequence: log.sequence, lines: lines,
                exitCode: code)
            if code != nil { retire(id) }
            return result
        }
    }

    func release(_ presentation: UUID) {
        for id in logs.keys.filter({ logs[$0]?.presentationID == presentation }) { retire(id) }
    }

    private func retire(_ id: UUID) {
        guard let log = logs.removeValue(forKey: id) else { return }
        log.stream.cancel()
        log.owner.release(log.stream)
        retired.append(log.stream)
    }

    private func startReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !stopped else { return }
                let expired = logs.filter { $0.value.touched.duration(to: .now) > .seconds(10) }
                    .map(\.key)
                for id in expired { retire(id) }
                await drainRetired()
            }
        }
    }

    private func drainRetired() async {
        let streams = retired
        retired = []
        for stream in streams { await stream.waitForProcessExit() }
    }

    func shutdown() async {
        stopped = true
        reaper?.cancel(); reaper = nil
        for id in Array(logs.keys) { retire(id) }
        await drainRetired()
    }
}
