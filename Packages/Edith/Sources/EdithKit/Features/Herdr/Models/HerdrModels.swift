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
    public static let terminalLabel = "Terminal"

    public static let filterLabels = [
        "Claude Code", "Codex", "OpenCode", "Cursor Agent", "Copilot CLI", "Pi", "Gemini", "Grok",
        "Cline", "FX.sh",
    ]

    public static func displayName(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        switch trimmed.lowercased().replacingOccurrences(of: " ", with: "-") {
        case "claude", "claude-code", "claude-code-cli":
            return "Claude Code"
        case "codex", "openai-codex":
            return "Codex"
        case "opencode", "open-code", "opencode2":
            return "OpenCode"
        case "cursor", "cursor-agent", "cursor-agent-cli", "cursor-cli":
            return "Cursor Agent"
        case "copilot", "github-copilot", "github-copilot-cli", "copilot-cli", "ghcs":
            return "Copilot CLI"
        case "pi", "py", "pi-coding-agent":
            return "Pi"
        case "gemini", "gemini-cli":
            return "Gemini"
        case "grok", "grok-build", "grok-cli":
            return "Grok"
        case "cline":
            return "Cline"
        case "fx", "fx.sh", "fx-sh":
            return "FX.sh"
        case "devin", "devin-cli":
            return "Devin"
        case "agy", "antigravity", "antigravity-cli":
            return "Antigravity"
        case "amp", "amp-local":
            return "Amp"
        case "droid", "factory-droid":
            return "Droid"
        case "kimi", "kimi-code":
            return "Kimi"
        case "kilo", "kilo-code":
            return "Kilo"
        case "qwen", "qwen-code":
            return "Qwen"
        case "hermes", "hermes-agent":
            return "Hermes"
        case "kiro", "kiro-cli":
            return "Kiro"
        case "qodercli", "qoder", "qoderclicn":
            return "Qoder"
        case "omp":
            return "OMP"
        case "mastracode", "mastra-code":
            return "Mastra Code"
        case "maki":
            return "Maki"
        default:
            return trimmed
        }
    }

    public static func logoName(for kind: String) -> String? {
        switch displayName(for: kind) {
        case "Claude Code": "claude"
        case "Codex": "codex"
        case "OpenCode": "opencode"
        case "Cursor Agent": "cursor"
        case "Copilot CLI": "copilot"
        case "Pi": "pi"
        case "Gemini": "gemini"
        case "Grok": "grok"
        case "Cline": "cline"
        case "FX.sh": "fx"
        case "Amp": "amp"
        case "Antigravity": "antigravity"
        case "Devin": "devin"
        case "Kilo": "kilo"
        case "Kimi": "kimi"
        case "Kiro": "kiro"
        case "Mastra Code": "mastra"
        case "Qoder": "qoder"
        case "Qwen": "qwen"
        default: nil
        }
    }

    public static func monogram(for kind: String) -> String {
        let name = displayName(for: kind)
        return String(name.prefix(1)).uppercased()
    }
}

public enum HerdrPaneCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case agent
    case terminal

    public var title: String {
        switch self {
        case .agent: "Agent"
        case .terminal: "Terminal"
        }
    }
}

public struct HerdrAgent: Identifiable, Codable, Equatable, Hashable, Sendable {
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
    public var category: HerdrPaneCategory
    public var stateSequence: Int?

    public init(
        id: String, machineID: String, machineName: String, machineIsLocal: Bool,
        sshTarget: String?, session: String, pane: String, kind: String,
        status: HerdrAgentStatus, title: String, workspace: String, cwd: String,
        category: HerdrPaneCategory = .agent, stateSequence: Int? = nil
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
        self.category = category
        self.stateSequence = stateSequence
    }

    public static func make(
        machineID: String, machineName: String, machineIsLocal: Bool, sshTarget: String?,
        session: String, pane: String, kind: String, status: HerdrAgentStatus, title: String,
        workspace: String, cwd: String, category: HerdrPaneCategory = .agent,
        stateSequence: Int? = nil
    ) -> HerdrAgent {
        HerdrAgent(
            id: "\(machineID)|\(session)|\(pane)",
            machineID: machineID, machineName: machineName, machineIsLocal: machineIsLocal,
            sshTarget: sshTarget, session: session, pane: pane, kind: kind, status: status,
            title: title, workspace: workspace, cwd: cwd, category: category,
            stateSequence: stateSequence)
    }

    public var isTerminal: Bool { category == .terminal }
}

public struct HerdrSpacePane: Codable, Equatable, Hashable, Sendable {
    public var session: String
    public var pane: String
    public var cwd: String

    public init(session: String, pane: String, cwd: String) {
        self.session = session
        self.pane = pane
        self.cwd = cwd
    }
}

public struct HerdrHostSnapshot: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isLocal: Bool
    public var sshTarget: String?
    public var herdrPresent: Bool
    public var reachable: Bool
    public var agents: [HerdrAgent]
    public var terminals: [HerdrSpacePane]
    public var error: String?

    public init(
        id: String, name: String, isLocal: Bool, sshTarget: String? = nil,
        herdrPresent: Bool, reachable: Bool, agents: [HerdrAgent] = [],
        terminals: [HerdrSpacePane] = [], error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
        self.sshTarget = sshTarget
        self.herdrPresent = herdrPresent
        self.reachable = reachable
        self.agents = agents
        self.terminals = terminals
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isLocal = try container.decode(Bool.self, forKey: .isLocal)
        sshTarget = try container.decodeIfPresent(String.self, forKey: .sshTarget)
        herdrPresent = try container.decode(Bool.self, forKey: .herdrPresent)
        reachable = try container.decode(Bool.self, forKey: .reachable)
        agents = try container.decode([HerdrAgent].self, forKey: .agents)
        terminals =
            try container.decodeIfPresent([HerdrSpacePane].self, forKey: .terminals) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    public static let localID = "local"

    public static func local(
        herdrPresent: Bool, agents: [HerdrAgent] = [], terminals: [HerdrSpacePane] = [],
        error: String? = nil
    ) -> HerdrHostSnapshot {
        HerdrHostSnapshot(
            id: localID, name: "This Mac", isLocal: true, herdrPresent: herdrPresent,
            reachable: true, agents: agents, terminals: terminals, error: error)
    }
}

public enum HerdrCollectScope: Sendable {
    case all
    case local
    case machine(Machine)
}

public struct HerdrSessionRecord: Equatable, Sendable {
    public var name: String
    public var running: Bool
    public var socketPath: String?

    public init(name: String, running: Bool, socketPath: String? = nil) {
        self.name = name
        self.running = running
        self.socketPath = socketPath
    }
}

public struct HerdrBoardContext: Equatable, Sendable {
    public var session: String
    public var machineID: String
    public var machineName: String
    public var machineIsLocal: Bool
    public var sshTarget: String?

    public init(
        session: String, machineID: String, machineName: String, machineIsLocal: Bool,
        sshTarget: String?
    ) {
        self.session = session
        self.machineID = machineID
        self.machineName = machineName
        self.machineIsLocal = machineIsLocal
        self.sshTarget = sshTarget
    }
}

public struct HerdrPaneRecord: Equatable, Sendable {
    public var pane: String
    public var kindRaw: String?
    public var statusRaw: String?
    public var title: String?
    public var workspaceID: String?
    public var cwd: String?
    public var revision: Int?
    public var stateSequence: Int?

    public init(
        pane: String, kindRaw: String? = nil, statusRaw: String? = nil, title: String? = nil,
        workspaceID: String? = nil, cwd: String? = nil, revision: Int? = nil,
        stateSequence: Int? = nil
    ) {
        self.pane = pane
        self.kindRaw = kindRaw
        self.statusRaw = statusRaw
        self.title = title
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.revision = revision
        self.stateSequence = stateSequence
    }

    public var looksLikeAgent: Bool {
        if let kindRaw, !kindRaw.isEmpty { return true }
        guard let statusRaw else { return false }
        return HerdrAgentStatus.parse(statusRaw) != .unknown
    }

    public func merging(_ incoming: HerdrPaneRecord) -> HerdrPaneRecord {
        let kind: String?
        if let incomingKind = incoming.kindRaw, !incomingKind.isEmpty {
            kind = incomingKind
        } else {
            kind = kindRaw
        }
        let status: String?
        if let incomingStatus = incoming.statusRaw {
            if HerdrAgentStatus.parse(incomingStatus) == .unknown,
                let statusRaw, HerdrAgentStatus.parse(statusRaw) != .unknown
            {
                status = statusRaw
            } else {
                status = incomingStatus
            }
        } else {
            status = statusRaw
        }
        return HerdrPaneRecord(
            pane: incoming.pane.isEmpty ? pane : incoming.pane,
            kindRaw: kind,
            statusRaw: status,
            title: incoming.title ?? title,
            workspaceID: incoming.workspaceID ?? workspaceID,
            cwd: incoming.cwd ?? cwd,
            revision: incoming.revision ?? revision,
            stateSequence: incoming.stateSequence ?? stateSequence)
    }
}

public struct HerdrSnapshotBoard: Equatable, Sendable {
    public var labels: [String: String]
    public var panes: [HerdrPaneRecord]
    public var agents: [HerdrPaneRecord]
    public var hasPaneList: Bool

    public init(
        labels: [String: String], panes: [HerdrPaneRecord], agents: [HerdrPaneRecord],
        hasPaneList: Bool
    ) {
        self.labels = labels
        self.panes = panes
        self.agents = agents
        self.hasPaneList = hasPaneList
    }
}

public struct HerdrWorkspaceSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var tabCount: Int
    public var paneCount: Int

    public init(id: String, label: String, tabCount: Int, paneCount: Int) {
        self.id = id
        self.label = label
        self.tabCount = tabCount
        self.paneCount = paneCount
    }
}

public struct HerdrCreatedPane: Equatable, Sendable {
    public var workspaceID: String
    public var tabID: String
    public var paneID: String

    public init(workspaceID: String, tabID: String, paneID: String) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
    }
}
