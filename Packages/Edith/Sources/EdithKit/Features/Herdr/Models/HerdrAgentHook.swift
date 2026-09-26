import Foundation

public enum HerdrHookOperation {
    public static let list = "sessions.hooks.list"
    public static let arm = "sessions.hooks.arm"
    public static let remove = "sessions.hooks.remove"
    public static let internalOperations = [list, arm, remove]
}

public enum HerdrHookPhase: String, Codable, Sendable {
    case armed
    case sending
    case sent
    case skipped
    case cancelled

    public var settled: Bool { self == .sent || self == .skipped || self == .cancelled }
}

public struct HerdrAgentHook: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var agentID: String
    public var machineID: String
    public var machineIsLocal: Bool
    public var session: String
    public var pane: String
    public var kind: String
    public var title: String
    public var message: String
    public var schedule: HerdrHookSchedule
    public var identity: HerdrAgentIdentity
    public var createdAt: Date
    public var baselineSequence: Int?
    public var ran: Bool
    public var phase: HerdrHookPhase
    public var detail: String?
    public var settledAt: Date?

    public init(
        id: UUID = UUID(), agent: HerdrAgent, message: String,
        observation: HerdrAgentObservation, schedule: HerdrHookSchedule,
        createdAt: Date = Date()
    ) {
        self.id = id
        agentID = agent.id
        machineID = agent.machineID
        machineIsLocal = agent.machineIsLocal
        session = agent.session
        pane = agent.pane
        kind = agent.kind
        title = agent.title
        self.message = message
        self.schedule = schedule
        identity = observation.identity
        self.createdAt = createdAt
        baselineSequence = observation.sequence
        ran = observation.status == .working || observation.status == .blocked
        phase = .armed
    }

    public var isArmed: Bool { phase == .armed }

    public mutating func settle(_ phase: HerdrHookPhase, _ detail: String, at date: Date) {
        self.phase = phase
        self.detail = detail
        settledAt = date
    }
}

public struct HerdrHooksSnapshot: Codable, Equatable, Sendable {
    public var hooks: [HerdrAgentHook]

    public init(hooks: [HerdrAgentHook] = []) {
        self.hooks = hooks
    }

    public func armed(for agentID: String) -> HerdrAgentHook? {
        hooks.first { $0.agentID == agentID && !$0.phase.settled }
    }

    public func latestSettled(for agentID: String) -> HerdrAgentHook? {
        hooks.filter { $0.agentID == agentID && $0.phase.settled }
            .max { ($0.settledAt ?? $0.createdAt) < ($1.settledAt ?? $1.createdAt) }
    }
}

public enum HerdrHookSchedule: Codable, Equatable, Sendable {
    case whenFinished
    case at(Date)

    public func sendsPhrase(now: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .whenFinished: "Sends when it finishes"
        case .at(let when): "Sends \(Self.moment(when, now: now, calendar: calendar))"
        }
    }

    public static func moment(_ when: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = Self.clockText(when, calendar: calendar)
        if calendar.isDate(when, inSameDayAs: now) { return "today at \(time)" }
        if let tomorrow = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
            calendar.isDate(when, inSameDayAs: tomorrow)
        {
            return "tomorrow at \(time)"
        }
        let weekday = calendar.shortWeekdaySymbols[calendar.component(.weekday, from: when) - 1]
        let month = calendar.shortMonthSymbols[calendar.component(.month, from: when) - 1]
        let day = calendar.component(.day, from: when)
        return "\(weekday), \(month) \(day) at \(time)"
    }

    public static func clockText(_ when: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: when)
        let minute = calendar.component(.minute, from: when)
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", hour12, minute, hour >= 12 ? "PM" : "AM")
    }

    public static func delayPhrase(hours: Int, minutes: Int) -> String {
        switch (hours, minutes) {
        case (0, 1): "in 1 minute"
        case (0, _): "in \(minutes) minutes"
        case (1, 0): "in 1 hour"
        case (_, 0): "in \(hours) hours"
        case (1, _): "in 1 hour \(minutes) \(minutes == 1 ? "minute" : "minutes")"
        default: "in \(hours) hours \(minutes) minutes"
        }
    }
}

public enum HerdrScheduleParser {
    public static func delay(_ text: String, from now: Date) -> Date? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hours = 0
        var minutes = 0
        var sawHours = false
        var sawMinutes = false
        var digits = ""
        func take(_ unit: Character) -> Bool {
            guard let value = Int(digits) else { return false }
            digits = ""
            if unit == "h" {
                guard !sawHours, !sawMinutes else { return false }
                sawHours = true
                hours = value
            } else {
                guard !sawMinutes else { return false }
                sawMinutes = true
                minutes = value
            }
            return true
        }
        for character in raw {
            if character.isNumber {
                digits.append(character)
            } else if character == "h" || character == "m" {
                guard take(character) else { return nil }
            } else {
                return nil
            }
        }
        guard digits.isEmpty, sawHours || sawMinutes else { return nil }
        let total = hours * 60 + minutes
        guard total >= 1, total <= 7 * 24 * 60 else { return nil }
        return now.addingTimeInterval(TimeInterval(total * 60))
    }

    public static func clock(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        var words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        var day = calendar.startOfDay(for: now)
        if words[0] == "tomorrow" {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
            words.removeFirst()
        }
        guard words.count == 1, let time = clockTime(words[0]) else { return nil }
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = time.hour
        parts.minute = time.minute
        guard let when = calendar.date(from: parts), when > now else { return nil }
        return when
    }

    private static func clockTime(_ token: String) -> (hour: Int, minute: Int)? {
        let suffix: String?
        let body: Substring
        if token.hasSuffix("am") {
            suffix = "am"
            body = token.dropLast(2)
        } else if token.hasSuffix("pm") {
            suffix = "pm"
            body = token.dropLast(2)
        } else {
            suffix = nil
            body = Substring(token)
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let hour = Int(parts[0]) else { return nil }
        let minute: Int
        if parts.count == 2 {
            guard parts[1].count == 2, let value = Int(parts[1]) else { return nil }
            minute = value
        } else {
            minute = 0
        }
        guard (0..<60).contains(minute) else { return nil }
        switch suffix {
        case nil:
            guard parts.count == 2, (0...23).contains(hour) else { return nil }
            return (hour, minute)
        case "am":
            guard (1...12).contains(hour) else { return nil }
            return (hour == 12 ? 0 : hour, minute)
        case "pm":
            guard (1...12).contains(hour) else { return nil }
            return (hour == 12 ? 12 : hour + 12, minute)
        default:
            return nil
        }
    }
}

public struct HerdrHookArmRequest: Codable, Equatable, Sendable {
    public var agent: HerdrAgent
    public var message: String
    public var schedule: HerdrHookSchedule

    public init(
        agent: HerdrAgent, message: String, schedule: HerdrHookSchedule = .whenFinished
    ) {
        self.agent = agent
        self.message = message
        self.schedule = schedule
    }
}

public enum HerdrHookDecision: Equatable, Sendable {
    case keep(HerdrAgentHook)
    case fire(HerdrAgentHook)
    case cancel(String)
}

public enum HerdrHookEvaluator {
    public static let goneReason = "The agent closed before it finished."
    public static let missedReason = "The agent closed before the message was sent."
    public static let replacedReason = "A different agent took over the pane."

    public static func evaluate(
        _ hook: HerdrAgentHook, _ probe: HerdrAgentProbe, now: Date = Date()
    ) -> HerdrHookDecision {
        switch probe {
        case .unreachable:
            return .keep(hook)
        case .gone:
            return .cancel(hook.schedule == .whenFinished ? goneReason : missedReason)
        case .agent(let observation):
            guard
                observation.identity == hook.identity,
                HerdrKind.displayName(for: observation.kind)
                    == HerdrKind.displayName(
                        for: hook.kind)
            else { return .cancel(replacedReason) }
            if case .at(let when) = hook.schedule {
                return now >= when ? .fire(hook) : .keep(hook)
            }
            var next = hook
            let moved =
                observation.sequence != nil && hook.baselineSequence != nil
                && observation.sequence != hook.baselineSequence
            switch observation.status {
            case .working, .blocked:
                next.ran = true
            case .done where next.ran || moved:
                return .fire(next)
            case .idle where next.ran:
                return .fire(next)
            case .done, .idle, .unknown:
                break
            }
            if observation.status != .unknown {
                next.baselineSequence = observation.sequence ?? next.baselineSequence
            }
            return .keep(next)
        }
    }
}
