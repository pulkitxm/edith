import EdithExtensionSupport
import Foundation

public struct HerdrInventoryCommands: Sendable {
    public typealias Collect = @Sendable (HerdrCollectScope) async -> [HerdrHostSnapshot]
    private let collect: Collect
    private let machines: @Sendable () -> [Machine]
    public init(
        collect: @escaping Collect = { await HerdrSessionOperationExecution.list($0) },
        machines: @escaping @Sendable () -> [Machine] = { MachineRegistry.machines() }
    ) {
        self.collect = collect
        self.machines = machines
    }
    public func execute(_ command: String, payload: Data) async throws -> Data {
        guard payload.count <= 8_192,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            Set(object.keys).isSubset(of: ["machineID", "agentID"])
        else { throw ExtensionPeerError.invalidRequest }
        if let value = object["machineID"], !(value is String) {
            throw ExtensionPeerError.invalidRequest
        }
        let selection = object["machineID"] as? String
        let scope: HerdrCollectScope
        if selection == nil {
            scope = .all
        } else if selection == "local" {
            scope = .local
        } else {
            guard let selection, let id = UUID(uuidString: selection),
                let machine = machines().first(where: { $0.id == id })
            else { throw ExtensionPeerError.rejected("No saved machine matches this selection.") }
            scope = .machine(machine)
        }
        guard command == "herdr.list" || command == "herdr.command" else {
            throw ExtensionPeerError.invalidRequest
        }
        try Task.checkCancellation()
        let hosts = await collect(scope)
        try Task.checkCancellation()
        guard hosts.count <= 64, hosts.reduce(0, { $0 + $1.agents.count }) <= 512 else {
            throw ExtensionPeerError.invalidRequest
        }
        let output: [String: Any]
        if command == "herdr.command" {
            guard let id = object["agentID"] as? String, !id.isEmpty, id.utf8.count <= 512,
                let agent = hosts.flatMap(\.agents).first(where: { $0.id == id })
            else {
                throw ExtensionPeerError.rejected("The selected Herdr pane is no longer available.")
            }
            output = ["command": HerdrAttachCommand.line(for: agent)]
        } else {
            guard object["agentID"] == nil else { throw ExtensionPeerError.invalidRequest }
            output = [
                "hosts": hosts.map {
                    [
                        "id": $0.id, "name": $0.name, "local": $0.isLocal, "herdr": $0.herdrPresent,
                        "reachable": $0.reachable, "error": $0.error as Any? ?? NSNull(),
                    ] as [String: Any]
                },
                "agents": hosts.flatMap(\.agents).map {
                    [
                        "id": $0.id, "machine": $0.machineID, "machineName": $0.machineName,
                        "local": $0.machineIsLocal, "session": $0.session, "pane": $0.pane,
                        "kind": $0.kind, "status": $0.status.rawValue, "title": $0.title,
                        "workspace": $0.workspace, "cwd": $0.cwd,
                        "command": HerdrAttachCommand.line(for: $0),
                    ] as [String: Any]
                },
            ]
        }
        let result = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        guard result.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        return result
    }
}
