import Foundation

struct MachinePTYLaunch: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let currentDirectory: String
    let startupCommand: String?
}

struct MachineTerminalRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case open, read, input, resize, close, upload, shells, register, unregister, heartbeat,
            resolveLink, openLink
    }
    var operation: Operation
    var machineID: UUID
    var tabID: UUID = UUID()
    var handle: UUID?
    var presentationID: UUID?
    var tabIDs: [UUID] = []
    var offset: UInt64 = 0
    var bytes = Data()
    var columns: UInt16 = 80
    var rows: UInt16 = 24
    var directory: String?
    var containerID: String?
    var windowsShell = WindowsTerminalShell.automatic
    var paths: [String] = []
    var target: String = ""
    var untrusted = false
    var linkID: UUID?

    func validate() throws {
        guard (1...1000).contains(columns), (1...1000).contains(rows), bytes.count <= 16_384,
            target.utf8.count <= 4096, !target.utf8.contains(0),
            tabIDs.count <= 64, Set(tabIDs).count == tabIDs.count, paths.count <= 128,
            paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.utf8.contains(0) }
            ),
            directory.map({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }) ?? true,
            containerID.map({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }) ?? true
        else { throw MachineUIError.invalidRequest }
        if [.read, .input, .resize, .close, .resolveLink, .openLink].contains(operation),
            handle == nil
        {
            throw MachineUIError.invalidRequest
        }
    }
}

struct MachineTerminalFrame: Codable, Sendable {
    var handle: UUID? = nil
    var bytes = Data()
    var nextOffset: UInt64 = 0
    var exitCode: Int32?
    var canonical = false
    var echo = false
    var paths: [String] = []
    var shells: [WindowsTerminalShell] = []
    var linkID: UUID?
    var link: Data?
}
