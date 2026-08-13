import Foundation

private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func receive(_ data: Data) -> [String] {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        pending += text
        var lines: [String] = []
        while let newline = pending.firstIndex(of: "\n") {
            lines.append(String(pending[..<newline]))
            pending.removeSubrange(...newline)
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let rest = pending
        pending = ""
        return rest.isEmpty ? [] : [rest]
    }
}

private final class StreamCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuations: [CheckedContinuation<Int32, Never>] = []

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish(_ status: Int32) {
        lock.lock()
        guard self.status == nil else {
            lock.unlock()
            return
        }
        self.status = status
        let waiting = continuations
        continuations.removeAll(keepingCapacity: false)
        lock.unlock()
        for continuation in waiting { continuation.resume(returning: status) }
    }
}

public final class SSHLineStream: @unchecked Sendable {
    private let process: Process
    private let stdinData: Data?
    private let onLine: @Sendable (String, Bool) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutSplitter = LineSplitter()
    private let stderrSplitter = LineSplitter()
    private let completion = StreamCompletion()

    public init(
        process: Process, stdinData: Data? = nil,
        onLine: @escaping @Sendable (String, Bool) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.process = process
        self.stdinData = stdinData
        self.onLine = onLine
        self.onExit = onExit
    }

    public func start() throws {
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdout = stdoutSplitter
        let stderr = stderrSplitter
        let deliver = onLine
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            PipeReading.consume(handle) { data in
                for line in stdout.receive(data) { deliver(line, false) }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            PipeReading.consume(handle) { data in
                for line in stderr.receive(data) { deliver(line, true) }
            }
        }
        let finish = onExit
        let completion = completion
        process.terminationHandler = { [stdoutPipe, stderrPipe, completion] finished in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            for line in stdout.receive(
                stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            {
                deliver(line, false)
            }
            for line in stdout.flush() { deliver(line, false) }
            for line in stderr.receive(
                stderrPipe.fileHandleForReading.readDataToEndOfFile())
            {
                deliver(line, true)
            }
            for line in stderr.flush() { deliver(line, true) }
            completion.finish(finished.terminationStatus)
            finish(finished.terminationStatus)
        }
        if let stdinData {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try process.run()
            DispatchQueue.global(qos: .utility).async {
                stdinPipe.fileHandleForWriting.write(stdinData)
                try? stdinPipe.fileHandleForWriting.close()
            }
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
    }

    public func waitForExit() async -> Int32 {
        await withTaskCancellationHandler {
            await completion.wait()
        } onCancel: {
            cancel()
        }
    }

    public func cancel() {
        process.terminationHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let status = process.isRunning ? 130 : process.terminationStatus
        if process.isRunning {
            process.terminate()
        }
        completion.finish(status)
    }
}

public enum MachineCollector {
    public static let streamCommand = "sh -s -- --stream -i 2"
    public static let onceCommand = "sh -s -- --once"

    public static func script() -> Data? {
        guard
            let url = BundledResources.url(
                forResource: "machine-collector", withExtension: "sh")
        else { return nil }
        return try? Data(contentsOf: url)
    }
}
