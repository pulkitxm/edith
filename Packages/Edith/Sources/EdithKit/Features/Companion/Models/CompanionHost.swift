import Foundation

public struct CompanionHost: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let target: String
    public let isLocal: Bool
    public let reachable: Bool
    public let facts: CompanionHostFacts?
    public let hostsTheStack: Bool

    public init(
        id: UUID, name: String, target: String, isLocal: Bool, reachable: Bool,
        facts: CompanionHostFacts?, hostsTheStack: Bool = false
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.isLocal = isLocal
        self.reachable = reachable
        self.facts = facts
        self.hostsTheStack = hostsTheStack
    }

    public var blockers: [CompanionBlocker] {
        guard reachable else { return [.unreachable("not reachable")] }
        guard let facts else { return [.unreachable("not probed yet")] }
        guard hostsTheStack else { return facts.blockers }
        return facts.blockers.filter { blocker in
            if case .portsInUse = blocker { return false }
            return true
        }
    }

    public var canHostTheStack: Bool { blockers.isEmpty }

    public var tier: CompanionTier? {
        guard let facts else { return nil }
        return CompanionTier.derive(from: facts)
    }

    public var summary: String {
        guard reachable else { return "not reachable" }
        guard let facts else { return "not probed yet" }
        return facts.plainEnglish
    }
}

public enum CompanionHostList {
    public static func ordered(
        local: CompanionHost, machines: [CompanionHost], deployment: CompanionDeployment?
    ) -> [CompanionHost] {
        let all = [local] + machines
        guard let deployment else { return all }
        return all.map { host in
            let matches =
                deployment.isLocal ? host.isLocal : host.id == deployment.machineID
            guard matches else { return host }
            return CompanionHost(
                id: host.id, name: host.name, target: host.target, isLocal: host.isLocal,
                reachable: host.reachable, facts: host.facts, hostsTheStack: true)
        }
    }

    public static func recommended(_ hosts: [CompanionHost]) -> CompanionHost? {
        hosts.first { $0.hostsTheStack && $0.canHostTheStack }
            ?? hosts.first { $0.canHostTheStack }
    }

    public static func emptyStateMessage(_ hosts: [CompanionHost]) -> String {
        let usable = hosts.filter(\.canHostTheStack)
        if !usable.isEmpty {
            return "The companion isn't running anywhere yet."
        }
        let reachable = hosts.filter(\.reachable)
        if reachable.isEmpty {
            return "No machine is reachable right now. Connect one, or add one in Machines."
        }
        return "None of your machines can run it yet. Each one below says what it needs."
    }
}
