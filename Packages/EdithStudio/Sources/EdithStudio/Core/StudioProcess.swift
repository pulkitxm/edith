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
        let exit = StudioProcessExit()
        process.terminationHandler = { finished in
            exit.finish(finished.terminationStatus)
        }
        return try await withTaskCancellationHandler {
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                throw StudioError.failed(
                    "\(executable.lastPathComponent) could not start: \(error.localizedDescription)"
                )
            }
            let pid = process.processIdentifier
            let deadline = timeout.map { Date().addingTimeInterval($0) }
            let status = await exit.wait(deadline: deadline) {
                stop(pid: pid)
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
            if process.isRunning { stop(pid: process.processIdentifier) }
        }
    }

    static func stop(pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + terminationGrace) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
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

    func finish(_ code: Int32) {
        lock.lock()
        status = code
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: code)
    }

    func wait(deadline: Date?, onTimeout: @escaping @Sendable () -> Void) async -> Int32? {
        if let deadline {
            let remaining = deadline.timeIntervalSinceNow
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, remaining)) {
                [weak self] in
                guard let self else { return }
                self.lock.lock()
                let pending = self.status == nil ? self.continuation : nil
                if pending != nil { self.continuation = nil }
                self.lock.unlock()
                if let pending {
                    onTimeout()
                    pending.resume(returning: nil)
                }
            }
        }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
                return
            }
            self.continuation = continuation
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
        self.limit = limit
        self.onLine = onLine
    }

    func receiveOutput(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        if outputData.count < limit { outputData.append(data.prefix(limit - outputData.count)) }
        if onLine != nil {
            pendingLine.append(data)
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
