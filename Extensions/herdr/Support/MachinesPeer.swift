import EdithExtensionSupport
import Foundation

public struct Machine: Codable, Identifiable, Equatable, Hashable, Sendable {
    public static let localID = UUID(uuidString: "00000000-0000-0000-0000-0000000000ED")!
    public static let local = Machine(id: localID, name: "This Mac", host: "localhost")
    public let id: UUID
    public let name: String
    public let host: String
    public let username: String
    public let port: Int
    public var sshTarget: String { username.isEmpty ? host : "\(username)@\(host)" }
    public var subtitle: String { sshTarget }
    public init(
        id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String = ""
    ) {
        self.id = id; self.name = name; self.host = host; self.port = port; self.username = username
    }
}

public enum MachineRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var snapshot: [Machine] = []
    public static func machines() -> [Machine] { lock.withLock { snapshot } }
    public static func refresh(
        invoke: @Sendable (String, Data, TimeInterval) async throws -> Data = {
            try await MachinesPeer.invoke($0, $1, $2)
        }
    ) async throws {
        let data = try await invoke("machines.companion.hosts", Data("{}".utf8), 15)
        let hosts = try JSONDecoder().decode(Hosts.self, from: data)
        guard hosts.machines.count <= 1_024,
            Set(hosts.machines.map(\.id)).count == hosts.machines.count,
            hosts.machines.allSatisfy({
                !$0.name.isEmpty && $0.name.utf8.count <= 256 && validTarget($0.sshTarget)
            })
        else { throw ExtensionPeerError.invalidRequest }
        lock.withLock {
            snapshot = hosts.machines.map { Machine(id: $0.id, name: $0.name, host: $0.sshTarget) }
        }
    }
    public static func shutdown() { lock.withLock { snapshot = [] } }
    private struct Host: Decodable { let id: UUID; let name: String; let sshTarget: String }
    private struct Hosts: Decodable { let machines: [Host] }
    static func validTarget(_ target: String) -> Bool {
        !target.isEmpty && target.utf8.count <= 512 && !target.hasPrefix("-")
            && !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public enum MachinesPeer {
    public static func invoke(_ command: String, _ payload: Data, _ timeout: TimeInterval)
        async throws -> Data
    {
        guard let endpoint = ExtensionPeerEndpoint.current(owner: "machines") else {
            throw ExtensionPeerError.rejected("Enable Machines to use saved remote connections.")
        }
        return try await endpoint.invoke(command, payload: payload, timeout: timeout)
    }
}

public struct SSHExecResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
    public var succeeded: Bool { status == 0 }
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public final class SSHConnection: @unchecked Sendable {
    public enum ControlSocketMode { case shared, isolated }
    public static let executable = URL(fileURLWithPath: "/usr/bin/ssh")
    public let machine: Machine
    private let lock = NSLock()
    private var recipe: Recipe?
    private let invoke: @Sendable (String, Data, TimeInterval) async throws -> Data
    public var remotePlatform: RemoteMachinePlatform? {
        get async { lock.withLock { recipe?.platform } }
    }
    public var controlSocketPath: String { lock.withLock { recipe?.controlPath ?? "" } }
    public init(
        machine: Machine, controlSocketMode: ControlSocketMode = .isolated,
        invoke: @escaping @Sendable (String, Data, TimeInterval) async throws -> Data = {
            try await MachinesPeer.invoke($0, $1, $2)
        }
    ) {
        self.machine = machine
        self.invoke = invoke
    }
    public func connect() async throws {
        try Task.checkCancellation()
        guard MachineRegistry.machines().contains(machine) else {
            throw ExtensionPeerError.unavailable
        }
        let payload = try JSONEncoder().encode(Selection(machineID: machine.id))
        let data = try await invoke("machines.connection.prepare", payload, 60)
        let value = try JSONDecoder().decode(Recipe.self, from: data)
        guard value.machineID == machine.id, value.name == machine.name,
            value.sshTarget == machine.sshTarget, value.sshArguments.count <= 64,
            value.sshArguments.reduce(0, { $0 + $1.utf8.count }) <= 16_384,
            value.sshArguments.allSatisfy({ !$0.utf8.contains(0) }),
            !value.controlPath.isEmpty, value.controlPath.utf8.count <= 1_024
        else { throw ExtensionPeerError.invalidRequest }
        try Task.checkCancellation()
        lock.withLock { recipe = value }
    }
    public func disconnect() async { lock.withLock { recipe = nil } }
    public func run(_ command: String, stdin: Data? = nil, timeout: TimeInterval = 30) async throws
        -> SSHExecResult
    {
        guard command.utf8.count <= 65_536, !command.utf8.contains(0), timeout.isFinite,
            timeout > 0, timeout <= 1_800, (stdin?.count ?? 0) <= 4 * 1_024 * 1_024,
            MachineRegistry.machines().contains(machine)
        else { throw ExtensionPeerError.invalidRequest }
        let payload = try JSONEncoder().encode(
            Run(
                machineID: machine.id, command: command,
                stdinbase64: stdin?.base64EncodedString(), timeout: timeout))
        let data = try await invoke("machines.companion.run", payload, timeout + 15)
        let reply = try JSONDecoder().decode(Output.self, from: data)
        try Task.checkCancellation()
        guard reply.output.utf8.count <= 6 * 1_024 * 1_024 else {
            throw ExtensionPeerError.invalidRequest
        }
        return SSHExecResult(status: 0, stdout: Data(reply.output.utf8), stderr: Data())
    }
    public func execArguments(command: String) throws -> [String] {
        try arguments(tty: false) + [command]
    }
    public func terminalArguments(remoteCommand: String? = nil) throws -> [String] {
        try arguments(tty: true) + (remoteCommand.map { [$0] } ?? [])
    }
    private func arguments(tty: Bool) throws -> [String] {
        try lock.withLock {
            guard let recipe else {
                throw ExtensionPeerError.rejected(
                    "Connect the saved machine through Machines before opening a remote terminal.")
            }
            return [tty ? "-tt" : "-T"] + recipe.sshArguments
        }
    }
    public func terminalEnvironment() -> [String] {
        CLIToolEnvironment.sanitized().map { "\($0.key)=\($0.value)" }
    }
    public func streamProcess(command: String) throws -> Process {
        let process = Process(); process.executableURL = Self.executable
        process.arguments = try execArguments(command: command);
        process.environment = CLIToolEnvironment.sanitized()
        return process
    }
    private struct Selection: Encodable { let machineID: UUID }
    private struct Run: Encodable {
        let machineID: UUID; let command: String; let stdinbase64: String?;
        let timeout: TimeInterval
    }
    private struct Output: Decodable { let output: String }
    private struct Recipe: Decodable {
        let machineID: UUID; let name: String; let sshTarget: String; let sshArguments: [String]
        let controlPath: String; let platform: RemoteMachinePlatform
    }
}
