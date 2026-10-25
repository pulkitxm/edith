import EdithExtensionFiles
import EdithExtensionSupport
import Foundation

extension SSHConnection: RemoteShellConnection {
    public var shellPlatform: RemoteMachinePlatform? {
        get async { await remotePlatform }
    }

    public func runShell(_ command: String, stdin: Data?, timeout: TimeInterval) async throws
        -> RemoteShellResult
    {
        let result = try await run(command, stdin: stdin, timeout: timeout)
        return RemoteShellResult(
            status: result.status, stdoutText: result.stdoutText, stderrText: result.stderrText)
    }

    public func downloadFile(
        remotePath: String, to localURL: URL, maximumBytes: Int64,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        guard await remotePlatform != .windows else {
            throw FileTransferError.transferFailed(
                "Windows machines cannot transfer files from Herdr.")
        }
        let quoted = POSIXQuote.quote(remotePath)
        let command =
            maximumBytes == .max ? "cat -- \(quoted)" : "head -c \(maximumBytes + 1) -- \(quoted)"
        FileManager.default.createFile(atPath: localURL.path, contents: Data())
        let output = try FileHandle(forWritingTo: localURL)
        defer { try? output.close() }
        let process = try streamProcess(command: command)
        process.standardOutput = output
        let errors = Pipe()
        process.standardError = errors
        let status = try await Self.run(process)
        try output.synchronize()
        let size =
            (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size])
            as? Int64 ?? 0
        guard status == 0, size <= maximumBytes else {
            try? FileManager.default.removeItem(at: localURL)
            let detail = String(
                decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
            throw FileTransferError.transferFailed(
                detail.isEmpty ? "The file could not be downloaded." : detail)
        }
        progress?(size)
    }

    public func uploadFile(
        localURL: URL, toRemotePath remotePath: String, progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        guard await remotePlatform != .windows else {
            throw FileTransferError.transferFailed(
                "Windows machines cannot transfer files from Herdr.")
        }
        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }
        let size =
            (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size])
            as? Int64 ?? 0
        let process = try streamProcess(command: "cat > \(POSIXQuote.quote(remotePath))")
        process.standardInput = input
        let errors = Pipe()
        process.standardError = errors
        let status = try await Self.run(process)
        guard status == 0 else {
            let detail = String(
                decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
            throw FileTransferError.transferFailed(
                detail.isEmpty ? "The file could not be uploaded." : detail)
        }
        progress?(size)
    }

    private static func run(_ process: Process) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
