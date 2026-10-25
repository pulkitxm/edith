import Foundation

public struct MachinePreviewRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case prepare, read, close }
    public var operation: Operation
    public var machineID: UUID
    public var entry: RemoteFileEntry?
    public var maximumBytes: Int64 = 8_388_608
    public var id: UUID?
    public var offset: UInt64 = 0
}

public struct MachinePreviewHandle: Codable, Sendable {
    public let id: UUID
    public let count: UInt64
    public let name: String
}

public struct MachinePreviewChunk: Codable, Sendable {
    public let offset: UInt64
    public let bytes: Data
    public let complete: Bool
}
