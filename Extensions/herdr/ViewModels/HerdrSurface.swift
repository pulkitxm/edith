import EdithExtensionUI
import EdithExtensionSupport
import Foundation

@MainActor final class HerdrSurface {
    private enum Target: Equatable {
        case terminal(String)
        case approval(AgentApprovalToken, AgentApprovalChoice)
    }
    private let worker: HerdrWorker
    private let privacyValues: @MainActor () -> [String: String]
    private var actions: [String: Target] = [:]
    init(
        worker: HerdrWorker,
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) {
        self.worker = worker
        self.privacyValues = privacyValues
    }
    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "herdr", command: command, payload: payload,
            snapshot: { try await self.snapshot($0) }, perform: { try await self.perform($0) },
            privacyValues: privacyValues)
    }
    func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        let activity = await worker.activity.surfaceSnapshot()
        let terminals = worker.activity.terminals.snapshot(
            hosts: Array(worker.store.hosts.prefix(64)),
            enabled: worker.activity.discoversTerminals)
        let presentation = AgentActivityPresentation(
            activity: activity, terminals: terminals,
            tile: tile, observedAt: worker.activity.terminals.observedAt)
        let all = AgentActivityPresentation(activity: activity, terminals: terminals)
        actions = actions.filter { _, target in
            switch target {
            case .terminal(let id): return worker.currentAgent(id) != nil
            case .approval(let token, _):
                return activity.approvals.contains { $0.id == token.id && $0.nonce == token.nonce }
            }
        }
        if actions.count > 512 { actions = [:] }
        var rows: [SurfaceDataRow] = []
        for request in presentation.approvals.prefix(tile.itemLimit) where tile.shows("approvals") {
            let controls: [SurfaceAction] = [AgentApprovalChoice.deny, .allowOnce].map { choice in
                let target = Target.approval(.init(request), choice)
                let id = action(target)
                return .init(
                    id, choice == .deny ? "Deny" : "Allow once",
                    choice == .deny ? "xmark" : "checkmark", field: "approvals")
            }
            rows.append(
                .init(
                    request.id.uuidString, sourceID: request.provider.rawValue,
                    title: request.tool, detail: HerdrWorker.bounded(request.detail, 1_024),
                    value: "\(max(0, Int(request.expiresAt.timeIntervalSinceNow)))s",
                    icon: "hand.raised.fill",
                    field: "approvals",
                    actions: [
                        .init(
                            "connections", "Review full request", "doc.text.magnifyingglass",
                            field: "approvals")
                    ] + controls))
        }
        for row in presentation.rows.prefix(max(0, tile.itemLimit - rows.count))
        where tile.shows("sessions") {
            var details: [String] = []
            if tile.shows("project") { details.append(row.projectTitle) }
            if tile.shows("provider") { details.append(row.providerTitle) }
            if tile.shows("model"), let model = row.model { details.append(model) }
            if tile.shows("tool"), let tool = row.tool {
                details.append(tool + (row.detail.map { ": " + $0 } ?? ""))
            }
            if tile.shows("source") { details.append(row.sourceTitle) }
            if tile.shows("elapsed") {
                details.append("\(max(0, Int(Date().timeIntervalSince(row.startedAt))))s")
            }
            let controls: [SurfaceAction] =
                row.terminal.map { terminal in
                    [.init(action(.terminal(terminal.id)), "Open", "macwindow", field: "sessions")]
                } ?? []
            rows.append(
                .init(
                    HerdrWorker.bounded(row.id, 512), sourceID: row.provider,
                    title: HerdrWorker.bounded(row.title, 512),
                    detail: HerdrWorker.bounded(details.joined(separator: " · "), 1_024),
                    value: row.phase.title,
                    icon: row.isSubagent ? "arrow.turn.down.right" : "terminal",
                    field: "sessions", actions: controls))
        }
        var metrics: [SurfaceMetric] = [
            .init("running", "Working", "\(presentation.working)"),
            .init("waiting", "Needs you", "\(presentation.waiting)"),
            .init("total", "Active", "\(presentation.active)"),
            .init(
                "stuck", "Stuck",
                activity.settings.monitorTerminalAttention ? "\(presentation.stuck)" : "Off"),
            .init("quiet", "No signal", "\(presentation.quiet)"),
            .init("errors", "Errors", "\(presentation.errors)"),
            .init("subagents", "Subagents", "\(presentation.subagents)"),
        ]
        if tile.shows("approvals") {
            metrics.append(
                .init("permissions", "Permission requests", "\(presentation.approvals.count)"))
        }
        return SurfaceSnapshot(
            providerID: "herdr", metrics: metrics, rows: rows,
            actions: [.init("open", "Open Herdr", "macwindow")],
            sources: all.providerChoices(including: tile.sourceIDs ?? []),
            message: rows.isEmpty
                ? "No sessions match this widget. Configure provider hooks in Herdr's Agent connections."
                : nil,
            updatedAt: activity.refreshedAt)
    }
    private func action(_ target: Target) -> String {
        if let current = actions.first(where: { $0.value == target }) { return current.key }
        let id = UUID().uuidString
        actions[id] = target
        return id
    }
    private func perform(_ action: String) async throws {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        if action == "connections" {
            worker.activity.connectionsPresented = true; ExtensionPresentation.showWindow(); return
        }
        if action == "open" { ExtensionPresentation.showWindow(); return }
        guard let target = actions[action] else { throw ExtensionPeerError.invalidRequest }
        switch target {
        case .terminal(let id):
            guard worker.currentAgent(id) != nil else { throw ExtensionPeerError.invalidRequest }
            _ = try await worker.execute(
                "herdr.open", payload: JSONSerialization.data(withJSONObject: ["agentID": id]))
        case .approval(let token, let choice):
            let decision = AgentApprovalDecision(token: token, choice: choice)
            let data = try await worker.activity.execute(
                AgentActivityOperation.decide, payload: AgentPayload.encode(decision))
            guard try AgentPayload.decode(Bool.self, from: data) else {
                throw ExtensionPeerError.invalidRequest
            }
        }
    }
}
