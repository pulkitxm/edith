import EdithExtensionSupport
import Foundation

public enum BifrostCommandExecution {
    public static func run(
        _ script: String, environment: [String: String] = [:], timeout: TimeInterval
    ) async -> Result<String, Error> {
        await run(
            executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", script],
            commandLabel: "shell",
            environment: CLIToolEnvironment.sanitized().merging(environment) { _, new in new },
            timeout: timeout)
    }

    public static func run(
        executable: URL, arguments: [String], commandLabel: String,
        environment: [String: String]? = nil, mergesStandardError: Bool = true,
        timeout: TimeInterval
    ) async -> Result<String, Error> {
        do {
            try Task.checkCancellation()
            let request = CLICommandRequest(
                executableURL: executable, arguments: arguments,
                environment: environment ?? ExtensionEnvironment.values,
                timeout: timeout, maximumOutputBytes: 256 << 20, terminatesProcessGroup: true)
            let result = try await CLICommandRunner.run(request, onLine: { _ in })
            try Task.checkCancellation()
            guard result.terminationStatus == 0 else {
                throw ExtensionPeerError.rejected(String(result.output.prefix(2_000)))
            }
            return .success(mergesStandardError ? result.output : result.standardOutput)
        } catch { return .failure(error) }
    }
}
