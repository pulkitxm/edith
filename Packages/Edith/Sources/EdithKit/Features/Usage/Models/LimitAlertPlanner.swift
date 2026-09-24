import Foundation

public struct LimitBurn: Equatable, Sendable {
    public let perHour: Double
    public let lookback: TimeInterval

    public var phrase: String {
        if lookback >= 20 * 3600 { return "your pace over the last day" }
        if lookback >= 3500 && lookback <= 3700 { return "your last hour's pace" }
        if lookback >= 1700 && lookback <= 1900 { return "your last 30 minutes' pace" }
        return "your pace so far this window"
    }
}

public struct LimitOutlook: Equatable, Sendable {
    public let perDay: Double
    public let finishPercent: Double
    public let runOutAt: Date?
}

public struct LimitAlertAssessment: Equatable, Sendable {
    public let target: LimitAlertTarget
    public let window: LimitWindow
    public let now: Date
    public let burn: LimitBurn?
    public let active: Bool
    public let recentlyActive: Bool
    public let projectedCapAt: Date?

    public var timeLeft: TimeInterval? { window.resetsAt.map { $0.timeIntervalSince(now) } }
    public var windowStart: Date? {
        window.resetsAt.map { $0.addingTimeInterval(-target.duration) }
    }

    public var outlook: LimitOutlook? {
        guard target.isWeekly, let start = windowStart, let left = timeLeft,
            window.percent >= 5, window.percent < 100
        else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 86_400, left >= 86_400 else { return nil }
        let perDay = window.percent / (elapsed / 86_400)
        let finish = window.percent + perDay * left / 86_400
        let runOut =
            finish >= 100
            ? now.addingTimeInterval((100 - window.percent) / perDay * 86_400) : nil
        return LimitOutlook(perDay: perDay, finishPercent: finish, runOutAt: runOut)
    }
}

public struct LimitAlertVerdict: Equatable, Sendable {
    public let assessment: LimitAlertAssessment
    public let alert: LimitAlert?
    public let reason: String
}

public struct LimitAlertPlan: Equatable, Sendable {
    public var ledger: LimitAlertLedger
    public var alerts: [LimitAlert] = []
    public var scheduled: [LimitAlert] = []
    public var verdicts: [LimitAlertVerdict] = []
}

public enum LimitAlertPlanner {
    public static let historySpan: TimeInterval = 26 * 3600
    public static let onPaceMinimumPercent = 40.0
    public static let backPercent = 90.0
    public static let headroomUnusedPercent = 50.0
    public static let outlookHours = 8..<12

    public static func assess(
        _ target: LimitAlertTarget, window: LimitWindow, samples: [LimitAlertSample], now: Date
    ) -> LimitAlertAssessment {
        let start = window.resetsAt.map { $0.addingTimeInterval(-target.duration) }
        let points = trail(samples, target: target, window: window, start: start, now: now)
        let burn: LimitBurn?
        if target.isWeekly {
            burn = rate(points, start: start, now: now, lookback: 86_400, minimumSpan: 6 * 3600)
        } else {
            burn = [1800.0, 3600].compactMap {
                rate(points, start: start, now: now, lookback: $0, minimumSpan: 900)
            }.min { $0.perHour < $1.perHour }
        }
        let projected: Date? = {
            guard let burn, burn.perHour > 0, window.percent < 100 else { return nil }
            return now.addingTimeInterval((100 - window.percent) / burn.perHour * 3600)
        }()
        let block: TimeInterval = target.isWeekly ? 2 * 3600 : 10 * 60
        let blocks = target.isWeekly ? 1 : 3
        let active = (0..<blocks).allSatisfy { index in
            rose(
                points, from: now.addingTimeInterval(-block * Double(index + 1)),
                to: now.addingTimeInterval(-block * Double(index)), start: start)
        }
        return LimitAlertAssessment(
            target: target, window: window, now: now, burn: burn, active: active,
            recentlyActive: rose(
                points, from: now.addingTimeInterval(-900), to: now, start: start),
            projectedCapAt: projected)
    }

    public static func plan(
        _ assessments: [LimitAlertAssessment], problems: [LimitProvider: LimitLoginProblem] = [:],
        healthy: Set<LimitProvider> = [], ledger: LimitAlertLedger, settings: LimitAlertSettings,
        clock: LimitAlertClock
    ) -> LimitAlertPlan {
        var plan = LimitAlertPlan(ledger: ledger)
        let recentlyActive = assessments.contains { $0.recentlyActive }
        for assessment in assessments {
            var entry = plan.ledger.windows[assessment.target.id] ?? .init()
            let (alert, reason) = decide(
                assessment, entry: &entry, settings: settings, clock: clock,
                recentlyActive: recentlyActive)
            plan.ledger.windows[assessment.target.id] = entry
            if let alert { plan.alerts.append(alert) }
            plan.verdicts.append(
                LimitAlertVerdict(assessment: assessment, alert: alert, reason: reason))
        }
        for provider in healthy { plan.ledger.login[provider.rawValue] = nil }
        for provider in LimitProvider.allCases {
            guard let problem = problems[provider], settings.allows(.login),
                settings.providers.contains(provider),
                plan.ledger.login[provider.rawValue] != problem.rawValue
            else { continue }
            plan.ledger.login[provider.rawValue] = problem.rawValue
            plan.alerts.append(LimitAlertCopy.login(provider, problem, clock: clock))
        }
        plan.scheduled = scheduled(plan.ledger, settings: settings, clock: clock)
        return plan
    }

    static func scheduled(
        _ ledger: LimitAlertLedger, settings: LimitAlertSettings, clock: LimitAlertClock
    ) -> [LimitAlert] {
        guard settings.allows(.back) else { return [] }
        return LimitAlertTarget.all.compactMap { target in
            guard settings.tracks(target), let at = ledger.windows[target.id]?.backAt,
                at > clock.now
            else { return nil }
            return LimitAlertCopy.back(target, resetAt: at, early: false, clock: clock)
        }
    }

    private enum Outcome {
        case fire(LimitAlert)
        case held(String)
        case quiet(String)
    }

    private static func decide(
        _ a: LimitAlertAssessment, entry: inout LimitAlertLedger.Entry,
        settings: LimitAlertSettings, clock: LimitAlertClock, recentlyActive: Bool
    ) -> (LimitAlert?, String) {
        let now = clock.now
        if isNewWindow(entry, a) {
            let previous = entry
            entry = LimitAlertLedger.Entry(resetsAt: a.window.resetsAt)
            if settings.allows(.back), previous.peak >= backPercent,
                (previous.backAt ?? .distantFuture) > now.addingTimeInterval(60)
            {
                let alert = LimitAlertCopy.back(a.target, resetAt: now, early: true, clock: clock)
                return (alert, alert.reason)
            }
        }
        entry.resetsAt = a.window.resetsAt
        entry.peak = max(entry.peak, a.window.percent)
        if entry.peak >= backPercent, let reset = a.window.resetsAt,
            abs((entry.backAt ?? .distantPast).timeIntervalSince(reset)) > 60
        {
            entry.backAt = reset
        }
        let facts = LimitAlertCopy.facts(
            a, entry: entry, clock: clock, recentlyActive: recentlyActive)
        let outcomes = [
            capped(a, entry, settings, clock), almostCapped(a, entry, settings, clock),
            onPace(a, entry, settings, clock, facts), headroom(a, entry, settings, clock, facts),
            outlook(a, entry, settings, clock, facts),
        ]
        var held: String?
        for outcome in outcomes {
            switch outcome {
            case .fire(let alert):
                record(alert, a, in: &entry, clock: clock)
                return (alert, alert.reason)
            case .held(let reason):
                held = held ?? reason
            case .quiet:
                continue
            }
        }
        if let held { return (nil, held) }
        if case .quiet(let reason) = outcomes[2] { return (nil, reason) }
        return (nil, "nothing to flag")
    }

    private static func isNewWindow(_ entry: LimitAlertLedger.Entry, _ a: LimitAlertAssessment)
        -> Bool
    {
        switch (entry.resetsAt, a.window.resetsAt) {
        case (nil, nil): return false
        case (let old?, let new?):
            return abs(new.timeIntervalSince(old)) > a.target.sameWindowTolerance
        default: return entry.peak > 0 || !entry.sent.isEmpty
        }
    }

    private static func record(
        _ alert: LimitAlert, _ a: LimitAlertAssessment, in entry: inout LimitAlertLedger.Entry,
        clock: LimitAlertClock
    ) {
        let now = clock.now
        entry.sent[alert.kind.rawValue] = now
        entry.outlookDay = clock.day(now)
        switch alert.kind {
        case .capped:
            entry.sent[LimitAlertKind.almostCapped.rawValue] = now
            entry.sent[LimitAlertKind.onPace.rawValue] = now
            entry.capAt = nil
        case .almostCapped:
            entry.sent[LimitAlertKind.onPace.rawValue] = now
            entry.capAt = nil
        case .onPace:
            entry.capAt = a.projectedCapAt
        default:
            break
        }
    }

    private static func sentNote(
        _ kind: String, _ entry: LimitAlertLedger.Entry, _ clock: LimitAlertClock
    )
        -> String?
    {
        entry.sent[kind].map {
            "\(kind.replacingOccurrences(of: "_", with: "-")) alert already sent \(clock.at($0))"
        }
    }

    private static func capped(
        _ a: LimitAlertAssessment, _ entry: LimitAlertLedger.Entry,
        _ settings: LimitAlertSettings, _ clock: LimitAlertClock
    ) -> Outcome {
        guard a.window.percent >= 100 else { return .quiet("below the cap") }
        guard settings.allows(.capped) else { return .quiet("capped alerts are off") }
        if let note = sentNote(LimitAlertKind.capped.rawValue, entry, clock) { return .held(note) }
        return .fire(LimitAlertCopy.capped(a, backOn: settings.allows(.back), clock: clock))
    }

    private static func almostCapped(
        _ a: LimitAlertAssessment, _ entry: LimitAlertLedger.Entry,
        _ settings: LimitAlertSettings, _ clock: LimitAlertClock
    ) -> Outcome {
        let threshold = Double(settings.almostCappedPercent)
        guard a.window.percent >= threshold, a.window.percent < 100 else {
            return .quiet("below \(settings.almostCappedPercent)%")
        }
        guard settings.allows(.almostCapped) else { return .quiet("almost-capped alerts are off") }
        if let note = sentNote(LimitAlertKind.almostCapped.rawValue, entry, clock) {
            return .held(note)
        }
        return .fire(LimitAlertCopy.almostCapped(a, clock: clock))
    }

    private static func onPace(
        _ a: LimitAlertAssessment, _ entry: LimitAlertLedger.Entry,
        _ settings: LimitAlertSettings, _ clock: LimitAlertClock, _ facts: [String: String]
    ) -> Outcome {
        guard settings.allows(.onPace) else { return .quiet("on-pace alerts are off") }
        guard a.window.percent < 100 else { return .quiet("already capped") }
        guard a.window.percent >= onPaceMinimumPercent else {
            return .quiet("below \(Int(onPaceMinimumPercent))%, too early to project")
        }
        guard let reset = a.window.resetsAt else { return .quiet("no reset time reported") }
        guard let burn = a.burn else { return .quiet("not enough history for a burn rate yet") }
        guard a.active, burn.perHour > 0 else {
            return .quiet(
                a.target.isWeekly
                    ? "idle: no change in the last 2 hours"
                    : "no steady burn over the last 30 minutes")
        }
        let lead: TimeInterval = a.target.isWeekly ? 6 * 3600 : 15 * 60
        guard let cap = a.projectedCapAt, cap <= reset.addingTimeInterval(-lead) else {
            return .quiet(
                String(format: "at %.1f%% an hour it reaches the cap after the reset", burn.perHour)
            )
        }
        if entry.sent[LimitAlertKind.onPace.rawValue] != nil {
            let shift: TimeInterval = a.target.isWeekly ? 12 * 3600 : 30 * 60
            let cooldown: TimeInterval = a.target.isWeekly ? 12 * 3600 : 45 * 60
            let sentAt = entry.sent[LimitAlertKind.onPace.rawValue] ?? .distantPast
            guard let previous = entry.capAt, previous.timeIntervalSince(cap) >= shift,
                clock.now.timeIntervalSince(sentAt) >= cooldown
            else {
                return .held(
                    "on-pace alert already sent and the cap time has not moved much earlier")
            }
        }
        return .fire(
            LimitAlertCopy.onPace(a, burn: burn, cap: cap, reset: reset, clock: clock, facts: facts)
        )
    }

    private static func headroom(
        _ a: LimitAlertAssessment, _ entry: LimitAlertLedger.Entry,
        _ settings: LimitAlertSettings, _ clock: LimitAlertClock, _ facts: [String: String]
    ) -> Outcome {
        guard a.target.isWeekly, settings.allows(.headroom) else {
            return .quiet("headroom alerts are off")
        }
        guard let left = a.timeLeft, left <= 86_400, left >= 3600, let reset = a.window.resetsAt
        else { return .quiet("not in the last day of the window") }
        guard a.window.percent <= 100 - headroomUnusedPercent else {
            return .quiet("less than half is unused")
        }
        if let note = sentNote(LimitAlertKind.headroom.rawValue, entry, clock) {
            return .held(note)
        }
        return .fire(LimitAlertCopy.headroom(a, reset: reset, clock: clock, facts: facts))
    }

    private static func outlook(
        _ a: LimitAlertAssessment, _ entry: LimitAlertLedger.Entry,
        _ settings: LimitAlertSettings, _ clock: LimitAlertClock, _ facts: [String: String]
    ) -> Outcome {
        guard a.target.isWeekly, settings.allows(.outlook) else {
            return .quiet("weekly outlooks are off")
        }
        guard outlookHours.contains(clock.hour) else {
            return .quiet("outlooks only go out in the morning")
        }
        guard entry.outlookDay != clock.day(clock.now) else {
            return .held("this window already had an alert today")
        }
        guard let outlook = a.outlook, let reset = a.window.resetsAt else {
            return .quiet("too little of the week to judge")
        }
        guard outlook.finishPercent >= 70 else {
            return .quiet("on track to finish around \(Int(outlook.finishPercent))%")
        }
        return .fire(
            LimitAlertCopy.outlook(a, outlook: outlook, reset: reset, clock: clock, facts: facts))
    }

    private struct Point {
        let date: Date
        let percent: Double
    }

    private static func trail(
        _ samples: [LimitAlertSample], target: LimitAlertTarget, window: LimitWindow,
        start: Date?, now: Date
    ) -> [Point] {
        let floor = start?.addingTimeInterval(-60) ?? .distantPast
        let matching = samples.filter { sample in
            guard sample.date <= now, sample.date >= floor else { return false }
            switch (sample.resetsAt, window.resetsAt) {
            case (nil, nil): return true
            case (let a?, let b?): return abs(a.timeIntervalSince(b)) <= target.sameWindowTolerance
            default: return false
            }
        }
        return
            (matching.map { Point(date: $0.date, percent: $0.percent) }
            + [Point(date: now, percent: window.percent)])
            .sorted { $0.date < $1.date }
    }

    private static func rate(
        _ points: [Point], start: Date?, now: Date, lookback: TimeInterval,
        minimumSpan: TimeInterval
    ) -> LimitBurn? {
        let from = now.addingTimeInterval(-lookback)
        let current = points.last?.percent ?? 0
        if let start, start >= from {
            let span = now.timeIntervalSince(start)
            guard span >= minimumSpan else { return nil }
            return LimitBurn(perHour: max(0, current) / (span / 3600), lookback: span)
        }
        let gap = max(minimumSpan, lookback / 4)
        if let base = points.last(where: { $0.date <= from }),
            from.timeIntervalSince(base.date) <= gap
        {
            return LimitBurn(
                perHour: max(0, current - base.percent) / (lookback / 3600), lookback: lookback)
        }
        guard let first = points.first(where: { $0.date > from }) else { return nil }
        let span = now.timeIntervalSince(first.date)
        guard span >= minimumSpan else { return nil }
        return LimitBurn(perHour: max(0, current - first.percent) / (span / 3600), lookback: span)
    }

    private static func rose(_ points: [Point], from: Date, to: Date, start: Date?) -> Bool {
        percent(points, at: to, start: start) > percent(points, at: from, start: start) + 0.05
    }

    private static func percent(_ points: [Point], at date: Date, start: Date?) -> Double {
        if let start, start >= date { return 0 }
        if let point = points.last(where: { $0.date <= date }) { return point.percent }
        return points.first?.percent ?? 0
    }
}
