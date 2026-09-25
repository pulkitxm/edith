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
        return await withTaskGroup(of: [AttentionOutcome].self) { group in
            for hostChecks in Dictionary(grouping: checks, by: \.hostID).values {
                group.addTask {
                    await resolve(hostChecks, settings: settings, decider: decider)
                }
            }
            var outcomes: [AttentionOutcome] = []
            for await hostOutcomes in group { outcomes += hostOutcomes }
            return outcomes
        }
    }

    private func resolve(
        _ hostChecks: [AttentionCheck], settings: AgentAttentionSettings,
        decider: JevDeciding?
    ) async -> [AttentionOutcome] {
        let probes = hostChecks.map { check in
            HerdrAttentionProbe(
                agent: check.agent,
                countChanges: check.event == .finished && (settings.finished || settings.openDiff),
                readsExplain: check.event != .blocked)
        }
        let evidence = await inspect(probes)
        let verdicts = await withTaskGroup(of: (Int, HerdrAttentionVerdict).self) { group in
            for (index, check) in hostChecks.enumerated() {
                let item = evidence[check.agent.id] ?? HerdrAttentionEvidence()
                let stalled =
                    check.fingerprint != nil && item.screen?.fingerprint == check.fingerprint
                    ? settings.stuckMinutes : nil
                let verdict = HerdrAttentionClassifier.verdict(
                    event: check.event, evidence: item, stalledMinutes: stalled)
                guard let decider, item.screen != nil else {
                    group.addTask { (index, verdict) }
                    continue
                }
                group.addTask {
                    let refined = await HerdrAttentionClassifier.refine(
                        verdict, agent: check.agent, event: check.event, evidence: item,
                        decider: decider)
                    return (index, refined)
                }
            }
            var verdicts: [Int: HerdrAttentionVerdict] = [:]
            for await (index, verdict) in group { verdicts[index] = verdict }
            return verdicts
        }
        return hostChecks.enumerated().map { index, check in
            AttentionOutcome(
                agentID: check.agent.id, hostID: check.hostID,
                fingerprint: evidence[check.agent.id]?.screen?.fingerprint,
                notification: verdicts[index].flatMap {
                    notification(for: check, verdict: $0, settings: settings)
                })
        }
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
