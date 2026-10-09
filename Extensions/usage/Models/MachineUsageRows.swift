import Foundation

enum MachineUsageRows {
    static func summariesByMachineID(
        _ summaries: [MachineUsageSummary]
    ) -> [UUID: MachineUsageSummary] {
        summaries.reduce(into: [:]) { result, candidate in
            guard let existing = result[candidate.machineID] else {
                result[candidate.machineID] = candidate
                return
            }
            if prefers(candidate, over: existing) {
                result[candidate.machineID] = candidate
            }
        }
    }

    private static func prefers(
        _ candidate: MachineUsageSummary, over existing: MachineUsageSummary
    ) -> Bool {
        if candidate.collectedAt != existing.collectedAt {
            return candidate.collectedAt > existing.collectedAt
        }
        let candidateText = [
            candidate.name, candidate.slug, candidate.host,
            candidate.sources.joined(separator: "\u{0}"),
        ]
        let existingText = [
            existing.name, existing.slug, existing.host,
            existing.sources.joined(separator: "\u{0}"),
        ]
        if candidateText != existingText {
            return candidateText.lexicographicallyPrecedes(existingText)
        }
        if candidate.days != existing.days { return candidate.days > existing.days }
        if candidate.cost != existing.cost { return candidate.cost > existing.cost }
        return candidate.tokens > existing.tokens
    }

    static func spoken(_ event: UsageRefreshEvent) -> String? {
        switch event {
        case let .phase(name, detail, _): return "\(name): \(detail)"
        case let .note(text): return text
        default: return nil
        }
    }

    static func outcome(_ round: MachineUsageRoundResult) -> String {
        if round.skippedBecauseBusy { return "another collection is already running" }
        if let failure = round.failures.first, round.collected.isEmpty {
            return "\(failure.machine): \(failure.reason)"
        }
        let collected = round.collected.count
        let counted = collected == 1 ? "1 machine" : "\(collected) machines"
        guard round.failures.isEmpty else {
            return "\(counted) collected, \(round.failures.count) failed"
        }
        return collected == 0 ? "nothing to collect" : "\(counted) collected"
    }
}
