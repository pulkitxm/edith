import Foundation

public enum AgentActivityProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, opencode
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }
}

public enum AgentActivityPhase: String, Codable, CaseIterable, Sendable {
    case idle, working, waiting, permission, finished, error, stuck, quiet, ended
    public var title: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .waiting: "Needs an answer"
        case .permission: "Needs approval"
        case .finished: "Finished"
        case .error: "Error"
        case .stuck: "Stuck"
        case .quiet: "No recent signal"
        case .ended: "Ended"
        }
    }
}

public struct AgentActivityEvent: Codable, Equatable, Sendable {
    public var id = UUID()
    public var provider: AgentActivityProvider
    public var sessionID: String
    public var parentSessionID: String?
    public var eventName: String
    public var phase: AgentActivityPhase
    public var project: String
    public var model: String?
    public var tool: String?
    public var detail: String?
    public var pane: String?
    public var permissionID: String?
    public var permissionRequest = false
    public var receivedAt: Date
    public var identity: String { provider.rawValue + ":" + sessionID }

    public init(
        provider: AgentActivityProvider, sessionID: String, eventName: String,
        phase: AgentActivityPhase, project: String, receivedAt: Date = Date()
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.eventName = eventName
        self.phase = phase
        self.project = project
        self.receivedAt = receivedAt
    }
}

public struct AgentActivitySession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: AgentActivityProvider
    public var sessionID: String
    public var parentID: String?
    public var phase: AgentActivityPhase
    public var project: String
    public var model: String?
    public var tool: String?
    public var detail: String?
    public var pane: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var completedTools = 0
    public var isSubagent: Bool { parentID != nil }

    public init(event: AgentActivityEvent) {
        id = event.identity
        provider = event.provider
        sessionID = event.sessionID
        parentID = event.parentSessionID.map { event.provider.rawValue + ":" + $0 }
        phase = event.phase
        project = event.project
        model = event.model
        tool = event.tool
        detail = event.detail
        pane = event.pane
        completedTools =
            (event.eventName == "PostToolUse" || event.eventName == "tool.execute.after") ? 1 : 0
        startedAt = event.receivedAt
        updatedAt = event.receivedAt
    }

    public mutating func apply(_ event: AgentActivityEvent) {
        guard event.identity == id, event.receivedAt >= updatedAt else { return }
        phase = event.phase
        project = event.project.isEmpty ? project : event.project
        model = event.model ?? model
        tool = event.tool ?? tool
        detail = event.detail ?? detail
        pane = event.pane ?? pane
        if let parent = event.parentSessionID { parentID = provider.rawValue + ":" + parent }
        updatedAt = event.receivedAt
        if event.eventName == "PostToolUse" || event.eventName == "tool.execute.after" {
            completedTools += 1
        }
    }
}

public enum AgentApprovalChoice: String, Codable, Sendable {
    case allowOnce, deny
}

public struct AgentApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var nonce: UUID
    public var sessionID: String
    public var provider: AgentActivityProvider
    public var providerPermissionID: String?
    public var project: String
    public var tool: String
    public var detail: String
    public var createdAt: Date
    public var expiresAt: Date

    public init(event: AgentActivityEvent, now: Date, lifetime: TimeInterval) {
        id = UUID()
        nonce = UUID()
        sessionID = event.identity
        provider = event.provider
        providerPermissionID = event.permissionID
        project = event.project
        tool = event.tool ?? "Tool"
        detail = event.detail ?? "No additional request details were supplied."
        createdAt = now
        expiresAt = now.addingTimeInterval(lifetime)
    }
}

public struct AgentApprovalToken: Codable, Equatable, Sendable {
    public var id: UUID
    public var nonce: UUID
    public init(id: UUID, nonce: UUID) { self.id = id; self.nonce = nonce }
    public init(_ request: AgentApprovalRequest) { self.init(id: request.id, nonce: request.nonce) }
}

public struct AgentApprovalDecision: Codable, Equatable, Sendable {
    public var token: AgentApprovalToken
    public var choice: AgentApprovalChoice
    public init(token: AgentApprovalToken, choice: AgentApprovalChoice) {
        self.token = token
        self.choice = choice
    }
}

public struct AgentApprovalResult: Codable, Equatable, Sendable {
    public var pending: Bool
    public var choice: AgentApprovalChoice?
    public init(pending: Bool = false, choice: AgentApprovalChoice? = nil) {
        self.pending = pending
        self.choice = choice
    }
}

public struct AgentActivitySnapshot: Codable, Equatable, Sendable {
    public var sessions: [AgentActivitySession]
    public var approvals: [AgentApprovalRequest]
    public var settings: AgentActivitySettings
    public var providerSignals: [String: Date]
    public var refreshedAt: Date
    public init(
        sessions: [AgentActivitySession] = [], approvals: [AgentApprovalRequest] = [],
        refreshedAt: Date = Date(), settings: AgentActivitySettings = AgentActivitySettings(),
        providerSignals: [String: Date] = [:]
    ) {
        self.sessions = sessions
        self.approvals = approvals
        self.settings = settings
        self.providerSignals = providerSignals
        self.refreshedAt = refreshedAt
    }
}

public enum AgentActivityParser {
    public static let maximumInputBytes = 131_072

    public static func parse(
        _ data: Data, provider: AgentActivityProvider, pane: String? = nil, now: Date = Date()
    ) throws -> AgentActivityEvent? {
        guard data.count <= maximumInputBytes,
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return provider == .opencode
            ? openCode(root, pane: pane, now: now)
            : hook(root, provider: provider, pane: pane, now: now)
    }

    private static func hook(
        _ root: [String: Any], provider: AgentActivityProvider, pane: String?, now: Date
    ) -> AgentActivityEvent? {
        guard let name = string(root["hook_event_name"]),
            let parent = string(root["session_id"])
        else { return nil }
        let phase: AgentActivityPhase
        switch name {
        case "SessionStart": phase = .idle
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart": phase = .working
        case "PermissionRequest": phase = .permission
        case "PermissionDenied", "PostToolUseFailure": phase = .error
        case "Interrupt": phase = .idle
        case "Elicitation": phase = .waiting
        case "ElicitationResult": phase = .working
        case "Stop", "SubagentStop": phase = .finished
        case "StopFailure": phase = .error
        case "SessionEnd": phase = .ended
        case "Notification":
            switch string(root["notification_type"]) {
            case "permission_prompt": phase = .permission
            case "elicitation_dialog", "idle_prompt": phase = .waiting
            default: return nil
            }
        default: return nil
        }
        let child = name == "SubagentStart" || name == "SubagentStop"
        let childID = string(root["agent_id"])
        guard !child || childID != nil else { return nil }
        var event = AgentActivityEvent(
            provider: provider, sessionID: childID.flatMap { child ? $0 : nil } ?? parent,
            eventName: name, phase: phase, project: string(root["cwd"]) ?? "", receivedAt: now)
        event.parentSessionID = child ? parent : nil
        event.model = string(root["model"])
        event.tool = string(root["tool_name"])
        event.detail = describe(root["tool_input"]) ?? string(root["message"])
        event.pane = string(pane)
        event.permissionRequest =
            name == "PermissionRequest" && event.tool != nil
            && root.keys.contains("tool_input")
        event.permissionID = string(root["tool_use_id"])
        return event
    }

    private static func openCode(
        _ root: [String: Any], pane: String?, now: Date
    ) -> AgentActivityEvent? {
        guard let name = string(root["type"]),
            let properties = root["properties"] as? [String: Any]
        else { return nil }
        let info = properties["info"] as? [String: Any] ?? [:]
        guard let session = string(properties["sessionID"]) ?? string(info["id"])
        else { return nil }
        let phase: AgentActivityPhase
        switch name {
        case "session.created": phase = .idle
        case "session.idle": phase = .finished
        case "session.deleted": phase = .ended
        case "session.error": phase = .error
        case "permission.asked": phase = .permission
        case "permission.replied", "tool.execute.before", "tool.execute.after": phase = .working
        case "session.status":
            let status = properties["status"] as? [String: Any] ?? [:]
            switch string(status["type"]) {
            case "busy": phase = .working
            case "idle": phase = .finished
            case "retry": phase = .waiting
            default: return nil
            }
        default: return nil
        }
        var event = AgentActivityEvent(
            provider: .opencode, sessionID: session, eventName: name, phase: phase,
            project: string(root["directory"]) ?? string(info["directory"]) ?? "", receivedAt: now)
        event.parentSessionID = string(info["parentID"])
        event.tool = string(properties["permission"]) ?? string(properties["tool"])
        event.detail =
            describe(properties["metadata"]) ?? describe(properties["patterns"])
            ?? describe(properties["error"])
        event.permissionID = string(properties["id"]) ?? string(properties["requestID"])
        event.permissionRequest =
            name == "permission.asked" && event.permissionID != nil
            && event.tool != nil
        event.pane = string(pane)
        return event
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(4096))
    }

    private static func describe(_ value: Any?) -> String? {
        if let raw = string(value) { return raw }
        if let fields = value as? [String: Any], let command = string(fields["command"]) {
            return command
        }
        guard let value, JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(String(data: data, encoding: .utf8)?.prefix(8192) ?? "")
    }
}
