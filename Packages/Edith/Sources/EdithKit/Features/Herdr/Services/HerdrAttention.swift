import Foundation

public enum HerdrAttentionState: String, CaseIterable, Codable, Sendable {
    case working
    case waitingInput = "waiting_input"
    case permissionPrompt = "permission_prompt"
    case done
    case error
    case looping

    var meaning: String {
        switch self {
        case .working: "The agent is still making progress on its task."
        case .waitingInput: "The agent asked the user a question and waits for an answer."
        case .permissionPrompt: "The agent waits for the user to approve or deny an action."
        case .done: "The agent finished its task and stopped."
        case .error: "The agent stopped because of an error or failure."
        case .looping: "The agent repeats itself or makes no progress."
        }
    }
}

public enum HerdrAttentionNeed: String, CaseIterable, Codable, Sendable {
    case approval
    case answer
    case review
    case error
    case nothing

    var meaning: String {
        switch self {
        case .approval: "The user must approve an action."
        case .answer: "The user must answer a question."
        case .review: "The user should review finished work."
        case .error: "The user should look at an error."
        case .nothing: "The user does not need to do anything."
        }
    }
}

public enum HerdrAttentionEvent: String, Codable, Sendable {
    case blocked
    case finished
    case stalled
}

public struct HerdrAgentExplain: Equatable, Sendable {
    public var state: String?
    public var rule: String?
    public var visibleBlocker: Bool
    public var visibleIdle: Bool
    public var visibleWorking: Bool

    public init(
        state: String? = nil, rule: String? = nil, visibleBlocker: Bool = false,
        visibleIdle: Bool = false, visibleWorking: Bool = false
    ) {
        self.state = state
        self.rule = rule
        self.visibleBlocker = visibleBlocker
        self.visibleIdle = visibleIdle
        self.visibleWorking = visibleWorking
    }

    public static func parse(_ text: String) -> HerdrAgentExplain? {
        guard var object = HerdrListParser.firstJSON(in: text) as? [String: Any],
            object["error"] == nil
        else { return nil }
        if let result = object["result"] as? [String: Any] { object = result }
        if let explain = object["explain"] as? [String: Any] { object = explain }
        guard object["state"] != nil || object["visible_blocker"] != nil else { return nil }
        return HerdrAgentExplain(
            state: object["state"] as? String,
            rule: (object["matched_rule"] as? [String: Any])?["id"] as? String,
            visibleBlocker: object["visible_blocker"] as? Bool ?? false,
            visibleIdle: object["visible_idle"] as? Bool ?? false,
            visibleWorking: object["visible_working"] as? Bool ?? false)
    }
}

public struct HerdrPaneScreen: Equatable, Sendable {
    public var text: String
    public var explain: HerdrAgentExplain?

    public init(raw: String, explain: HerdrAgentExplain? = nil) {
        text = JevRedaction.tail(raw)
        self.explain = explain
    }

    public var fingerprint: UInt64 {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            .reduce(UInt64(14_695_981_039_346_656_037)) { hash, scalar in
                (hash ^ UInt64(scalar.value)) &* 1_099_511_628_211
            }
    }

    public var recentLines: [String] {
        Array(
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(12))
    }
}

public struct HerdrAttentionEvidence: Equatable, Sendable {
    public var screen: HerdrPaneScreen?
    public var changes: Int?

    public init(screen: HerdrPaneScreen? = nil, changes: Int? = nil) {
        self.screen = screen
        self.changes = changes
    }
}

public struct HerdrAttentionVerdict: Equatable, Sendable {
    public var state: HerdrAttentionState
    public var need: HerdrAttentionNeed
    public var interrupt: Bool
    public var reason: String
    public var readyForReview: Bool

    public init(
        state: HerdrAttentionState, need: HerdrAttentionNeed, interrupt: Bool, reason: String,
        readyForReview: Bool = false
    ) {
        self.state = state
        self.need = need
        self.interrupt = interrupt
        self.reason = reason
        self.readyForReview = readyForReview
    }
}

public enum HerdrAttentionClassifier {
    public static let purpose = "agent attention"
    public static let confidence = 0.6

    private static let promptMarkers = [
        "do you want to", "(y/n)", "[y/n]", "allow ", "approve", "yes, and don't ask again",
        "press enter to confirm", "waiting for approval", "would you like to run",
    ]

    private static let errorPattern = try? NSRegularExpression(
        pattern:
            #"(?i)(^[^a-z0-9]*(error|fatal)\b|panicked at|traceback \(most recent call last\)|\b(build|command|tests?|request|job|task|process) failed\b)"#
    )

    public static func verdict(
        event: HerdrAttentionEvent, evidence: HerdrAttentionEvidence, stalledMinutes: Int? = nil
    ) -> HerdrAttentionVerdict {
        let lines = evidence.screen?.recentLines ?? []
        let promptLines = event == .blocked ? lines : Array(lines.suffix(4))
        if let prompt = promptLines.last(where: isPrompt) {
            return HerdrAttentionVerdict(
                state: .permissionPrompt, need: .approval, interrupt: true, reason: clean(prompt))
        }
        let explain = evidence.screen?.explain
        if event == .blocked || explain?.visibleBlocker == true {
            let question = lines.last { $0.contains("?") }.map(clean)
            return HerdrAttentionVerdict(
                state: .waitingInput, need: .answer, interrupt: true,
                reason: question ?? "waiting for your answer")
        }
        if event == .finished || explain?.visibleIdle == true {
            if let failure = lines.last(where: isError) {
                return HerdrAttentionVerdict(
                    state: .error, need: .error, interrupt: true, reason: clean(failure))
            }
            let changes = evidence.changes ?? 0
            return HerdrAttentionVerdict(
                state: .done, need: changes > 0 ? .review : .nothing, interrupt: true,
                reason: changes > 0 ? "ready for review, \(filesChanged(changes))" : "finished",
                readyForReview: changes > 0)
        }
        guard let minutes = stalledMinutes else {
            return HerdrAttentionVerdict(
                state: .working, need: .nothing, interrupt: false, reason: "still working")
        }
        return HerdrAttentionVerdict(
            state: .looping, need: .nothing, interrupt: true,
            reason: "no screen change in \(minutes) minutes")
    }

    public static func refine(
        _ base: HerdrAttentionVerdict, agent: HerdrAgent, event: HerdrAttentionEvent,
        evidence: HerdrAttentionEvidence, decider: JevDeciding
    ) async -> HerdrAttentionVerdict {
        let request = request(agent: agent, event: event, evidence: evidence)
        guard let decision = try? await decider.decide(request, purpose: purpose) else {
            return base
        }
        var refined = base
        let pinned = [.approval, .answer, .error].contains(base.need)
        if !pinned,
            let state = confident(decision.answer("state")).flatMap(HerdrAttentionState.init)
        {
            refined.state = state
        }
        if !pinned,
            let need = confident(decision.answer("need")).flatMap(HerdrAttentionNeed.init)
        {
            refined.need = need
        }
        if let interrupt = decision.noul("interrupt") {
            refined.interrupt = pinned || interrupt >= 0.5
        }
        if refined.state == .done, let ready = decision.noul("ready_for_review") {
            refined.readyForReview = base.readyForReview && ready >= 0.5
        }
        if refined.state != .done { refined.readyForReview = false }
        if refined.state != base.state || refined.readyForReview != base.readyForReview {
            refined.reason = defaultReason(refined, base: base)
        }
        return refined
    }

    public static func request(
        agent: HerdrAgent, event: HerdrAttentionEvent, evidence: HerdrAttentionEvidence
    ) -> JevRequest {
        var fields = [
            "agent": agent.kind, "status": agent.status.rawValue, "event": event.rawValue,
            "screen": evidence.screen?.text ?? "",
        ]
        if let explain = evidence.screen?.explain {
            fields["detector"] =
                [
                    explain.state, explain.rule, explain.visibleBlocker ? "blocker visible" : nil,
                    explain.visibleIdle ? "idle visible" : nil,
                ]
                .compactMap { $0 }.joined(separator: ", ")
        }
        var questions: [String: JevQuestion] = [
            "state": .choice(
                "Which state is the coding agent in, judging by `screen`, `status` and `detector`?",
                options: HerdrAttentionState.allCases.map { JevOption($0.rawValue, $0.meaning) }),
            "interrupt": .noul(
                "The user should look at this agent now, judging by `screen` and `event`."),
            "need": .choice(
                "What does the agent need from the user, judging by `screen`?",
                options: HerdrAttentionNeed.allCases.map { JevOption($0.rawValue, $0.meaning) }),
        ]
        if let changes = evidence.changes, changes > 0 {
            fields["changes"] = filesChanged(changes)
            questions["ready_for_review"] = .noul(
                "The agent finished its task and the work in `changes` is ready for the user to review, judging by `screen`."
            )
        }
        return JevRequest(state: .fields(fields), questions: questions)
    }

    public static func filesChanged(_ count: Int) -> String {
        count == 1 ? "1 file changed" : "\(count) files changed"
    }

    static func isPrompt(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return promptMarkers.contains { lowered.contains($0) }
    }

    static func isError(_ line: String) -> Bool {
        errorPattern?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    static func clean(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(
            in: CharacterSet.alphanumerics.union(.punctuationCharacters).inverted)
        return trimmed.count > 120 ? String(trimmed.prefix(119)) + "…" : trimmed
    }

    private static func confident(_ answer: JevAnswer?) -> String? {
        guard let answer, let choice = answer.choice,
            (answer.chosenProbability ?? 0) >= confidence
        else { return nil }
        return choice
    }

    private static func defaultReason(
        _ verdict: HerdrAttentionVerdict, base: HerdrAttentionVerdict
    ) -> String {
        switch verdict.state {
        case .waitingInput: "waiting for your answer"
        case .error: "stopped with an error"
        case .looping: "it keeps repeating itself"
        case .done: verdict.readyForReview ? base.reason : "finished"
        case .working, .permissionPrompt: base.reason
        }
    }
}
