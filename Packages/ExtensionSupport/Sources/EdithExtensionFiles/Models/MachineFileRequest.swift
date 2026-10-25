import Foundation

public struct MachineFileRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case load, places, home, measure, open, reveal, undo, rename, mkdir, duplicate
        case trash, download, upload, search, drop, commitDrop, cancel, release
    }
    public var presentationID: UUID?
    public var viewID: UUID
    public var machineID: UUID
    public var operation: Operation
    public var path: String
    public var selection: Set<String> = []
    public var text = ""
    public var paths: [String] = []
    public var permanently = false
    public var intent: DropIntent?
    public var resolutions: [String: NameConflictResolution] = [:]

    public func validate() throws {
        let values =
            [path, text] + Array(selection) + paths + (intent?.paths ?? [])
            + Array(resolutions.keys)
        guard values.count <= 2_048,
            values.allSatisfy({ $0.utf8.count <= 4_096 && !$0.utf8.contains(0) })
        else { throw MachineUIError.invalidRequest }
    }
}

public struct MachineFileState: Codable, Sendable {
    public var path: String
    public var entries: [RemoteFileEntry]
    public var selection: Set<String>
    public var freeSpaceKB: Int64?
    public var places: [FilePlaceSection]
    public var searchResults: [RemoteFileEntry]?
    public var error: String?
    public var status: String?
    public var undoSteps: [FinderUndoStep]
    public var folderSizes: [String: Int64]
    public var folderCounts: [String: Int]
    public var renaming: String?
    public var renameText: String
    public var conflict: Conflict?

    public struct Conflict: Codable, Sendable {
        public let intent: DropIntent
        public let destination: String
        public let names: [String]

        public init(intent: DropIntent, destination: String, names: [String]) {
            self.intent = intent
            self.destination = destination
            self.names = names
        }
    }
}
