import Foundation
import Testing

@testable import EdithKit

enum LimitAlertScenario {
    static let start = Date(timeIntervalSince1970: 1_789_992_000)
    static let hour: TimeInterval = 3600

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func clock(_ now: Date) -> LimitAlertClock {
        LimitAlertClock(now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
    }

    static var settings: LimitAlertSettings {
        var settings = LimitAlertSettings()
        settings.master = true
        return settings
    }

    static func samples(
        _ reset: Date?, from: Date, to: Date, percent: (Date) -> Double
    ) -> [LimitAlertSample] {
        stride(from: from.timeIntervalSince1970, through: to.timeIntervalSince1970, by: 300).map {
            let date = Date(timeIntervalSince1970: $0)
            return LimitAlertSample(date: date, percent: percent(date), resetsAt: reset)
        }
    }

    static func plan(
        _ target: LimitAlertTarget, percent: Double, reset: Date?, now: Date,
        samples: [LimitAlertSample] = [], settings: LimitAlertSettings = settings,
        ledger: LimitAlertLedger = LimitAlertLedger(), held: Set<String> = []
    ) -> LimitAlertPlan {
        let assessment = LimitAlertPlanner.assess(
            target, window: LimitWindow(percent: percent, resetsAt: reset), samples: samples,
            now: now)
        return LimitAlertPlanner.plan(
            [assessment], ledger: ledger, settings: settings, clock: clock(now), held: held)
    }

    static func simulate(
        _ target: LimitAlertTarget, reset: Date, from: Date, to: Date,
        every step: TimeInterval = 300, settings: LimitAlertSettings = settings,
        percent: (Date) -> Double
    ) -> (alerts: [LimitAlert], last: LimitAlertPlan?) {
        var ledger = LimitAlertLedger()
        var alerts: [LimitAlert] = []
        var last: LimitAlertPlan?
        let historyStart = max(
            reset.addingTimeInterval(-target.duration),
            from.addingTimeInterval(-LimitAlertPlanner.historySpan))
        for tick in stride(
            from: from.timeIntervalSince1970, through: to.timeIntervalSince1970, by: step)
        {
            let now = Date(timeIntervalSince1970: tick)
            let history = samples(reset, from: historyStart, to: now, percent: percent)
            let result = plan(
                target, percent: percent(now), reset: reset, now: now, samples: history,
                settings: settings, ledger: ledger)
            ledger = result.ledger
            alerts += result.alerts
            last = result
        }
        return (alerts, last)
    }

    static func hours(_ date: Date, since origin: Date = start) -> Double {
        date.timeIntervalSince(origin) / hour
    }
}

@Suite struct LimitAlertPlannerTests {
    typealias S = LimitAlertScenario
    let session = LimitAlertTarget(.claude, .session)
    let weekly = LimitAlertTarget(.claude, .week)

    @Test func steadyBurnCrossesTheProjectionOnceThenCapsAndSchedulesTheReturn() throws {
        let reset = S.start.addingTimeInterval(5 * S.hour)
        let run = S.simulate(
            session, reset: reset, from: S.start.addingTimeInterval(300),
            to: reset.addingTimeInterval(-300)
        ) { min(100, (25 * S.hours($0)).rounded(.down)) }
        #expect(run.alerts.map(\.kind) == [.onPace, .almostCapped, .capped])
        let capped = try #require(run.alerts.last)
        #expect(capped.title == "Claude 5h capped")
        #expect(
            capped.body == "Claude 5h is capped until 5:00 PM. Edith will tell you when it's back.")
        let back = try #require(run.last?.scheduled.first)
        #expect(back.identifier == "limits.back.claude.session")
        #expect(back.fireAt == reset)
        #expect(back.body == "Claude 5h reset at 5:00 PM. The full limit is available again.")
    }

    @Test func idleAfterASpikeYieldsNothing() {
        let reset = S.start.addingTimeInterval(5 * S.hour)
        let run = S.simulate(
            session, reset: reset, from: S.start.addingTimeInterval(300),
            to: S.start.addingTimeInterval(4 * S.hour)
        ) { date in
            let minutes = date.timeIntervalSince(S.start) / 60
            return minutes < 60 ? 0 : min(55, (5.5 * (minutes - 60)).rounded(.down))
        }
        #expect(run.alerts.isEmpty)
    }

    @Test func burstyUsageFiresTheProjectionOnlyOnce() {
        let reset = S.start.addingTimeInterval(5 * S.hour)
        let run = S.simulate(
            session, reset: reset, from: S.start.addingTimeInterval(300),
            to: reset.addingTimeInterval(-300)
        ) { date in
            let minutes = date.timeIntervalSince(S.start) / 60
            let bursts = (minutes / 60).rounded(.down)
            return min(100, bursts * 30 + min(minutes.truncatingRemainder(dividingBy: 60), 30))
        }
        #expect(run.alerts.filter { $0.kind == .onPace }.count == 1)
        #expect(run.alerts.map(\.kind) == [.onPace, .almostCapped, .capped])
    }

    @Test func onPaceCopyUsesAbsoluteTimes() throws {
        let now = S.start.addingTimeInterval(2 * S.hour)
        let reset = S.start.addingTimeInterval(5 * S.hour)
        let history = S.samples(reset, from: S.start, to: now) { 30 * S.hours($0) }
        let plan = S.plan(session, percent: 60, reset: reset, now: now, samples: history)
        let alert = try #require(plan.alerts.first)
        #expect(alert.identifier == "limits.on_pace.claude.session")
        #expect(alert.title == "Claude 5h on pace to cap")
        #expect(
            alert.body
                == "Claude 5h is at 60%. At your last 30 minutes' pace you'll hit the cap around 3:20 PM, 1 h 40 m before it resets at 5:00 PM."
        )
        #expect(alert.expiresAt == now.addingTimeInterval(80 * 60))
        #expect(!alert.body.contains(" in "))
    }

    @Test func projectionStaysQuietBelowFortyPercentOrWithoutHistory() {
        let now = S.start.addingTimeInterval(S.hour)
        let reset = S.start.addingTimeInterval(5 * S.hour)
        let history = S.samples(reset, from: S.start, to: now) { 35 * S.hours($0) }
        #expect(
            S.plan(session, percent: 35, reset: reset, now: now, samples: history).alerts.isEmpty)
        let alone = S.plan(session, percent: 70, reset: reset, now: now)
        #expect(alone.alerts.isEmpty)
        #expect(alone.verdicts.first?.reason == "no steady burn over the last 30 minutes")
    }

    @Test func oneTickNeverStacksAlertsForTheSameWindow() {
        let now = S.start.addingTimeInterval(3 * S.hour)
        let reset = S.start.addingTimeInterval(5 * S.hour)
        let history = S.samples(reset, from: S.start, to: now) { 30.7 * S.hours($0) }
        let first = S.plan(session, percent: 92, reset: reset, now: now, samples: history)
        #expect(first.alerts.map(\.kind) == [.almostCapped])
        #expect(
            first.alerts.first?.body
                == "Claude 5h is at 92%. About 8% left until it resets at 5:00 PM.")
        let later = now.addingTimeInterval(300)
        let next = S.plan(
            session, percent: 94, reset: reset, now: later,
            samples: S.samples(reset, from: S.start, to: later) { 30.7 * S.hours($0) },
            ledger: first.ledger)
        #expect(next.alerts.isEmpty)
        let jump = S.plan(session, percent: 100, reset: reset, now: now)
        #expect(jump.alerts.map(\.kind) == [.capped])
        let after = S.plan(session, percent: 100, reset: reset, now: later, ledger: jump.ledger)
        #expect(after.alerts.isEmpty)
    }

    @Test func recoveryOnlyFollowsARealReset() {
        let now = S.start.addingTimeInterval(3 * S.hour)
        let reset = S.start.addingTimeInterval(5 * S.hour)
        let high = S.plan(session, percent: 95, reset: reset, now: now)
        #expect(high.scheduled.map(\.fireAt) == [reset])
        let glitch = S.plan(
            session, percent: 80, reset: reset, now: now.addingTimeInterval(300),
            ledger: high.ledger)
        #expect(glitch.alerts.isEmpty)
        let early = S.plan(
            session, percent: 2, reset: reset.addingTimeInterval(5 * S.hour),
            now: now.addingTimeInterval(600), ledger: glitch.ledger)
        #expect(early.alerts.map(\.identifier) == ["limits.back.claude.session"])
        #expect(
            early.alerts.first?.body == "Claude 5h reset early. The full limit is available again.")
        #expect(early.scheduled.isEmpty)
        let onTime = S.plan(
            session, percent: 2, reset: reset.addingTimeInterval(5 * S.hour),
            now: reset.addingTimeInterval(600), ledger: glitch.ledger)
        #expect(onTime.alerts.isEmpty)
        let low = S.plan(session, percent: 50, reset: reset, now: now)
        let quiet = S.plan(
            session, percent: 2, reset: reset.addingTimeInterval(5 * S.hour),
            now: now.addingTimeInterval(600), ledger: low.ledger)
        #expect(quiet.alerts.isEmpty)
    }

    @Test func aResetThatMovesBackwardsIsIgnored() {
        let codex = LimitAlertTarget(.codex, .week)
        let now = S.start
        let reset = now.addingTimeInterval(60 * S.hour)
        let first = S.plan(codex, percent: 40, reset: reset, now: now)
        let flipped = S.plan(
            codex, percent: 99, reset: reset.addingTimeInterval(-46 * S.hour),
            now: now.addingTimeInterval(300), ledger: first.ledger)
        #expect(flipped.alerts.isEmpty)
        #expect(flipped.ledger == first.ledger)
        let restored = S.plan(
            codex, percent: 41, reset: reset, now: now.addingTimeInterval(600),
            ledger: flipped.ledger)
        #expect(restored.alerts.isEmpty)
    }

    @Test func inspectorReadsTheHistoryAndHonoursWhatWasSent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("limits-history.jsonl")
        let suite = "test.limit.alerts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: dir)
            defaults.removePersistentDomain(forName: suite)
        }
        let now = S.start.addingTimeInterval(2 * S.hour)
        let reset = S.start.addingTimeInterval(5 * S.hour)
        var history = LimitsHistory(url: url)
        for sample in S.samples(reset, from: S.start, to: now, percent: { 30 * S.hours($0) }) {
            history.append(
                session: LimitWindow(percent: sample.percent, resetsAt: reset),
                week: LimitWindow(percent: 20, resetsAt: reset.addingTimeInterval(86_400)),
                now: sample.date)
        }
        let verdicts = LimitAlertInspector.inspect(
            clock: S.clock(now), defaults: defaults, historyURL: url, ledger: nil)
        #expect(verdicts.map(\.assessment.target.id) == ["claude.session", "claude.week"])
        #expect(verdicts.first?.alert?.kind == .onPace)
        #expect(
            verdicts.first?.summary(clock: S.clock(now))
                == "Claude 5h: 60%, 30.0% an hour, cap around 3:20 PM")
        var ledger = LimitAlertLedger()
        var entry = LimitAlertLedger.Entry(resetsAt: reset)
        entry.sent[LimitAlertKind.onPace.rawValue] = now.addingTimeInterval(-600)
        entry.capAt = now.addingTimeInterval(80 * 60)
        ledger.windows["claude.session"] = entry
        let held = LimitAlertInspector.inspect(
            clock: S.clock(now), defaults: defaults, historyURL: url, ledger: ledger)
        #expect(held.first?.alert == nil)
        #expect(held.first?.reason.hasPrefix("on-pace alert already sent") == true)
    }

    @Test func weeklyOutlookGoesOutAtMostOncePerMorning() throws {
        let reset = S.start.addingTimeInterval(3 * 24 * S.hour)
        let windowStart = reset.addingTimeInterval(-weekly.duration)
        var settings = S.settings
        settings.outlook = true
        settings.onPace = false
        let run = S.simulate(
            weekly, reset: reset, from: S.start.addingTimeInterval(-5 * S.hour),
            to: S.start.addingTimeInterval(25 * S.hour), every: 900, settings: settings
        ) { (16 * $0.timeIntervalSince(windowStart) / 86_400).rounded(.down) }
        #expect(run.alerts.map(\.kind) == [.outlook, .outlook])
        let first = try #require(run.alerts.first)
        #expect(first.title == "Claude weekly outlook")
        #expect(
            first.body
                == "Claude weekly: 61% used with 3 days left. At your usual pace you'll run out Wednesday evening, before it resets Thursday 12:00 PM."
        )
    }

    @Test func severalWeeklyWindowsShareOneOutlookEachMorning() {
        let now = S.start.addingTimeInterval(-3 * S.hour)
        let reset = S.start.addingTimeInterval(3 * 24 * S.hour)
        var settings = S.settings
        settings.outlook = true
        let assessments = [weekly, LimitAlertTarget(.codex, .week)].map {
            LimitAlertPlanner.assess(
                $0, window: LimitWindow(percent: 50, resetsAt: reset), samples: [], now: now)
        }
        let plan = LimitAlertPlanner.plan(
            assessments, ledger: LimitAlertLedger(), settings: settings, clock: S.clock(now))
        #expect(plan.alerts.map(\.kind) == [.outlook])
        #expect(plan.verdicts.last?.reason == "one outlook per morning already went out")
        let again = LimitAlertPlanner.plan(
            assessments, ledger: plan.ledger, settings: settings,
            clock: S.clock(now.addingTimeInterval(S.hour)))
        #expect(again.alerts.isEmpty)
    }

    @Test func outlookReportsAFinishWhenTheWeekFitsAndSkipsQuietWeeks() {
        let now = S.start.addingTimeInterval(-3 * S.hour)
        let reset = S.start.addingTimeInterval(3 * 24 * S.hour)
        var settings = S.settings
        settings.outlook = true
        let tight = S.plan(weekly, percent: 50, reset: reset, now: now, settings: settings)
        #expect(tight.alerts.first?.body.hasSuffix("you'll finish around 90%.") == true)
        let easy = S.plan(weekly, percent: 20, reset: reset, now: now, settings: settings)
        #expect(easy.alerts.isEmpty)
    }

    @Test func codexAndFableWindowsAreHandled() {
        var settings = S.settings
        settings.headroom = true
        let now = S.start
        let headroom = S.plan(
            LimitAlertTarget(.codex, .week), percent: 30,
            reset: now.addingTimeInterval(20 * S.hour), now: now, settings: settings)
        #expect(headroom.alerts.map(\.identifier) == ["limits.headroom.codex.week"])
        #expect(
            headroom.alerts.first?.body == "Codex weekly resets tomorrow 8:00 AM with 70% unused.")
        let fable = S.plan(
            LimitAlertTarget(.claude, .fable), percent: 92,
            reset: now.addingTimeInterval(50 * S.hour), now: now)
        #expect(fable.alerts.first?.title == "Claude Fable weekly at 92%")
        #expect(fable.alerts.first?.body.hasSuffix("until it resets Wednesday 2:00 PM.") == true)
        let codexSession = S.plan(
            LimitAlertTarget(.codex, .session), percent: 100,
            reset: now.addingTimeInterval(S.hour), now: now)
        #expect(codexSession.alerts.first?.title == "Codex 5h capped")
    }

    @Test func loginProblemsAlertOnceUntilTheProviderRecovers() {
        let clock = S.clock(S.start)
        let first = LimitAlertPlanner.plan(
            [], problems: [.claude: .expired], ledger: LimitAlertLedger(), settings: S.settings,
            clock: clock)
        #expect(first.alerts.map(\.title) == ["Claude session expired"])
        let repeated = LimitAlertPlanner.plan(
            [], problems: [.claude: .expired], ledger: first.ledger, settings: S.settings,
            clock: clock)
        #expect(repeated.alerts.isEmpty)
        let changed = LimitAlertPlanner.plan(
            [], problems: [.claude: .denied], ledger: repeated.ledger, settings: S.settings,
            clock: clock)
        #expect(changed.alerts.first?.body.contains("claude auth login --claudeai") == true)
        let healthy = LimitAlertPlanner.plan(
            [], healthy: [.claude], ledger: changed.ledger, settings: S.settings, clock: clock)
        let again = LimitAlertPlanner.plan(
            [], problems: [.claude: .denied], ledger: healthy.ledger, settings: S.settings,
            clock: clock)
        #expect(again.alerts.count == 1)
        #expect(LimitLoginProblem(error: "Claude Code token not found") == .missing)
        #expect(
            LimitLoginProblem(error: "Claude session expired - run claude to re-login") == .expired)
        #expect(LimitLoginProblem(error: "Offline") == nil)
    }

    @Test func settingsPermitOnlyEnabledKindsAndWindows() {
        var settings = S.settings
        settings.onPace = false
        settings.trackWeekly = false
        #expect(settings.permits(identifier: "limits.capped.claude.session"))
        #expect(!settings.permits(identifier: "limits.on_pace.claude.session"))
        #expect(!settings.permits(identifier: "limits.capped.codex.week"))
        #expect(settings.permits(identifier: "limits.login.codex"))
        #expect(!settings.permits(identifier: "limits.escalation_session"))
        settings.master = false
        #expect(!settings.permits(identifier: "limits.login.codex"))
    }

    @Test func jevGateOnlyWeighsInOnNonCriticalAlerts() async {
        let probe = LimitAlertJevProbe(score: 0.2)
        let gate = LimitAlertJevGate(decider: probe)
        let now = S.start.addingTimeInterval(2 * S.hour)
        let reset = S.start.addingTimeInterval(5 * S.hour)
        let history = S.samples(reset, from: S.start, to: now) { 30 * S.hours($0) }
        let onPace = S.plan(session, percent: 60, reset: reset, now: now, samples: history)
        let capped = S.plan(session, percent: 100, reset: reset, now: now)
        #expect(await gate.allows(capped.alerts[0]))
        #expect(probe.calls == 0)
        #expect(await !gate.allows(onPace.alerts[0]))
        #expect(probe.calls == 1)
        let request = probe.requests.first
        guard case .fields(let fields) = request?.state else {
            Issue.record("expected a fields state")
            return
        }
        #expect(fields["alert"] == "on pace")
        #expect(fields["percent"] == "60")
        #expect(fields["projected_cap"] == "3:20 PM")
        #expect(fields["recently_active"] == "yes")
        #expect(
            await LimitAlertJevGate(decider: LimitAlertJevProbe(score: 0.6)).allows(
                onPace.alerts[0]))
        #expect(
            await LimitAlertJevGate(decider: LimitAlertJevProbe(score: nil)).allows(
                onPace.alerts[0]))
        #expect(await LimitAlertJevGate(decider: nil).allows(onPace.alerts[0]))
    }

    @Test func aHeldAlertIsNotRecordedSoItCanStillGoOutLater() throws {
        let now = S.start.addingTimeInterval(2 * S.hour)
        let reset = S.start.addingTimeInterval(5 * S.hour)
        let history = S.samples(reset, from: S.start, to: now) { 30 * S.hours($0) }
        let proposed = S.plan(session, percent: 60, reset: reset, now: now, samples: history)
        let alert = try #require(proposed.alerts.first)
        let held = S.plan(
            session, percent: 60, reset: reset, now: now, samples: history,
            held: [alert.identifier])
        #expect(held.alerts.isEmpty)
        #expect(held.verdicts.first?.reason == LimitAlertPlanner.heldReason)
        #expect(held.ledger.windows[session.id]?.sent[LimitAlertKind.onPace.rawValue] == nil)
        let later = now.addingTimeInterval(600)
        let laterHistory = S.samples(reset, from: S.start, to: later) { 30 * S.hours($0) }
        let released = S.plan(
            session, percent: 65, reset: reset, now: later, samples: laterHistory,
            ledger: held.ledger)
        #expect(released.alerts.map(\.kind) == [.onPace])
    }

    @Test func clockFormatsMomentsRelativeToToday() {
        let clock = S.clock(S.start)
        #expect(clock.moment(S.start.addingTimeInterval(4.5 * S.hour)) == "4:30 PM")
        #expect(clock.at(S.start.addingTimeInterval(4.5 * S.hour)) == "at 4:30 PM")
        #expect(clock.moment(S.start.addingTimeInterval(21 * S.hour)) == "tomorrow 9:00 AM")
        #expect(clock.moment(S.start.addingTimeInterval(70 * S.hour)) == "Thursday 10:00 AM")
        #expect(clock.dayPart(S.start.addingTimeInterval(51 * S.hour)) == "Wednesday afternoon")
        #expect(LimitAlertClock.span(70 * 60) == "1 h 10 m")
    }
}

final class LimitAlertJevProbe: JevDeciding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedScore: Double?
    private var recorded: [JevRequest] = []

    init(score: Double?) {
        storedScore = score
    }

    var score: Double? {
        get { lock.withLock { storedScore } }
        set { lock.withLock { storedScore = newValue } }
    }
    var calls: Int { lock.withLock { recorded.count } }
    var requests: [JevRequest] { lock.withLock { recorded } }

    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        lock.withLock { recorded.append(request) }
        guard let score else { throw JevError.noCredits("no credits") }
        return JevDecision(
            response: JevResponse(
                model: "jev-latest",
                answers: [LimitAlertJevGate.question: JevAnswer(type: "noul", noul: score)]),
            milliseconds: 5)
    }
}
