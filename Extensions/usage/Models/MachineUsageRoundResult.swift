import Foundation

public struct MachineUsageRoundResult: Sendable {
    public var collected: [MachineUsageSummary]
    public var failures: [(machine: String, reason: String)]
    public var skippedBecauseBusy: Bool

    public init(
        collected: [MachineUsageSummary] = [],
        failures: [(machine: String, reason: String)] = [],
        skippedBecauseBusy: Bool = false
    ) {
        self.collected = collected
        self.failures = failures
        self.skippedBecauseBusy = skippedBecauseBusy
    }

    public var changedAnything: Bool { !collected.isEmpty }
}
