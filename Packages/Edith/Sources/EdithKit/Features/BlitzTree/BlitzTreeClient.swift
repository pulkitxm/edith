import Foundation

public struct BlitzTreeReport: Decodable, Sendable {
    public struct Summary: Decodable, Sendable {
        public let allocatedBytes: UInt64
        public let logicalBytes: UInt64
        public let fileCount: UInt64
        public let directoryCount: UInt64
    }

    public struct Coverage: Decodable, Sendable {
        public let complete: Bool
        public let errors: UInt64
        public let skippedCloudDirectories: UInt64
        public let skippedMountPoints: UInt64
    }

    public struct Entry: Decodable, Identifiable, Sendable {
        public var id: String { path }
        public var name: String { URL(fileURLWithPath: path).lastPathComponent }
        public var isDirectory: Bool { kind == "directory" }
        public let path: String
        public let kind: String
        public let allocatedBytes: UInt64
        public let logicalBytes: UInt64
        public let fileCount: UInt64
        public let complete: Bool
        public let reason: String?
    }

    public struct Inventory: Decodable, Sendable {
        public let largestChildren: [Entry]
        public let largestDirectories: [Entry]
        public let largestFiles: [Entry]
    }

    public struct Findings: Decodable, Sendable {
        public let candidates: [Entry]
        public let candidateCount: Int
        public let truncated: Bool
        public let inventory: Inventory
    }

    public let schemaVersion: Int
    public let tool: String
    public let command: String
    public let readOnly: Bool
    public let root: String
    public let scanSeconds: Double
    public let summary: Summary
    public let coverage: Coverage
    public let report: Findings

    public var unlistedBytes: UInt64 {
        report.inventory.largestChildren.reduce(summary.allocatedBytes) {
            $0 - min($0, $1.allocatedBytes)
        }
    }
}

public enum BlitzTreeError: LocalizedError, Equatable {
    case notInstalled
    case invalidRoot
    case invalidReport
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Install the BlitzTree CLI to scan a folder."
        case .invalidRoot: "Choose an absolute folder path to scan."
        case .invalidReport:
            "BlitzTree returned an unsupported or invalid report. Reinstall the CLI."
        case let .failed(message): message
        }
    }
}

public struct BlitzTreeClient: Sendable {
    public typealias Execute = @Sendable ([String]) async throws -> CLICommandResult
    private let execute: Execute

    public init(execute: @escaping Execute) {
        self.execute = execute
    }

    public func scan(root: String) async throws -> BlitzTreeReport {
        guard root.hasPrefix("/"), !root.contains("\0") else { throw BlitzTreeError.invalidRoot }
        try Task.checkCancellation()
        let result = try await execute([
            "quick-wins", "--root", root, "--limit", "200",
        ])
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard result.terminationStatus == 0 else {
            let failure = try? decoder.decode(Failure.self, from: result.standardOutputData)
            throw BlitzTreeError.failed(
                failure?.error.message
                    ?? "BlitzTree exited with status \(result.terminationStatus).")
        }
        guard
            let report = try? decoder.decode(BlitzTreeReport.self, from: result.standardOutputData),
            report.schemaVersion == 1, report.tool == "blitztree",
            report.command == "quick-wins", report.readOnly, report.root.hasPrefix("/"),
            report.scanSeconds.isFinite, report.scanSeconds >= 0
        else { throw BlitzTreeError.invalidReport }
        return report
    }

    public static let live = BlitzTreeClient { arguments in
        guard let executable = CLIToolEnvironment.executable(named: "blitztree") else {
            throw BlitzTreeError.notInstalled
        }
        return try await CLICommandRunner.runLocal(
            CLICommandRequest(
                executableURL: executable, arguments: arguments,
                environment: CLIToolEnvironment.sanitized(), timeout: 600,
                maximumOutputBytes: 8 * 1_024 * 1_024)
        ) { _ in }
    }

    private struct Failure: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}
