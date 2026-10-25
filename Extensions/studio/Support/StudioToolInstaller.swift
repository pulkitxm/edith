import EdithExtensionSupport
import Foundation

struct CLIToolSpec: Sendable {
    let executable: String
    let displayName: String
    let versionArguments: [String]

    static let ffmpeg = CLIToolSpec(
        executable: "ffmpeg", displayName: "FFmpeg", versionArguments: ["-version"])
    static let qpdf = CLIToolSpec(
        executable: "qpdf", displayName: "qpdf", versionArguments: ["--version"])
}

enum StudioToolInstallFailure: Error, LocalizedError, Equatable {
    case homebrewUnavailable(String)
    case commandFailed(String, Int32)
    case unverified(String)

    var errorDescription: String? {
        switch self {
        case let .homebrewUnavailable(name):
            "Homebrew is required for installing \(name)."
        case let .commandFailed(command, status):
            "\(command) exited with status \(status)."
        case let .unverified(name):
            "Installation finished, but \(name) could not be verified."
        }
    }
}

struct ToolInstaller: Sendable {
    typealias Log = @Sendable (String) -> Void
    typealias RunCommand =
        @Sendable (CLICommandRequest, @escaping Log) async throws -> CLICommandResult

    private let runCommand: RunCommand

    init(runCommand: @escaping RunCommand = { try await CLICommandRunner.run($0, onLine: $1) }) {
        self.runCommand = runCommand
    }

    @discardableResult
    func install(_ tool: CLIToolSpec, log: @escaping Log = { _ in }) async throws -> String {
        try Task.checkCancellation()
        let environment = CLIToolEnvironment.sanitized()
        guard let brew = CLIToolEnvironment.executable(named: "brew") else {
            throw StudioToolInstallFailure.homebrewUnavailable(tool.displayName)
        }
        log("Running brew install \(tool.executable)")
        let result = try await runCommand(
            CLICommandRequest(
                executableURL: brew, arguments: ["install", tool.executable],
                environment: environment, timeout: 600, maximumOutputBytes: 1_024 * 1_024,
                terminatesProcessGroup: true), log)
        guard result.terminationStatus == 0 else {
            throw StudioToolInstallFailure.commandFailed("brew", result.terminationStatus)
        }
        try Task.checkCancellation()
        guard let executable = CLIToolEnvironment.executable(named: tool.executable),
            let version = await ToolVersionProbe.version(
                CLICommandRequest(
                    executableURL: executable, arguments: tool.versionArguments,
                    environment: environment, timeout: 5, maximumOutputBytes: 64 * 1_024,
                    terminatesProcessGroup: true),
                runCommand: { request, onLine in
                    try await runCommand(request) { line in
                        log(line)
                        onLine(line)
                    }
                })
        else {
            try Task.checkCancellation()
            throw StudioToolInstallFailure.unverified(tool.displayName)
        }
        try Task.checkCancellation()
        return version
    }
}
