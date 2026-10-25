import Foundation

public struct MachineDirectoryExportRequest: Codable, Sendable {
    public static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4096 && !path.utf8.contains(0)
            && !path.contains("\\")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    public enum Operation: String, Codable, Sendable { case prepare, read, close }
    public var operation: Operation
    public var machineID: UUID
    public var entry: RemoteFileEntry?
    public var id: UUID?
    public var path = ""
    public var offset: UInt64 = 0
    public var maximumBytes: Int64 = RemoteFileOperationExecution.cacheLimitBytes
}

public struct MachineDirectoryExportItem: Codable, Sendable {
    public var path: String
    public var kind: FileEntryKind
    public var count: UInt64
    public var linkTarget: String?
    public var modified: Date?
}

public struct MachineDirectoryExportHandle: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [MachineDirectoryExportItem]
    public var count: UInt64
}
