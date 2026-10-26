import Darwin
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

    static func downloadCommand(path: String, platform: RemoteMachinePlatform?, maximumBytes: Int64)
        throws -> String
    {
        guard maximumBytes >= 0, !path.isEmpty, !path.utf8.contains(0) else {
            throw FileTransferError.transferFailed("The download path or byte limit is invalid.")
        }
        if platform == .windows {
            let copy =
                maximumBytes == .max
                ? "$sourceStream.CopyTo($output)"
                : "$buffer=New-Object byte[] 131072; $remaining=[long]\(maximumBytes + 1); "
                    + "while($remaining -gt 0) { "
                    + "$count=$sourceStream.Read($buffer,0,[int][Math]::Min($remaining,$buffer.Length)); "
                    + "if($count -eq 0) { break }; $output.Write($buffer,0,$count); "
                    + "$remaining-=$count }"
            return PowerShell.userCommand(
                "$path=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath("
                    + "\(PowerShell.literal(path))); $sourceStream=[IO.File]::OpenRead($path); "
                    + "try { $output=[Console]::OpenStandardOutput(); \(copy); $output.Flush() } "
                    + "finally { $sourceStream.Dispose() }")
        }
        let quoted = POSIXQuote.quote(path)
        return maximumBytes == .max
            ? "cat -- \(quoted)" : "head -c \(maximumBytes + 1) -- \(quoted)"
    }

    static func uploadCommand(path: String, platform: RemoteMachinePlatform?) throws -> String {
        guard !path.isEmpty, !path.utf8.contains(0) else {
            throw FileTransferError.transferFailed("The upload path is invalid.")
        }
        guard platform == .windows else { return "cat > \(POSIXQuote.quote(path))" }
        return PowerShell.userCommand(
            "$path=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath("
                + "\(PowerShell.literal(path))); $output=[IO.File]::Create($path); "
                + "try { [Console]::OpenStandardInput().CopyTo($output); $output.Flush() } "
                + "finally { $output.Dispose() }")
    }

    public func downloadFile(
        remotePath: String, to localURL: URL, maximumBytes: Int64,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        let command = try Self.downloadCommand(
            path: remotePath, platform: await remotePlatform, maximumBytes: maximumBytes)
        try await HerdrFileTransfer.download(
            request: transferRequest(command: command), to: localURL, maximumBytes: maximumBytes,
            progress: progress)
    }

    public func uploadFile(
        localURL: URL, toRemotePath remotePath: String, progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        let command = try Self.uploadCommand(path: remotePath, platform: await remotePlatform)
        try await HerdrFileTransfer.upload(
            request: transferRequest(command: command), from: localURL, progress: progress)
    }

    private func transferRequest(command: String) throws -> CLICommandRequest {
        CLICommandRequest(
            executableURL: Self.executable, arguments: try execArguments(command: command),
            environment: CLIToolEnvironment.sanitized(), timeout: 15 * 60,
            terminatesProcessGroup: true)
    }
}

enum HerdrFileTransfer {
    static func download(
        request: CLICommandRequest, to destination: URL, maximumBytes: Int64,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        guard maximumBytes >= 0 else {
            throw FileTransferError.transferFailed("The download byte limit is invalid.")
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".edith-download-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: staging.path, contents: Data()) else {
            throw FileTransferError.transferFailed("The download could not be created.")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = try FileHandle(forWritingTo: staging)
        defer { try? output.close() }
        try await run(
            request, input: FileHandle.nullDevice, output: output, maximumBytes: maximumBytes,
            bytes: { try size(staging) }, progress: progress)
        try output.synchronize()
        try output.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }

    static func upload(
        request: CLICommandRequest, from source: URL,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        let expected = try size(source)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try await run(
            request, input: input, output: FileHandle.nullDevice, maximumBytes: expected,
            bytes: { Int64(try input.offset()) }, progress: progress)
        guard Int64(try input.offset()) == expected else {
            throw FileTransferError.transferFailed("The complete file was not uploaded.")
        }
    }

    private static func run(
        _ request: CLICommandRequest, input: FileHandle, output: FileHandle, maximumBytes: Int64,
        bytes: @escaping @Sendable () throws -> Int64, progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let errorURL = directory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: Data()) else {
            throw FileTransferError.transferFailed("The transfer log could not be created.")
        }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        let exited = DispatchSemaphore(value: 0)
        let process = try CLIChildProcess(
            request: request, input: input.fileDescriptor, output: output.fileDescriptor,
            error: errors.fileDescriptor, onExit: { exited.signal() })
        let deadline = ContinuousClock.now + .seconds(request.timeout ?? 15 * 60)
        let inspect = {
            try Task.checkCancellation()
            guard try bytes() <= maximumBytes else {
                throw FileTransferError.transferFailed("The download exceeds its byte limit.")
            }
            guard try size(errorURL) <= 1_024 * 1_024 else {
                throw FileTransferError.transferFailed(
                    "The transfer produced too much error output.")
            }
        }
        do {
            try await withTaskCancellationHandler {
                progress?(0)
                while process.isRunning {
                    try inspect()
                    guard ContinuousClock.now < deadline else {
                        throw FileTransferError.transferFailed("The file transfer timed out.")
                    }
                    progress?(try bytes())
                    try await Task.sleep(for: .milliseconds(50))
                }
                try inspect()
                guard process.terminationStatus == 0 else {
                    let detail = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw FileTransferError.transferFailed(
                        detail.isEmpty
                            ? "The file transfer failed." : PowerShell.decodedError(detail))
                }
                progress?(try bytes())
            } onCancel: {
                process.signal(SIGKILL)
            }
        } catch {
            process.signal(SIGKILL)
            _ = await BlockingWork.value { exited.wait(timeout: .now() + 5) }
            throw error
        }
        if process.groupIsAlive { process.signal(SIGKILL) }
    }

    private static func size(_ url: URL) throws -> Int64 {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = values[.size] as? NSNumber else {
            throw FileTransferError.transferFailed("The transfer file size is unavailable.")
        }
        return size.int64Value
    }
}
