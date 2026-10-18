import EdithExtensionUI
import EdithExtensionSupport
import Foundation

public struct CompanionFleetMachine: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let sshTarget: String
}

public struct CompanionMachines: Sendable {
    typealias Invoke = @Sendable (String, Data, TimeInterval) async throws -> Data

    static let owner = "machines"
    static let maximumTimeout: TimeInterval = 1_800
    private let invoke: Invoke

    init(invoke: @escaping Invoke) { self.invoke = invoke }

    public static var live: Self {
        Self { command, payload, timeout in
            guard let endpoint = ExtensionPeerEndpoint.current(owner: owner) else {
                throw ExtensionPeerError.unavailable
            }
            return try await endpoint.invoke(command, payload: payload, timeout: timeout)
        }
    }

    func list() async -> [CompanionFleetMachine] {
        guard
            let data = try? await invoke("machines.companion.hosts", Data("{}".utf8), 15),
            let reply = try? JSONDecoder().decode(HostsReply.self, from: data)
        else { return [] }
        var seen = Set<UUID>()
        return reply.machines.filter {
            !$0.name.isEmpty && $0.name.utf8.count <= 256 && $0.sshTarget.utf8.count <= 512
                && seen.insert($0.id).inserted
        }.prefix(64).map { $0 }
    }

    func run(
        machineID: UUID, command: String, stdin: Data?, timeout: TimeInterval
    ) async throws -> String {
        guard timeout.isFinite, timeout > 0 else { throw ExtensionPeerError.invalidRequest }
        let request = RunRequest(
            machineID: machineID, command: command, stdin: stdin,
            timeout: min(timeout, Self.maximumTimeout))
        let data = try await invoke(
            "machines.companion.run", try JSONEncoder().encode(request),
            min(timeout, Self.maximumTimeout) + 15)
        return try JSONDecoder().decode(RunReply.self, from: data).output
    }

    func forward(machineID: UUID, localPort: Int, remotePort: Int) async -> Bool {
        guard (1...65_535).contains(localPort), (1...65_535).contains(remotePort),
            let payload = try? JSONEncoder().encode(
                ForwardRequest(machineID: machineID, localPort: localPort, remotePort: remotePort)),
            let data = try? await invoke("machines.companion.forward", payload, 60),
            let reply = try? JSONDecoder().decode(ForwardReply.self, from: data)
        else { return false }
        return reply.connected
    }

    private struct HostsReply: Decodable { let machines: [CompanionFleetMachine] }
    private struct RunRequest: Encodable {
        let machineID: UUID
        let command: String
        let stdin: Data?
        let timeout: TimeInterval
    }
    private struct RunReply: Decodable { let output: String }
    private struct ForwardRequest: Encodable {
        let machineID: UUID
        let localPort: Int
        let remotePort: Int
    }
    private struct ForwardReply: Decodable { let connected: Bool }
}
