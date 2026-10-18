import Foundation

struct MachineDirectoryExportRequest: Codable, Sendable {
    static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4096 && !path.utf8.contains(0)
            && !path.contains("\\")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    enum Operation: String, Codable, Sendable { case prepare, read, close }
    var operation: Operation
    var machineID: UUID
    var entry: RemoteFileEntry?
    var id: UUID?
    var path = ""
    var offset: UInt64 = 0
    var maximumBytes: Int64 = RemoteFileOperationExecution.cacheLimitBytes
}

struct MachineDirectoryExportItem: Codable, Sendable {
    var path: String
    var kind: FileEntryKind
    var count: UInt64
    var linkTarget: String?
    var modified: Date?
}

struct MachineDirectoryExportHandle: Codable, Sendable {
    var id: UUID
    var name: String
    var items: [MachineDirectoryExportItem]
    var count: UInt64
}
