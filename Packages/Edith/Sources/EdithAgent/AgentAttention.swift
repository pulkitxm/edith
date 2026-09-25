import AppKit
import EdithKit
import Foundation

struct AttentionCheck: Equatable, Sendable {
    var agent: HerdrAgent
    var hostID: String
    var event: HerdrAttentionEvent
    var fingerprint: UInt64?
}

struct AttentionOutcome: Equatable, Sendable {
    var agentID: String
    var hostID: String
    var fingerprint: UInt64?
    var notification: AgentNotification?
}

public struct AgentAttention: Sendable {
    public typealias Inspect =
        @Sendable ([HerdrAttentionProbe]) async -> [String: HerdrAttentionEvidence]

    public static let kinds = ["blocked", "finished", "error", "stuck"]

    var inspect: Inspect
    var decider: @Sendable () async -> JevDeciding?
    var appIsRunning: @Sendable () -> Bool
    var openAgent: @Sendable (HerdrOpenRequest) -> Void

    public init(
        inspect: @escaping Inspect,
        decider: @escaping @Sendable () async -> JevDeciding?,
        appIsRunning: @escaping @Sendable () -> Bool,
        openAgent: @escaping @Sendable (HerdrOpenRequest) -> Void
    ) {
        self.inspect = inspect
        self.decider = decider
        self.appIsRunning = appIsRunning
        self.openAgent = openAgent
    }

    public static let live = AgentAttention(
        inspect: { await HerdrPaneReader.inspect($0) },
        decider: { await AgentJev.engine.isConfigured ? AgentJev.engine : nil },
        appIsRunning: {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: MainApp.bundleIdentifier
            ).isEmpty
        },
        openAgent: { HerdrOpenRequests.submit($0) })

    public static func identifier(kind: String, agentID: String) -> String {
        "session.\(kind).\(agentID)"
    }

    func resolve(_ checks: [AttentionCheck], settings: AgentAttentionSettings) async
        -> [AttentionOutcome]
    {
        let decider = await decider()
        var outcomes: [AttentionOutcome] = []
        for hostChecks in Dictionary(grouping: checks, by: \.hostID).values {
            let probes = hostChecks.map { check in
                HerdrAttentionProbe(
                    agent: check.agent,
                    countChanges: check.event == .finished
                        && (settings.finished || settings.openDiff))
            }
            let evidence = await inspect(probes)
            for check in hostChecks {
                let item = evidence[check.agent.id] ?? HerdrAttentionEvidence()
                let fingerprint = item.screen?.fingerprint
                let stalled =
                    check.fingerprint != nil && fingerprint == check.fingerprint
                    ? settings.stuckMinutes : nil
                var verdict = HerdrAttentionClassifier.verdict(
                    event: check.event, evidence: item, stalledMinutes: stalled)
                if let decider, item.screen != nil {
                    verdict = await HerdrAttentionClassifier.refine(
                        verdict, agent: check.agent, event: check.event, evidence: item,
                        decider: decider)
                }
                outcomes.append(
                    AttentionOutcome(
                        agentID: check.agent.id, hostID: check.hostID, fingerprint: fingerprint,
                        notification: notification(
                            for: check, verdict: verdict, settings: settings)))
            }
        }
        return outcomes
    }

    func notification(
        for check: AttentionCheck, verdict: HerdrAttentionVerdict,
        settings: AgentAttentionSettings
    ) -> AgentNotification? {
        guard verdict.interrupt else { return nil }
        let agent = check.agent
        let (kind, title, enabled): (String, String, Bool) =
            switch verdict.state {
            case .permissionPrompt: ("blocked", "needs approval", settings.blocked)
            case .waitingInput: ("blocked", "needs an answer", settings.blocked)
            case .done: ("finished", "finished", settings.finished)
            case .error: ("error", "hit an error", settings.errors)
            case .looping: ("stuck", "looks stuck", settings.stuck)
            case .working: ("", "", false)
            }
        let ready = verdict.state == .done && verdict.readyForReview
        let request = HerdrOpenRequest(
            agentID: agent.id, hostID: check.hostID, view: ready ? .diff : .agent)
        var reason = verdict.reason
        if ready, settings.openDiff, appIsRunning() {
            openAgent(request)
        } else if ready {
            reason += ", click to review"
        }
        guard enabled else { return nil }
        let task = agent.title.isEmpty ? agent.session : agent.title
        let place = agent.workspace.isEmpty ? "" : " in \(agent.workspace)"
        return AgentNotification(
            identifier: Self.identifier(kind: kind, agentID: agent.id),
            title: "\(agent.kind) \(title)",
            body: "\(task)\(place) on \(agent.machineName): \(reason)", action: request)
    }
}
