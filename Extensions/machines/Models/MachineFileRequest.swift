import Foundation

struct MachineFileRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case load, places, home, measure, open, reveal, undo, rename, mkdir, duplicate
        case trash, download, upload, search, drop, commitDrop, cancel, release
    }
    var viewID: UUID
    var machineID: UUID
    var operation: Operation
    var path: String
    var selection: Set<String> = []
    var text = ""
    var paths: [String] = []
    var permanently = false
    var intent: DropIntent?
    var resolutions: [String: NameConflictResolution] = [:]

    func validate() throws {
        let values =
            [path, text] + Array(selection) + paths + (intent?.paths ?? [])
            + Array(resolutions.keys)
        guard values.count <= 2_048,
            values.allSatisfy({ $0.utf8.count <= 4_096 && !$0.utf8.contains(0) })
        else { throw MachineUIError.invalidRequest }
    }
}

struct MachineFileState: Codable, Sendable {
    var path: String
    var entries: [RemoteFileEntry]
    var selection: Set<String>
    var freeSpaceKB: Int64?
    var places: [FilePlaceSection]
    var searchResults: [RemoteFileEntry]?
    var error: String?
    var status: String?
    var undoSteps: [FinderUndoStep]
    var folderSizes: [String: Int64]
    var folderCounts: [String: Int]
    var renaming: String?
    var renameText: String
    var conflict: Conflict?

    struct Conflict: Codable, Sendable {
        let intent: DropIntent
        let destination: String
        let names: [String]
    }
}
