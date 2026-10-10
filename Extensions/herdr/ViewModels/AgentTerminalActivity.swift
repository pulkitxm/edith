import EdithExtensionSupport
import Foundation

@MainActor final class AgentTerminalActivity {
    typealias Inspect = @Sendable ([HerdrAttentionProbe]) async -> [String: HerdrAttentionEvidence]
    private struct Progress {
        var fingerprint: UInt64
        var changedAt: Date
    }
    private let inspect: Inspect
    private var progress: [String: Progress] = [:]
    private(set) var attention: [String: AgentTerminalAttentionObservation] = [:]
    private(set) var observedAt: [String: Date] = [:]
    private var stopped = false

    init(inspect: @escaping Inspect = { await HerdrPaneReader.inspect($0) }) {
        self.inspect = inspect
    }

    func snapshot(hosts: [HerdrHostSnapshot], enabled: Bool) -> SessionsSnapshot? {
        guard !stopped, enabled else { return nil }
        let ids = Set(hosts.flatMap(\.agents).filter { !$0.isTerminal }.map(\.id))
        attention = attention.filter { ids.contains($0.key) }
        progress = progress.filter { ids.contains($0.key) }
        observedAt = observedAt.filter { ids.contains($0.key) }
        for id in ids where observedAt[id] == nil { observedAt[id] = Date() }
        return SessionsSnapshot(
            discoveredAt: Date(), hosts: hosts, working: 0, total: ids.count,
            attention: attention)
    }

    func refresh(hosts: [HerdrHostSnapshot], enabled: Bool, stuckMinutes: Int, now: Date = Date())
        async
    {
        guard !stopped, enabled else { attention = [:]; progress = [:]; return }
        let groups = Dictionary(
            grouping: hosts.filter { $0.reachable && $0.error == nil }
                .flatMap(\.agents).filter { !$0.isTerminal }.prefix(64), by: \.machineID)
        for group in groups.values {
            try? Task.checkCancellation()
            guard !Task.isCancelled, !stopped else { return }
            let evidence = await inspect(
                group.map { HerdrAttentionProbe(agent: $0, countChanges: false) })
            guard !Task.isCancelled, !stopped else { return }
            for agent in group {
                guard let item = evidence[agent.id], let screen = item.screen else { continue }
                let previous = progress[agent.id]
                let changedAt =
                    previous?.fingerprint == screen.fingerprint ? previous!.changedAt : now
                progress[agent.id] = Progress(fingerprint: screen.fingerprint, changedAt: changedAt)
                let stalled =
                    now.timeIntervalSince(changedAt) >= Double(min(120, max(2, stuckMinutes)) * 60)
                let event: HerdrAttentionEvent =
                    agent.status == .done
                    ? .finished : (agent.status == .blocked ? .blocked : .stalled)
                let verdict = HerdrAttentionClassifier.verdict(
                    event: event, evidence: item,
                    stalledMinutes: stalled ? stuckMinutes : nil)
                attention[agent.id] = .init(state: verdict.state, checkedAt: now)
            }
        }
    }

    func shutdown() { stopped = true; progress = [:]; attention = [:]; observedAt = [:] }
}
