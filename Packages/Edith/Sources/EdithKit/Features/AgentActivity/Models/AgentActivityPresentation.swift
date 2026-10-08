import Foundation

public struct AgentActivityRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var provider: String
    public var providerTitle: String
    public var phase: AgentActivityPhase
    public var project: String
    public var model: String?
    public var tool: String?
    public var detail: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var completedTools: Int
    public var isSubagent: Bool
    public var terminal: HerdrAgent?
    public var attentionCheckedAt: Date?
    public var isHook: Bool
    public var sourceTitle: String {
        isHook ? "Provider hook" : (terminal?.machineName ?? "Terminal discovery")
    }
    public var isActive: Bool { phase != .finished && phase != .ended }
    public var projectTitle: String {
        let component = URL(fileURLWithPath: project).lastPathComponent
        return component.isEmpty ? providerTitle : component
    }

    public init(_ session: AgentActivitySession) {
        id = session.id
        provider = session.provider.rawValue
        providerTitle = session.provider.title
        phase = session.phase
        project = session.project
        model = session.model
        tool = session.tool
        detail = session.detail
        startedAt = session.startedAt
        updatedAt = session.updatedAt
        completedTools = session.completedTools
        isSubagent = session.isSubagent
        isHook = true
    }

    public init(_ agent: HerdrAgent, observedAt: Date) {
        id = agent.id
        provider =
            AgentActivityProvider.terminalKind(agent.kind)?.rawValue
            ?? HerdrKind.displayName(for: agent.kind).lowercased()
        providerTitle = HerdrKind.displayName(for: agent.kind)
        phase = Self.phase(agent.status)
        project = agent.cwd.isEmpty ? agent.workspace : agent.cwd
        startedAt = observedAt
        updatedAt = observedAt
        completedTools = 0
        isSubagent = false
        terminal = agent
        isHook = false
    }

    public static func phase(_ status: HerdrAgentStatus) -> AgentActivityPhase {
        switch status {
        case .working: .working
        case .blocked: .blocked
        case .done: .finished
        case .idle: .idle
        case .unknown: .quiet
        }
    }

    public static func phase(_ state: HerdrAttentionState) -> AgentActivityPhase {
        switch state {
        case .working: .working
        case .waitingInput: .waiting
        case .permissionPrompt: .permission
        case .done: .finished
        case .error: .error
        case .looping: .stuck
        }
    }
}

extension AgentActivityProvider {
    public static func terminalKind(_ raw: String) -> Self? {
        let title = HerdrKind.displayName(for: raw)
        return allCases.first { $0.title == title }
    }
}

public struct AgentActivityPresentation: Equatable, Sendable {
    public var rows: [AgentActivityRow]
    public var approvals: [AgentApprovalRequest]
    public var working: Int { rows.filter { $0.phase == .working }.count }
    public var waiting: Int {
        rows.filter { [.waiting, .permission, .blocked].contains($0.phase) }.count
    }
    public var stuck: Int { rows.filter { $0.phase == .stuck }.count }
    public var quiet: Int { rows.filter { $0.phase == .quiet }.count }
    public var errors: Int { rows.filter { $0.phase == .error }.count }
    public var active: Int { rows.filter(\.isActive).count }
    public var subagents: Int { rows.filter { $0.isSubagent && $0.isActive }.count }

    public init(
        activity: AgentActivitySnapshot, terminals: SessionsSnapshot? = nil,
        tile: SurfaceTile? = nil, now: Date = Date(), observedAt: [String: Date] = [:]
    ) {
        var result = activity.sessions.filter { $0.phase != .ended }.map { session in
            var row = AgentActivityRow(session)
            if (row.phase == .working || row.phase == .idle),
                now.timeIntervalSince(row.updatedAt) > Double(activity.settings.quietMinutes * 60)
            {
                row.phase = .quiet
            }
            return row
        }
        for host in terminals?.hosts ?? [] where host.reachable && host.error == nil {
            for agent in host.agents where !agent.isTerminal {
                let matched: Int?
                if host.isLocal, let native = agent.nativeSession,
                    let provider = AgentActivityProvider.terminalKind(native.provider)
                {
                    matched = result.firstIndex { $0.id == provider.rawValue + ":" + native.value }
                } else {
                    matched = nil
                }
                let index: Int
                if let matched {
                    index = matched
                    result[index].terminal = agent
                    if result[index].phase == .quiet {
                        result[index].phase = AgentActivityRow.phase(agent.status)
                    }
                } else {
                    index = result.count
                    result.append(
                        AgentActivityRow(
                            agent,
                            observedAt: observedAt[agent.id] ?? terminals?.discoveredAt
                                ?? activity.refreshedAt))
                }
                if let evidence = terminals?.attention[agent.id],
                    !result[index].isHook || evidence.checkedAt >= result[index].updatedAt
                {
                    result[index].phase = AgentActivityRow.phase(evidence.state)
                    result[index].attentionCheckedAt = evidence.checkedAt
                }
            }
        }
        rows = result.filter {
            (tile?.sourceIDs == nil || tile?.sourceIDs?.contains($0.provider) == true)
                && (tile?.agentPhases == nil
                    || tile?.agentPhases?.contains($0.phase.rawValue) == true)
                && (tile?.includeSubagents != false || !$0.isSubagent)
        }.sorted {
            let left = Self.priority($0.phase), right = Self.priority($1.phase)
            if left != right { return left < right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        approvals = activity.approvals.filter {
            tile?.sourceIDs == nil || tile?.sourceIDs?.contains($0.provider.rawValue) == true
        }
    }

    private static func priority(_ phase: AgentActivityPhase) -> Int {
        switch phase {
        case .permission, .blocked, .waiting: 0
        case .error, .stuck: 1
        case .working: 2
        case .quiet: 3
        case .idle: 4
        case .finished, .ended: 5
        }
    }
}
