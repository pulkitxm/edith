import Foundation

enum LimitAlertCopy {
    static func capped(_ a: LimitAlertAssessment, backOn: Bool, clock: LimitAlertClock)
        -> LimitAlert
    {
        let label = a.target.label
        let until = a.window.resetsAt.map { " until " + clock.moment($0) } ?? ""
        let follow =
            backOn && a.window.resetsAt != nil ? " Edith will tell you when it's back." : ""
        return LimitAlert(
            kind: .capped, scope: a.target.id, title: "\(label) capped",
            body: "\(label) is capped\(until).\(follow)", reason: "at 100% of the limit",
            expiresAt: a.window.resetsAt)
    }

    static func almostCapped(_ a: LimitAlertAssessment, clock: LimitAlertClock) -> LimitAlert {
        let label = a.target.label
        let used = Int(a.window.percent.rounded(.down))
        let resets = a.window.resetsAt.map { " until it resets " + clock.at($0) } ?? ""
        return LimitAlert(
            kind: .almostCapped, scope: a.target.id, title: "\(label) at \(used)%",
            body: "\(label) is at \(used)%. About \(100 - used)% left\(resets).",
            reason: "at \(used)%, past the almost-capped line", expiresAt: a.window.resetsAt)
    }

    static func onPace(
        _ a: LimitAlertAssessment, burn: LimitBurn, cap: Date, reset: Date,
        clock: LimitAlertClock, facts: [String: String]
    ) -> LimitAlert {
        let label = a.target.label
        let used = Int(a.window.percent.rounded(.down))
        let early = LimitAlertClock.span(reset.timeIntervalSince(cap))
        let pace = burn.phrase.prefix(1).uppercased() + burn.phrase.dropFirst()
        return LimitAlert(
            kind: .onPace, scope: a.target.id, title: "\(label) on pace to cap",
            body:
                "\(label) is at \(used)%. At \(burn.phrase) you'll hit the cap around \(clock.moment(cap)), \(early) before it resets \(clock.at(reset)).",
            reason: String(
                format: "%@ is %.1f%% an hour, reaching the cap %@ before the reset", String(pace),
                burn.perHour, early),
            expiresAt: cap, facts: facts)
    }

    static func headroom(
        _ a: LimitAlertAssessment, reset: Date, clock: LimitAlertClock, facts: [String: String]
    ) -> LimitAlert {
        let label = a.target.label
        let unused = 100 - Int(a.window.percent.rounded(.up))
        return LimitAlert(
            kind: .headroom, scope: a.target.id, title: "\(label) has room left",
            body: "\(label) resets \(clock.moment(reset)) with \(unused)% unused.",
            reason: "\(unused)% unused with less than a day left", expiresAt: reset, facts: facts)
    }

    static func outlook(
        _ a: LimitAlertAssessment, outlook: LimitOutlook, reset: Date, clock: LimitAlertClock,
        facts: [String: String]
    ) -> LimitAlert {
        let label = a.target.label
        let used = Int(a.window.percent.rounded(.down))
        let left = LimitAlertClock.days(reset.timeIntervalSince(clock.now))
        let ending: String
        if let runOut = outlook.runOutAt {
            ending =
                "you'll run out \(clock.dayPart(runOut)), before it resets \(clock.moment(reset))."
        } else {
            ending = "you'll finish around \(Int(outlook.finishPercent.rounded()))%."
        }
        return LimitAlert(
            kind: .outlook, scope: a.target.id, title: "\(label) outlook",
            body: "\(label): \(used)% used with \(left) left. At your usual pace \(ending)",
            reason: String(
                format: "averaging %.1f%% a day, heading for %d%%", outlook.perDay,
                Int(outlook.finishPercent.rounded())),
            expiresAt: clock.now.addingTimeInterval(6 * 3600), facts: facts)
    }

    static func back(_ target: LimitAlertTarget, resetAt: Date, early: Bool, clock: LimitAlertClock)
        -> LimitAlert
    {
        let label = target.label
        let when = early ? "reset early" : "reset at \(clock.time(resetAt))"
        return LimitAlert(
            kind: .back, scope: target.id, title: "\(label) is back",
            body: "\(label) \(when). The full limit is available again.",
            reason: early
                ? "the window reset before its scheduled time" : "scheduled for the reset",
            fireAt: early ? nil : resetAt,
            expiresAt: resetAt.addingTimeInterval(early ? 6 * 3600 : 3600))
    }

    static func login(
        _ provider: LimitProvider, _ problem: LimitLoginProblem, clock: LimitAlertClock
    )
        -> LimitAlert
    {
        let label = provider.label
        let fix: String
        let title: String
        switch (provider, problem) {
        case (.claude, .expired):
            title = "Claude session expired"
            fix = "Run claude in a terminal and log in again."
        case (.claude, .missing):
            title = "Claude login not found"
            fix = "Run claude and sign in so Edith can read your limits."
        case (.claude, .denied):
            title = "Claude can't share usage"
            fix = "Run claude auth login --claudeai so Edith can read your limits."
        case (.codex, .expired):
            title = "Codex session expired"
            fix = "Run codex login in a terminal."
        case (.codex, .missing):
            title = "Codex login not found"
            fix = "Run codex login so Edith can read your limits."
        case (.codex, .denied):
            title = "Codex can't share usage"
            fix = "Run codex login again so Edith can read your limits."
        case (.cursor, .expired):
            title = "Cursor session expired"
            fix = "Open Cursor and sign in again."
        case (.cursor, .missing):
            title = "Cursor login not found"
            fix = "Open Cursor and sign in so Edith can read your limits."
        case (.cursor, .denied):
            title = "Cursor can't share usage"
            fix = "Open Cursor and sign in again so Edith can read your limits."
        case (.grok, .expired):
            title = "Grok session expired"
            fix = "Run grok login in a terminal."
        case (.grok, .missing):
            title = "Grok login not found"
            fix = "Run grok login so Edith can read your allowance."
        case (.grok, .denied):
            title = "Grok can't share usage"
            fix = "Run grok login again so Edith can read your allowance."
        }
        return LimitAlert(
            kind: .login, scope: provider.rawValue, title: title,
            body: "\(fix) \(label) limit alerts resume once it works.",
            reason: "\(label) reported a \(problem.rawValue) login",
            expiresAt: clock.now.addingTimeInterval(86_400))
    }

    static func facts(
        _ a: LimitAlertAssessment, entry: LimitAlertLedger.Entry, clock: LimitAlertClock,
        recentlyActive: Bool
    ) -> [String: String] {
        let last = entry.sent.values.max()
        return [
            "provider": a.target.provider.label,
            "window": a.target.slot.title(for: a.target.provider),
            "percent": String(Int(a.window.percent.rounded())),
            "burn_per_hour": a.burn.map { String(format: "%.1f", $0.perHour) } ?? "unknown",
            "projected_cap": a.projectedCapAt.map(clock.moment) ?? "none",
            "resets_at": a.window.resetsAt.map(clock.moment) ?? "unknown",
            "minutes_since_last_alert": last.map {
                String(Int(clock.now.timeIntervalSince($0) / 60))
            } ?? "never",
            "local_hour": String(clock.hour),
            "recently_active": recentlyActive ? "yes" : "no",
        ]
    }
}
