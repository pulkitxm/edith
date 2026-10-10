import Foundation

struct MachineHostWindowRequest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case machine, files, docker, terminal }
    var kind: Kind
    var machineID: UUID
    var path: String?
    var presentationID: UUID?

    func validate() throws {
        guard path.map({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }) ?? true,
            path == nil || kind == .files
        else { throw MachineUIError.invalidRequest }
    }
}

@MainActor enum MachinesHostWindowNavigation {
    static var open: (MachineHostWindowRequest) async throws -> Void = { _ in
        throw MachineUIFailure(message: "The owning app window bridge is unavailable.")
    }
}
