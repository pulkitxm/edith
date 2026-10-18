import Foundation

public struct JevRouteCandidate: Sendable, Equatable, Codable {
    public var id: String
    public var summary: String

    public init(id: String, summary: String) {
        self.id = id
        self.summary = summary
    }
}

public struct JevRouteGroup: Sendable, Equatable {
    public var id: String
    public var summary: String
    public var members: [JevRouteCandidate]

    public init(id: String, summary: String, members: [JevRouteCandidate]) {
        self.id = id
        self.summary = summary
        self.members = members
    }
}

public struct JevRoutePick: Sendable, Equatable, Codable {
    public var id: String
    public var probability: Double

    public init(id: String, probability: Double) {
        self.id = id
        self.probability = probability
    }
}

public struct JevRouteResult: Sendable, Equatable {
    public var picks: [JevRoutePick]
    public var milliseconds: Int

    public init(picks: [JevRoutePick], milliseconds: Int) {
        self.picks = picks
        self.milliseconds = milliseconds
    }
}

public struct JevRouter: Sendable {
    public var groups: [JevRouteGroup]
    public var model: String
    public var groupsToExpand: Int

    public init(
        groups: [JevRouteGroup], model: String = JevRequest.defaultModel, groupsToExpand: Int = 2
    ) {
        self.groups = groups.filter { !$0.members.isEmpty }
        self.model = model
        self.groupsToExpand = max(1, groupsToExpand)
    }

    public func groupRequest(for intent: String) -> JevRequest {
        JevRequest(
            model: model, state: .fields(["request": intent]),
            questions: [
                "area": .choice(
                    "Which area of the Edith app should handle `request`?",
                    options: groups.map { group in
                        JevOption(group.id, Self.describe(group))
                    })
            ])
    }

    public func memberRequest(for intent: String, group: JevRouteGroup) -> JevRequest {
        JevRequest(
            model: model, state: .fields(["request": intent, "area": group.id]),
            questions: [
                "command": .choice(
                    "Which `\(group.id)` command does `request` ask for?",
                    options: group.members.map { JevOption($0.id, $0.summary) })
            ])
    }

    public func route(_ intent: String, using decider: JevDeciding, purpose: String) async throws
        -> JevRouteResult
    {
        let first = try await decider.decide(groupRequest(for: intent), purpose: purpose)
        let ranked = first.answer("area")?.ranked() ?? []
        let expanded = ranked.prefix(groupsToExpand).compactMap { pick in
            groups.first { $0.id == pick.id }.map { ($0, pick.probability) }
        }
        var elapsed = first.milliseconds
        let expansions = try await withThrowingTaskGroup(
            of: (JevDecision?, JevRouteGroup, Double).self
        ) {
            tasks in
            for (group, weight) in expanded {
                tasks.addTask {
                    guard group.members.count > 1 else { return (nil, group, weight) }
                    return (
                        try await decider.decide(
                            memberRequest(for: intent, group: group), purpose: purpose), group,
                        weight
                    )
                }
            }
            var collected: [(JevDecision?, JevRouteGroup, Double)] = []
            for try await item in tasks { collected.append(item) }
            return collected
        }
        var picks: [JevRoutePick] = []
        var slowest = 0
        for (decision, group, weight) in expansions {
            guard let decision else {
                picks.append(JevRoutePick(id: group.members[0].id, probability: weight))
                continue
            }
            slowest = max(slowest, decision.milliseconds)
            for member in decision.answer("command")?.ranked() ?? [] {
                picks.append(JevRoutePick(id: member.id, probability: weight * member.probability))
            }
        }
        elapsed += slowest
        picks.sort {
            $0.probability == $1.probability ? $0.id < $1.id : $0.probability > $1.probability
        }
        return JevRouteResult(picks: Array(picks.prefix(5)), milliseconds: elapsed)
    }

    static func describe(_ group: JevRouteGroup) -> String {
        let verbs = group.members.prefix(12).map {
            $0.id.split(separator: " ").dropFirst().joined(separator: " ")
        }
        let summary = group.summary.isEmpty ? group.id : group.summary
        guard verbs.contains(where: { !$0.isEmpty }) else { return summary }
        return summary + " Commands: " + verbs.filter { !$0.isEmpty }.joined(separator: ", ") + "."
    }
}
