import Foundation

public struct MachineUsageBindings: Sendable {
    public let summaries: [UUID: MachineUsageSummary]

    public init(
        machines: [Machine], summaries stored: [MachineUsageSummary]
    ) {
        let registered = Set(machines.map(\.id))
        var bound: [UUID: MachineUsageSummary] = [:]
        for machine in machines {
            let direct = stored.filter {
                $0.machineID == machine.id || $0.connectionID == machine.id
            }
            if direct.count == 1 {
                let summary = direct[0]
                let owners = registered.intersection([summary.machineID, summary.connectionID])
                guard owners == [machine.id] else { continue }
                bound[machine.id] = summary
                continue
            }
            guard direct.isEmpty, !machine.name.trimmingCharacters(in: .whitespaces).isEmpty,
                machines.filter({ $0.name.lowercased() == machine.name.lowercased() }).count == 1
            else { continue }
            let orphaned = stored.filter {
                !registered.contains($0.machineID) && !registered.contains($0.connectionID)
                    && $0.name.lowercased() == machine.name.lowercased()
            }
            if orphaned.count == 1 { bound[machine.id] = orphaned[0] }
        }
        summaries = bound
    }

    public init(
        machines: [Machine], directory: URL = UsageCollector.machinesDirectory
    ) {
        self.init(machines: machines, summaries: MachineUsageStore.summaries(in: directory))
    }

    public func identity(for machineID: UUID) -> UUID {
        summaries[machineID]?.machineID ?? machineID
    }

    public func included(_ machines: [Machine], selected: Set<UUID>) -> [Machine] {
        machines.filter {
            selected.contains($0.id) || selected.contains(identity(for: $0.id))
        }
    }

    public func validateHost(_ host: String, for machine: Machine) throws {
        guard let summary = summaries[machine.id], summary.connectionID != machine.id else {
            return
        }
        guard !host.isEmpty, !summary.host.isEmpty,
            host.caseInsensitiveCompare(summary.host) == .orderedSame
        else {
            throw MachineUsageError.historyHostMismatch(machine.name)
        }
    }
}
