import Foundation

public enum AgentMachineTaskOperation {
    public static let command = "machine.command"
    public static let transfer = "machine.transfer"
}

public struct AgentMachineCommandRequest: Codable, Sendable {
    public let machine: Machine?
    public let command: String
    public let standardInput: Data?
    public let timeout: TimeInterval

    public init(
        machine: Machine?, command: String, standardInput: Data? = nil,
        timeout: TimeInterval = 60
    ) {
        self.machine = machine
        self.command = command
        self.standardInput = standardInput
        self.timeout = timeout
    }
}

public enum AgentMachineTransferDirection: String, Codable, Sendable {
    case upload
    case download
}

public struct AgentMachineTransferRequest: Codable, Sendable {
    public let machine: Machine
    public let direction: AgentMachineTransferDirection
    public let localURL: URL
    public let remotePath: String
    public let timeout: TimeInterval

    public init(
        machine: Machine, direction: AgentMachineTransferDirection, localURL: URL,
        remotePath: String, timeout: TimeInterval = 3_600
    ) {
        self.machine = machine
        self.direction = direction
        self.localURL = localURL
        self.remotePath = remotePath
        self.timeout = timeout
    }
}

public struct AgentMachineTransferResult: Codable, Sendable {
    public let bytes: Int64

    public init(bytes: Int64) { self.bytes = bytes }
}

extension AgentTaskClient {
    public func runMachineCommand(_ request: AgentMachineCommandRequest) async throws
        -> SSHExecResult
    {
        let submission = AgentTaskSubmission(
            operation: AgentMachineTaskOperation.command,
            title: "Run command on \(request.machine?.name ?? "This Mac")",
            payload: try AgentPayload.encode(request))
        return try AgentPayload.decode(SSHExecResult.self, from: await run(submission))
    }

    public func transferMachineFile(
        _ request: AgentMachineTransferRequest,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        let verb = request.direction == .upload ? "Upload to" : "Download from"
        let submission = AgentTaskSubmission(
            operation: AgentMachineTaskOperation.transfer,
            title: "\(verb) \(request.machine.name)", payload: try AgentPayload.encode(request))
        let data = try await run(submission) { output in
            guard output.text.hasPrefix("bytes:"),
                let bytes = Int64(output.text.dropFirst(6))
            else { return }
            progress?(bytes)
        }
        let result = try AgentPayload.decode(AgentMachineTransferResult.self, from: data)
        progress?(result.bytes)
    }
}
