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
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.receiveOutput(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
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
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            collector.drain(stdout.fileHandleForReading, stderr.fileHandleForReading)
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

    func drain(_ output: FileHandle, _ error: FileHandle) {
        if let rest = try? output.readToEnd(), !rest.isEmpty { receiveOutput(rest) }
        if let rest = try? error.readToEnd(), !rest.isEmpty { receiveError(rest) }
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
