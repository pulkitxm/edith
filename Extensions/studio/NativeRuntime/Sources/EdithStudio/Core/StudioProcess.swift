import Foundation

public struct StudioProcessResult: Sendable {
    public let status: Int32
    public let output: String
    public let errorTail: String
}

public enum StudioProcess {
    public static let terminationGrace: TimeInterval = 2

    public static func run(
        _ executable: URL, _ arguments: [String], currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil, captureLimit: Int = 4 << 20,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> StudioProcessResult {
        if Task.isCancelled { throw StudioError.cancelled }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let collector = StudioProcessCollector(limit: captureLimit, onLine: onOutputLine)
        let streams = StudioStreamCompletion(count: 2)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                streams.finish(0)
            } else {
                collector.receiveOutput(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                streams.finish(1)
            } else {
                collector.receiveError(data)
            }
        }
        let lifecycle = StudioProcessLifecycle(process: process)
        let exit = StudioProcessExit()
        process.terminationHandler = { [weak lifecycle] finished in
            lifecycle?.finish()
            exit.finish(finished.terminationStatus)
        }
        return try await withTaskCancellationHandler {
            do {
                try lifecycle.start()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                if error as? StudioError == .cancelled { throw StudioError.cancelled }
                throw StudioError.failed(
                    "\(executable.lastPathComponent) could not start: \(error.localizedDescription)"
                )
            }
            let deadline = timeout.map { Date().addingTimeInterval($0) }
            let status = await exit.wait(deadline: deadline) {
                lifecycle.stop()
            }
            await streams.wait(timeout: status == nil ? 0.2 : 3)
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if Task.isCancelled { throw StudioError.cancelled }
            guard let status else {
                throw StudioError.failed("\(executable.lastPathComponent) timed out.")
            }
            return StudioProcessResult(
                status: status, output: collector.output, errorTail: collector.errorTail)
        } onCancel: {
            lifecycle.cancel()
        }
    }

}

private final class StudioProcessLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false
    private var escalation: DispatchWorkItem?

    init(process: Process) {
        self.process = process
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw StudioError.cancelled }
        try process.run()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        stop()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning, escalation == nil else { return }
        let pid = process.processIdentifier
        kill(pid, SIGTERM)
        let work = DispatchWorkItem { [self] in
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.process.isRunning { kill(pid, SIGKILL) }
        }
        escalation = work
        DispatchQueue.global().asyncAfter(
            deadline: .now() + StudioProcess.terminationGrace, execute: work)
    }

    func finish() {
        lock.lock()
        escalation?.cancel()
        escalation = nil
        lock.unlock()
    }
}

private final class StudioStreamCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Set<Int>
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        open = Set(0..<count)
    }

    func finish(_ stream: Int) {
        lock.lock()
        open.remove(stream)
        let ready = open.isEmpty ? waiters : []
        if open.isEmpty { waiters.removeAll() }
        lock.unlock()
        for waiter in ready { waiter.resume() }
    }

    func wait(timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if open.isEmpty {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.expire()
            }
        }
    }

    private func expire() {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}

private final class StudioProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32?, Never>?
    private var timeoutWork: DispatchWorkItem?

    func finish(_ code: Int32) {
        lock.lock()
        status = code
        timeoutWork?.cancel()
        timeoutWork = nil
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: code)
    }

    func wait(deadline: Date?, onTimeout: @escaping @Sendable () -> Void) async -> Int32? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
                return
            }
            self.continuation = continuation
            if let deadline {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let pending = self.status == nil ? self.continuation : nil
                    self.continuation = nil
                    self.timeoutWork = nil
                    self.lock.unlock()
                    if let pending {
                        onTimeout()
                        pending.resume(returning: nil)
                    }
                }
                timeoutWork = work
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: work)
            }
            lock.unlock()
        }
    }
}

private final class StudioProcessCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let onLine: (@Sendable (String) -> Void)?
    private var outputData = Data()
    private var errorData = Data()
    private var pendingLine = Data()

    init(limit: Int, onLine: (@Sendable (String) -> Void)?) {
        self.limit = max(0, limit)
        self.onLine = onLine
    }

    func receiveOutput(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        if outputData.count < limit { outputData.append(data.prefix(limit - outputData.count)) }
        if onLine != nil {
            pendingLine.append(data)
            if pendingLine.count > 64 << 10 { pendingLine = pendingLine.suffix(64 << 10) }
            while let newline = pendingLine.firstIndex(of: 0x0A) {
                let line = pendingLine[pendingLine.startIndex..<newline]
                lines.append(String(decoding: line, as: UTF8.self))
                pendingLine.removeSubrange(pendingLine.startIndex...newline)
            }
        }
        lock.unlock()
        for line in lines { onLine?(line) }
    }

    func receiveError(_ data: Data) {
        lock.lock()
        errorData.append(data)
        if errorData.count > 64 << 10 { errorData = errorData.suffix(32 << 10) }
        lock.unlock()
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: outputData, as: UTF8.self)
    }

    var errorTail: String {
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: errorData.suffix(4096), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
