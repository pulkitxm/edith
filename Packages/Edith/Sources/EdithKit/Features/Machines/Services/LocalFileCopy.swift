import Foundation

public enum LocalFileCopy {
    public static func copy(_ source: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: destination.path),
            (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil
        else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let result = try await CLICommandRunner.runSeparated(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/cp"),
                arguments: ["-c", "-p", "-P", source.path, destination.path],
                environment: CLIToolEnvironment.sanitized(), timeout: 7_200,
                maximumOutputBytes: 4_096, terminatesProcessGroup: true),
            onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
        try Task.checkCancellation()
        guard result.terminationStatus == 0 else {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHConnectionError.transferFailed(
                detail.isEmpty ? "The local file could not be copied." : detail)
        }
    }
}
