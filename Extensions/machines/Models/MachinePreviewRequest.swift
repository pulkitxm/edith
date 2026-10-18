import Foundation

struct MachinePreviewRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable { case prepare, read, close }
    var operation: Operation
    var machineID: UUID
    var entry: RemoteFileEntry?
    var maximumBytes: Int64 = 8_388_608
    var id: UUID?
    var offset: UInt64 = 0
}

struct MachinePreviewHandle: Codable, Sendable {
    let id: UUID
    let count: UInt64
    let name: String
}

struct MachinePreviewChunk: Codable, Sendable {
    let offset: UInt64
    let bytes: Data
    let complete: Bool
}
