import EdithExtensionSupport
import Foundation

@MainActor public final class MachinePeerService {
    public typealias Run = @MainActor (Machine, String, Data?, TimeInterval) async throws -> String
    public typealias PrepareConnection =
        @MainActor (Machine) async throws -> MachineConnectionRecipe
    public typealias Forward = @MainActor (Machine, PortForward) async throws -> Bool
    private let files: MachineRegistry.Files
    private let run: Run
    private let forward: Forward
    private let usage: MachineUsageCollectionService
    private let prepareConnection: PrepareConnection?
    private var stopped = false

    public init(
        files: MachineRegistry.Files = .init(), usage: MachineUsageCollectionService,
        run: @escaping Run, forward: @escaping Forward,
        prepareConnection: PrepareConnection? = nil
    ) {
        self.files = files
        self.usage = usage
        self.run = run
        self.forward = forward
        self.prepareConnection = prepareConnection
    }

    public func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try Task.checkCancellation()
        switch command {
        case "machines.companion.hosts":
            try MachineCommandPayload.empty(payload)
            let machines = MachineRegistry.machines(files)
            guard machines.count <= 1_024, machines.allSatisfy(MachineCommandPayload.valid),
                Set(machines.map(\.id)).count == machines.count
            else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(
                Hosts(
                    machines: machines.map {
                        Host(
                            id: $0.id, name: $0.name, sshTarget: $0.sshTarget,
                            aliases: Self.aliases($0))
                    }))
        case "machines.connection.prepare":
            let request = try MachineCommandPayload.decode(
                ConnectionRequest.self, data: payload, required: ["machineID"])
            let machine = try selected(request.machineID)
            guard MachineConnectionRecipe.valid(machine), let prepareConnection else {
                throw ExtensionPeerError.unavailable
            }
            let recipe = try await prepareConnection(machine)
            try Task.checkCancellation()
            guard !stopped, try selected(machine.id) == machine,
                recipe.machineID == machine.id, recipe.name == machine.name,
                recipe.sshTarget == machine.sshTarget
            else { throw ExtensionPeerError.unavailable }
            return try JSONEncoder().encode(recipe)
        case "machines.companion.run":
            let request = try MachineCommandPayload.decode(
                RunRequest.self, data: payload, required: ["machineID", "command", "timeout"],
                optional: ["stdinbase64"])
            guard request.timeout.isFinite, request.timeout > 0, request.timeout <= 1_800,
                !request.command.isEmpty, request.command.utf8.count <= 65_536,
                !request.command.utf8.contains(0)
            else { throw ExtensionPeerError.invalidRequest }
            let input: Data?
            if let encoded = request.stdinbase64 {
                guard encoded.utf8.count <= 6 * 1_024 * 1_024,
                    let decoded = Data(base64Encoded: encoded)
                else { throw ExtensionPeerError.invalidRequest }
                input = decoded
            } else {
                input = nil
            }
            let machine = try selected(request.machineID)
            let output = try await run(machine, request.command, input, request.timeout)
            try Task.checkCancellation()
            guard !stopped, try selected(machine.id) == machine,
                output.utf8.count <= 6 * 1_024 * 1_024
            else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(Output(output: output))
        case "machines.companion.forward":
            let request = try MachineCommandPayload.decode(
                ForwardRequest.self, data: payload,
                required: ["machineID", "localPort", "remotePort"])
            guard Self.validPort(request.localPort), Self.validPort(request.remotePort) else {
                throw ExtensionPeerError.invalidRequest
            }
            let machine = try selected(request.machineID)
            let connected = try await forward(
                machine,
                PortForward(
                    machineID: machine.id, localPort: request.localPort,
                    remotePort: request.remotePort))
            try Task.checkCancellation()
            guard !stopped, try selected(machine.id) == machine else {
                throw ExtensionPeerError.unavailable
            }
            return try JSONEncoder().encode(Connected(connected: connected))
        case "machines.forward.prepare":
            let request = try MachineCommandPayload.decode(
                PrepareRequest.self, data: payload, required: ["ports"])
            guard !request.ports.isEmpty, request.ports.count <= 8,
                Set(request.ports).count == request.ports.count,
                request.ports.allSatisfy(Self.validPort)
            else { throw ExtensionPeerError.invalidRequest }
            let all = MachineRegistry.forwards(files)
            var candidates: [PortForward] = []
            for port in request.ports {
                let matching = all.filter { $0.localPort == port }
                guard matching.count == 1, let saved = matching.first,
                    Self.validPort(saved.remotePort), Self.loopback(saved.remoteHost)
                else {
                    throw ExtensionPeerError.rejected(
                        "Save one unambiguous loopback forward for every requested port.")
                }
                candidates.append(saved)
            }
            let ids = Set(candidates.map(\.machineID))
            guard ids.count == 1, let id = ids.first else {
                throw ExtensionPeerError.rejected(
                    "The requested forwards must belong to one saved machine.")
            }
            let machine = try selected(id)
            for saved in candidates {
                guard try await forward(machine, saved) else {
                    throw ExtensionPeerError.unavailable
                }
                try Task.checkCancellation()
                guard !stopped, try selected(machine.id) == machine else {
                    throw ExtensionPeerError.unavailable
                }
            }
            return try JSONEncoder().encode(Prepared(prepared: true, name: machine.name))
        case "machines.usage.start", "machines.usage.progress", "machines.usage.collect",
            "machines.usage.result", "machines.usage.cancel":
            return try await usage.execute(command, payload: payload)
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    public func shutdown() {
        stopped = true
        usage.shutdown()
    }

    public func shutdownAndWait() async {
        stopped = true
        await usage.shutdownAndWait()
    }

    private func selected(_ id: UUID) throws -> Machine {
        let matching = MachineRegistry.machines(files).filter { $0.id == id }
        guard matching.count == 1, let machine = matching.first,
            MachineCommandPayload.valid(machine)
        else { throw ExtensionPeerError.rejected("Choose an available saved machine.") }
        return machine
    }

    private static func validPort(_ port: Int) -> Bool { (1...65_535).contains(port) }
    private static func loopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }

    private struct ConnectionRequest: Decodable { let machineID: UUID }
    private struct RunRequest: Decodable {
        let machineID: UUID
        let command: String
        let stdinbase64: String?
        let timeout: TimeInterval
    }
    private struct ForwardRequest: Decodable {
        let machineID: UUID; let localPort: Int; let remotePort: Int
    }
    private struct PrepareRequest: Decodable { let ports: [Int] }
    private static func aliases(_ machine: Machine) -> [String]? {
        guard case let .sshConfigAlias(alias) = machine.source,
            SSHConfigFile.isConcreteAlias(alias),
            !alias.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return [alias]
    }

    private struct Host: Encodable {
        let id: UUID
        let name: String
        let sshTarget: String
        let aliases: [String]?
    }
    private struct Hosts: Encodable { let machines: [Host] }
    private struct Output: Encodable { let output: String }
    private struct Connected: Encodable { let connected: Bool }
    private struct Prepared: Encodable { let prepared: Bool; let name: String? }
}
