import EdithExtensionSupport
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
        HerdrResources.url(forResource: scriptName, withExtension: "py")
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
    public static let superseded = "A newer search replaced this one."

    public typealias RemoteSearch =
        @Sendable (AgentSearchRequest, SSHConnection) async throws -> AgentSearchReply

    private let local: AgentSessionSearch
    private let machines: @Sendable () -> [Machine]
    private let remote: RemoteSearch
    private var connections: [UUID: SSHConnection] = [:]
    private var queues: [UUID: Task<Void, Never>] = [:]
    private var latest: [UUID: UUID] = [:]
    private var work: [UUID: Task<AgentSearchReply, Never>] = [:]
    private var stopped = false

    public init(
        local: AgentSessionSearch = .shared,
        machines: @escaping @Sendable () -> [Machine] = { MachineRegistry.machines() },
        remote: @escaping RemoteSearch = { try await AgentSearchRemote.search($0, over: $1) }
    ) {
        self.local = local
        self.machines = machines
        self.remote = remote
    }

    public func shutdown() async {
        stopped = true
        let pending = Array(work.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.value }
        work.removeAll()
        queues.removeAll()
        latest.removeAll()
        for connection in connections.values { await connection.disconnect() }
        connections.removeAll()
        await local.shutdown()
    }

    public func search(_ request: AgentSearchRequest) async -> AgentSearchReply {
        guard !stopped, !Task.isCancelled else {
            return AgentSearchReply(
                machineID: request.machineID, error: "The search was cancelled.")
        }
        guard request.machineID != HerdrHostSnapshot.localID else {
            return await local.search(request)
        }
        guard let machine = machines().first(where: { $0.id.uuidString == request.machineID })
        else {
            return AgentSearchReply(
                machineID: request.machineID, error: "This machine is no longer in Edith.")
        }
        let token = UUID()
        latest[machine.id] = token
        let previous = queues[machine.id]
        let task = Task { await self.queued(request, on: machine, token: token, after: previous) }
        work[token] = task
        queues[machine.id] = Task { _ = await task.value }
        let reply = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        work.removeValue(forKey: token)
        return reply
    }

    private func queued(
        _ request: AgentSearchRequest, on machine: Machine, token: UUID,
        after previous: Task<Void, Never>?
    ) async -> AgentSearchReply {
        await previous?.value
        guard !stopped, !Task.isCancelled, latest[machine.id] == token else {
            return AgentSearchReply(machineID: request.machineID, error: Self.superseded)
        }
        let started = Date()
        do {
            return try await remote(request, connection(for: machine))
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
    private let service: AgentSearchService
    public init(service: AgentSearchService = .shared) { self.service = service }
    public func search(_ request: AgentSearchRequest) async throws -> AgentSearchReply {
        try Task.checkCancellation()
        let reply = await service.search(request)
        try Task.checkCancellation()
        return reply
    }
}
