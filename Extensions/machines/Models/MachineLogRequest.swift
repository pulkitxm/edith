import Foundation

struct MachineLogRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable { case start, read, cancel }
    var operation: Operation
    var presentationID: UUID?
    var machineID: UUID
    var containerID: String = ""
    var handle: UUID?
    var sequence: UInt64 = 0

    func validate() throws {
        guard containerID.utf8.count <= 256, !containerID.utf8.contains(0),
            operation == .start ? !containerID.isEmpty : handle != nil
        else { throw MachineUIError.invalidRequest }
    }
}

struct MachineLogChunk: Codable, Sendable {
    var text: String
    var isStderr: Bool
}

struct MachineLogFrame: Codable, Sendable {
    var handle: UUID
    var sequence: UInt64
    var nextSequence: UInt64
    var lines: [MachineLogChunk]
    var exitCode: Int32?
}
