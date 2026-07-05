import Foundation

struct LimitAlert: Equatable {
    let id: String
    let title: String
    let body: String
}

struct NotifySettings {
    var master = false
    var trackSession = true, trackWeekly = true
    var recovery = true
    var pacingWarning = true, pacingHot = true
    var reminderSession = false; var reminderSessionOffsetMin = 30
    var reminderWeekly = false; var reminderWeeklyOffsetMin = 120
    var tokenExpired = true
    var smartColor = true
    var pacingMargin = 10.0
    var thresholds = UsageThresholds.default

    static func fromDefaults(_ d: UserDefaults = .standard) -> NotifySettings {
        var s = NotifySettings()
        s.master = d.bool(forKey: "notifyMaster")
        s.trackSession = d.object(forKey: "notifyTrackSession") as? Bool ?? true
        s.trackWeekly = d.object(forKey: "notifyTrackWeekly") as? Bool ?? true
        s.recovery = d.object(forKey: "notifyRecovery") as? Bool ?? true
        s.pacingWarning = d.object(forKey: "notifyPacingWarning") as? Bool ?? true
        s.pacingHot = d.object(forKey: "notifyPacingHot") as? Bool ?? true
        s.reminderSession = d.bool(forKey: "notifyReminderSession")
        s.reminderSessionOffsetMin =
            d.object(forKey: "notifyReminderSessionOffsetMin") as? Int ?? 30
        s.reminderWeekly = d.bool(forKey: "notifyReminderWeekly")
        s.reminderWeeklyOffsetMin = d.object(forKey: "notifyReminderWeeklyOffsetMin") as? Int ?? 120
        s.tokenExpired = d.object(forKey: "notifyTokenExpired") as? Bool ?? true
        s.smartColor = d.object(forKey: "smartColor") as? Bool ?? true
        s.pacingMargin = d.object(forKey: "pacingMargin") as? Double ?? 10
        s.thresholds = UsageThresholds.fromDefaults(d)
        return s
    }
}

struct LimitNotifierState: Equatable {
    var sessionLevel: UsageLevel = .green
    var weeklyLevel: UsageLevel = .green
    var sessionPacing: PacingZone = .onTrack
    var weeklyPacing: PacingZone = .onTrack
}

enum LimitNotifierLogic {
    static func decide(
        session: LimitWindow?, week: LimitWindow?,
        settings: NotifySettings, state: inout LimitNotifierState, now: Date = Date()
    ) -> [LimitAlert] {
        guard settings.master else { return [] }
        var alerts: [LimitAlert] = []

        let sessionPacing = pacing(session, kind: .session, margin: settings.pacingMargin, now: now)
        let weeklyPacing = pacing(week, kind: .weekly, margin: settings.pacingMargin, now: now)

        if settings.trackSession, let session {
            alerts += checkSurface(
                .session, window: session, pacing: sessionPacing,
                settings: settings, level: &state.sessionLevel, now: now)
        }
        if settings.trackWeekly, let week {
            alerts += checkSurface(
                .weekly, window: week, pacing: weeklyPacing,
                settings: settings, level: &state.weeklyLevel, now: now)
        }
        if let z = sessionPacing {
            alerts += checkPacing(
                z, surface: .session, settings: settings, last: &state.sessionPacing)
        }
        if let z = weeklyPacing {
            alerts += checkPacing(
                z, surface: .weekly, settings: settings, last: &state.weeklyPacing)
        }
        return alerts
    }

    private static func pacing(
        _ window: LimitWindow?, kind: LimitWindowKind, margin: Double, now: Date
    ) -> PacingZone? {
        guard let window, let resetsAt = window.resetsAt else { return nil }
        let delta = LimitMath.pacingDelta(
            utilization: window.percent, resetsAt: resetsAt, windowDuration: kind.duration, now: now
        )
        return LimitMath.pacingZone(delta: delta, margin: margin)
    }

    private static func checkSurface(
        _ kind: LimitWindowKind, window: LimitWindow, pacing: PacingZone?,
        settings: NotifySettings, level previous: inout UsageLevel, now: Date
    ) -> [LimitAlert] {
        let absolute = UsageLevel.from(pct: window.percent, thresholds: settings.thresholds)
        let current: UsageLevel =
            settings.smartColor
            ? LimitMath.level(
                forRisk: LimitMath.smartRisk(
                    utilization: window.percent, resetsAt: window.resetsAt,
                    windowDuration: kind.duration, pacingMargin: settings.pacingMargin, now: now))
            : absolute
        guard current != previous else { return [] }
        let prev = previous
        previous = current

        let paceDriven = settings.smartColor && current > absolute && kind == .weekly

        if current > prev {
            return [
                escalation(
                    kind, level: current, window: window, pacing: pacing, paceDriven: paceDriven,
                    now: now)
            ]
        }
        if current == .green, prev > .green, settings.recovery {
            return [recovery(kind, window: window, now: now)]
        }
        return []
    }

    private static func checkPacing(
        _ zone: PacingZone, surface: LimitWindowKind,
        settings: NotifySettings, last: inout PacingZone
    ) -> [LimitAlert] {
        guard zone != last else { return [] }
        last = zone
        let prefix = surface == .session ? "Session" : "Weekly"
        switch zone {
        case .hot where settings.pacingHot:
            return [
                LimitAlert(
                    id: "pacing_\(surface.rawValue)_hot",
                    title: "\(prefix): burning hot", body: "Way ahead of pace, pump the brakes")
            ]
        case .warning where settings.pacingWarning:
            return [
                LimitAlert(
                    id: "pacing_\(surface.rawValue)_warning",
                    title: "\(prefix): drifting fast",
                    body: "A touch faster than ideal, keep an eye")
            ]
        default:
            return []
        }
    }

    private static func escalation(
        _ kind: LimitWindowKind, level: UsageLevel, window: LimitWindow,
        pacing: PacingZone?, paceDriven: Bool, now: Date
    ) -> LimitAlert {
        let id = "escalation_\(kind.rawValue)"
        if paceDriven {
            return LimitAlert(
                id: id, title: "Ahead of weekly pace",
                body:
                    "You're ahead of an even weekly burn rate, not near the cap. Fine if intentional."
            )
        }
        switch kind {
        case .session:
            let left = window.resetsAt.flatMap { $0 > now ? countdown(from: now, to: $0) : nil }
            if level == .red {
                return LimitAlert(
                    id: id, title: "5h almost capped",
                    body: left.map { "Easy until reset, \($0) left" } ?? "Limit almost reached")
            }
            let zone = pacing ?? .onTrack
            let title: String
            switch zone {
            case .chill: title = "Pace check"
            case .onTrack: title = "Session getting heavy"
            case .warning: title = "Drifting on the 5h"
            case .hot: title = "Burning the 5h"
            }
            let body: String
            if let left {
                switch zone {
                case .chill: body = "Pace is fine, resets in \(left)"
                case .onTrack: body = "On track, resets in \(left)"
                case .warning: body = "A touch fast, \(left) left"
                case .hot: body = "Way ahead of pace, \(left) left"
                }
            } else {
                body = "Past the warning level"
            }
            return LimitAlert(id: id, title: title, body: body)
        case .weekly:
            let when = window.resetsAt.flatMap { $0 > now ? dateTime($0) : nil }
            if level == .red {
                return LimitAlert(
                    id: id, title: "Weekly almost capped",
                    body: when.map { "Take it slow until \($0)" } ?? "Weekly limit almost reached")
            }
            return LimitAlert(
                id: id, title: "Weekly filling up",
                body: when.map { "Resets \($0)" } ?? "Past the weekly warning")
        }
    }

    private static func recovery(_ kind: LimitWindowKind, window: LimitWindow, now: Date)
        -> LimitAlert
    {
        let id = "recovery_\(kind.rawValue)"
        switch kind {
        case .session:
            let at = window.resetsAt.flatMap { $0 > now ? time($0) : nil }
            return LimitAlert(
                id: id, title: "5h cleared",
                body: at.map { "Fresh slate at \($0)" } ?? "Fresh slate, you're back")
        case .weekly:
            let at = window.resetsAt.flatMap { $0 > now ? dateTime($0) : nil }
            return LimitAlert(
                id: id, title: "Weekly reset",
                body: at.map { "New cycle, you're back at \($0)" } ?? "New cycle, you're back")
        }
    }

    static func countdown(from now: Date, to target: Date) -> String {
        let mins = max(0, Int(target.timeIntervalSince(now)) / 60)
        let h = mins / 60, m = mins % 60
        if h >= 24 { return "\(h / 24) d \(h % 24) h" }
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return "\(m) min"
    }

    static func dateTime(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    static func time(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }

    static func offsetLabel(minutes: Int) -> String {
        minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes) min"
    }

    static func reminderFireDate(reset: Date?, offsetMinutes: Int, now: Date = Date()) -> Date? {
        guard let reset else { return nil }
        let fire = reset.addingTimeInterval(-Double(offsetMinutes) * 60)
        return fire > now ? fire : nil
    }
}
