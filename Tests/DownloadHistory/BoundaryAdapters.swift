import Foundation
import EdithExtensionSupport

public enum SharedDefaults {
    public static var store: UserDefaults { fatalError("Defaults are outside this fixture") }
}

public enum CLIToolEnvironment {
    public static func executable(named: String) -> URL? { nil }
    public static func sanitized() -> [String: String] { [:] }
}

public enum CLICommandRunner {
    public static func runLocalSeparated(
        _ request: CLICommandRequest, streamsWhileRunning: Bool,
        onStandardOutputLine: @escaping @Sendable (String) -> Void,
        onStandardErrorLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        fatalError("Only injected fake runners are allowed")
    }
}

public struct DownloadMutationResult {
    public let changed: Int
    public let records: [DownloadRecord]
}

public enum DownloadToolOperationError: Error { case missing }
