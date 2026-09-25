import Foundation

public enum LimitAlertInspector {
    public static func inspect(
        clock: LimitAlertClock = LimitAlertClock(), defaults: UserDefaults = SharedDefaults.store,
        historyURL: URL = LimitsHistory.url, ledger: LimitAlertLedger? = LimitAlertLedger.load()
    ) -> [LimitAlertVerdict] {
        let now = clock.now
        var settings = LimitAlertSettings.fromDefaults(defaults)
        settings.master = true
        let latest = LimitsHistory.latestProviders(url: historyURL)
        let samples = LimitsHistory.alertSamples(
            since: now.addingTimeInterval(-LimitAlertPlanner.historySpan), url: historyURL)
        let assessments = LimitAlertTarget.all.compactMap { target -> LimitAlertAssessment? in
            guard settings.tracks(target),
                let window = latest[target.provider]?.window(for: target.slot),
                (window.resetsAt ?? .distantFuture) > now
            else { return nil }
            return LimitAlertPlanner.assess(
                target, window: window, samples: samples[target] ?? [], now: now)
        }
        return LimitAlertPlanner.plan(
            assessments, ledger: ledger ?? LimitAlertLedger(), settings: settings, clock: clock
        ).verdicts
    }

    public static func previewLines() async -> [String] {
        await Task.detached(priority: .utility) {
            let clock = LimitAlertClock()
            return inspect(clock: clock).map { $0.summary(clock: clock) }
        }.value
    }
}

extension LimitAlertVerdict {
    public func summary(clock: LimitAlertClock) -> String {
        let a = assessment
        var parts = ["\(Int(a.window.percent.rounded()))%"]
        if let burn = a.burn, a.active {
            parts.append(String(format: "%.1f%% an hour", burn.perHour))
        } else {
            parts.append("idle")
        }
        if a.active, let cap = a.projectedCapAt, let reset = a.window.resetsAt, cap < reset {
            parts.append("cap around " + clock.moment(cap))
        } else if let reset = a.window.resetsAt {
            parts.append("resets " + clock.moment(reset))
        }
        return a.target.label + ": " + parts.joined(separator: ", ")
    }
}

extension LimitsHistory.Latest {
    public func window(for slot: LimitWindowSlot) -> LimitWindow? {
        switch slot {
        case .session: session
        case .week: week
        case .fable: fable
        }
    }
}
