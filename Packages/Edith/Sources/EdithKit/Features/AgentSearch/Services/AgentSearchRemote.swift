import Foundation

public enum AgentSearchRemoteError: LocalizedError, Equatable {
    case scriptMissing
    case windowsUnsupported
    case pythonMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .scriptMissing: "The session search script is missing from this build."
        case .windowsUnsupported: "Session search does not cover Windows machines yet."
        case .pythonMissing: "python3 is not installed there."
        case .failed(let message): message.isEmpty ? "The search did not finish." : message
        }
    }
}

public enum AgentSearchRemote {
    public static let scriptName = "agent-search"
    public static let remoteBudget = 4.0
    public static let timeout: TimeInterval = 40

    public static func scriptURL() -> URL? {
        BundledResources.url(forResource: scriptName, withExtension: "py")
    }

    public static func argument(for request: AgentSearchRequest) throws -> String {
        try JSONEncoder().encode(request).base64EncodedString()
    }

    public static func command(for request: AgentSearchRequest) throws -> String {
        "python3 - " + (try argument(for: request))
    }

    public static func decode(_ data: Data, machineID: String) throws -> AgentSearchReply {
        var reply = try JSONDecoder().decode(AgentSearchReply.self, from: data)
        reply.machineID = machineID
        reply.hits = reply.hits.map { $0.assigning(machineID: machineID) }
        return reply
    }

    public static func search(
        _ request: AgentSearchRequest, over connection: SSHConnection
    ) async throws -> AgentSearchReply {
        guard let url = scriptURL(), let script = try? Data(contentsOf: url) else {
            throw AgentSearchRemoteError.scriptMissing
        }
        try await connection.connect()
        if await connection.remotePlatform == .windows {
            throw AgentSearchRemoteError.windowsUnsupported
        }
        var remote = request
        remote.budget = max(request.budget, remoteBudget)
        let result = try await connection.run(
            command(for: remote), stdin: script, timeout: timeout)
        if result.status == 127 { throw AgentSearchRemoteError.pythonMissing }
        guard result.status == 0 else {
            let lines = result.stderrText.split(whereSeparator: \.isNewline)
            throw AgentSearchRemoteError.failed(lines.last.map(String.init) ?? "")
        }
        return try decode(result.stdout, machineID: request.machineID)
    }
}

public actor AgentSearchService {
    public static let shared = AgentSearchService()

    private let index: AgentTranscriptIndex
    private let machines: @Sendable () -> [Machine]
    private var connections: [UUID: SSHConnection] = [:]

    public init(
        index: AgentTranscriptIndex = .shared,
        machines: @escaping @Sendable () -> [Machine] = { MachineRegistry.machines() }
    ) {
        self.index = index
        self.machines = machines
    }

    public func search(_ request: AgentSearchRequest) async -> AgentSearchReply {
        guard request.machineID != HerdrHostSnapshot.localID else {
            return await index.search(request)
        }
        guard let machine = machines().first(where: { $0.id.uuidString == request.machineID })
        else {
            return AgentSearchReply(
                machineID: request.machineID, error: "This machine is no longer in Edith.")
        }
        let started = Date()
        do {
            return try await AgentSearchRemote.search(request, over: connection(for: machine))
        } catch {
            if !(error is AgentSearchRemoteError),
                let stale = connections.removeValue(forKey: machine.id)
            {
                await stale.disconnect()
            }
            let message =
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return AgentSearchReply(
                machineID: request.machineID, error: message,
                milliseconds: Int(Date().timeIntervalSince(started) * 1_000))
        }
    }

    private func connection(for machine: Machine) -> SSHConnection {
        if let existing = connections[machine.id] { return existing }
        let connection = SSHConnection(machine: machine, controlSocketMode: .isolated)
        connections[machine.id] = connection
        return connection
    }
}

public struct AgentSearchClient: Sendable {
    public static let timeout: TimeInterval = AgentSearchRemote.timeout + 20

    private let client: AgentClient

    public init(client: AgentClient = .shared) {
        self.client = client
    }

    public func search(_ request: AgentSearchRequest) async throws -> AgentSearchReply {
        let data = try await client.performInternalAsync(
            AgentSearchOperation.search, payload: AgentPayload.encode(request),
            timeout: Self.timeout)
        return try AgentPayload.decode(AgentSearchReply.self, from: data)
    }
}
