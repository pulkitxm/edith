import Foundation

public struct AgentSearchCandidate: Sendable, Equatable {
    public var id: String
    public var meaning: String

    public init(id: String, meaning: String) {
        self.id = id
        self.meaning = meaning
    }
}

public enum AgentSearchJev {
    public static let purpose = "sessions.search"
    public static let question = "session"
    public static let noneID = "none"
    public static let threshold = 0.12
    public static let maximumCandidates = 40
    public static let maximumPicks = 3
    public static let meaningLimit = 280

    public static func meaning(
        kind: String, project: String, branch: String?, machine: String, title: String,
        summary: String
    ) -> String {
        let place = [project, branch].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " on branch ")
        let text = "\(kind) session in \(place) (\(machine)): \(title). \(summary)"
        return JevText.compact(text, limit: meaningLimit)
    }

    public static func request(query: String, candidates: [AgentSearchCandidate]) -> JevRequest? {
        let trimmed = JevText.compact(query, limit: 200)
        let chosen = Array(candidates.prefix(maximumCandidates))
        guard !trimmed.isEmpty, chosen.count >= 2 else { return nil }
        let options =
            chosen.enumerated().map { JevOption("s\($0.offset)", $0.element.meaning) }
            + [JevOption(noneID, "None of these sessions is what the request describes")]
        return JevRequest(
            state: .fields(["request": trimmed]),
            questions: [
                question: .choice(
                    "Which coding agent session is the work described in `request`? Pick none when no session fits.",
                    options: options)
            ])
    }

    public static func picks(_ decision: JevDecision, candidates: [AgentSearchCandidate])
        -> [String]
    {
        guard let answer = decision.answer(question) else { return [] }
        let chosen = Array(candidates.prefix(maximumCandidates))
        var picks: [String] = []
        for (id, probability) in answer.ranked() {
            if id == noneID || probability < threshold || picks.count == maximumPicks { break }
            guard id.hasPrefix("s"), let index = Int(id.dropFirst()), chosen.indices.contains(index)
            else { continue }
            picks.append(chosen[index].id)
        }
        return picks
    }

    public static func rank(
        _ query: String, candidates: [AgentSearchCandidate], using decider: JevDeciding
    ) async throws -> [String]? {
        guard let request = request(query: query, candidates: candidates) else { return nil }
        let decision = try await decider.decide(request, purpose: purpose)
        return picks(decision, candidates: candidates)
    }
}
