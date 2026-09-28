import Foundation

public struct BlitzTreeReport: Sendable {
    public struct Summary: Sendable {
        public let allocatedBytes: UInt64
        public let logicalBytes: UInt64
        public let fileCount: UInt64
        public let directoryCount: UInt64
    }

    public struct Coverage: Sendable {
        public let complete: Bool
        public let errors: UInt64
        public let skippedCloudDirectories: UInt64
        public let skippedMountPoints: UInt64
    }

    public struct Entry: Identifiable, Sendable {
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
        public let device: Int32
        public let inode: UInt64
    }

    public struct Inventory: Sendable {
        public let largestChildren: [Entry]
        public let largestDirectories: [Entry]
        public let largestFiles: [Entry]
    }

    public struct Findings: Sendable {
        public let candidates: [Entry]
        public let candidateCount: Int
        public let truncated: Bool
        public let inventory: Inventory
    }

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
    case invalidRoot
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot: "Choose an absolute folder path to scan."
        case let .failed(message): message
        }
    }
}

public struct BlitzTreeClient: Sendable {
    public typealias Progress = @Sendable (UInt64) -> Void
    public typealias Execute =
        @Sendable (String, @escaping Progress) async throws -> BlitzTreeReport
    private let execute: Execute

    public init(execute: @escaping Execute) {
        self.execute = execute
    }

    public func scan(root: String, progress: @escaping Progress = { _ in }) async throws
        -> BlitzTreeReport
    {
        guard root.hasPrefix("/"), !root.contains("\0") else { throw BlitzTreeError.invalidRoot }
        try Task.checkCancellation()
        let result = try await execute(root, progress)
        try Task.checkCancellation()
        return result
    }

    public static let live = BlitzTreeClient { root, progress in
        let worker = Task.detached(priority: .userInitiated) {
            try BlitzTreeScanner.scan(root: root, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
