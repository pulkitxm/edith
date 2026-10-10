import EdithExtensionSupport
import Foundation

struct AgentActivityRow: Identifiable, Equatable, Sendable {
    var id: String
    var provider: String
    var providerTitle: String
    var phase: AgentActivityPhase
    var project: String
    var model: String?
    var tool: String?
    var detail: String?
    var startedAt: Date
    var updatedAt: Date
    var completedTools: Int
    var isSubagent: Bool
    var terminal: HerdrAgent?
    var attentionCheckedAt: Date?
    var isHook: Bool
    var sourceTitle: String {
        isHook ? "Provider hook" : (terminal?.machineName ?? "Terminal discovery")
    }
    var isActive: Bool { phase != .finished && phase != .ended }
    var title: String {
        let name = terminal?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? projectTitle : name
    }
    var projectTitle: String {
        guard !project.isEmpty else { return providerTitle }
        let component = URL(fileURLWithPath: project).lastPathComponent
        return component.isEmpty ? providerTitle : component
    }

    init(_ session: AgentActivitySession) {
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

    init(_ agent: HerdrAgent, observedAt: Date) {
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

    static func phase(_ status: HerdrAgentStatus) -> AgentActivityPhase {
        switch status {
        case .working: .working
        case .blocked: .blocked
        case .done: .finished
        case .idle: .idle
        case .unknown: .quiet
        }
    }

    static func phase(_ state: HerdrAttentionState) -> AgentActivityPhase {
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
    static func terminalKind(_ raw: String) -> Self? {
        if let provider = Self(rawValue: raw.lowercased()) { return provider }
        let title = HerdrKind.displayName(for: raw)
        if title == "Gemini" { return .gemini }
        return allCases.first { $0.title == title }
    }
}

struct AgentActivityPresentation: Equatable, Sendable {
    var rows: [AgentActivityRow]
    var approvals: [AgentApprovalRequest]
    func providerChoices(including selected: Set<String> = []) -> [SurfaceSourceChoice] {
        var titles = Dictionary(
            uniqueKeysWithValues: AgentActivityProvider.allCases.map { ($0.rawValue, $0.title) })
        for title in HerdrKind.filterLabels {
            let id = AgentActivityProvider.terminalKind(title)?.rawValue ?? title.lowercased()
            if titles[id] == nil { titles[id] = title }
        }
        for row in rows where titles[row.provider] == nil {
            titles[row.provider] = row.providerTitle
        }
        for id in selected where titles[id] == nil { titles[id] = HerdrKind.displayName(for: id) }
        return titles.map { SurfaceSourceChoice($0.key, $0.value) }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    var working: Int { rows.filter { $0.phase == .working }.count }
    var waiting: Int {
        rows.filter { [.waiting, .permission, .blocked].contains($0.phase) }.count
    }
    var stuck: Int { rows.filter { $0.phase == .stuck }.count }
    var quiet: Int { rows.filter { $0.phase == .quiet }.count }
    var errors: Int { rows.filter { $0.phase == .error }.count }
    var active: Int { rows.filter(\.isActive).count }
    var subagents: Int { rows.filter { $0.isSubagent && $0.isActive }.count }

    init(
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
        approvals = activity.approvals.filter { request in
            (tile?.sourceIDs == nil || tile?.sourceIDs?.contains(request.provider.rawValue) == true)
                && (tile?.agentPhases == nil || tile?.agentPhases?.contains("permission") == true)
                && (tile?.includeSubagents != false
                    || !activity.sessions.contains { session in
                        session.id == request.sessionID && session.isSubagent
                    })
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
