import Foundation
import Testing
@testable import EdithKit

@Suite struct LimitNotifierLogicTests {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    var settings: NotifySettings {
        var s = NotifySettings()
        s.master = true
        s.smartColor = false
        return s
    }

    func decide(
        _ session: LimitWindow?, _ week: LimitWindow?, settings: NotifySettings,
        state: inout LimitNotifierState
    ) -> [LimitAlert] {
        LimitNotifierLogic.decide(
            session: session, week: week, settings: settings, state: &state, now: now)
    }

    @Test func masterOffProducesNothing() {
        var s = settings; s.master = false
        var state = LimitNotifierState()
        let session = LimitWindow(percent: 95, resetsAt: now.addingTimeInterval(3600))
        #expect(decide(session, nil, settings: s, state: &state).isEmpty)
        #expect(state == LimitNotifierState())
    }

    @Test func escalationFiresOncePerLevel() {
        var state = LimitNotifierState()
        let session = LimitWindow(percent: 70, resetsAt: now.addingTimeInterval(3600))
        let first = decide(session, nil, settings: settings, state: &state)
        #expect(first.count == 1)
        #expect(first[0].id == "escalation_session")
        #expect(state.sessionLevel == .orange)
        #expect(decide(session, nil, settings: settings, state: &state).isEmpty)
    }

    @Test func redEscalationAndRecovery() {
        var state = LimitNotifierState()
        let hot = LimitWindow(percent: 90, resetsAt: now.addingTimeInterval(1800))
        let red = decide(hot, nil, settings: settings, state: &state)
        #expect(red.count == 1)
        #expect(red[0].title == "5h almost capped")
        #expect(red[0].body.contains("30 min"))
        let fresh = LimitWindow(percent: 0, resetsAt: now.addingTimeInterval(5 * 3600))
        let rec = decide(fresh, nil, settings: settings, state: &state)
        #expect(rec.count == 1)
        #expect(rec[0].id == "recovery_session")
        #expect(rec[0].title == "5h cleared")
    }

    @Test func recoveryRespectsToggle() {
        var s = settings; s.recovery = false
        var state = LimitNotifierState(); state.sessionLevel = .red
        let fresh = LimitWindow(percent: 0, resetsAt: now.addingTimeInterval(5 * 3600))
        #expect(decide(fresh, nil, settings: s, state: &state).isEmpty)
        #expect(state.sessionLevel == .green)
    }

    @Test func weeklyCopyUsesDates() {
        var state = LimitNotifierState()
        let week = LimitWindow(percent: 65, resetsAt: now.addingTimeInterval(3 * 86400))
        let a = decide(nil, week, settings: settings, state: &state)
        #expect(a.count == 1)
        #expect(a[0].title == "Weekly filling up")
        #expect(a[0].body.hasPrefix("Resets "))
    }

    @Test func pacingEntryAlerts() {
        var state = LimitNotifierState()
        let week = LimitWindow(percent: 30, resetsAt: now.addingTimeInterval(6.7 * 86400))
        let alerts = decide(nil, week, settings: settings, state: &state)
        #expect(
            alerts.contains { $0.id == "pacing_weekly_hot" && $0.title == "Weekly: burning hot" })
        #expect(state.weeklyPacing == .hot)
        #expect(decide(nil, week, settings: settings, state: &state).isEmpty)
    }

    @Test func paceDrivenWeeklyEscalationWording() {
        var s = settings; s.smartColor = true
        var state = LimitNotifierState()
        let week = LimitWindow(percent: 55, resetsAt: now.addingTimeInterval(6.0 * 86400))
        let alerts = decide(nil, week, settings: s, state: &state)
        let esc = alerts.first { $0.id == "escalation_weekly" }
        #expect(esc != nil)
        #expect(esc!.title == "Ahead of weekly pace")
    }

    @Test func countdownFormatting() {
        #expect(
            LimitNotifierLogic.countdown(from: now, to: now.addingTimeInterval(45 * 60)) == "45 min"
        )
        #expect(
            LimitNotifierLogic.countdown(from: now, to: now.addingTimeInterval(2 * 3600 + 15 * 60))
                == "2 h 15 min")
        #expect(
            LimitNotifierLogic.countdown(from: now, to: now.addingTimeInterval(3 * 3600)) == "3 h")
        #expect(
            LimitNotifierLogic.countdown(from: now, to: now.addingTimeInterval(26 * 3600))
                == "1 d 2 h")
    }

    @Test func partialDeescalationAdvancesStateSilently() {
        var state = LimitNotifierState(); state.sessionLevel = .red
        let session = LimitWindow(percent: 70, resetsAt: now.addingTimeInterval(3600))
        let alerts = decide(session, nil, settings: settings, state: &state)
        #expect(alerts.isEmpty)
        #expect(state.sessionLevel == .orange)
    }

    @Test func offsetLabelFormatting() {
        #expect(LimitNotifierLogic.offsetLabel(minutes: 30) == "30 min")
        #expect(LimitNotifierLogic.offsetLabel(minutes: 60) == "1 h")
        #expect(LimitNotifierLogic.offsetLabel(minutes: 120) == "2 h")
        #expect(LimitNotifierLogic.offsetLabel(minutes: 90) == "90 min")
        #expect(LimitNotifierLogic.offsetLabel(minutes: 720) == "12 h")
    }

    @Test func reminderFireDateComputesOffsetFromReset() {
        let reset = now.addingTimeInterval(3600)
        let fire = LimitNotifierLogic.reminderFireDate(reset: reset, offsetMinutes: 30, now: now)
        #expect(fire == reset.addingTimeInterval(-30 * 60))
    }

    @Test func reminderFireDateNilWhenOffsetPastNow() {
        let reset = now.addingTimeInterval(10 * 60)
        #expect(
            LimitNotifierLogic.reminderFireDate(reset: reset, offsetMinutes: 30, now: now) == nil)
    }

    @Test func reminderFireDateNilWhenResetIsNil() {
        #expect(LimitNotifierLogic.reminderFireDate(reset: nil, offsetMinutes: 30, now: now) == nil)
    }
}
