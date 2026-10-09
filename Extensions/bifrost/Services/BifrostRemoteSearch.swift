import EdithExtensionSupport
import Foundation

public struct BifrostRemoteMachine: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let sshTarget: String
}

public enum BifrostRemoteSearch {
    public static func machines() async throws -> [BifrostRemoteMachine] {
        struct Hosts: Decodable { let machines: [BifrostRemoteMachine] }
        let response = try await BifrostPeers.invoke(
            owner: "machines", command: "machines.companion.hosts", payload: Data("{}".utf8))
        let all = try JSONDecoder().decode(Hosts.self, from: response).machines
        guard all.count <= 1_024, Set(all.map(\.id)).count == all.count,
            all.allSatisfy({
                !$0.name.isEmpty && $0.name.utf8.count <= 256 && !$0.name.utf8.contains(0)
            })
        else { throw ExtensionPeerError.invalidRequest }
        return all
    }

    public static func run(machineName: String, command: String) async -> String? {
        do {
            let all = try await machines()
            let candidates = all.filter { $0.name == machineName }
            guard candidates.count == 1, let machine = candidates.first else { return nil }
            struct Request: Encodable {
                let machineID: UUID; let command: String; let timeout: Double = 15
            }
            struct Output: Decodable { let output: String }
            let data = try await BifrostPeers.invoke(
                owner: "machines", command: "machines.companion.run",
                payload: JSONEncoder().encode(Request(machineID: machine.id, command: command)))
            let output = try JSONDecoder().decode(Output.self, from: data).output
            guard output.utf8.count <= 6 * 1_024 * 1_024 else { return nil }
            try Task.checkCancellation()
            return output
        } catch { return nil }
    }
}
