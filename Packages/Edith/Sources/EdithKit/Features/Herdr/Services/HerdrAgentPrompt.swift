import Foundation

public enum HerdrPromptOutcome: Codable, Equatable, Sendable {
    case submitted
    case blocked
    case notReady
    case gone
    case failed(String)

    public var delivered: Bool { self == .submitted }

    public var summary: String {
        switch self {
        case .submitted: "Submitted"
        case .blocked: "Skipped: waiting for your input"
        case .notReady: "Skipped: agent is not at its prompt"
        case .gone: "Skipped: agent is gone"
        case .failed(let message): "Failed: \(message)"
        }
    }

    public static func from(_ error: Error) -> HerdrPromptOutcome {
        guard let error = error as? HerdrCommandError else {
            return .failed(error.localizedDescription)
        }
        switch HerdrAgentReply.errorCode(in: error) {
        case "agent_blocked": return .blocked
        case "agent_not_ready": return .notReady
        case "agent_not_found", "pane_not_found": return .gone
        default: return .failed(HerdrAgentReply.errorMessage(in: error))
        }
    }
}

public struct HerdrAgentObservation: Equatable, Sendable {
    public var kind: String
    public var status: HerdrAgentStatus
    public var sequence: Int?

    public init(kind: String, status: HerdrAgentStatus, sequence: Int?) {
        self.kind = kind
        self.status = status
        self.sequence = sequence
    }
}

public enum HerdrAgentProbe: Equatable, Sendable {
    case agent(HerdrAgentObservation)
    case gone
    case unreachable(String)
}

public enum HerdrAgentReply {
    public static func observation(from output: String) -> HerdrAgentObservation? {
        guard let root = HerdrListParser.firstJSON(in: output) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let agent = result["agent"] as? [String: Any],
            let kind = agent["agent"] as? String
        else { return nil }
        return HerdrAgentObservation(
            kind: kind, status: HerdrAgentStatus.parse(agent["agent_status"] as? String),
            sequence: HerdrListParser.integer(in: agent, keys: ["state_change_seq"]))
    }

    static func errorCode(in error: HerdrCommandError) -> String? {
        guard case .commandFailed(let text) = error else { return nil }
        return errorBody(in: text)?["code"] as? String
    }

    static func errorMessage(in error: HerdrCommandError) -> String {
        guard case .commandFailed(let text) = error,
            let message = errorBody(in: text)?["message"] as? String
        else { return error.localizedDescription }
        return message
    }

    private static func errorBody(in text: String) -> [String: Any]? {
        (HerdrListParser.firstJSON(in: text) as? [String: Any])?["error"] as? [String: Any]
    }
}

public enum HerdrAgentPromptCommand {
    public static func arguments(session: String, pane: String, text: String) -> [String] {
        HerdrSessionCommand.scoped(["agent", "prompt", pane, text], session: session)
    }

    public static func probeArguments(session: String, pane: String) -> [String] {
        HerdrSessionCommand.scoped(["agent", "get", pane], session: session)
    }
}

public enum HerdrAgentPromptError: LocalizedError, Equatable {
    case emptyMessage
    case machineUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptyMessage: "Write a message first."
        case .machineUnavailable: "The agent's machine is no longer configured."
        }
    }
}

public enum HerdrAgentPrompt {
    public static let timeout: TimeInterval = 15
    public static let maximumInFlight = 4

    public static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func send(_ text: String, to agent: HerdrAgent) async -> HerdrPromptOutcome {
        await send(
            text, session: agent.session, pane: agent.pane, machineID: agent.machineID,
            local: agent.machineIsLocal)
    }

    public static func send(
        _ text: String, session: String, pane: String, machineID: String, local: Bool
    ) async -> HerdrPromptOutcome {
        guard let text = normalized(text) else { return .failed("empty message") }
        do {
            let machine = try machine(id: machineID, local: local)
            _ = try await HerdrCommand.run(
                HerdrAgentPromptCommand.arguments(session: session, pane: pane, text: text),
                timeout: timeout, on: machine)
            return .submitted
        } catch {
            return HerdrPromptOutcome.from(error)
        }
    }

    public static func probe(
        session: String, pane: String, machineID: String, local: Bool
    ) async -> HerdrAgentProbe {
        let machine: Machine?
        do {
            machine = try self.machine(id: machineID, local: local)
        } catch {
            return .gone
        }
        do {
            let output = try await HerdrCommand.run(
                HerdrAgentPromptCommand.probeArguments(session: session, pane: pane),
                timeout: timeout, on: machine)
            guard let observation = HerdrAgentReply.observation(from: output) else {
                return .unreachable(HerdrCommandError.malformedResponse.localizedDescription)
            }
            return .agent(observation)
        } catch {
            if case .gone = HerdrPromptOutcome.from(error) { return .gone }
            return .unreachable(error.localizedDescription)
        }
    }

    public static func broadcast(
        _ text: String, to agents: [HerdrAgent], maximumInFlight: Int = maximumInFlight,
        send: @escaping @Sendable (String, HerdrAgent) async -> HerdrPromptOutcome = {
            await HerdrAgentPrompt.send($0, to: $1)
        }
    ) async -> [String: HerdrPromptOutcome] {
        var outcomes: [String: HerdrPromptOutcome] = [:]
        var pending = agents[...]
        await withTaskGroup(of: (String, HerdrPromptOutcome).self) { group in
            func startNext() {
                guard let agent = pending.popFirst() else { return }
                group.addTask { (agent.id, await send(text, agent)) }
            }
            for _ in 0..<max(1, maximumInFlight) { startNext() }
            while let (id, outcome) = await group.next() {
                outcomes[id] = outcome
                startNext()
            }
        }
        return outcomes
    }

    static func machine(id: String, local: Bool) throws -> Machine? {
        guard !local else { return nil }
        guard let machine = MachineRegistry.machines().first(where: { $0.id.uuidString == id })
        else { throw HerdrAgentPromptError.machineUnavailable }
        return machine
    }
}

public struct HerdrHookClient: Sendable {
    public static let timeout: TimeInterval = 10

    private let client: AgentClient

    public init(client: AgentClient = .shared) {
        self.client = client
    }

    public func list() async throws -> HerdrHooksSnapshot {
        try await perform(HerdrHookOperation.list, payload: Data())
    }

    public func arm(_ message: String, for agent: HerdrAgent) async throws -> HerdrHooksSnapshot {
        try await perform(
            HerdrHookOperation.arm,
            payload: AgentPayload.encode(HerdrHookArmRequest(agent: agent, message: message)))
    }

    public func remove(_ id: UUID) async throws -> HerdrHooksSnapshot {
        try await perform(HerdrHookOperation.remove, payload: AgentPayload.encode(id))
    }

    private func perform(_ operation: String, payload: Data) async throws -> HerdrHooksSnapshot {
        let data = try await client.performInternalAsync(
            operation, payload: payload, timeout: Self.timeout)
        return try AgentPayload.decode(HerdrHooksSnapshot.self, from: data)
    }
}
