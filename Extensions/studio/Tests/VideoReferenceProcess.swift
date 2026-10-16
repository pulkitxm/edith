import Darwin
import Foundation
@testable import EdithExtensionSupport

struct CLIRun {
    let stdout: String
    let stderr: String
    let code: Int32
}

enum CLIProcessProbeError: Error, Equatable, LocalizedError {
    case timedOut(executable: String, arguments: [String], seconds: TimeInterval)
    case cleanupFailed(processID: Int32)

    var errorDescription: String? {
        switch self {
        case let .timedOut(executable, arguments, seconds):
            return
                "\(([executable] + arguments).joined(separator: " ")) timed out after \(seconds) seconds"
        case .cleanupFailed(let processID):
            return "The fixture process group \(processID) did not terminate."
        }
    }
}

enum CLIProcessProbe {
    static let defaultTimeout: TimeInterval = 15
    private static let terminationGrace: TimeInterval = 2

    static func run(
        _ arguments: [String], executable: URL, currentDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = defaultTimeout, input: Data? = nil
    ) throws -> CLIRun {
        let target = executable
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-cli-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: captureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let stdoutURL = captureDirectory.appendingPathComponent("stdout")
        let stderrURL = captureDirectory.appendingPathComponent("stderr")
        let stdin: FileHandle
        if let input {
            let url = captureDirectory.appendingPathComponent("stdin")
            try input.write(to: url)
            stdin = try FileHandle(forReadingFrom: url)
        } else {
            stdin = .nullDevice
        }
        defer { if input != nil { try? stdin.close() } }
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let finished = DispatchSemaphore(value: 0)
        let process = try CLIChildProcess(
            request: CLICommandRequest(
                executableURL: target, arguments: arguments, environment: environment,
                currentDirectoryURL: currentDirectory, terminatesProcessGroup: true),
            input: stdin.fileDescriptor, output: stdout.fileDescriptor,
            error: stderr.fileDescriptor, onExit: { finished.signal() })
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        guard finished.wait(timeout: .now() + max(0, timeout)) == .success else {
            _ = try terminate(
                process, finished: finished,
                deadline: ProcessInfo.processInfo.systemUptime + terminationGrace)
            throw CLIProcessProbeError.timedOut(
                executable: target.path, arguments: arguments, seconds: timeout)
        }
        if process.groupIsAlive, try terminate(process, finished: finished, deadline: deadline) {
            throw CLIProcessProbeError.timedOut(
                executable: target.path, arguments: arguments, seconds: timeout)
        }
        try stdout.close()
        try stderr.close()
        let out = try Data(contentsOf: stdoutURL)
        let err = try Data(contentsOf: stderrURL)
        return CLIRun(
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self), code: process.terminationStatus)
    }

    private static func terminate(
        _ process: CLIChildProcess, finished: DispatchSemaphore, deadline: TimeInterval
    ) throws -> Bool {
        process.signal(SIGTERM)
        let grace = min(deadline, ProcessInfo.processInfo.systemUptime + terminationGrace)
        while process.groupIsAlive, ProcessInfo.processInfo.systemUptime < grace {
            _ = finished.wait(timeout: .now() + 0.01)
        }
        let exceededDeadline =
            process.groupIsAlive
            && ProcessInfo.processInfo.systemUptime >= deadline
        if process.groupIsAlive { process.signal(SIGKILL) }
        let reaping = ProcessInfo.processInfo.systemUptime + terminationGrace
        while (process.isRunning || process.groupIsAlive),
            ProcessInfo.processInfo.systemUptime < reaping
        {
            _ = finished.wait(timeout: .now() + 0.01)
        }
        guard !process.isRunning, !process.groupIsAlive else {
            throw CLIProcessProbeError.cleanupFailed(processID: process.processIdentifier)
        }
        return exceededDeadline
    }

}
