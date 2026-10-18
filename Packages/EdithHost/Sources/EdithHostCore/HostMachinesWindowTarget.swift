import Foundation

public struct HostMachinesWindowTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case machine, files, docker, terminal }
    public let kind: Kind
    public let machineID: UUID
    public let path: String?
    public let title: String?
    public let subtitle: String?

    public init(
        kind: Kind, machineID: UUID, path: String? = nil, title: String? = nil,
        subtitle: String? = nil
    ) {
        self.kind = kind; self.machineID = machineID; self.path = path
        self.title = title; self.subtitle = subtitle
    }

    public func validate() throws {
        guard path.map({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }) ?? true,
            path == nil || kind == .files,
            [title, subtitle].allSatisfy({
                $0.map { $0.utf8.count <= 512 && !$0.utf8.contains(0) } ?? true
            })
        else { throw HostWorkerError.rejected }
    }

    public func context(presentationID: UUID) throws -> NSDictionary {
        try validate()
        let input: NSMutableDictionary = [
            "kind": kind.rawValue, "machineID": machineID.uuidString,
            "presentationID": presentationID.uuidString,
        ]
        if let path { input["path"] = path }
        return input
    }
}
