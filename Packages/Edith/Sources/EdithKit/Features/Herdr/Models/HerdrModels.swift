import Foundation

public enum HerdrAgentStatus: String, CaseIterable, Codable, Sendable, Equatable {
    case blocked
    case working
    case unknown
    case done
    case idle

    public var title: String {
        switch self {
        case .blocked: "Blocked"
        case .working: "Working"
        case .unknown: "Unknown"
        case .done: "Done"
        case .idle: "Idle"
        }
    }

    public static func parse(_ raw: String?) -> HerdrAgentStatus {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        {
        case "blocked", "needs_attention", "waiting", "waiting_for_input", "approval":
            .blocked
        case "working", "running", "busy", "in_progress", "thinking":
            .working
        case "done", "complete", "completed", "finished", "success":
            .done
        case "idle", "ready", "stopped":
            .idle
        default:
            .unknown
        }
    }
}

public enum HerdrKind {
    public static let filterLabels = [
        "Claude Code", "Codex", "OpenCode", "Cursor Agent", "Copilot CLI",
    ]

    public static func displayName(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        switch trimmed.lowercased().replacingOccurrences(of: " ", with: "-") {
        case "claude", "claude-code", "claude-code-cli":
            return "Claude Code"
        case "codex", "openai-codex":
            return "Codex"
        case "opencode", "open-code":
            return "OpenCode"
        case "cursor", "cursor-agent", "cursor-agent-cli", "cursor-cli":
            return "Cursor Agent"
        case "copilot", "github-copilot", "github-copilot-cli", "copilot-cli":
            return "Copilot CLI"
        default:
            return trimmed
        }
    }
}

public struct HerdrAgent: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var machineID: String
    public var machineName: String
    public var machineIsLocal: Bool
    public var sshTarget: String?
    public var session: String
    public var pane: String
    public var kind: String
    public var status: HerdrAgentStatus
    public var title: String
    public var workspace: String
    public var cwd: String

    public init(
        id: String, machineID: String, machineName: String, machineIsLocal: Bool,
        sshTarget: String?, session: String, pane: String, kind: String,
        status: HerdrAgentStatus, title: String, workspace: String, cwd: String
    ) {
        self.id = id
        self.machineID = machineID
        self.machineName = machineName
        self.machineIsLocal = machineIsLocal
        self.sshTarget = sshTarget
        self.session = session
        self.pane = pane
        self.kind = kind
        self.status = status
        self.title = title
        self.workspace = workspace
        self.cwd = cwd
    }

    public static func make(
        machineID: String, machineName: String, machineIsLocal: Bool, sshTarget: String?,
        session: String, pane: String, kind: String, status: HerdrAgentStatus, title: String,
        workspace: String, cwd: String
    ) -> HerdrAgent {
        HerdrAgent(
            id: "\(machineID)|\(session)|\(pane)",
            machineID: machineID, machineName: machineName, machineIsLocal: machineIsLocal,
            sshTarget: sshTarget, session: session, pane: pane, kind: kind, status: status,
            title: title, workspace: workspace, cwd: cwd)
    }
}

public struct HerdrHostSnapshot: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isLocal: Bool
    public var sshTarget: String?
    public var herdrPresent: Bool
    public var reachable: Bool
    public var agents: [HerdrAgent]
    public var error: String?

    public init(
        id: String, name: String, isLocal: Bool, sshTarget: String? = nil,
        herdrPresent: Bool, reachable: Bool, agents: [HerdrAgent] = [], error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
        self.sshTarget = sshTarget
        self.herdrPresent = herdrPresent
        self.reachable = reachable
        self.agents = agents
        self.error = error
    }

    public static let localID = "local"

    public static func local(
        herdrPresent: Bool, agents: [HerdrAgent] = [], error: String? = nil
    ) -> HerdrHostSnapshot {
        HerdrHostSnapshot(
            id: localID, name: "This Mac", isLocal: true, herdrPresent: herdrPresent,
            reachable: true, agents: agents, error: error)
    }
}

public enum HerdrCollectScope: Sendable {
    case all
    case local
    case machine(Machine)
}
